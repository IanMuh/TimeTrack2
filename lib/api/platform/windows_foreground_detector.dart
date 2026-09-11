/// Windows 前台进程/窗口标题检测器（批次 6 平台层）：纯 dart:ffi 手写
/// Win32 绑定（零新增第三方运行时依赖，`ffi` 包仅用于 calloc/Utf16 转换）。
///
/// 绑定的 API 链：
/// `GetForegroundWindow` → `GetWindowThreadProcessId`（取 PID）→
/// `OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION)` +
/// `QueryFullProcessImageNameW`（完整路径 → 文件名小写，如 `chrome.exe`）；
/// 窗口标题经 `GetWindowTextLengthW` + `GetWindowTextW`。
///
/// 容错语义（后台自动记录不因单次查询失败抖动）：任一步失败（无前台窗口、
/// PID 为 0、句柄打开失败——系统进程/UWP 常见、查询缓冲区不足等）一律返回
/// null/空串而非抛错；句柄即用即关，无常驻资源。
library;

import 'dart:ffi';
import 'dart:io' show Platform;

// Utf16（字符串缓冲类型，含 toDartString 扩展）与 calloc 来自本包。
import 'package:ffi/ffi.dart';

import '../../viewmodels/foreground_detector.dart';

// ---------------------------------------------------------------------------
// 原生/Dart 签名成对 typedef（lookupFunction 标准模式）
// ---------------------------------------------------------------------------

typedef _GetForegroundWindowC = IntPtr Function();
typedef _GetForegroundWindowDart = int Function();

typedef _GetWindowThreadProcessIdC = Void Function(
    IntPtr hwnd, Pointer<Uint32> pid);
typedef _GetWindowThreadProcessIdDart = void Function(
    int hwnd, Pointer<Uint32> pid);

typedef _OpenProcessC = IntPtr Function(
    Uint32 access, Int32 inheritHandle, Uint32 pid);
typedef _OpenProcessDart = int Function(
    int access, int inheritHandle, int pid);

typedef _QueryFullProcessImageNameC = Int32 Function(
    IntPtr process, Uint32 flags, Pointer<Uint16> buffer, Pointer<Uint32> size);
typedef _QueryFullProcessImageNameDart = int Function(
    int process, int flags, Pointer<Uint16> buffer, Pointer<Uint32> size);

typedef _CloseHandleC = Int32 Function(IntPtr handle);
typedef _CloseHandleDart = int Function(int handle);

typedef _GetWindowTextLengthC = Int32 Function(IntPtr hwnd);
typedef _GetWindowTextLengthDart = int Function(int hwnd);

typedef _GetWindowTextC = Int32 Function(
    IntPtr hwnd, Pointer<Uint16> buffer, Int32 count);
typedef _GetWindowTextDart = int Function(
    int hwnd, Pointer<Uint16> buffer, int count);

// ---------------------------------------------------------------------------
// 绑定持有者
// ---------------------------------------------------------------------------

/// Win32 API 绑定（懒加载单例；非 Windows 平台访问即抛，由
/// [WindowsForegroundDetector.isSupported]/装配层保证不会触达）。
class _Win32 {
  _Win32._();

  static final _Win32 instance = _Win32._();

  final DynamicLibrary user32 = DynamicLibrary.open('user32.dll');
  final DynamicLibrary kernel32 = DynamicLibrary.open('kernel32.dll');

  late final _GetForegroundWindowDart getForegroundWindow = user32
      .lookupFunction<_GetForegroundWindowC, _GetForegroundWindowDart>(
          'GetForegroundWindow');

  late final _GetWindowThreadProcessIdDart getWindowThreadProcessId = user32
      .lookupFunction<_GetWindowThreadProcessIdC,
          _GetWindowThreadProcessIdDart>('GetWindowThreadProcessId');

  late final _OpenProcessDart openProcess =
      kernel32.lookupFunction<_OpenProcessC, _OpenProcessDart>('OpenProcess');

  late final _QueryFullProcessImageNameDart queryFullProcessImageName =
      kernel32.lookupFunction<_QueryFullProcessImageNameC,
          _QueryFullProcessImageNameDart>('QueryFullProcessImageNameW');

  late final _CloseHandleDart closeHandle =
      kernel32.lookupFunction<_CloseHandleC, _CloseHandleDart>('CloseHandle');

  late final _GetWindowTextLengthDart getWindowTextLength = user32
      .lookupFunction<_GetWindowTextLengthC, _GetWindowTextLengthDart>(
          'GetWindowTextLengthW');

  late final _GetWindowTextDart getWindowText = user32.lookupFunction<
      _GetWindowTextC, _GetWindowTextDart>('GetWindowTextW');
}

const int _processQueryLimitedInformation = 0x1000;
const int _pathBufferSizeChars = 1024;

/// Windows 前台检测器（TrackingStore 装配用；仅 Windows 平台注册）。
class WindowsForegroundDetector implements ForegroundDetector {
  /// 当前平台是否支持（AppStore 装配判定用）。
  static bool get isSupported => Platform.isWindows;

  @override
  String? get processName {
    if (!Platform.isWindows) return null;
    final win32 = _Win32.instance;

    final hwnd = win32.getForegroundWindow();
    if (hwnd == 0) return null; // 无前台窗口（锁屏/切换瞬间）

    final pidBuf = calloc<Uint32>();
    final handleBuf = calloc<IntPtr>();
    // 字符串缓冲用 package:ffi 的 Utf16（自带 toDartString）；调用处按
    // Win32 签名 cast 回 Pointer<Uint16>。
    final pathBuf = calloc<Uint16>(_pathBufferSizeChars);
    final sizeBuf = calloc<Uint32>();
    var openHandle = 0;
    try {
      win32.getWindowThreadProcessId(hwnd, pidBuf);
      final pid = pidBuf.value;
      if (pid == 0) return null;

      openHandle = win32.openProcess(_processQueryLimitedInformation, 0, pid);
      if (openHandle == 0) return null; // 权限不足（系统进程等）

      sizeBuf.value = _pathBufferSizeChars;
      final ok = win32.queryFullProcessImageName(
          openHandle, 0, pathBuf, sizeBuf);
      if (ok == 0 || sizeBuf.value == 0) return null;

      final fullPath = pathBuf.cast<Utf16>().toDartString(length: sizeBuf.value);
      final fileName = fullPath.split('\\').last;
      return fileName.isEmpty ? null : fileName.toLowerCase();
    } on Error {
      // FFI 层契约外异常：收敛为"不可检测"——后台记录不因平台桥接崩溃。
      // ignore: avoid_print
      print('[foreground] 进程名查询异常');
      return null;
    } finally {
      if (openHandle != 0) {
        win32.closeHandle(openHandle);
      }
      calloc.free(pidBuf);
      calloc.free(handleBuf);
      calloc.free(pathBuf);
      calloc.free(sizeBuf);
    }
  }

  @override
  String? get windowTitle {
    if (!Platform.isWindows) return null;
    final win32 = _Win32.instance;

    final hwnd = win32.getForegroundWindow();
    if (hwnd == 0) return null;

    final length = win32.getWindowTextLength(hwnd);
    if (length <= 0) return '';

    final buf = calloc<Uint16>(length + 1);
    try {
      win32.getWindowText(hwnd, buf, length + 1);
      return buf.cast<Utf16>().toDartString(length: length);
    } on Error {
      // ignore: avoid_print
      print('[foreground] 窗口标题查询异常');
      return '';
    } finally {
      calloc.free(buf);
    }
  }
}
