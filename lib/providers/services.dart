import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../api/platform/android_tracking.dart';
import '../api/platform/tray_service.dart';
import '../data/cleanup/data_wipe_service.dart';
import '../viewmodels/foreground_detector.dart';
import 'engines.dart';

/// 平台服务访问器（PR5 迁移期）。
///
/// 这些对象仍由 `AppStore` 组装（释放责任也在它身上），provider 只做
/// "唯一实例的读取入口"，让页面不再直接持有 `AppStore`。PR5 删除
/// `AppStore` 时，把本文件的实现从 `appStoreInstanceProvider` 换成
/// 各自构造即可，调用方无需改动。

/// 应用壳托盘桥（非 Windows 平台为 no-op）。
final trayServiceProvider = Provider<TrayService>(
  (ref) => ref.watch(appStoreInstanceProvider).tray,
);

/// Android 后台记录桥（使用情况权限 / 前台包名）。
final androidTrackingBridgeProvider = Provider<AndroidTrackingBridge>(
  (ref) => ref.watch(appStoreInstanceProvider).androidTracking,
);

/// 前台应用检测器（Windows FFI / Android UsageStats / Noop）。
final foregroundDetectorProvider = Provider<ForegroundDetector>(
  (ref) => ref.watch(appStoreInstanceProvider).foregroundDetector,
);

/// 数据全清服务（设置页危险区）。
final dataWipeServiceProvider = Provider<DataWipeService>(
  (ref) => ref.watch(appStoreInstanceProvider).wipe,
);

/// 当前构建版本号（设置页"关于"、更新横幅展示用）。
final currentVersionProvider = Provider<String>(
  (ref) => ref.watch(appStoreInstanceProvider).currentVersion,
);
