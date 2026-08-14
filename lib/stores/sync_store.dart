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
import 'dart:io' show stderr;

import 'package:flutter/foundation.dart';

import '../api/supabase/sync_backend.dart';
import '../api/supabase/sync_status_store.dart';
import '../constants/app_constants.dart';
import '../constants/storage_keys.dart' show AppMetadataKeys;
import '../data/cleanup/cleanup_service.dart';
import '../utils/result.dart';
import 'command_contracts.dart';
import 'data_revision.dart';

/// 同步编排 store。
class SyncStore extends ChangeNotifier implements SyncNowProvider {
  SyncStore({
    required this.backend,
    required this.syncStatus,
    required this.cleanup,
    DataRevision? dataRevision,
  }) : _dataRevision = dataRevision ?? DataRevision() {
    // 认证流异常兜底：后端流错误不逃逸为未处理异步异常。
    _authSubscription = backend.authStateStream.listen(
      _onAuthChanged,
      onError: (Object e) {
        if (_disposed) return;
        _lastError = '认证流错误：$e';
        notifyListeners();
      },
    );
  }

  final SyncBackend backend;
  final SyncStatusStore syncStatus;
  final CleanupService cleanup;

  /// dataRevision（模块 3d③ 三类来源收口：同步成功后 bump）。
  final DataRevision _dataRevision;

  late final StreamSubscription<String?> _authSubscription;

  bool _disposed = false;
  String? _userId;
  bool _syncing = false;
  /// 互斥被拒时待重放的登录用户（同步结束后重试——防切换账号后不自动同步）。
  String? _pendingSyncUserId;
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
      // 旧账号同步进行中时 _syncing 互斥会拒绝本轮——记录 pending 登录，
      // 当前同步结束后重放（防"切换账号后新账号不自动同步"）。
      _pendingSyncUserId = userId;
      syncNow();
    } else {
      // 认证流登出（会话过期/被踢）：与 signOut 同口径完全重置编排状态。
      _lastSyncAt = null;
      _lastTarget = null;
      _lastError = null;
      _lastPulled = null;
      _lastPushed = null;
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
      _lastError = null; // 登出完全重置编排状态（防上一会话残留展示）
      _lastPulled = null;
      _lastPushed = null;
      notifyListeners();
    }
    return result;
  }

  /// 云同步（登录态；同步成功后编排清理——墓碑水位对齐）。
  @override
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
      // await 期间可能已登出/切换账号：会话未变才采纳结果，防旧会话报告
      // 写回 + 清理按错误用户作用域执行（跨账号/幽灵会话脏状态）。
      if (user != _userId) {
        return const AppFailure('会话已切换，本次同步结果已丢弃');
      }
      if (result case AppFailure<SyncReport> failure) {
        _lastError = failure.message;
        return failure;
      }
      final report = result.requireValue();
      _lastSyncAt = startedAt;
      _lastTarget = report.target;
      _lastPulled = report.pulledRows;
      _lastPushed = report.pushedRows;
      // **dataRevision 三类来源收口（模块 3d③）**：同步拉取可能改动本地
      // 数据——bump 使派生缓存（Stats/Today/Category 等）失效刷新（不变式
      // 9：任何数据变更写库成功后必须递增，防"同步后 UI 不刷新"）。
      _dataRevision.bump();
      // 同步成功后编排清理（startedAt 水位 + 启动时捕获的 user——见类文档）。
      // fire-and-forget：显式吞纳错误防未处理异步异常（_cleanupDue/cleanup
      // 的 DB 异常与 ArgumentError 均被收敛为失败，不逃逸）。
      unawaited(
        runCleanupIfDue(cursorOverride: startedAt, userId: user)
            .catchError((Object e) => const AppFailure('清理编排异常')),
      );
      return result;
    } on Exception catch (e) {
      // 契约外异常（AppResult 未覆盖路径）：会话未变才记录，防旧会话报错
      // 写回——与成功分支的会话校验口径一致。
      if (user != _userId) {
        return const AppFailure('会话已切换，本次同步结果已丢弃');
      }
      _lastError = '同步异常：$e';
      return AppFailure('同步异常：$e');
    } finally {
      _syncing = false;
      // pending 登录重放：同步期间新登录（互斥被拒）在当前同步结束后重试
      // ——防"切换账号后新账号不自动同步"（旧同步结果已被会话校验丢弃）。
      final pending = _pendingSyncUserId;
      if (pending != null && pending != _userId) {
        _pendingSyncUserId = null;
        if (_userId != null) syncNow();
      }
      if (!_disposed) notifyListeners(); // await 期间可能已 dispose
    }
  }

  /// 按 `last_cleanup_at` 限频触发清理（默认 24h）。
  ///
  /// 语义（与文档一致）：
  /// - [cursorOverride] != null（**同步触发**）：受限频——`last_cleanup_at`
  ///   距今 < 24h 时跳过（防每次同步都全表扫描）；到期才清理；
  /// - [cursorOverride] == null（**手动触发**，阶段 4 设置页按钮）：不限频，
  ///   走库内游标。
  /// [userId] 可选透传：同步编排传启动时捕获的用户（防 await 期间会话切换
  /// 导致清理作用域错误）；null 时用当前 [_userId]。
  Future<AppResult<void>> runCleanupIfDue({
    DateTime? cursorOverride,
    String? userId,
  }) async {
    if (_cleanupRunning) {
      return const AppFailure('清理进行中，请稍后再试');
    }
    // 手动清理（无水位）不限频：直接执行，跳过 _cleanupDue 的无效查询。
    if (cursorOverride == null) {
      return _runCleanup(userId: userId ?? _userId, cursorOverride: null);
    }
    final due = await _cleanupDue();
    if (!due) {
      return const AppSuccess(null); // 同步触发受限频：未到期跳过
    }
    return _runCleanup(userId: userId ?? _userId, cursorOverride: cursorOverride);
  }

  Future<AppResult<void>> _runCleanup({
    required String? userId,
    required DateTime? cursorOverride,
  }) async {
    _cleanupRunning = true;
    try {
      final result = await cleanup.run(
        userId: userId,
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
    try {
      final db = syncStatus.database;
      final row = await (db.select(db.appMetadata)
            ..where((t) => t.key.equals(AppMetadataKeys.lastCleanupAt)))
          .getSingleOrNull();
      if (row == null) return true; // 从未清理：到期
      final last = DateTime.tryParse(row.value);
      if (last == null) return true; // 损坏：到期（重跑）
      return DateTime.now().difference(last) >=
          const Duration(hours: AppConstants.cleanupIntervalHours);
    } on Exception catch (e) {
      // DB 异常收敛为"到期"（保守触发清理，由 cleanup.run 内部守卫兜底）——
      // 防 _cleanupDue 抛错使 runCleanupIfDue 以 error 完成（契约：恒返回
      // AppResult，UI 可感知）。
      _logSafe('清理限频查询失败：$e');
      return true;
    }
  }

  /// 安全 stderr 日志（stderr 管道断开时 writeln 会再抛——包一层防逃逸）。
  static void _logSafe(String message) {
    try {
      stderr.writeln(message);
    } catch (_) {
      // 日志写入失败不影响结论。
    }
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
