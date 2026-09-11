/// Windows 托盘桥接（批次 6 平台层）：C++ runner 侧托盘图标/菜单与 Flutter
/// 的双向 MethodChannel 封装。
///
/// 协议（channel `timetrack/platform/tray`）：
/// - Dart → native `configure`：`{mode, recording, paused, activity,
///   tipRecording/tipPaused/tipIdle/menuShow/menuPause/menuResume/menuExit}`——
///   关窗模式 + 记录状态 + 用户可见文案（铁律 6：ARB 本地化后下发，原生
///   不硬编码文字）；
/// - Dart → native `hideToTray` / `exitApp`：ask 模式首次选择对话框的落点
///   （native WM_CLOSE 不再自行隐藏——对话框必须渲染在可见窗口内）；
/// - native → Dart `onCloseToTray`：ask 模式下用户点关闭（壳层弹选择对话框）；
/// - native → Dart `trayCommand`：`show` / `togglePause`——壳层路由。
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

  /// ask 模式下用户点关闭（壳层据此弹出首次选择对话框；窗口保持可见）。
  void Function()? onCloseToTray;

  /// 最近一次成功/尝试推送的状态（去重基准；文案参与去重——locale 切换
  /// 后新文案必须重推）。
  String? _lastSignature;

  /// 推送托盘配置、记录状态与本地化文案（内部按全量签名去重；非 Windows
  /// 静默 no-op）。
  Future<void> configure({
    required String mode,
    required bool recording,
    required bool paused,
    required String activity,
    required String tipRecording,
    required String tipPaused,
    required String tipIdle,
    required String menuShow,
    required String menuPause,
    required String menuResume,
    required String menuExit,
  }) async {
    final signature =
        '$mode|$recording|$paused|$activity|$tipRecording|$tipPaused|'
        '$tipIdle|$menuShow|$menuPause|$menuResume|$menuExit';
    if (signature == _lastSignature) {
      return; // 状态未变：不重复过通道（秒级刷新路径的节流）
    }
    try {
      await _channel.invokeMethod<void>('configure', <String, dynamic>{
        'mode': mode,
        'recording': recording,
        'paused': paused,
        'activity': activity,
        'tipRecording': tipRecording,
        'tipPaused': tipPaused,
        'tipIdle': tipIdle,
        'menuShow': menuShow,
        'menuPause': menuPause,
        'menuResume': menuResume,
        'menuExit': menuExit,
      });
      _lastSignature = signature;
    } on MissingPluginException {
      // 非 Windows 平台 / 测试环境无实现：静默 no-op。
    } on PlatformException {
      // native 侧异常：不阻断 UI（下轮状态变化会重试推送）。
      debugPrint('[tray] configure 推送失败');
    }
  }

  /// 隐藏窗口到托盘（ask 模式对话框选择"最小化"后由壳层调用）。
  Future<void> hideToTray() async {
    try {
      await _channel.invokeMethod<void>('hideToTray');
    } on MissingPluginException {
      // 非 Windows：no-op。
    } on PlatformException {
      debugPrint('[tray] hideToTray 失败');
    }
  }

  /// 退出应用（ask 模式对话框选择"退出"后由壳层调用；native 走正常销毁
  /// 路径清理托盘/通道）。窗口销毁后响应不再返回——调用方 fire-and-forget。
  Future<void> exitApp() async {
    try {
      await _channel.invokeMethod<void>('exitApp');
    } on MissingPluginException {
      // 非 Windows：no-op。
    } on PlatformException {
      debugPrint('[tray] exitApp 失败');
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
