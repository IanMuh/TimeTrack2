import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:timetrack2/api/platform/tray_service.dart';

/// TrayService 单测：经 TestDefaultBinaryMessenger 拦截出站 configure；
/// 入站命令经 handlePlatformMessage 注入——验证去重推送、命令路由、
/// 回调缺省安全与无实现静默。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('timetrack/platform/tray');
  const codec = StandardMethodCodec();

  late TrayService service;
  final configureCalls = <Map<String, dynamic>>[];
  final methodCalls = <String>[];
  final commands = <String>[];
  var closeToTrayCount = 0;

  /// 全量本地化文案参数（configure 必填；文案参与去重签名）。
  Map<String, String> texts = const {
    'tipRecording': 'Recording: ',
    'tipPaused': 'Auto tracking paused',
    'tipIdle': 'Not recording',
    'menuShow': 'Show main window',
    'menuPause': 'Pause tracking',
    'menuResume': 'Resume tracking',
    'menuExit': 'Exit',
  };

  Future<Object?>? mockHandler(MethodCall call) async {
    if (call.method == 'configure') {
      configureCalls.add(Map<String, dynamic>.from(call.arguments! as Map));
      return null;
    }
    methodCalls.add(call.method);
    return null;
  }

  /// 模拟 native → Dart 入站调用（托盘菜单/关窗事件）。
  Future<void> pumpInbound(MethodCall call) async {
    await TestDefaultBinaryMessengerBinding
        .instance.defaultBinaryMessenger
        .handlePlatformMessage(
      channel.name,
      codec.encodeMethodCall(call),
      (ByteData? reply) {},
    );
  }

  setUp(() {
    configureCalls.clear();
    methodCalls.clear();
    commands.clear();
    closeToTrayCount = 0;
    texts = const {
      'tipRecording': 'Recording: ',
      'tipPaused': 'Auto tracking paused',
      'tipIdle': 'Not recording',
      'menuShow': 'Show main window',
      'menuPause': 'Pause tracking',
      'menuResume': 'Resume tracking',
      'menuExit': 'Exit',
    };
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, mockHandler);
    service = TrayService();
    service.onCommand = commands.add;
    service.onCloseToTray = () => closeToTrayCount++;
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  test('configure 推送状态+文案载荷；同值去重不重复过通道', () async {
    await service.configure(
        mode: 'ask',
        recording: true,
        paused: false,
        activity: '学习',
        tipRecording: texts['tipRecording']!,
        tipPaused: texts['tipPaused']!,
        tipIdle: texts['tipIdle']!,
        menuShow: texts['menuShow']!,
        menuPause: texts['menuPause']!,
        menuResume: texts['menuResume']!,
        menuExit: texts['menuExit']!);
    expect(configureCalls, hasLength(1));
    expect(configureCalls.first['mode'], 'ask');
    expect(configureCalls.first['activity'], '学习');
    expect(configureCalls.first['menuExit'], 'Exit');
    expect(configureCalls.first['tipRecording'], 'Recording: ');

    // 完全同参：去重。
    await service.configure(
        mode: 'ask',
        recording: true,
        paused: false,
        activity: '学习',
        tipRecording: texts['tipRecording']!,
        tipPaused: texts['tipPaused']!,
        tipIdle: texts['tipIdle']!,
        menuShow: texts['menuShow']!,
        menuPause: texts['menuPause']!,
        menuResume: texts['menuResume']!,
        menuExit: texts['menuExit']!);
    expect(configureCalls, hasLength(1));

    // 任一值变化：再次推送。
    await service.configure(
        mode: 'ask',
        recording: false,
        paused: true,
        activity: '',
        tipRecording: texts['tipRecording']!,
        tipPaused: texts['tipPaused']!,
        tipIdle: texts['tipIdle']!,
        menuShow: texts['menuShow']!,
        menuPause: texts['menuPause']!,
        menuResume: texts['menuResume']!,
        menuExit: texts['menuExit']!);
    expect(configureCalls, hasLength(2));
    expect(configureCalls.last['paused'], true);
  });

  test('文案变化（locale 切换）参与去重签名：新文案重推', () async {
    Future<void> push(String tipPaused) => service.configure(
        mode: 'ask',
        recording: false,
        paused: true,
        activity: '',
        tipRecording: texts['tipRecording']!,
        tipPaused: tipPaused,
        tipIdle: texts['tipIdle']!,
        menuShow: texts['menuShow']!,
        menuPause: texts['menuPause']!,
        menuResume: texts['menuResume']!,
        menuExit: texts['menuExit']!);
    await push('Auto tracking paused');
    await push('Auto tracking paused');
    expect(configureCalls, hasLength(1), reason: '同文案去重');
    await push('自动记录已暂停');
    expect(configureCalls, hasLength(2), reason: 'locale 切换后新文案必须重推');
    expect(configureCalls.last['tipPaused'], '自动记录已暂停');
  });

  test('hideToTray / exitApp 出站到对应通道方法', () async {
    await service.hideToTray();
    await service.exitApp();
    expect(methodCalls, ['hideToTray', 'exitApp']);
  });

  test('native 命令与关闭事件路由到回调', () async {
    await pumpInbound(const MethodCall('trayCommand', 'show'));
    await pumpInbound(const MethodCall('trayCommand', 'togglePause'));
    await pumpInbound(const MethodCall('onCloseToTray'));
    expect(commands, ['show', 'togglePause']);
    expect(closeToTrayCount, 1);
  });

  test('回调未设置时入站调用不抛异常', () async {
    service.onCommand = null;
    service.onCloseToTray = null;
    await pumpInbound(const MethodCall('trayCommand', 'togglePause'));
    await pumpInbound(const MethodCall('onCloseToTray'));
  });

  test('无平台实现：configure/hideToTray/exitApp 吞 MissingPluginException 静默 no-op',
      () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
    final bare = TrayService();
    await bare.configure(
        mode: 'minimize',
        recording: false,
        paused: false,
        activity: '',
        tipRecording: texts['tipRecording']!,
        tipPaused: texts['tipPaused']!,
        tipIdle: texts['tipIdle']!,
        menuShow: texts['menuShow']!,
        menuPause: texts['menuPause']!,
        menuResume: texts['menuResume']!,
        menuExit: texts['menuExit']!);
    // 失败推送不更新去重基准：同参数下次仍会尝试（恢复后可达）。
    await bare.configure(
        mode: 'minimize',
        recording: false,
        paused: false,
        activity: '',
        tipRecording: texts['tipRecording']!,
        tipPaused: texts['tipPaused']!,
        tipIdle: texts['tipIdle']!,
        menuShow: texts['menuShow']!,
        menuPause: texts['menuPause']!,
        menuResume: texts['menuResume']!,
        menuExit: texts['menuExit']!);
    await bare.hideToTray();
    await bare.exitApp();
  });
}
