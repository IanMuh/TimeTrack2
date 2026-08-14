/// 更新 store（模块 3c②）：检查/下载/校验/安装的有限状态机编排。
///
/// 设计（阶段 3 框架结论）：
/// - **显式迁移表**（非散落 switch）：`Map<UpdateState, Set<UpdateState>>`
///   声明全部合法迁移——非法迁移抛 [StateError]（fail-fast 暴露 bug）；
///   幂等事件（重复 download/install）返回失败而非崩溃；
/// - **进度作字段**（非状态枚举拆分）：receivedBytes/totalBytes 存于状态
///   对象，onProgress 回调节流合并（高频回调不逐条迁移）；
/// - **paused 枚举保留但下载中不可达**：自研下载器无 HTTP Range 断点续传
///   （已核 [UpdateDownloader.download] 仅 onProgress 无 pause API）——
///   真暂停/取消下载留后续（cancel = 取消下载+删临时文件），如实声明。
///
/// 流程：check() → available → download()（verify 内联）→ install()
///（Windows staging 两阶段；Android tryInstallApk 阶段 4 显式 UnsupportedError）。
library;

import 'dart:io' show stderr;

import 'package:flutter/foundation.dart';

import '../api/update/update_manifest_service.dart';
import '../api/update/update_verifier.dart';
import '../constants/storage_keys.dart';
import '../data/database/app_database.dart' hide ProfileSettings;
import '../data/update/windows_installer.dart';
import '../utils/result.dart';
import '../viewmodels/update/update_manifest.dart';

/// 更新状态（显式枚举）。
enum UpdateState {
  idle,
  checking,
  upToDate,
  available,
  downloading,
  paused,
  verifying,
  installing,
  restartRequired,
  failed,
}

/// 更新编排状态（状态 + 数据字段）。
class UpdateStatus {
  const UpdateStatus({
    required this.state,
    this.receivedBytes = 0,
    this.totalBytes,
    this.latestVersion = '',
    this.required = false,
    this.releaseNotes = '',
    this.errorMessage,
  });

  final UpdateState state;

  /// 已下载字节（进度展示）。
  final int receivedBytes;

  /// 总字节（未知为 null）。
  final int? totalBytes;

  /// 最新版本（SemVer）。
  final String latestVersion;

  /// 是否强制更新（不可跳过）。
  final bool required;

  final String releaseNotes;
  final String? errorMessage;

  UpdateStatus copyWith({
    UpdateState? state,
    int? receivedBytes,
    int? totalBytes,
    bool clearTotalBytes = false,
    String? latestVersion,
    bool? required,
    String? releaseNotes,
    String? errorMessage,
    bool clearError = false,
  }) {
    return UpdateStatus(
      state: state ?? this.state,
      receivedBytes: receivedBytes ?? this.receivedBytes,
      totalBytes: clearTotalBytes ? null : totalBytes ?? this.totalBytes,
      latestVersion: latestVersion ?? this.latestVersion,
      required: required ?? this.required,
      releaseNotes: releaseNotes ?? this.releaseNotes,
      errorMessage: clearError ? null : errorMessage ?? this.errorMessage,
    );
  }
}

/// 更新 store（状态机编排）。
class UpdateStore extends ChangeNotifier {
  UpdateStore({
    required this.manifestService,
    required this.verifier,
    required this.windowsInstaller,
    required this.database,
  });

  final UpdateManifestService manifestService;
  final UpdateVerifier verifier;
  final WindowsInstaller windowsInstaller;
  final AppDatabase database;

  UpdateStatus _status = const UpdateStatus(state: UpdateState.idle);
  bool _closed = false;

  /// 最近一次检查结果（install 平台判定用）。
  UpdateCheckResult? _lastCheck;

  /// 最近一次下载校验通过的产物（install 用；download 成功后设置）。
  UpdateVerifierResult? _verifiedResult;

  UpdateStatus get status => _status;
  UpdateState get state => _status.state;

  // ---------------------------------------------------------------------------
  // 显式迁移表（合法迁移声明；非法迁移 fail-fast）
  // ---------------------------------------------------------------------------

  static const _transitions = <UpdateState, Set<UpdateState>>{
    UpdateState.idle: {UpdateState.checking},
    UpdateState.checking: {UpdateState.upToDate, UpdateState.available, UpdateState.failed},
    UpdateState.upToDate: {UpdateState.checking},
    UpdateState.available: {UpdateState.checking, UpdateState.downloading},
    UpdateState.downloading: {
      UpdateState.verifying,
      UpdateState.failed,
      UpdateState.idle, // 取消下载 → idle
    },
    UpdateState.paused: {UpdateState.downloading}, // 保留（未来 Range 续传）
    UpdateState.verifying: {UpdateState.installing, UpdateState.failed},
    UpdateState.installing: {UpdateState.restartRequired, UpdateState.failed},
    UpdateState.restartRequired: {}, // 终态（重启由外部驱动）
    UpdateState.failed: {UpdateState.checking, UpdateState.downloading},
  };

  void _transition(UpdateState next, {UpdateStatus? withStatus}) {
    final allowed = _transitions[_status.state];
    if (allowed == null || !allowed.contains(next)) {
      throw StateError(
        '非法更新迁移：${_status.state} → $next'
        '（$next 不在 ${_status.state} 的合法迁移集内）',
      );
    }
    // 目标状态恒为 next：withStatus 可能由 _status.copyWith 派生（state 仍为
    // 旧值），须统一覆盖 state，防"迁移后状态停留旧值"（copyWith 不自动
    // 设 state 的陷阱）。
    _status = (withStatus ?? _status).copyWith(state: next);
    if (!_closed) notifyListeners(); // dispose 后不通知（进度回调异步驱动）
  }

  // ---------------------------------------------------------------------------
  // 编排
  // ---------------------------------------------------------------------------

  /// 检查更新（来自 idle/upToDate/available/failed 均可）。
  Future<AppResult<UpdateCheckResult>> check() async {
    if (_closed) return const AppFailure('更新服务已关闭');
    // 重入保护（与 download() 幂等契约一致）：流程进行中重复检查返回
    // 失败而非让 _transition 抛未捕获 StateError。
    if (_status.state == UpdateState.checking ||
        _status.state == UpdateState.downloading ||
        _status.state == UpdateState.verifying ||
        _status.state == UpdateState.installing) {
      return const AppFailure('更新检查已在进行中');
    }
    _transition(UpdateState.checking);
    // 离开 downloading 相关状态：重置进度字段（防 failed/upToDate/available
    // 残留上次下载进度，UI 展示不一致）。
    if (_status.receivedBytes != 0 || _status.totalBytes != null) {
      _status = _status.copyWith(receivedBytes: 0, clearTotalBytes: true);
    }
    final AppResult<UpdateCheckResult> result;
    try {
      result = await manifestService.checkForUpdate();
    } catch (e) {
      // 契约外异常（AppResult 未覆盖路径，含 Error 类）：收敛为失败，防
      // 状态停留 checking。文案脱敏（不拼 $e——可能含内部 URL/路径细节），
      // 详细原因写 stderr（安全日志函数，防 stderr 抛异常跳过收敛）。
      _logSafe('[update] 检查异常：$e');
      _fail('更新检查失败，请稍后重试');
      return AppFailure('更新检查失败，请稍后重试');
    }
    if (result case AppFailure<UpdateCheckResult> failure) {
      _fail(failure.message);
      return failure;
    }
    final check = result.requireValue();
    _lastCheck = check;
    if (!check.available) {
      _transition(UpdateState.upToDate, withStatus: _status.copyWith(
        latestVersion: check.latestVersion,
        required: check.required,
        releaseNotes: check.releaseNotes,
        clearError: true,
      ));
      return result;
    }
    // available：记录清单信息（latestVersion/required/releaseNotes）。
    _transition(UpdateState.available, withStatus: _status.copyWith(
      latestVersion: check.latestVersion,
      required: check.required,
      releaseNotes: check.releaseNotes,
      clearError: true,
    ));
    return result;
  }

  /// 下载并校验更新包（进度回调节流合并）。成功后状态到 verifying。
  Future<AppResult<UpdateVerifierResult>> download() async {
    if (_closed) return const AppFailure('更新服务已关闭');
    // 重入保护（幂等事件返回失败而非崩溃——头注释契约）：下载中/校验中/
    // 安装中再次调用返回失败。
    if (_status.state == UpdateState.downloading ||
        _status.state == UpdateState.verifying ||
        _status.state == UpdateState.installing) {
      return const AppFailure('下载/安装已在进行中');
    }
    // 先校验迁移合法（idle 直接 download 抛 StateError——fail-fast），
    // 再查平台产物（available 且无产物才业务失败）。
    _transition(UpdateState.downloading);
    final artifact = _platformArtifact();
    if (artifact == null) {
      _fail('当前平台无可用更新包');
      return const AppFailure('当前平台无可用更新包');
    }
    // 进度节流：仅按时间阈值（≥100ms）更新——`received != lastReceived`
    // 的字节判断会让高频分块回调恒真、时间节流完全失效；时间阈值天然覆盖
    // 字节变化（间隔足够时必更新），下载结束后补发最后一次进度防最终值丢失。
    var lastProgressAt = DateTime.now();
    final AppResult<UpdateVerifierResult> result;
    try {
      result = await verifier.downloadAndVerify(
        artifact,
        onProgress: (received, total) {
          final now = DateTime.now();
          if (now.difference(lastProgressAt) >= const Duration(milliseconds: 100)) {
            lastProgressAt = now;
            _status = _status.copyWith(
              receivedBytes: received,
              totalBytes: total,
            );
            if (!_closed) notifyListeners(); // dispose 后不通知
          }
        },
      );
    } catch (e) {
      // 契约外异常（含 Error 类）：收敛为失败，防状态停留 downloading。
      _logSafe('[update] 下载异常：$e');
      _fail('下载失败，请稍后重试');
      return const AppFailure('下载失败，请稍后重试');
    }
    if (result case AppFailure<UpdateVerifierResult> failure) {
      _status = _status.copyWith(
        state: UpdateState.failed,
        errorMessage: failure.message,
        receivedBytes: 0,
        clearTotalBytes: true,
      );
      if (!_closed) notifyListeners(); // dispose 后不通知（async 驱动路径）
      return failure;
    }
    final verified = result.requireValue();
    _verifiedResult = verified;
    _transition(UpdateState.verifying, withStatus: _status.copyWith(
      clearError: true,
    ));
    return result;
  }

  /// 安装更新（按平台分发：Windows staging 两阶段；Android 阶段 4 未支持；
  /// 其余平台业务失败）。
  Future<AppResult<void>> install() async {
    if (_closed) return const AppFailure('更新服务已关闭');
    final verified = _verifiedResult;
    if (verified == null) {
      return const AppFailure('尚未完成下载校验，无法安装');
    }
    // 源态强制校验：仅 verifying 是 installing 的合法源态（迁移表声明）。
    // downloading/upToDate/available/failed 等状态调用 install 属非法迁移，
    // 直接返回失败而非让 _transition 抛未捕获 StateError（幂等契约：
    // 失败返回而非崩溃）。_verifiedResult 不随 failed/check 清空，前置
    // null 校验可被陈旧产物绕过——源态校验补上这一缺口。
    if (_status.state != UpdateState.verifying) {
      return const AppFailure('尚未完成下载校验，无法安装');
    }
    // 平台分发：仅 Windows 走 WindowsInstaller；Android 阶段 4 未支持；
    // Linux/macOS 无安装器（业务失败）。
    switch (defaultTargetPlatform) {
      case TargetPlatform.windows:
        break;
      case TargetPlatform.android:
        return _fail('Android 自动安装待阶段 4 支持——请从下载页手动安装');
      case TargetPlatform.linux:
      case TargetPlatform.macOS:
        return _fail('当前平台暂不支持自动安装——请从下载页手动获取更新');
      default:
        return _fail('当前平台暂不支持自动安装');
    }
    _transition(UpdateState.installing);
    try {
      // Windows：checkWritable → prepareStaging → applyStaging。
      if (!windowsInstaller.checkWritable()) {
        return _fail('程序目录不可写，无法安装——请从下载页手动获取更新');
      }
      final staging =
          await windowsInstaller.prepareStaging(verified.filePath);
      if (staging case AppFailure<String> failure) {
        return _fail(failure.message);
      }
      final applied = await windowsInstaller.applyStaging(staging.requireValue());
      if (applied case AppFailure<void> failure) {
        return _fail(failure.message);
      }
      _transition(UpdateState.restartRequired);
      return const AppSuccess(null);
    } catch (e) {
      // 契约外异常（含 Error 类）收敛（防状态停留 installing）。
      _logSafe('[update] 安装异常：$e');
      return _fail('安装失败，请稍后重试');
    }
  }

  AppResult<void> _fail(String message) {
    // 统一失败路径：重置进度字段（防 failed 残留下载进度，UI 展示不一致）。
    _status = _status.copyWith(
      state: UpdateState.failed,
      errorMessage: message,
      receivedBytes: 0,
      clearTotalBytes: true,
    );
    if (!_closed) notifyListeners(); // dispose 后不通知
    return AppFailure(message);
  }

  /// 安全 stderr 日志：stderr 已关闭/管道断开时 writeln 会再抛（项目
  /// update_verifier r14 既有约定）——包一层防从 catch 分支逃逸（跳过
  /// 后续收敛逻辑、状态停留）。
  static void _logSafe(String message) {
    try {
      stderr.writeln(message);
    } catch (_) {
      // 日志写入失败不影响收敛结论。
    }
  }

  // ---------------------------------------------------------------------------
  // 内部
  // ---------------------------------------------------------------------------

  UpdatePlatformArtifact? _platformArtifact() {
    final check = _lastCheck;
    if (check == null) return null;
    switch (defaultTargetPlatform) {
      case TargetPlatform.windows:
        return check.windows;
      case TargetPlatform.android:
        return check.android;
      default:
        // Linux/macOS 无安装器（阶段 3）：不下载（避免下载错误平台产物）。
        return null;
    }
  }

  /// 忽略此版本（"忽略此版本"持久化——存储键已建）。
  Future<AppResult<void>> ignoreCurrentVersion() async {
    if (_closed) return const AppFailure('更新服务已关闭');
    final version = _status.latestVersion;
    if (version.isEmpty) return const AppFailure('当前无待忽略的更新版本');
    try {
      await (database.into(database.appMetadata).insertOnConflictUpdate(
        AppMetadataCompanion.insert(
          key: AppMetadataKeys.ignoredUpdateVersion,
          value: version,
        ),
      ));
      return const AppSuccess(null);
    } on Exception catch (e) {
      _logSafe('[update] 记录忽略版本失败：$e');
      return const AppFailure('记录忽略版本失败');
    }
  }

  /// 最近检查的清单版本（存储键已建；启动静默检查限频用）。
  Future<AppResult<void>> recordLastCheckedVersion(String version) async {
    if (_closed) return const AppFailure('更新服务已关闭');
    try {
      await (database.into(database.appMetadata).insertOnConflictUpdate(
        AppMetadataCompanion.insert(
          key: AppMetadataKeys.lastCheckedManifestVersion,
          value: version,
        ),
      ));
      return const AppSuccess(null);
    } on Exception catch (e) {
      _logSafe('[update] 记录检查版本失败：$e');
      return const AppFailure('记录检查版本失败');
    }
  }

  @override
  void dispose() {
    _closed = true;
    super.dispose();
  }
}
