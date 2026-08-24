#include "flutter_window.h"

#include <optional>

#include <shellapi.h>

#include "flutter/generated_plugin_registrant.h"
#include "resource.h"

namespace {

// 托盘回调消息（WM_APP 区段：应用自定义，不与系统消息冲突）。
constexpr UINT kTrayCallbackMessage = WM_APP + 1;

// 托盘菜单命令 ID（TrackPopupMenu 返回值；与 resource.h 解耦——仅本地使用，
// 不进资源编译器）。
constexpr int kTrayCmdShow = 1;
constexpr int kTrayCmdTogglePause = 2;
constexpr int kTrayCmdExit = 3;

// UTF-8 (Dart/EncodableValue) → UTF-16 (Win32)。
std::wstring Utf8ToWide(const std::string& utf8) {
  if (utf8.empty()) {
    return std::wstring();
  }
  const int size_needed = MultiByteToWideChar(
      CP_UTF8, MB_ERR_INVALID_CHARS, utf8.c_str(),
      static_cast<int>(utf8.size()), nullptr, 0);
  if (size_needed <= 0) {
    return std::wstring();
  }
  std::wstring wide(static_cast<size_t>(size_needed), L'\0');
  MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, utf8.c_str(),
                      static_cast<int>(utf8.size()), &wide[0], size_needed);
  return wide;
}

}  // namespace

FlutterWindow::FlutterWindow(const flutter::DartProject& project)
    : project_(project) {}

FlutterWindow::~FlutterWindow() {}

bool FlutterWindow::OnCreate() {
  if (!Win32Window::OnCreate()) {
    return false;
  }

  RECT frame = GetClientArea();

  // The size here must match the window dimensions to avoid unnecessary surface
  // creation / destruction in the startup path.
  flutter_controller_ = std::make_unique<flutter::FlutterViewController>(
      frame.right - frame.left, frame.bottom - frame.top, project_);
  // Ensure that basic setup of the controller was successful.
  if (!flutter_controller_->engine() || !flutter_controller_->view()) {
    return false;
  }
  RegisterPlugins(flutter_controller_->engine());
  SetChildContent(flutter_controller_->view()->GetNativeWindow());

  // ---- 托盘通道装配（批次 6）----
  taskbar_created_msg_ = RegisterWindowMessage(L"TaskbarCreated");
  tray_channel_ =
      std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
          flutter_controller_->engine()->messenger(),
          "timetrack/platform/tray",
          &flutter::StandardMethodCodec::GetInstance());
  tray_channel_->SetMethodCallHandler(
      [this](const auto& call, auto result) {
        if (call.method_name() == "configure") {
          const auto* args = std::get_if<flutter::EncodableMap>(call.arguments());
          if (args != nullptr) {
            if (const auto mode = args->find(flutter::EncodableValue("mode"));
                mode != args->end()) {
              const auto* s = std::get_if<std::string>(&mode->second);
              if (s != nullptr) {
                close_mode_ = Utf8ToWide(*s);
              }
            }
            if (const auto rec = args->find(flutter::EncodableValue("recording"));
                rec != args->end()) {
              if (const auto* b = std::get_if<bool>(&rec->second)) {
                recording_ = *b;
              }
            }
            if (const auto paused = args->find(flutter::EncodableValue("paused"));
                paused != args->end()) {
              if (const auto* b = std::get_if<bool>(&paused->second)) {
                tracking_paused_ = *b;
              }
            }
            if (const auto act = args->find(flutter::EncodableValue("activity"));
                act != args->end()) {
              if (const auto* s = std::get_if<std::string>(&act->second)) {
                activity_name_ = Utf8ToWide(*s);
              }
            }
          }
          EnsureTrayIcon();
          UpdateTrayTip();
          result->Success();
        } else {
          result->NotImplemented();
        }
      });

  flutter_controller_->engine()->SetNextFrameCallback([this]() {
    Show();
  });

  // Flutter can complete the first frame before the "show window" callback is
  // registered. The following call ensures a frame is pending to ensure the
  // window is shown. It is a no-op if the first frame hasn't completed yet.
  flutter_controller_->ForceRedraw();

  return true;
}

void FlutterWindow::OnDestroy() {
  RemoveTrayIcon();
  tray_channel_ = nullptr;
  if (flutter_controller_) {
    flutter_controller_ = nullptr;
  }

  Win32Window::OnDestroy();
}

LRESULT
FlutterWindow::MessageHandler(HWND hwnd, UINT const message,
                              WPARAM const wparam,
                              LPARAM const lparam) noexcept {
  // Give Flutter, including plugins, an opportunity to handle window messages.
  if (flutter_controller_) {
    std::optional<LRESULT> result =
        flutter_controller_->HandleTopLevelWindowProc(hwnd, message, wparam,
                                                      lparam);
    if (result) {
      return *result;
    }
  }

  switch (message) {
    case WM_FONTCHANGE:
      flutter_controller_->engine()->ReloadSystemFonts();
      break;

    // ---- 托盘（批次 6）----

    case WM_CLOSE:
      // 关窗拦截：exit 模式走正常销毁退出；其余隐藏到托盘并通知 Dart
      // （ask 模式下 Dart 弹首次选择对话框）。返回非零表示已处理。
      if (close_mode_ == L"exit") {
        DestroyWindow(hwnd);
        return 0;
      }
      ShowWindow(hwnd, SW_HIDE);
      if (tray_channel_) {
        tray_channel_->InvokeMethod("onCloseToTray", nullptr);
      }
      return 0;

    case kTrayCallbackMessage:
      return OnTrayNotify(lparam);

    default:
      // explorer 重启后任务栏重建：重加托盘图标。
      if (taskbar_created_msg_ != 0 && message == taskbar_created_msg_) {
        tray_added_ = false;
        EnsureTrayIcon();
        UpdateTrayTip();
      }
      break;
  }

  return Win32Window::MessageHandler(hwnd, message, wparam, lparam);
}

void FlutterWindow::EnsureTrayIcon() {
  if (tray_added_) {
    return;
  }
  ZeroMemory(&tray_, sizeof(tray_));
  tray_.cbSize = sizeof(tray_);
  tray_.hWnd = GetHandle();
  tray_.uID = 1;
  tray_.uFlags = NIF_ICON | NIF_MESSAGE | NIF_TIP;
  tray_.uCallbackMessage = kTrayCallbackMessage;
  tray_.hIcon = LoadIcon(GetModuleHandle(nullptr),
                         MAKEINTRESOURCE(IDI_APP_ICON));
  lstrcpynW(tray_.szTip, L"TimeTrack2", ARRAYSIZE(tray_.szTip));
  if (Shell_NotifyIcon(NIM_ADD, &tray_)) {
    tray_added_ = true;
  }
}

void FlutterWindow::UpdateTrayTip() {
  if (!tray_added_) {
    return;
  }
  std::wstring tip;
  if (recording_) {
    tip = L"正在记录：" + activity_name_;
  } else if (tracking_paused_) {
    tip = L"自动记录已暂停";
  } else {
    tip = L"未在记录";
  }
  tray_.uFlags = NIF_TIP;
  lstrcpynW(tray_.szTip, tip.c_str(), ARRAYSIZE(tray_.szTip));
  Shell_NotifyIcon(NIM_MODIFY, &tray_);
}

void FlutterWindow::RemoveTrayIcon() {
  if (tray_added_) {
    Shell_NotifyIcon(NIM_DELETE, &tray_);
    tray_added_ = false;
  }
}

void FlutterWindow::ShowMainWindow() {
  ShowWindow(GetHandle(), SW_RESTORE);
  SetForegroundWindow(GetHandle());
}

LRESULT FlutterWindow::OnTrayNotify(LPARAM lparam) {
  const UINT msg = LOWORD(lparam);
  if (msg == WM_LBUTTONUP) {
    // 左键：唤起主窗口。
    ShowMainWindow();
    if (tray_channel_) {
      tray_channel_->InvokeMethod("trayCommand",
                                  std::make_unique<flutter::EncodableValue>(
                                      std::string("show")));
    }
    return 0;
  }
  if (msg == WM_RBUTTONUP) {
    ShowTrayMenu();
    return 0;
  }
  return 0;
}

void FlutterWindow::ShowTrayMenu() {
  HWND hwnd = GetHandle();
  // TrackPopupMenu 前必须前置窗口，否则菜单不会随点击外区域消失。
  SetForegroundWindow(hwnd);

  HMENU menu = CreatePopupMenu();
  AppendMenuW(menu, MF_STRING, kTrayCmdShow, L"显示主窗口");
  AppendMenuW(menu, MF_SEPARATOR, 0, nullptr);
  AppendMenuW(menu, MF_STRING, kTrayCmdTogglePause,
              tracking_paused_ ? L"恢复记录" : L"暂停记录");
  AppendMenuW(menu, MF_SEPARATOR, 0, nullptr);
  AppendMenuW(menu, MF_STRING, kTrayCmdExit, L"退出");

  POINT point;
  GetCursorPos(&point);
  const int cmd = TrackPopupMenu(menu, TPM_RETURNCMD | TPM_NONOTIFY | TPM_RIGHTBUTTON,
                                 point.x, point.y, 0, hwnd, nullptr);
  DestroyMenu(menu);
  // 防菜单残留的第二次幽灵 WM_CONTEXTMENU（Win32 经典 quirk）。
  PostMessage(hwnd, WM_NULL, 0, 0);

  switch (cmd) {
    case kTrayCmdShow:
      ShowMainWindow();
      break;
    case kTrayCmdTogglePause:
      // 状态翻转由 Dart 侧执行后经 configure 推回（菜单文案随之更新）。
      if (tray_channel_) {
        tray_channel_->InvokeMethod("trayCommand",
                                    std::make_unique<flutter::EncodableValue>(
                                        std::string("togglePause")));
      }
      break;
    case kTrayCmdExit:
      DestroyWindow(hwnd);
      break;
    default:
      break;
  }
}
