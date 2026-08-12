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

    test('从未同步时 markFailure：错误写入、hasSynced 保持 false、后续成功清错误', () async {
      final db = AppDatabase(NativeDatabase.memory());
      try {
        final store = SyncStatusStore(database: db);
        // 无游标直接 markFailure
        await store.markFailure('首次失败');
        var status = (await store.read()).requireValue();
        expect(status.lastError, '首次失败', reason: '无游标时错误仍写入');
        expect(status.hasSynced, isFalse, reason: '失败不清游标（仍从未同步）');
        expect(status.lastTarget, isNull);

        // 后续成功：游标推进 + 错误清除
        final t = DateTime.now().toUtc().subtract(const Duration(minutes: 30));
        await store.markSuccess(syncedAt: t, target: SyncTarget.supabase);
        status = (await store.read()).requireValue();
        expect(status.hasSynced, isTrue, reason: '成功后 hasSynced 为 true');
        expect(status.lastError, isNull, reason: '成功清错误');
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

    test('markSuccess 单调性：乱序完成不覆盖游标/目标，且仍保留错误', () async {
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

    test('markSuccess 并发交错：最终游标为较晚时间戳（事务原子性，每轮全新库）', () async {
      final t0 = DateTime.now().toUtc().subtract(const Duration(minutes: 30));
      final t1 = t0.add(const Duration(minutes: 5));
      // 循环多轮、**每轮全新库**：读-改-写若非事务，两调用谁先读谁先写取决于
      // 真实调度，首轮可能"侥幸通过"——多轮显著提高原子性回归的检出概率。
      // （复用同一库会让首轮后游标已推进，后续轮次全走相等分支，失去检出力。）
      for (var round = 0; round < 10; round++) {
        final db = AppDatabase(NativeDatabase.memory());
        try {
          final store = SyncStatusStore(database: db);
          await Future.wait([
            store.markSuccess(syncedAt: t1, target: SyncTarget.supabase),
            store.markSuccess(syncedAt: t0, target: SyncTarget.supabase),
          ]);
          final status = (await store.read()).requireValue();
          expect(status.lastSuccessfulSyncAt, isNotNull,
              reason: '并发完成后游标不得丢失（第 $round 轮）');
          expect(
            status.lastSuccessfulSyncAt!.isAtSameMomentAs(t1),
            isTrue,
            reason: '并发完成后游标必须为较晚时间戳（事务原子性，第 $round 轮）',
          );
        } finally {
          await db.close();
        }
      }
    });

    test('markSuccess（推进）× markFailure 并发交错：不抛错且终态自洽（冒烟守护）', () async {
      final t = DateTime.now().toUtc().subtract(const Duration(minutes: 30));
      // 循环多轮、每轮全新库：markFailure 与 markSuccess 并发交错。
      // **守护定位（r32 明确）**：本用例是**并发冒烟守护**——并发调度不可控，
      // "无论顺序都清错"的 LWW 缺陷无法在此确定性检出（错误为 null 是合法
      // 终态之一）；顺序敏感的 LWW 语义由**确定性用例**锁定（"推进后失败
      // 保留错误/失败后推进清错"分别见 markFailure 保留游标、从未同步失败
      // 后成功清错、相等/乱序分支保留错误用例）。本用例只守护并发下不抛错、
      // 游标/错误键终态自洽（不出现矛盾组合）。
      for (var round = 0; round < 10; round++) {
        final db = AppDatabase(NativeDatabase.memory());
        try {
          final store = SyncStatusStore(database: db);
          await Future.wait([
            store.markSuccess(syncedAt: t, target: SyncTarget.supabase),
            store.markFailure('并发失败（第 $round 轮）'),
          ]);
          final status = (await store.read()).requireValue();
          expect(status.lastSuccessfulSyncAt, isNotNull,
              reason: '并发成功×失败后游标不得丢失（第 $round 轮）');
          expect(
            status.lastSuccessfulSyncAt!.isAtSameMomentAs(t),
            isTrue,
            reason: '并发成功×失败后游标仍为 t（第 $round 轮）',
          );
          // lastError 合法终态之一：清除（成功晚于失败）或保留最近失败
          //（失败晚于成功写回）——两者都是合法 LWW 结果。
          final error = status.lastError;
          expect(
            error == null || error.startsWith('并发失败'),
            isTrue,
            reason: 'lastError 必须为合法 LWW 终态：清除或保留最近失败'
                '（第 $round 轮，实际：$error）',
          );
        } finally {
          await db.close();
        }
      }
    });

    test('userId 契约（r12 行为变更）：空/空白/超长 userId 直接抛 ArgumentError', () async {
      final db = AppDatabase(NativeDatabase.memory());
      try {
        final store = SyncStatusStore(database: db);
        final t = DateTime.now().toUtc().subtract(const Duration(minutes: 30));
        // 空/空白/超长是调用方编程错误：入口直接抛（不被包成 AppFailure）——
        // 防编程错误被静默降级为普通运行期数据错误；null 仍走全局键（合法）。
        // **空白覆盖**：含 \t/\n 等其它空白字符（String.trim 一并剥离；
        // 若回归为仅剥离空格的自定义 trim 可检出）+ trim 后超长（
        // `' ' + 'x'*129` trim 后 129 仍抛——固化"先 trim 后判长"顺序）。
        for (final bad in [
          '',
          '   ',
          '\t',
          '\n',
          'x' * 129,
          ' ${'x' * 129}', // trim 后 129 仍抛（固化"先 trim 后判长"顺序）
        ]) {
          await expectLater(store.read(userId: bad), throwsArgumentError,
              reason: 'read 空/超长 userId 直接抛：$bad');
          await expectLater(
            store.markSuccess(syncedAt: t, target: SyncTarget.supabase,
                userId: bad),
            throwsArgumentError,
            reason: 'markSuccess 空/超长 userId 直接抛：$bad',
          );
          await expectLater(
            store.markFailure('失败', userId: bad),
            throwsArgumentError,
            reason: 'markFailure 空/超长 userId 直接抛：$bad',
          );
          await expectLater(store.reset(userId: bad), throwsArgumentError,
              reason: 'reset 空/超长 userId 直接抛：$bad');
        }
        // null = 未登录用全局键：合法，不抛。
        expect((await store.read()).isSuccess, isTrue);
        // **无污染断言**：非法输入循环后，全局状态必须仍为
        // "从未同步"且游标/错误/目标三字段均 null——固化"校验发生在任何写
        // 操作之前"的顺序契约（防"先写后校验"污染 lastError/lastTarget 时
        // 仅查 hasSynced 漏检）。
        final afterBad = (await store.read()).requireValue();
        expect(afterBad.lastSuccessfulSyncAt, isNull,
            reason: '非法 userId 校验失败不得产生任何写副作用（游标）');
        expect(afterBad.lastError, isNull,
            reason: '非法 userId 校验失败不得产生任何写副作用（错误）');
        expect(afterBad.lastTarget, isNull,
            reason: '非法 userId 校验失败不得产生任何写副作用（目标）');
        // **整表零写入（r45）**：超长非空 userId 若走"先写后校验"会写独立
        // 分区键（lastSyncAt:xxx...），全局 read 观察不到——查全表才能覆盖
        // 分区侧写副作用（库全新，非法输入循环后应零写入）。
        expect(await db.select(db.appMetadata).get(), isEmpty,
            reason: '非法 userId 校验失败不得产生任何分区写副作用');

        // 合法边界（防阈值误改 `>= 128` 或空串误判）：恰好 128 长度与 1 字符
        // 都是合法 userId（trim 后不改变长度、不超上限）。
        // **先 trim 后判长（r33/r36 修正）**：`' ${'x' * 127} '` 原始 129 > 128、
        // trim 后 127 ≤ 128 应成功写入；`' ${'x' * 128} '` 原始 130、trim 后
        // 恰好 128 也应合法——完整锁定"先 trim 后判长"在阈值 128 处的包含
        // 关系（回归为先判长后 trim 会误拒绝）。
        for (final ok in ['a', 'x' * 128, ' ${'x' * 127} ', ' ${'x' * 128} ']) {
          expect(
            (await store.markSuccess(
              syncedAt: t,
              target: SyncTarget.supabase,
              userId: ok,
            ))
                .isSuccess,
            isTrue,
            reason: '合法 userId 正常读写：$ok',
          );
          expect((await store.read(userId: ok)).requireValue().hasSynced, isTrue);
        }

        // **trim 归一化验证（双向交叉读写）**：锁读侧与写侧都必须 trim——
        // 单向用例（写入带空白/读取已 trim）无法防"仅单侧 trim"的回归。
        // 方向 1：写入带空白、读取已 trim（锁写侧 trim）
        await store.markSuccess(
          syncedAt: t,
          target: SyncTarget.supabase,
          userId: '  user-1  ',
        );
        expect(
          (await store.read(userId: 'user-1')).requireValue().hasSynced,
          isTrue,
          reason: '带空白写入 / trim 后读取命中同一分区键',
        );
        // 方向 2：写入已 trim、读取带空白（锁读侧 trim）
        await store.markSuccess(
          syncedAt: t,
          target: SyncTarget.supabase,
          userId: 'user-2',
        );
        expect(
          (await store.read(userId: '  user-2  ')).requireValue().hasSynced,
          isTrue,
          reason: 'trim 后写入 / 带空白读取命中同一分区键',
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
          contains(SyncStatusMessages.cursorUnreasonable),
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
          contains(SyncStatusMessages.cursorUnreasonable),
          reason: '失败信息包含"游标不合理"常量前缀（不绑定具体文案）',
        );
      } finally {
        await db.close();
      }
    });

    test('未来时间容差边界（r53）：+4min 接受 / 恰好 +5min 接受 / +6min 拒绝', () async {
      // **容差窗口边界锁定**：生产守卫是 `isAfter(now + 5min)`——+4min 应
      // 接受、恰好 +5min（isAfter 为 false）应接受、+6min 应拒绝。若实现把
      // 容差误改为 0 或 10 分钟，现有"仅 +30min 拒绝"用例无法检出。
      // **flaky 防抖（r53）**：守卫按**每次 markSuccess 调用时刻**的 now
      // 计算——base 只在开头捕获会让 +6min 用例在慢速 CI/时钟回拨下漂移
      //（base+6min 不再晚于 now+5min 而误接受）；每次调用前用最新 now
      // 构造 syncedAt，把漂移窗口缩到微秒级。
      final db = AppDatabase(NativeDatabase.memory());
      try {
        final store = SyncStatusStore(database: db);
        // +4min：接受（游标写入成功）
        final plus4 = await store.markSuccess(
          syncedAt: DateTime.now().toUtc().add(const Duration(minutes: 4)),
          target: SyncTarget.supabase,
        );
        expect(plus4.isSuccess, isTrue, reason: '+4min（容差内）接受');
        // 恰好 +5min：isAfter(now+5min) 为 false → 接受
        final plus5 = await store.markSuccess(
          syncedAt: DateTime.now().toUtc().add(const Duration(minutes: 5)),
          target: SyncTarget.supabase,
        );
        expect(plus5.isSuccess, isTrue, reason: '恰好 +5min（isAfter 边界）接受');
        // +6min：拒绝（超出容差）
        final plus6 = await store.markSuccess(
          syncedAt: DateTime.now().toUtc().add(const Duration(minutes: 6)),
          target: SyncTarget.supabase,
        );
        expect(plus6.isSuccess, isFalse, reason: '+6min（超容差）拒绝');
      } finally {
        await db.close();
      }
    });

    test('容差内未来游标自愈（r52）：时钟校正后首个真实同步回退游标', () async {
      // 场景：设备时钟偏快时同步写入游标（容差内 ≤+5min 曾被 read 接受），
      // 随后时钟被向后校正——旧实现下：read 接受未来游标作为 since → 每轮
      // 空跑 → markSuccess 因 syncedAt < existingAt 走 no-op → 游标永不回退
      // → 新数据永久静默漏同步（报告仍显示成功）。r52 修正：existingAt 为
      // 未来时间时允许真实 syncedAt 覆盖回退（自愈，与 >5min 显式失败分支
      // 互补——超容差走 reset，容差内自动恢复）。
      final db = AppDatabase(NativeDatabase.memory());
      try {
        final store = SyncStatusStore(database: db);
        // 模拟时钟偏快时写入的未来游标（容差内，read 会接受）。
        final skewed = DateTime.now()
            .toUtc()
            .add(const Duration(minutes: 3));
        await store.markSuccess(syncedAt: skewed, target: SyncTarget.supabase);
        // **前置条件锁定（r53）**：偏快游标确已落库且被容差接受——防未来
        // 实现收窄写入/读取容差时后续 markSuccess(now) 平凡成功、本测试
        // 未真正覆盖自愈分支也通过（假阳性）。
        final seeded = (await store.read()).requireValue();
        expect(
          seeded.lastSuccessfulSyncAt!.isAtSameMomentAs(skewed),
          isTrue,
          reason: '偏快游标已写入（自愈分支前置条件）',
        );
        // 时钟校正后：真实同步时刻（now）覆盖回退未来游标。
        final healed = await store.markSuccess(
          syncedAt: DateTime.now().toUtc(),
          target: SyncTarget.supabase,
        );
        expect(healed.isSuccess, isTrue, reason: '未来游标可被真实同步覆盖');
        final status = (await store.read()).requireValue();
        expect(status.lastSuccessfulSyncAt, isNotNull);
        expect(
          status.lastSuccessfulSyncAt!.isAfter(DateTime.now().toUtc()),
          isFalse,
          reason: '游标已回退到非未来（自愈完成，不再空跑）',
        );
        // 正常单调性不受影响：更早的 syncedAt 仍不覆盖（乱序保护保留）。
        final earlier = DateTime.now()
            .toUtc()
            .subtract(const Duration(days: 1));
        await store.markSuccess(
          syncedAt: earlier,
          target: SyncTarget.supabase,
        );
        final afterEarly = (await store.read()).requireValue();
        expect(
          afterEarly.lastSuccessfulSyncAt!.isAfter(earlier),
          isTrue,
          reason: '非未来场景乱序 syncedAt 仍不覆盖（单调性保护保留）',
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
      // 登录态流契约：多次访问 getter 返回**同一流实例**（所有订阅者共享
      // 同一事件源）。
      final stream = backend.authStateStream;
      expect(identical(backend.authStateStream, stream), isTrue,
          reason: '多次访问 getter 必须返回同一流实例（契约）');
      // 订阅即收到 null（未登录）——确定性等待（不依赖固定延时）。
      await expectLater(stream, emits(null));
      // 多订阅者**并发**监听同一流实例：均立即收到 null（broadcast 契约）。
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
      // **toString 输出契约（r53）**：逐字段断言字符串表示（防实现只输出
      // target、漏掉其余字段时现有 `contains('supabase')` 仍通过）。
      final text = report.toString();
      expect(text, contains('supabase'));
      expect(text, contains('full: true'));
      expect(text, contains('pulled: 5'));
      expect(text, contains('pushed: 3'));
    });
  });
}
