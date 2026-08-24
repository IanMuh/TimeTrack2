import 'package:flutter_test/flutter_test.dart';
import 'package:timetrack2/api/platform/android_tracking.dart';
import 'package:timetrack2/stores/clock_store.dart';

/// 可覆写的假桥：绕过真实通道（宿主为 Windows，isSupported=false 时真桥
/// 全部短路——无法覆盖通道路径；此处以覆写方法模拟 Android 行为）。
class _FakeBridge extends AndroidTrackingBridge {
  _FakeBridge();

  String foregroundPackage = '';
  int openSettingsCalls = 0;

  @override
  Future<bool> isUsageGranted() async => false;

  @override
  Future<String> latestForegroundPackage() async => foregroundPackage;

  @override
  Future<void> openUsageAccessSettings() async => openSettingsCalls++;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('AndroidTrackingBridge 平台守卫（Windows 宿主）', () {
    test('isSupported=false；方法全部短路返回默认值且不触达通道', () async {
      final bridge = AndroidTrackingBridge();
      expect(AndroidTrackingBridge.isSupported, isFalse,
          reason: '测试宿主为 Windows');
      expect(await bridge.isUsageGranted(), isFalse);
      expect(await bridge.latestForegroundPackage(), isEmpty);
      // 打开设置/请求权限：no-op 不抛异常。
      await bridge.openUsageAccessSettings();
      await bridge.requestNotificationPermission();
    });

    test('guideDismissedThisSession 非 Android 默认 true（无引导）', () {
      expect(AndroidTrackingBridge().guideDismissedThisSession, isTrue);
    });
  });

  group('AndroidForegroundDetector 缓存与刷新', () {
    late _FakeBridge bridge;
    late ClockStore clock;

    setUp(() {
      bridge = _FakeBridge();
      clock = ClockStore(autoStart: false);
    });

    tearDown(() => clock.dispose());

    test('refresh 后缓存包名；空串视为不可检测（null）', () async {
      final seen = <String?>[];
      final detector = AndroidForegroundDetector(
        clock: clock,
        bridge: bridge,
        now: () => DateTime(2026, 8, 24, 9),
        onPackageChanged: seen.add,
      );
      addTearDown(detector.dispose);

      bridge.foregroundPackage = 'com.android.chrome';
      await detector.refresh();
      expect(detector.processName, 'com.android.chrome');
      // 回调收到原始查询值（''=不可检测）；processName 归一化为 null。
      expect(seen, ['com.android.chrome']);

      bridge.foregroundPackage = '';
      await detector.refresh();
      expect(detector.processName, isNull, reason: '空串=不可检测');
      expect(seen, ['com.android.chrome', '']);
    });

    test('tick 驱动：首拍即刷新；间隔内不重复；达标后更新', () async {
      var now = DateTime(2026, 8, 24, 9);
      final detector = AndroidForegroundDetector(
        clock: clock,
        bridge: bridge,
        refreshInterval: const Duration(seconds: 4),
        now: () => now,
      );
      addTearDown(detector.dispose);
      expect(detector.processName, isNull);

      bridge.foregroundPackage = 'com.android.chrome';
      now = now.add(const Duration(seconds: 1));
      clock.notifyListeners(); // 首次 tick（_lastRefresh 初始 epoch）→ 立即刷新
      await Future<void>.delayed(Duration.zero);
      expect(detector.processName, 'com.android.chrome');

      bridge.foregroundPackage = 'com.example.other';
      now = now.add(const Duration(seconds: 2));
      clock.notifyListeners(); // 距上次刷新 2s < 4s：不刷新
      await Future<void>.delayed(Duration.zero);
      expect(detector.processName, 'com.android.chrome',
          reason: '间隔未达不刷新');

      now = now.add(const Duration(seconds: 4));
      bridge.foregroundPackage = '';
      clock.notifyListeners();
      await Future<void>.delayed(Duration.zero);
      expect(detector.processName, isNull);
    });

    test('dispose 后 tick/refresh 均静默', () async {
      final detector = AndroidForegroundDetector(
        clock: clock,
        bridge: bridge,
        now: () => DateTime(2026, 8, 24, 9),
      );
      detector.dispose();
      bridge.foregroundPackage = 'x';
      await detector.refresh();
      expect(detector.processName, isNull);
      // notifyListeners 路径同样静默（不抛）。
      clock.notifyListeners();
      await Future<void>.delayed(Duration.zero);
    });
  });
}
