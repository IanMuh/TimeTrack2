/// 前台检测器契约（后台自动记录）。
///
/// 落位 viewmodels（依赖方向：`data/api ← stores`——api/platform 的两个
/// 平台实现与 stores 的 TrackingStore 共同依赖此契约，契约必须住在公共
/// 下层，防 api 反向依赖 stores）。
library;

/// 前台检测器（平台实现归 api/platform；TrackingStore 轮询读取、测试注入 fake）。
abstract interface class ForegroundDetector {
  /// 当前前台进程名（如 `chrome.exe`；不可用返回 null）。
  String? get processName;

  /// 当前前台窗口标题（可空）。
  String? get windowTitle;
}
