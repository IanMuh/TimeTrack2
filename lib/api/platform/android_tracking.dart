/// Android 平台通道桥接（批次 6b）：「使用情况访问」权限、前台包名查询、
/// 通知权限请求（前台服务通知可见性）。非 Android 平台全部方法短路返回
/// 安全默认值（isSupported=false），业务零感知。
library;

import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../../stores/clock_store.dart';
import '../../stores/tracking_store.dart';

/// Android 后台记录平台桥。
class AndroidTrackingBridge {
  AndroidTrackingBridge(
      {String channelName = 'timetrack/platform/android_tracking'})
      : _channel = MethodChannel(channelName);

  final MethodChannel _channel;

  /// 授权引导"本会话不再纠缠"标志（契约 §6.3：暂不开启后本会话内不再
  /// 自动弹出；应用重启自然复位）。非 Android 平台恒 true（无引导）。
  bool guideDismissedThisSession = !isSupported;

  /// 当前平台是否支持（AppStore 装配判定用）。
  static bool get isSupported => !kIsWeb && Platform.isAndroid;

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
  Future<void> requestNotificationPermission() async {
    if (!isSupported) return;
    try {
      await _channel.invokeMethod<void>('requestNotificationPermission');
    } on PlatformException {
      // 用户拒绝/异常不阻断流程（通知不可见但服务仍可运行）。
    }
  }
}

/// Android 前台检测器：UsageStats 包名缓存 + ClockStore 周期刷新。
///
/// [ForegroundDetector] 接口是同步 getter——本实现持**最近一次查询缓存**
/// （[refresh] 异步拉取后更新），TrackingStore 的 5s 轮询读到的始终是
/// ≤ refreshInterval 新鲜度的包名。空串视为"当前不可检测"→ processName
/// 返回 null（title 类规则自动跳过，process 类规则匹配完整包名）。
class AndroidForegroundDetector implements ForegroundDetector {
  AndroidForegroundDetector({
    required this.clock,
    required this.bridge,
    this.refreshInterval = const Duration(seconds: 4),
    this.onPackageChanged,
    DateTime Function()? now,
  })  : _now = now ?? DateTime.now {
    clock.addListener(_onTick);
  }

  final ClockStore clock;
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

  void _onTick() {
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

  /// dispose（ClockStore 监听摘除；AppStore.dispose 调用）。
  void dispose() {
    _disposed = true;
    clock.removeListener(_onTick);
  }
}
