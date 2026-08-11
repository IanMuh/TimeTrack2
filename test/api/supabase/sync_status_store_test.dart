import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:timetrack2/api/supabase/sync_backend.dart';
import 'package:timetrack2/api/supabase/sync_status_store.dart';
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

    test('markFailure 只记错误、不清游标', () async {
      final db = AppDatabase(NativeDatabase.memory());
      try {
        final store = SyncStatusStore(database: db);
        await store.markSuccess(
          syncedAt: DateTime(2026, 8, 11, 10),
          target: SyncTarget.supabase,
        );
        await store.markFailure('同步失败：网络中断');
        final status = (await store.read()).requireValue();
        expect(status.lastError, '同步失败：网络中断');
        expect(status.lastSuccessfulSyncAt, isNotNull,
            reason: '失败不清游标');
        expect(status.lastTarget, SyncTarget.supabase);
      } finally {
        await db.close();
      }
    });

    test('markSuccess 单调性：旧游标不覆盖新游标（防并发回退）', () async {
      final db = AppDatabase(NativeDatabase.memory());
      try {
        final store = SyncStatusStore(database: db);
        final t0 = DateTime(2026, 8, 11, 10);
        final t1 = t0.add(const Duration(minutes: 5));
        await store.markSuccess(syncedAt: t1, target: SyncTarget.supabase);

        // 乱序完成的旧同步（syncedAt 早于现有游标）→ 不覆盖游标
        await store.markSuccess(syncedAt: t0, target: SyncTarget.supabase);
        var status = (await store.read()).requireValue();
        expect(
          status.lastSuccessfulSyncAt!.isAtSameMomentAs(t1),
          isTrue,
          reason: '旧 syncedAt 不得回退已推进的游标',
        );
        // 仍清错误/记目标（乱序完成也视为一次成功）
        expect(status.lastError, isNull);
        expect(status.lastTarget, SyncTarget.supabase);
      } finally {
        await db.close();
      }
    });

    test('read：损坏游标值显式失败（不静默降级为全量）', () async {
      final db = AppDatabase(NativeDatabase.memory());
      try {
        final store = SyncStatusStore(database: db);
        await db.into(db.appMetadata).insert(AppMetadataCompanion.insert(
          key: 'last_sync_at',
          value: 'not-a-date',
        ));
        final result = await store.read();
        expect(result.isSuccess, isFalse);
        expect(
          result.when(onSuccess: (_) => '', onFailure: (m) => m),
          contains('损坏'),
          reason: '损坏游标应显式报错，不得当"从未同步"触发全量',
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
      // 多订阅者可用（broadcast 契约）：各订阅者都立即收到 null。
      await expectLater(backend.authStateStream, emits(null));
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
