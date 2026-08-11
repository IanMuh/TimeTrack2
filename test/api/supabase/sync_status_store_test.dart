import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:timetrack2/api/supabase/sync_backend.dart';
import 'package:timetrack2/api/supabase/sync_status_store.dart';
import 'package:timetrack2/constants/storage_keys.dart';
import 'package:timetrack2/data/database/app_database.dart';

void main() {
  group('SyncStatusStore（app_metadata 读写）', () {
    test('默认状态：从未同步（游标 null / 无错误 / 无目标）', () async {
      final db = AppDatabase(NativeDatabase.memory());
      try {
        final store = SyncStatusStore(database: db);
        final status = (await store.read()).requireValue();
        expect(status.hasSynced, isFalse);
        expect(status.lastSuccessfulSyncAt, isNull);
        expect(status.lastError, isNull);
        expect(status.lastTarget, isNull);
      } finally {
        await db.close();
      }
    });

    test('markSuccess 推进游标 + 清错误 + 记目标（幂等覆盖）', () async {
      final db = AppDatabase(NativeDatabase.memory());
      try {
        final store = SyncStatusStore(database: db);
        await store.markFailure('先前的失败');
        // 相对当前时间构造（防 markSuccess 的"不晚于 now+5min"校验误判）。
        final syncedAt = DateTime.now().toUtc().subtract(const Duration(minutes: 30));
        await store.markSuccess(syncedAt: syncedAt, target: SyncTarget.supabase);
        final status = (await store.read()).requireValue();
        expect(
          status.lastSuccessfulSyncAt!.isAtSameMomentAs(syncedAt),
          isTrue,
        );
        expect(status.lastError, isNull, reason: '成功后清错误');
        expect(status.lastTarget, SyncTarget.supabase);

        // 更晚时间戳再次 markSuccess：游标真正推进则覆盖（幂等覆盖旧游标）
        final later = syncedAt.add(const Duration(minutes: 5));
        await store.markSuccess(syncedAt: later, target: SyncTarget.supabase);
        final again = (await store.read()).requireValue();
        expect(
          again.lastSuccessfulSyncAt!.isAtSameMomentAs(later),
          isTrue,
          reason: '更晚 syncedAt 推进游标（覆盖旧游标）',
        );
      } finally {
        await db.close();
      }
    });

    test('markFailure 只记错误、不清游标（精确值）', () async {
      final db = AppDatabase(NativeDatabase.memory());
      try {
        final store = SyncStatusStore(database: db);
        final syncedAt = DateTime.now().toUtc().subtract(const Duration(minutes: 30));
        await store.markSuccess(syncedAt: syncedAt, target: SyncTarget.supabase);
        await store.markFailure('同步失败：网络中断');
        final status = (await store.read()).requireValue();
        expect(status.lastError, '同步失败：网络中断');
        expect(
          status.lastSuccessfulSyncAt!.isAtSameMomentAs(syncedAt),
          isTrue,
          reason: '失败不清游标（游标值必须保持不变，非仅非空）',
        );
        expect(status.lastTarget, SyncTarget.supabase);
      } finally {
        await db.close();
      }
    });

    test('markSuccess 单调性：乱序完成不覆盖游标/目标，且仍清错误', () async {
      final db = AppDatabase(NativeDatabase.memory());
      try {
        final store = SyncStatusStore(database: db);
        final t0 = DateTime.now().toUtc().subtract(const Duration(minutes: 30));
        final t1 = t0.add(const Duration(minutes: 5));
        await store.markSuccess(syncedAt: t1, target: SyncTarget.supabase);
        await store.markFailure('先前失败'); // 先设错误，验证乱序分支保留

        // 乱序完成的旧同步（syncedAt 早于现有游标）→ 不覆盖游标/目标
        await store.markSuccess(syncedAt: t0, target: 'other-target');
        var status = (await store.read()).requireValue();
        expect(
          status.lastSuccessfulSyncAt!.isAtSameMomentAs(t1),
          isTrue,
          reason: '旧 syncedAt 不得回退已推进的游标',
        );
        expect(status.lastTarget, SyncTarget.supabase,
            reason: '乱序完成不得把目标覆盖为旧同步的目标（与游标指向的'
                '最近成功点保持一致）');
        expect(status.lastError, '先前失败',
            reason: '乱序完成**保留** lastError——较早开始的慢同步乱序完成不得'
                '抹掉更新的失败记录（"错误反映最近一次失败"语义）');
      } finally {
        await db.close();
      }
    });

    test('markSuccess 并发交错：最终游标为较晚时间戳（事务原子性）', () async {
      final db = AppDatabase(NativeDatabase.memory());
      try {
        final store = SyncStatusStore(database: db);
        final t0 = DateTime.now().toUtc().subtract(const Duration(minutes: 30));
        final t1 = t0.add(const Duration(minutes: 5));
        // 并发同时触发 t1/t0 两次 markSuccess：断言最终游标仍为 t1
        //（读-改-写在同一 transaction 内，drift 串行化事务保证原子性）。
        await Future.wait([
          store.markSuccess(syncedAt: t1, target: SyncTarget.supabase),
          store.markSuccess(syncedAt: t0, target: SyncTarget.supabase),
        ]);
        final status = (await store.read()).requireValue();
        expect(
          status.lastSuccessfulSyncAt!.isAtSameMomentAs(t1),
          isTrue,
          reason: '并发完成后游标必须为较晚时间戳（事务原子性）',
        );
      } finally {
        await db.close();
      }
    });

    test('空值防护：markFailure 空串 / markSuccess 空 target 显式失败且保留既有状态', () async {
      final db = AppDatabase(NativeDatabase.memory());
      try {
        final store = SyncStatusStore(database: db);
        final syncedAt = DateTime.now().toUtc().subtract(const Duration(minutes: 30));
        await store.markSuccess(syncedAt: syncedAt, target: SyncTarget.supabase);
        await store.markFailure('真实错误');

        expect((await store.markFailure('')).isSuccess, isFalse,
            reason: '空失败原因拒绝（防静默清掉已有错误）');
        expect((await store.markFailure('   ')).isSuccess, isFalse);
        expect(
          (await store.markSuccess(
            syncedAt: DateTime.now().toUtc().subtract(const Duration(minutes: 20)),
            target: '  ',
          ))
              .isSuccess,
          isFalse,
          reason: '空 target 拒绝',
        );

        // 拒绝调用不得产生副作用：错误/游标/目标均保持原值。
        final status = (await store.read()).requireValue();
        expect(status.lastError, '真实错误');
        expect(status.lastSuccessfulSyncAt!.isAtSameMomentAs(syncedAt), isTrue);
        expect(status.lastTarget, SyncTarget.supabase);
      } finally {
        await db.close();
      }
    });

    test('markSuccess 遇损坏游标显式失败（不静默重置且无部分写入）', () async {
      final db = AppDatabase(NativeDatabase.memory());
      try {
        final store = SyncStatusStore(database: db);
        await db.into(db.appMetadata).insert(AppMetadataCompanion.insert(
          key: AppMetadataKeys.lastSyncAt,
          value: 'not-a-date',
        ));
        final result = await store.markSuccess(
          syncedAt: DateTime.now().toUtc().subtract(const Duration(minutes: 30)),
          target: SyncTarget.supabase,
        );
        expect(result.isSuccess, isFalse,
            reason: '损坏游标下 markSuccess 显式失败，不静默重置');

        // 失败路径不得产生部分写入：损坏值保持原样，目标/错误键不被触碰。
        final rows = await db.select(db.appMetadata).get();
        expect(
          rows.where((r) => r.key == AppMetadataKeys.lastSyncAt).single.value,
          'not-a-date',
        );
        expect(
          rows.any((r) => r.key == AppMetadataKeys.lastSyncTarget),
          isFalse,
        );
        expect(
          rows.any((r) => r.key == AppMetadataKeys.lastSyncError),
          isFalse,
        );
      } finally {
        await db.close();
      }
    });

    test('游标按 userId 分区：不同用户互不影响，null 回落全局键', () async {
      final db = AppDatabase(NativeDatabase.memory());
      try {
        final store = SyncStatusStore(database: db);
        final tA = DateTime.now().toUtc().subtract(const Duration(minutes: 30));
        final tB = tA.add(const Duration(minutes: 5));
        await store.markSuccess(syncedAt: tA, target: SyncTarget.supabase,
            userId: 'user-A');
        await store.markSuccess(syncedAt: tB, target: SyncTarget.supabase,
            userId: 'user-B');

        // A/B 各自读到自己游标
        final aStatus =
            (await store.read(userId: 'user-A')).requireValue();
        expect(aStatus.lastSuccessfulSyncAt!.isAtSameMomentAs(tA), isTrue);
        final bStatus =
            (await store.read(userId: 'user-B')).requireValue();
        expect(bStatus.lastSuccessfulSyncAt!.isAtSameMomentAs(tB), isTrue);
        // null 写入回落全局键：全局 read 能读到，且不影响用户分区
        final tG = tB.add(const Duration(minutes: 5));
        await store.markSuccess(syncedAt: tG, target: SyncTarget.supabase,
            userId: null);
        final global = (await store.read()).requireValue();
        expect(global.lastSuccessfulSyncAt!.isAtSameMomentAs(tG), isTrue,
            reason: 'null userId 写入应落到全局键');
        // 全局键写入不得影响用户分区
        final aAfter2 =
            (await store.read(userId: 'user-A')).requireValue();
        expect(aAfter2.lastSuccessfulSyncAt!.isAtSameMomentAs(tA), isTrue);
        // B 的写入不覆盖 A（分区隔离）
        final aAfter =
            (await store.read(userId: 'user-A')).requireValue();
        expect(aAfter.lastSuccessfulSyncAt!.isAtSameMomentAs(tA), isTrue,
            reason: '用户 B 的同步不得推进用户 A 的游标');

        // lastError 分区隔离：A 的失败不被 B 读到、A 的 markSuccess 不清 B 的错误
        await store.markFailure('A 失败', userId: 'user-A');
        final aErr = (await store.read(userId: 'user-A')).requireValue();
        expect(aErr.lastError, 'A 失败');
        final bErr = (await store.read(userId: 'user-B')).requireValue();
        expect(bErr.lastError, isNull, reason: 'B 不得读到 A 的失败原因');
        // A 推进游标（更晚时间戳）→ 清 A 的错误，B 的错误不受影响
        final tA2 = tA.add(const Duration(minutes: 30));
        await store.markFailure('B 失败', userId: 'user-B');
        await store.markSuccess(syncedAt: tA2, target: SyncTarget.supabase,
            userId: 'user-A');
        final aAfter3 = (await store.read(userId: 'user-A')).requireValue();
        expect(aAfter3.lastError, isNull, reason: 'A 推进清 A 的错误');
        final bAfter3 = (await store.read(userId: 'user-B')).requireValue();
        expect(bAfter3.lastError, 'B 失败',
            reason: 'A 的 markSuccess 不得清 B 的错误');
      } finally {
        await db.close();
      }
    });

    test('相等时间戳分支：不覆盖游标、更新目标、保留错误', () async {
      final db = AppDatabase(NativeDatabase.memory());
      try {
        final store = SyncStatusStore(database: db);
        final t0 = DateTime.now().toUtc().subtract(const Duration(minutes: 30));
        await store.markSuccess(syncedAt: t0, target: SyncTarget.supabase);
        await store.markFailure('失败');

        // 相等时间戳：游标不覆盖、lastTarget 更新为本次目标、lastError 保留
        await store.markSuccess(syncedAt: t0, target: 'other-target');
        final status = (await store.read()).requireValue();
        expect(status.lastSuccessfulSyncAt!.isAtSameMomentAs(t0), isTrue);
        expect(status.lastTarget, 'other-target',
            reason: '相等分支更新 lastTarget（空跑反映本次目标）');
        expect(status.lastError, '失败',
            reason: '相等分支保留 lastError（游标未推进，不清真实失败）');
      } finally {
        await db.close();
      }
    });

    test('未来时间守卫：read 与 markSuccess 均显式失败（需重置）', () async {
      final db = AppDatabase(NativeDatabase.memory());
      try {
        final store = SyncStatusStore(database: db);
        final future = DateTime.now()
            .toUtc()
            .add(const Duration(minutes: 30));
        // markSuccess 拒绝未来 syncedAt
        final rejected = await store.markSuccess(
          syncedAt: future,
          target: SyncTarget.supabase,
        );
        expect(rejected.isSuccess, isFalse, reason: '未来 syncedAt 拒绝');
        expect(
          rejected.when(onSuccess: (_) => '', onFailure: (m) => m),
          contains('不合理'),
        );
        // read 拒绝未来存储游标
        await db.into(db.appMetadata).insert(AppMetadataCompanion.insert(
          key: AppMetadataKeys.lastSyncAt,
          value: future.toIso8601String(),
        ));
        final readResult = await store.read();
        expect(readResult.isSuccess, isFalse, reason: '未来游标 read 显式失败');
        expect(
          readResult.when(onSuccess: (_) => '', onFailure: (m) => m),
          contains('需重置'),
        );
      } finally {
        await db.close();
      }
    });

    test('read：损坏游标值显式失败（不静默降级为全量）', () async {
      final db = AppDatabase(NativeDatabase.memory());
      try {
        final store = SyncStatusStore(database: db);
        // 键名用常量（防键名变更后测试失真），断言语义不绑定具体文案。
        await db.into(db.appMetadata).insert(AppMetadataCompanion.insert(
          key: AppMetadataKeys.lastSyncAt,
          value: 'not-a-date',
        ));
        final result = await store.read();
        expect(result.isSuccess, isFalse, reason: '损坏游标应显式失败');
        expect(
          result.when(onSuccess: (_) => '', onFailure: (m) => m),
          contains('not-a-date'),
          reason: '失败信息应包含损坏的原值',
        );
      } finally {
        await db.close();
      }
    });

    test('reset：清除分区游标/目标/错误（损坏/未来游标恢复入口）', () async {
      final db = AppDatabase(NativeDatabase.memory());
      try {
        final store = SyncStatusStore(database: db);
        // 先建立状态：损坏游标 + 目标 + 错误
        await db.into(db.appMetadata).insert(AppMetadataCompanion.insert(
          key: AppMetadataKeys.lastSyncAt,
          value: 'not-a-date',
        ));
        await db.into(db.appMetadata).insert(AppMetadataCompanion.insert(
          key: AppMetadataKeys.lastSyncTarget,
          value: SyncTarget.supabase,
        ));
        await store.markFailure('损坏前的失败');
        // read 此时失败（损坏游标）
        expect((await store.read()).isSuccess, isFalse);

        // reset 后恢复可用（从未同步状态）
        expect((await store.reset()).isSuccess, isTrue);
        final status = (await store.read()).requireValue();
        expect(status.lastSuccessfulSyncAt, isNull, reason: '游标已清除');
        expect(status.lastTarget, isNull);
        expect(status.lastError, isNull, reason: '错误已清除');

        // reset 后可正常 markSuccess（恢复到可用状态）
        final t = DateTime.now().toUtc().subtract(const Duration(minutes: 30));
        expect(
          (await store.markSuccess(
            syncedAt: t,
            target: SyncTarget.supabase,
          ))
              .isSuccess,
          isTrue,
        );
        // reset 按分区：user-A 的 reset 不影响 user-B
        await store.markSuccess(
          syncedAt: t.add(const Duration(minutes: 1)),
          target: SyncTarget.supabase,
          userId: 'user-B',
        );
        expect((await store.reset(userId: 'user-A')).isSuccess, isTrue);
        final bAfter = (await store.read(userId: 'user-B')).requireValue();
        expect(bAfter.lastSuccessfulSyncAt, isNotNull,
            reason: 'user-A 的 reset 不得清 user-B 状态');
      } finally {
        await db.close();
      }
    });
  });

  group('SyncBackend / NoopSyncBackend', () {
    test('NoopSyncBackend：未配置时全离线语义', () async {
      final backend = NoopSyncBackend();
      expect(backend.isConfigured, isFalse);
      expect(backend.currentUserId, isNull);
      expect(
        (await backend.sendMagicLink('a@b.com')).isSuccess,
        isFalse,
        reason: '未配置发码失败',
      );
      expect(
        (await backend.verifyEmailOtp('a@b.com', '123456')).isSuccess,
        isFalse,
      );
      expect((await backend.syncNow()).isSuccess, isFalse);
      expect((await backend.signOut()).isSuccess, isFalse,
          reason: '未配置场景登出返回失败（与其余方法一致，防误判登出成功）');
      // 登录态流：订阅即收到 null（未登录）——确定性等待（不依赖固定延时）。
      await expectLater(backend.authStateStream, emits(null));
      // 多订阅者**并发**监听同一流实例：均立即收到 null（broadcast 契约）。
      final stream = backend.authStateStream;
      await Future.wait([
        expectLater(stream, emits(null)),
        expectLater(stream, emits(null)),
      ]);
    });

    test('SyncReport 携带目标/全量标记/行数', () {
      const report = SyncReport(
        target: SyncTarget.supabase,
        wasFullSync: true,
        pulledRows: 5,
        pushedRows: 3,
      );
      expect(report.target, SyncTarget.supabase);
      expect(report.wasFullSync, isTrue);
      expect(report.pulledRows, 5);
      expect(report.pushedRows, 3);
      expect(report.toString(), contains('supabase'));
    });
  });
}
