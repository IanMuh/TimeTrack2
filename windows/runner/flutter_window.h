#ifndef RUNNER_FLUTTER_WINDOW_H_
#define RUNNER_FLUTTER_WINDOW_H_

#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <flutter/method_channel.h>
#include <flutter/standard_method_codec.h>

#include <memory>
#include <string>

#include "win32_window.h"

// A window that does nothing but host a Flutter view.
// 批次 6：叠加 Windows 托盘能力——Shell_NotifyIcon 图标、关窗隐藏到托盘
// （WM_CLOSE 拦截）、左键唤起、右键菜单（显示主窗口/暂停记录/退出），
// 与 Dart 侧经 MethodChannel "timetrack/platform/tray" 双向通信。
class FlutterWindow : public Win32Window {
 public:
  // Creates a new FlutterWindow hosting a Flutter view running |project|.
  explicit FlutterWindow(const flutter::DartProject& project);
  virtual ~FlutterWindow();

 protected:
  // Win32Window:
  bool OnCreate() override;
  void OnDestroy() override;
  LRESULT MessageHandler(HWND window, UINT const message, WPARAM const wparam,
                         LPARAM const lparam) noexcept override;

 private:
  // The project to run.
  flutter::DartProject project_;

  // The Flutter instance hosted by this window.
  std::unique_ptr<flutter::FlutterViewController> flutter_controller_;

  // ---- 托盘（批次 6）----

  // 与 Dart 的双向通道（OnCreate 装配，生命周期随窗口）。
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> tray_channel_;

  // Shell_NotifyIcon 数据与"已添加"标志（防重复添加/未添加时误删）。
  NOTIFYICONDATA tray_ = {};
  bool tray_added_ = false;

  // 关窗模式（Dart 推送；ask=通知 Dart 弹首次选择框（窗口保持可见）/
  // minimize=静默隐藏 / exit=直接退出）。默认 ask。
  std::wstring close_mode_ = L"ask";

  // 记录状态（tooltip/菜单文案）：是否在记录、活动名、自动检测是否挂起。
  bool recording_ = false;
  bool tracking_paused_ = false;
  std::wstring activity_name_;

  // 托盘/菜单用户可见文案（Dart 经 configure 下发——铁律 6：原生不硬编码
  // 用户可见文字；托盘图标仅在 Dart 首次 configure 后创建，默认值不可见）。
  std::wstring tip_recording_prefix_ = L"Recording: ";
  std::wstring tip_paused_ = L"Auto tracking paused";
  std::wstring tip_idle_ = L"Not recording";
  std::wstring menu_show_ = L"Show main window";
  std::wstring menu_pause_ = L"Pause tracking";
  std::wstring menu_resume_ = L"Resume tracking";
  std::wstring menu_exit_ = L"Exit";

  // 任务栏重建消息（explorer 重启后托盘图标需重加）。
  UINT taskbar_created_msg_ = 0;

  // 确保托盘图标存在（幂等）；更新 tooltip 文案。
  void EnsureTrayIcon();
  void UpdateTrayTip();
  void RemoveTrayIcon();

  // 显示并前置主窗口（托盘左键/菜单「显示主窗口」）。
  void ShowMainWindow();

  // 托盘鼠标事件分发（WM_APP_TRAY 的 lparam 为鼠标消息）。
  LRESULT OnTrayNotify(LPARAM lparam);

  // 右键弹出菜单；选中项经通道推给 Dart（退出项本地直接销毁窗口）。
  void ShowTrayMenu();
};

#endif  // RUNNER_FLUTTER_WINDOW_H_
