import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../api/platform/android_tracking.dart';
import '../api/platform/windows_foreground_detector.dart';
import '../api/platform/tray_service.dart';
import '../data/cleanup/data_wipe_service.dart';
import '../stores/tracking_store.dart';
import 'foundation.dart';
import 'infrastructure.dart';

/// 平台服务（PR5：由容器直接构造，释放责任落在 provider）。

/// 应用壳托盘桥（非 Windows 平台为 no-op）。
final trayServiceProvider = Provider<TrayService>((ref) => TrayService());

/// Android 后台记录桥（使用情况权限 / 前台包名）。
final androidTrackingBridgeProvider = Provider<AndroidTrackingBridge>(
  (ref) => AndroidTrackingBridge(),
);

/// 前台应用检测器（Windows FFI / Android UsageStats / Noop）。
///
/// Android 检测器的周期刷新在此挂接 `ClockStore`（api 层不依赖 stores），
/// 容器释放时摘除监听并释放检测器。
final foregroundDetectorProvider = Provider<ForegroundDetector>((ref) {
  if (WindowsForegroundDetector.isSupported) {
    return WindowsForegroundDetector();
  }
  if (AndroidTrackingBridge.isSupported) {
    final detector = AndroidForegroundDetector(
      bridge: ref.watch(androidTrackingBridgeProvider),
    );
    final clock = ref.watch(clockStoreProvider);
    clock.addListener(detector.maybeRefresh);
    ref.onDispose(() {
      clock.removeListener(detector.maybeRefresh);
      detector.dispose();
    });
    return detector;
  }
  return NoopForegroundDetector();
});

/// 数据全清服务（设置页危险区）。
final dataWipeServiceProvider = Provider<DataWipeService>(
  (ref) => DataWipeService(database: ref.watch(appDatabaseProvider)),
);

/// 当前构建版本号（设置页"关于"、更新横幅展示用）。
final currentVersionProvider = Provider<String>(
  (ref) => ref.watch(appVersionProvider),
);




