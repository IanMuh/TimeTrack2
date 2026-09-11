/// Android 平台通道桥接（批次 6b）：「使用情况访问」权限、前台包名查询、
/// 通知权限请求（前台服务通知可见性）。非 Android 平台全部方法短路返回
/// 安全默认值（isSupported=false），业务零感知。
library;

import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../../viewmodels/foreground_detector.dart';

/// Android 后台记录平台桥。
class AndroidTrackingBridge {
  AndroidTrackingBridge(
      {String channelName = 'timetrack/platform/android_tracking'})
      : _channel = MethodChannel(channelName) {
    // 入站事件（通知暂停动作）仅 Android 注册——真机 Binding 恒已初始化。
    if (isSupported) {
      _channel.setMethodCallHandler(_onNativeCall);
    }
  }

  final MethodChannel _channel;

  /// 授权引导"本会话不再纠缠"标志（契约 §6.3：暂不开启后本会话内不再
  /// 自动弹出；应用重启自然复位）。非 Android 平台恒 true（无引导）。
  bool guideDismissedThisSession = !isSupported;

  /// 通知权限本会话是否已请求过（API 33+ 运行时弹窗只问一次，避免反复
  /// 打扰；用户拒绝后可在系统设置重开）。
  bool notificationPermissionAsked = false;

  /// 通知「暂停/恢复」动作回调（native → Dart；壳层路由到
  /// TrackingStore.setSessionPaused）。
  void Function()? onPauseRequested;

  /// 当前平台是否支持（AppStore 装配判定用）。
  static bool get isSupported => !kIsWeb && Platform.isAndroid;

  /// native 入站分发（当前仅通知暂停动作）。
  Future<Object?> _onNativeCall(MethodCall call) async {
    if (call.method == 'onPauseToggleRequested') {
      onPauseRequested?.call();
    }
    return null;
  }

  /// 「使用情况访问」是否已授予；非 Android / 无实现 / 异常 → false。
  Future<bool> isUsageGranted() async {
    if (!isSupported) return false;
    try {
      return await _channel.invokeMethod<bool>('isUsageGranted') ?? false;
    } on PlatformException {
      return false;
    }
  }

  /// 最近一次前台应用包名；未授权/无事件/非 Android → 空串（调用方以
  /// 空串表示"不可检测"）。
  Future<String> latestForegroundPackage() async {
    if (!isSupported) return '';
    try {
      return await _channel.invokeMethod<String>('latestForegroundPackage') ??
          '';
    } on PlatformException {
      return '';
    }
  }

  /// 跳系统设置开启「使用情况访问」。
  Future<void> openUsageAccessSettings() async {
    if (!isSupported) return;
    try {
      await _channel.invokeMethod<void>('openUsageAccessSettings');
    } on PlatformException {
      // 打开失败不阻断 UI。
    }
  }

  /// 请求通知权限（API 33+ 运行时弹窗；低版本系统设置默认可见，no-op）。
  /// 调用即置 [notificationPermissionAsked]（本会话只主动问一次；用户拒绝
  /// 后可去系统设置重开）。
  Future<void> requestNotificationPermission() async {
    if (!isSupported) return;
    notificationPermissionAsked = true;
    try {
      await _channel.invokeMethod<void>('requestNotificationPermission');
    } on PlatformException {
      // 用户拒绝/异常不阻断流程（通知不可见但服务仍可运行）。
    }
  }

  // ---------------------------------------------------------------------------
  // 前台服务（契约 §6.4 常驻通知）
  // ---------------------------------------------------------------------------

  /// 启动前台服务（重复调用 = 更新通知内容/暂停态，幂等）。
  Future<void> startTrackingService({
    required bool paused,
    required String content,
  }) async {
    if (!isSupported) return;
    try {
      await _channel.invokeMethod<void>('startTrackingService', <String, dynamic>{
        'paused': paused,
        'content': content,
      });
    } on PlatformException {
      // 服务启动失败（厂商限制等）不阻断 UI。
    }
  }

  /// 停止前台服务并移除通知。
  Future<void> stopTrackingService() async {
    if (!isSupported) return;
    try {
      await _channel.invokeMethod<void>('stopTrackingService');
    } on PlatformException {
      // 忽略：未运行时停止是 no-op 失败。
    }
  }

  /// 更新常驻通知内容/暂停文案（服务未运行时 native 返回 false 静默）。
  Future<void> updateNotification({
    required bool paused,
    required String content,
  }) async {
    if (!isSupported) return;
    try {
      await _channel.invokeMethod<void>('updateNotification', <String, dynamic>{
        'paused': paused,
        'content': content,
      });
    } on PlatformException {
      // 忽略。
    }
  }
}

/// Android 前台检测器：UsageStats 包名缓存 + 周期刷新。
///
/// [ForegroundDetector] 接口是同步 getter——本实现持**最近一次查询缓存**
/// （[maybeRefresh]/[refresh] 异步拉取后更新），TrackingStore 的 5s 轮询
/// 读到的始终是 ≤ refreshInterval 新鲜度的包名。空串视为"当前不可检测"
/// → processName 返回 null（title 类规则自动跳过，process 类规则匹配完
/// 整包名）。
///
/// 周期驱动由**装配层**（AppStore）挂接 ClockStore 监听调 [maybeRefresh]——
/// 本类不依赖 ClockStore（依赖方向：api 不得反向依赖 stores）。
class AndroidForegroundDetector implements ForegroundDetector {
  AndroidForegroundDetector({
    required this.bridge,
    this.refreshInterval = const Duration(seconds: 4),
    this.onPackageChanged,
    DateTime Function()? now,
  }) : _now = now ?? DateTime.now;

  final AndroidTrackingBridge bridge;
  final Duration refreshInterval;

  /// 包名变更回调（测试/未来通知联动挂点）。
  final void Function(String? package)? onPackageChanged;

  final DateTime Function() _now;

  String? _cachedPackage;
  bool _disposed = false;
  bool _refreshing = false;
  DateTime _lastRefresh = DateTime.fromMillisecondsSinceEpoch(0);

  @override
  String? get processName {
    final p = _cachedPackage;
    if (p == null || p.isEmpty) return null; // 未刷新过/当前不可检测
    return p;
  }

  @override
  String? get windowTitle => null; // Android 无窗口标题语义

  /// 时钟 tick 入口（装配层挂接）：限频 + 防重入后拉取最新包名。
  void maybeRefresh() {
    if (_disposed) return;
    final now = _now();
    if (now.difference(_lastRefresh) < refreshInterval) return;
    if (_refreshing) return;
    _lastRefresh = now;
    unawaited(refresh());
  }

  /// 拉取最新前台包名并更新缓存（变更时回调；测试可直调）。
  Future<void> refresh() async {
    if (_disposed) return;
    _refreshing = true;
    try {
      final package = await bridge.latestForegroundPackage();
      if (_disposed) return;
      if (package != _cachedPackage) {
        _cachedPackage = package;
        onPackageChanged?.call(package);
      }
    } finally {
      _refreshing = false;
    }
  }

  /// dispose（AppStore.dispose 调用；时钟监听由装配层自行摘除）。
  void dispose() {
    _disposed = true;
  }
}
