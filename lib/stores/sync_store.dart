/// 同步编排 store（模块 3c①）：云同步 + 认证 + 清理编排的单一入口。
///
/// 职责：
/// - **认证流**：订阅 [SyncBackend.authStateStream]（broadcast，未配置 →
///   Noop 离线），登录成功自动云同步；登出清状态；
/// - **云同步**：`syncNow()`——登录态下调引擎，成功后**编排清理**
///   （见"墓碑水位对齐"）；
/// - **清理限频**：`runCleanupIfDue()`——按 `last_cleanup_at` 距今 ≥
///   [AppConstants.cleanupIntervalHours] 限频（防每次同步都全表扫描）；
/// - **墓碑水位对齐（模块 3c 点 3 修正方案）**：同步开始时记 `startedAt`，
///   成功后传 [CleanupService.run] 的 `cursorOverride`——引擎游标可能被
///   同表其他行推过"未推送墓碑"（同步期间新建的 deleted_at > startedAt），
///   用库内游标清理会误删未传播墓碑（远端删除丢失/复活）；startedAt 水位
///   天然保护（新建墓碑 > startedAt 不误删，已推送墓碑 < startedAt 照删）。
///
/// LAN / 文件互通：本 store 仅声明骨架（[SyncTarget.lan] 待 3d 启用、
/// export/import 走 3d 指令通道）——编排收敛到 3d 统一分发（铁律 7）。
library;

import 'dart:async';

import 'package:flutter/foundation.dart';

import '../api/supabase/sync_backend.dart';
import '../api/supabase/sync_status_store.dart';
import '../constants/app_constants.dart';
import '../constants/storage_keys.dart' show AppMetadataKeys;
import '../data/cleanup/cleanup_service.dart';
import '../utils/result.dart';

/// 同步编排 store。
class SyncStore extends ChangeNotifier {
  SyncStore({
    required this.backend,
    required this.syncStatus,
    required this.cleanup,
  }) {
    _authSubscription = backend.authStateStream.listen(_onAuthChanged);
  }

  final SyncBackend backend;
  final SyncStatusStore syncStatus;
  final CleanupService cleanup;

  late final StreamSubscription<String?> _authSubscription;

  bool _disposed = false;
  String? _userId;
  bool _syncing = false;
  bool _cleanupRunning = false;
  String? _lastError;
  DateTime? _lastSyncAt;
  String? _lastTarget;
  int? _lastPulled;
  int? _lastPushed;

  /// 当前登录用户 id（null = 未登录/未配置离线）。
  String? get userId => _userId;

  /// 同步进行中。
  bool get syncing => _syncing;

  /// 最近一次同步结果（报告字段，UI 展示）。
  String? get lastError => _lastError;
  DateTime? get lastSyncAt => _lastSyncAt;
  String? get lastTarget => _lastTarget;
  int? get lastPulled => _lastPulled;
  int? get lastPushed => _lastPushed;

  /// 云同步是否已配置（未配置 → 离线语义）。
  bool get isConfigured => backend.isConfigured;

  /// 清理进行中。
  bool get cleanupRunning => _cleanupRunning;

  void _onAuthChanged(String? userId) {
    if (_disposed) return;
    _userId = userId;
    if (userId != null) {
      // 登录成功自动云同步（fire-and-forget；失败记录错误供 UI）。
      syncNow();
    } else {
      _lastSyncAt = null;
      _lastTarget = null;
    }
    notifyListeners();
  }

  /// 发起邮箱 OTP 登录（发送魔法链接）。
  Future<AppResult<void>> sendMagicLink(String email) => backend.sendMagicLink(email);

  /// 校验 OTP 并登录。
  Future<AppResult<String>> verifyEmailOtp(String email, String token) =>
      backend.verifyEmailOtp(email, token);

  /// 登出（先检查 [backend.isConfigured]——未配置时后端返回失败，语义由
  /// 编排层透传，不做本地状态清理误判）。
  Future<AppResult<void>> signOut() async {
    final result = await backend.signOut();
    if (result.isSuccess) {
      _userId = null;
      _lastSyncAt = null;
      _lastTarget = null;
      notifyListeners();
    }
    return result;
  }

  /// 云同步（登录态；同步成功后编排清理——墓碑水位对齐）。
  Future<AppResult<SyncReport>> syncNow() async {
    final user = _userId;
    if (user == null) {
      return const AppFailure('未登录，无法同步');
    }
    if (_syncing) {
      return const AppFailure('同步进行中，请稍后再试');
    }
    _syncing = true;
    _lastError = null;
    notifyListeners();
    // 同步开始时刻（墓碑水位）：同步期间新建墓碑 deleted_at > startedAt，
    // 清理 cutoff 用此水位天然保护未推送墓碑。
    final startedAt = DateTime.now();
    try {
      final result = await backend.syncNow();
      if (result case AppFailure<SyncReport> failure) {
        _lastError = failure.message;
        return failure;
      }
      final report = result.requireValue();
      _lastSyncAt = startedAt;
      _lastTarget = report.target;
      _lastPulled = report.pulledRows;
      _lastPushed = report.pushedRows;
      // 同步成功后编排清理（startedAt 水位，非库内游标——见类文档）。
      // fire-and-forget：runCleanupIfDue 内部 await 后有 _disposed 守卫。
      runCleanupIfDue(cursorOverride: startedAt);
      return result;
    } finally {
      _syncing = false;
      if (!_disposed) notifyListeners(); // await 期间可能已 dispose
    }
  }

  /// 按 `last_cleanup_at` 限频触发清理（默认 24h）。
  ///
  /// [cursorOverride] 可选（同步编排传 startedAt 水位）；手动清理（阶段 4
  /// 设置页按钮）可传 null 走库内游标且不受限频（separate 入口）。
  Future<AppResult<void>> runCleanupIfDue({DateTime? cursorOverride}) async {
    if (_cleanupRunning) {
      return const AppFailure('清理进行中，请稍后再试');
    }
    final due = await _cleanupDue();
    if (!due && cursorOverride == null) {
      return const AppSuccess(null); // 未到期：跳过（同步水位触发不跳过——
      // 同步成功本身即"数据有变动"的信号，理应清理）
    }
    _cleanupRunning = true;
    try {
      final result = await cleanup.run(
        userId: _userId,
        cursorOverride: cursorOverride,
      );
      if (result case AppFailure<CleanupReport> failure) {
        _lastError = failure.message;
        return AppFailure(failure.message);
      }
      return const AppSuccess(null);
    } finally {
      _cleanupRunning = false;
      if (!_disposed) notifyListeners(); // await 期间可能已 dispose
    }
  }

  Future<bool> _cleanupDue() async {
    final db = syncStatus.database;
    final row = await (db.select(db.appMetadata)
          ..where((t) => t.key.equals(AppMetadataKeys.lastCleanupAt)))
        .getSingleOrNull();
    if (row == null) return true; // 从未清理：到期
    final last = DateTime.tryParse(row.value);
    if (last == null) return true; // 损坏：到期（重跑）
    return DateTime.now().difference(last) >=
        const Duration(hours: AppConstants.cleanupIntervalHours);
  }

  // ---------------------------------------------------------------------------
  // LAN / 文件互通（骨架占位，编排随 3d 统一通道）
  // ---------------------------------------------------------------------------

  /// LAN 同步（3d 启用 [SyncTarget.lan]；当前显式拒绝防误调）。
  Future<AppResult<dynamic>> syncLanNow() {
    return Future.value(const AppFailure('LAN 同步编排未就绪（随阶段 3d 启用）'));
  }

  /// 导出数据（3d 指令通道）。
  Future<AppResult<dynamic>> exportData({String? path}) {
    return Future.value(const AppFailure('导出编排未就绪（随阶段 3d 启用）'));
  }

  /// 导入数据（3d 指令通道）。
  Future<AppResult<dynamic>> importData(String path) {
    return Future.value(const AppFailure('导入编排未就绪（随阶段 3d 启用）'));
  }

  @override
  void dispose() {
    _disposed = true;
    _authSubscription.cancel();
    super.dispose();
  }
}
