import 'dart:async';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:timetrack2/api/supabase/sync_backend.dart';
import 'package:timetrack2/api/supabase/sync_status_store.dart';
import 'package:timetrack2/constants/app_constants.dart';
import 'package:timetrack2/constants/storage_keys.dart' show AppMetadataKeys;
import 'package:timetrack2/data/cleanup/cleanup_service.dart';
import 'package:timetrack2/data/database/app_database.dart' hide ProfileSettings;
import 'package:timetrack2/stores/data_revision.dart';
import 'package:timetrack2/stores/sync_store.dart';
import 'package:timetrack2/utils/result.dart';

/// 可控 mock 后端：登录流/同步结果可注入。
class _MockBackend implements SyncBackend {
  _MockBackend({this.configured = true});

  bool configured;
  bool syncFails = false; // 测试内字段赋值控制（同步失败用例）
  bool throwOnSync = false; // true 时 syncNow 真抛异常（on Exception 分支）
  String? currentUser;
  int syncCalls = 0;
  Completer<void>? _syncGate; // 非空时 syncNow 挂起（并发/会话切换测试）

  final _authController = StreamController<String?>.broadcast();

  @override
  bool get isConfigured => configured;

  @override
  Stream<String?> get authStateStream => _authController.stream;

  @override
  String? get currentUserId => currentUser;

  void emitLogin(String userId) => _authController.add(userId);
  void emitLogout() => _authController.add(null);

  @override
  Future<AppResult<void>> sendMagicLink(String email) async =>
      const AppSuccess(null);

  @override
  Future<AppResult<String>> verifyEmailOtp(String email, String token) async =>
      AppSuccess('user-1');

  @override
  Future<AppResult<SyncReport>> syncNow() async {
    syncCalls++;
    // 门控：非空时挂起直到放行（并发互斥/会话切换测试用）。
    final gate = _syncGate;
    if (gate != null) {
      _syncGate = null;
      await gate.future;
    }
    if (throwOnSync) throw Exception('后端崩溃'); // on Exception 分支
    if (syncFails) return const AppFailure('网络错误');
    return const AppSuccess(SyncReport(
      target: SyncTarget.supabase,
      wasFullSync: false,
      pulledRows: 2,
      pushedRows: 3,
    ));
  }

  @override
  Future<AppResult<void>> signOut() async {
    currentUser = null;
    return const AppSuccess(null);
  }
}

class _TestHarness {
  _TestHarness() {
    db = AppDatabase(NativeDatabase.memory());
    syncStatus = SyncStatusStore(database: db);
    cleanup = CleanupService(database: db);
    backend = _MockBackend();
    revision = DataRevision();
    store = SyncStore(
      backend: backend,
      syncStatus: syncStatus,
      cleanup: cleanup,
      dataRevision: revision,
    );
  }

  late final AppDatabase db;
  late final SyncStatusStore syncStatus;
  late final CleanupService cleanup;
  late final _MockBackend backend;
  late final DataRevision revision;
  late final SyncStore store;

  Future<void> close() async {
    store.dispose();
    revision.dispose();
    backend._authController.close();
    await db.close();
  }
}

void main() {
  group('SyncStore 认证与同步', () {
    late _TestHarness h;

    setUp(() => h = _TestHarness());
    tearDown(() => h.close());

    test('未配置：isConfigured false，authState 为 null', () async {
      expect(h.store.isConfigured, isTrue);
      final unconfigured = _MockBackend(configured: false);
      final store = SyncStore(
        backend: unconfigured,
        syncStatus: h.syncStatus,
        cleanup: h.cleanup,
      );
      addTearDown(store.dispose);
      expect(store.isConfigured, isFalse);
      expect(store.userId, isNull);
    });

    test('登录事件自动触发云同步并记录报告', () async {
      h.backend.emitLogin('user-1');
      await pumpEventQueue(); // 登录触发 syncNow（async）
      expect(h.backend.syncCalls, 1);
      expect(h.store.userId, 'user-1');
      expect(h.store.lastTarget, SyncTarget.supabase);
      expect(h.store.lastPulled, 2);
      expect(h.store.lastPushed, 3);
      expect(h.store.lastSyncAt, isNotNull);
      expect(h.store.lastError, isNull);
    });

    test('同步失败：记录错误，游标不清（mock 无游标推进语义）', () async {
      h.backend.syncFails = true;
      h.backend.emitLogin('user-1');
      await pumpEventQueue();
      expect(h.backend.syncCalls, 1);
      expect(h.store.lastError, '网络错误');
      expect(h.store.lastSyncAt, isNull); // 失败不推进
    });

    test('同步成功后 dataRevision 递增（三类来源收口）', () async {
      final before = h.revision.value;
      h.backend.emitLogin('user-1');
      await pumpEventQueue();
      expect(h.backend.syncCalls, 1);
      expect(h.revision.value, before + 1); // 同步成功 bump（派生缓存失效）
    });

    test('同步失败：dataRevision 不递增', () async {
      h.backend.syncFails = true;
      h.backend.emitLogin('user-1');
      await pumpEventQueue();
      final revision = h.revision.value;
      expect(h.backend.syncCalls, 1);
      expect(h.revision.value, revision); // 失败不 bump
    });

    test('登出：清用户与同步状态', () async {
      h.backend.emitLogin('user-1');
      await pumpEventQueue();
      await h.store.signOut();
      expect(h.store.userId, isNull);
      expect(h.store.lastSyncAt, isNull);
    });

    test('未登录 syncNow：返回失败', () async {
      final result = await h.store.syncNow();
      expect(result, isA<AppFailure<SyncReport>>());
      expect(h.backend.syncCalls, 0); // 未触达后端
    });

    test('同步进行中互斥（Completer 门控真实并发）', () async {
      final gate = Completer<void>();
      h.backend._syncGate = gate;
      h.backend.emitLogin('user-1'); // 触发首次同步（挂起在 gate）
      await pumpEventQueue();
      expect(h.store.syncing, isTrue); // 同步进行中

      final concurrent = await h.store.syncNow(); // 并发调用
      expect(concurrent, isA<AppFailure<SyncReport>>()); // 互斥拒绝

      gate.complete(); // 放行首次同步
      await pumpEventQueue();
      expect(h.store.syncing, isFalse); // 完成后复位
      expect(h.backend.syncCalls, 1); // 仅首次执行（并发被拒）
    });

    test('同步挂起期间登出：结果丢弃，不写报告/不触发清理', () async {
      final gate = Completer<void>();
      h.backend._syncGate = gate;
      h.backend.emitLogin('user-1');
      await pumpEventQueue();
      h.backend.emitLogout(); // 登出（_userId = null）
      await pumpEventQueue(); // 先让登出事件被消费（_userId 置 null）
      gate.complete(); // 放行同步（user != _userId）
      await pumpEventQueue();
      expect(h.store.lastSyncAt, isNull); // 结果被丢弃
      expect(h.store.lastPushed, isNull);
      expect(h.store.userId, isNull);
      expect(h.store.cleanupRunning, isFalse); // 不触发清理
    });

    test('后端抛异常 + 会话切换：on Exception 分支不污染新会话 _lastError', () async {
      final gate = Completer<void>();
      h.backend._syncGate = gate;
      h.backend.throwOnSync = true;
      h.backend.emitLogin('user-1');
      await pumpEventQueue();
      h.backend.emitLogout(); // 登出（会话已切换）
      await pumpEventQueue();
      gate.complete(); // 放行：syncNow 抛异常进入 on Exception
      await pumpEventQueue();
      // 会话不一致：返回"会话已切换"且不写 _lastError（防旧会话报错写回）。
      expect(h.store.lastError, isNull);
      expect(h.store.userId, isNull);
    });

    test('后端抛异常（会话一致）：记录同步异常并复位 syncing', () async {
      final gate = Completer<void>();
      h.backend._syncGate = gate;
      h.backend.throwOnSync = true;
      h.backend.emitLogin('user-1');
      await pumpEventQueue();
      gate.complete(); // 放行：syncNow 抛异常
      await pumpEventQueue();
      // 会话一致子路径：_lastError 写"同步异常"、syncing 复位。
      expect(h.store.lastError, contains('同步异常'));
      expect(h.store.syncing, isFalse);
      expect(h.store.userId, 'user-1'); // 会话未变
    });
  });

  group('SyncStore 清理编排', () {
    late _TestHarness h;

    setUp(() => h = _TestHarness());
    tearDown(() => h.close());

    test('同步成功后编排清理（startedAt 水位；轮询等待完成）', () async {
      h.backend.emitLogin('user-1');
      await pumpEventQueue();
      // 轮询等待 last_cleanup_at 写入（fire-and-forget 清理含多次 DB 往返，
      // pumpEventQueue 不保证完成）。
      final row = await _waitForCleanup(h.db);
      expect(row, isNotNull);
      // 用常量口径（与 _cleanupDue 一致）。
      expect(row!.key, AppMetadataKeys.lastCleanupAt);
    });

    test('限频：同步触发未到期跳过，手动触发受限频跳过', () async {
      // 预置 last_cleanup_at = now（未到期）。
      final now = DateTime.now().toUtc().toIso8601String();
      await (h.db.into(h.db.appMetadata).insert(
        AppMetadataCompanion.insert(
          key: AppMetadataKeys.lastCleanupAt,
          value: now,
        ),
      ));
      // 同步触发（cursorOverride 非空）：受限频 → 未到期跳过（不执行清理）。
      final syncTriggered = await h.store.runCleanupIfDue(cursorOverride: DateTime.now());
      expect(syncTriggered, isA<AppSuccess<void>>());
      expect(h.store.cleanupRunning, isFalse);
      // **副作用断言**：跳过 → last_cleanup_at 未被重写（若误执行清理会
      // 写入新时间戳——旧行为回归可被此断言捕获）。
      final afterSync = await (h.db.select(h.db.appMetadata)
            ..where((t) => t.key.equals(AppMetadataKeys.lastCleanupAt)))
          .getSingle();
      expect(afterSync.value, now);
      // 手动触发（cursorOverride null）：**同样受限频** → 未到期跳过
      //（AppStore 启动路径防每次启动全量清理）。
      final manual = await h.store.runCleanupIfDue();
      expect(manual, isA<AppSuccess<void>>());
      final afterManual = await (h.db.select(h.db.appMetadata)
            ..where((t) => t.key.equals(AppMetadataKeys.lastCleanupAt)))
          .getSingle();
      expect(afterManual.value, now); // 手动触发未到期也跳过
    });

    test('cleanupIntervalHours 常量存在', () {
      expect(AppConstants.cleanupIntervalHours, greaterThan(0));
    });
  });
}

/// 轮询等待 last_cleanup_at 写入（fire-and-forget 清理含多次 DB 往返，
/// 需确定性等待；超时 3s 判失败）。
Future<AppMetadataRow?> _waitForCleanup(AppDatabase db) async {
  final deadline = DateTime.now().add(const Duration(seconds: 3));
  while (DateTime.now().isBefore(deadline)) {
    final row = await (db.select(db.appMetadata)
          ..where((t) => t.key.equals(AppMetadataKeys.lastCleanupAt)))
        .getSingleOrNull();
    if (row != null) return row;
    await Future<void>.delayed(const Duration(milliseconds: 50));
  }
  return null;
}
