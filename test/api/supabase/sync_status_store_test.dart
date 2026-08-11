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
        final syncedAt = DateTime(2026, 8, 11, 10, 30);
        await store.markSuccess(syncedAt: syncedAt, target: SyncTarget.supabase);
        final status = (await store.read()).requireValue();
        expect(
          status.lastSuccessfulSyncAt!.isAtSameMomentAs(syncedAt),
          isTrue,
        );
        expect(status.lastError, isNull, reason: '成功后清错误');
        expect(status.lastTarget, SyncTarget.supabase);

        // 再次 markSuccess 覆盖（幂等）
        final later = syncedAt.add(const Duration(minutes: 5));
        await store.markSuccess(syncedAt: later, target: SyncTarget.supabase);
        final again = (await store.read()).requireValue();
        expect(
          again.lastSuccessfulSyncAt!.isAtSameMomentAs(later),
          isTrue,
          reason: '重复 markSuccess 覆盖旧游标',
        );
      } finally {
        await db.close();
      }
    });

    test('markFailure 只记错误、不清游标（精确值）', () async {
      final db = AppDatabase(NativeDatabase.memory());
      try {
        final store = SyncStatusStore(database: db);
        final syncedAt = DateTime(2026, 8, 11, 10);
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

    test('markSuccess 单调性：乱序完成不覆盖游标、不改目标', () async {
      final db = AppDatabase(NativeDatabase.memory());
      try {
        final store = SyncStatusStore(database: db);
        final t0 = DateTime(2026, 8, 11, 10);
        final t1 = t0.add(const Duration(minutes: 5));
        await store.markSuccess(syncedAt: t1, target: SyncTarget.supabase);

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
        expect(status.lastError, isNull);
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
  });

  group('SyncBackend / NoopSyncBackend', () {
    test('NoopSyncBackend：未配置时全离线语义', () async {
      const backend = NoopSyncBackend();
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
      // 多订阅者可用：**同一流实例**可被多个订阅者同时监听并各自收到 null。
      final stream = backend.authStateStream;
      await expectLater(stream, emits(null));
      await expectLater(stream, emits(null));
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
