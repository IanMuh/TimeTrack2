/// Android 更新安装器（计划"完整更新系统设计"·Android 安装）。
///
/// 流程：APK 下载 cache → 校验 → FileProvider content:// URI → ACTION_VIEW
/// + FLAG_GRANT_READ_URI_PERMISSION。
///
/// 本文件实现**纯函数部分**（可单测）：校验后的 APK 文件 → 构造 FileProvider
/// content URI → 安装 Intent 的权限标志。**平台侧配置归阶段 4**：
/// - AndroidManifest：`REQUEST_INSTALL_PACKAGES` 权限、FileProvider 声明、
///   `grantUriPermissions`；
/// - `res/xml/file_paths.xml`：`<cache-path>` 映射；
/// - 未授权来源安装引导（`ACTION_MANAGE_UNKNOWN_APP_SOURCES`）。
library;

import 'dart:io';

import '../../utils/result.dart';

/// Android 安装器（纯函数构造；真实 startActivity 由阶段 4 UI/平台层调用）。
class AndroidInstaller {
  const AndroidInstaller({this.providerAuthority = '$packageName.fileprovider'});

  /// 应用包名（FileProvider authority 后缀；阶段 4 Manifest 对齐）。
  static const packageName = 'com.example.timetrack2';
  /// FileProvider authority（与阶段 4 Manifest 的 provider 声明一致）。
  final String providerAuthority;

  /// 校验通过的 APK → content URI 字符串（FileProvider 路径）。
  ///
  /// 约定：APK 放应用 cache 目录下（FileProvider 以 cache-path 映射），
  /// 文件名编码规范化（防 URI 特殊字符）。返回 `content://authority/cache/<name>`。
  /// 纯函数：不检查文件存在（调用方 `UpdateVerifier` 已确认校验通过）。
  String apkContentUri(String cacheDirPath, String apkFileName) {
    return 'content://$providerAuthority/cache/$apkFileName';
  }

  /// 构造安装 Intent 的权限标志（ACTION_VIEW + GRANT_READ_URI_PERMISSION）。
  ///
  /// 返回 (action, flags) 元组——阶段 4 平台层据此调
  /// `Intent(ACTION_VIEW, contentUri).addFlags(flags)` 并 startActivity。
  ({String action, int flags}) installIntentFor(String contentUri) {
    return (
      action: 'android.intent.action.VIEW',
      flags: 0x00000001, // FLAG_GRANT_READ_URI_PERMISSION
    );
  }

  /// 校验 APK 文件存在且非空（安装前置守卫；失败返回可读原因）。
  AppResult<void> ensureApkValid(String filePath) {
    final file = File(filePath);
    if (!file.existsSync()) {
      return const AppFailure('安装文件不存在');
    }
    if (file.lengthSync() == 0) {
      return const AppFailure('安装文件为空');
    }
    return const AppSuccess(null);
  }
}
