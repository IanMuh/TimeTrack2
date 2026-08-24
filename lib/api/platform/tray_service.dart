/// Windows 托盘桥接（批次 6 平台层）：C++ runner 侧托盘图标/菜单与 Flutter
/// 的双向 MethodChannel 封装。
///
/// 协议（channel `timetrack/platform/tray`）：
/// - Dart → native `configure`：`{mode: ask|minimize|exit, recording: bool,
///   paused: bool, activity: String}`——关窗模式 + 托盘 tooltip/菜单文案状态；
/// - native → Dart `onCloseToTray`：用户点关闭且已隐藏到托盘（壳层据此在
///   `ask` 模式下弹首次选择对话框）；
/// - native → Dart `trayCommand`：`show`（显示主窗口）/ `togglePause`
///   （切换会话级暂停）——壳层路由到对应 store。
///
/// 非 Windows 平台：全部调用吞 [MissingPluginException] 静默 no-op
/// （通道不存在即无托盘能力，业务零感知）。重复状态推送在本类内去重，
/// 调用方无需自行节流。
library;

import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// 托盘桥接服务。
class TrayService {
  TrayService({String channelName = 'timetrack/platform/tray'})
      : _channel = MethodChannel(channelName) {
    // 入站处理器仅 Windows 注册（其他平台无托盘能力；纯 Dart 单测宿主
    // 即便运行于 Windows 也可能未初始化 Binding，no-op 兼容两者）。
    if (!kIsWeb && Platform.isWindows) {
      _channel.setMethodCallHandler(_onNativeCall);
    }
  }

  final MethodChannel _channel;

  /// 托盘命令回调：`show` / `togglePause`（由壳层路由到导航/store）。
  void Function(String command)? onCommand;

  /// 窗口已被关窗动作隐藏到托盘（壳层据此处理首次选择对话框）。
  void Function()? onCloseToTray;

  /// 最近一次成功/尝试推送的状态（去重基准）。
  String? _lastMode;
  bool? _lastRecording;
  bool? _lastPaused;
  String? _lastActivity;

  /// 推送托盘配置与记录状态（内部按值去重；非 Windows 静默 no-op）。
  Future<void> configure({
    required String mode,
    required bool recording,
    required bool paused,
    required String activity,
  }) async {
    if (mode == _lastMode &&
        recording == _lastRecording &&
        paused == _lastPaused &&
        activity == _lastActivity) {
      return; // 状态未变：不重复过通道（秒级刷新路径的节流）
    }
    try {
      await _channel.invokeMethod<void>('configure', <String, dynamic>{
        'mode': mode,
        'recording': recording,
        'paused': paused,
        'activity': activity,
      });
      _lastMode = mode;
      _lastRecording = recording;
      _lastPaused = paused;
      _lastActivity = activity;
    } on MissingPluginException {
      // 非 Windows 平台 / 测试环境无实现：静默 no-op。
    } on PlatformException {
      // native 侧异常：不阻断 UI（下轮状态变化会重试推送）。
      debugPrint('[tray] configure 推送失败');
    }
  }

  Future<Object?> _onNativeCall(MethodCall call) async {
    switch (call.method) {
      case 'trayCommand':
        final command = call.arguments as String?;
        if (command != null) {
          onCommand?.call(command);
        }
        return null;
      case 'onCloseToTray':
        onCloseToTray?.call();
        return null;
      default:
        throw MissingPluginException('未知托盘方法：${call.method}');
    }
  }
}
