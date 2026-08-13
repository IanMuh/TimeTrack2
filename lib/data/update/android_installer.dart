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

import 'dart:io' show File, FileSystemException;

import '../../utils/result.dart';

/// Android 安装器（纯函数构造；真实 startActivity 由阶段 4 UI/平台层调用）。
class AndroidInstaller {
  const AndroidInstaller({this.providerAuthority = '$packageName.fileprovider'});

  /// 应用包名（FileProvider authority 后缀；阶段 4 Manifest 对齐）。
  static const packageName = 'com.example.timetrack2';
  /// FileProvider authority（与阶段 4 Manifest 的 provider 声明一致）。
  final String providerAuthority;

  /// APK MIME 类型（ACTION_VIEW 安装必需的显式 type——FileProvider 无法为
  /// package archive 推断 MIME，缺省会解析不到安装器 Activity）。
  static const apkMimeType = 'application/vnd.android.package-archive';

  /// 校验通过的 APK → content URI 字符串（FileProvider 路径）。
  ///
  /// **文件名按段编码（r1 安全修复）**：`Uri.encodeComponent` 把空格/`#`/`?`/
  /// `%` 编码掉（防 URI 解析错误），同时把 `..` 编码为 `%2E%2E` 阻断路径穿越
  ///（配合 FLAG_GRANT_READ_URI_PERMISSION 不得把 cache 根目录之外的文件暴露
  /// 给外部安装器）。`cacheDirPath` 仅用于校验文件名不含路径分隔符——实际
  /// FileProvider 路径段固定为 `cache`（与阶段 4 file_paths.xml 的 cache-path
  /// 映射一致）。
  String apkContentUri(String cacheDirPath, String apkFileName) {
    if (apkFileName.contains('/') || apkFileName.contains(r'\')) {
      throw ArgumentError.value(
        apkFileName,
        'apkFileName',
        '文件名不得含路径分隔符（应仅为文件名）',
      );
    }
    final encoded = Uri.encodeComponent(apkFileName);
    return 'content://$providerAuthority/cache/$encoded';
  }

  /// 构造安装 Intent 的参数（ACTION_VIEW + data URI + MIME + GRANT 标志）。
  ///
  /// 返回 (action, dataUri, mimeType, flags)——阶段 4 平台层据此调
  /// `Intent(ACTION_VIEW).setDataAndType(contentUri, mime).addFlags(flags)`
  /// 并 startActivity。**dataUri 参与结果**（防调用方误传 URI）、**携带 MIME**
  ///（系统才能解析到安装器 Activity）。
  ({String action, String dataUri, String mimeType, int flags})
      installIntentFor(String contentUri) {
    return (
      action: 'android.intent.action.VIEW',
      dataUri: contentUri,
      mimeType: apkMimeType,
      flags: 0x00000001, // FLAG_GRANT_READ_URI_PERMISSION
    );
  }

  /// 校验 APK 文件存在且非空（安装前置守卫；失败返回可读原因）。
  /// FileSystemException（并发删除/无权限/路径为目录）捕获转 AppFailure。
  AppResult<void> ensureApkValid(String filePath) {
    try {
      final file = File(filePath);
      if (!file.existsSync()) {
        return const AppFailure('安装文件不存在');
      }
      if (file.lengthSync() == 0) {
        return const AppFailure('安装文件为空');
      }
      return const AppSuccess(null);
    } on FileSystemException {
      return const AppFailure('安装文件读取失败');
    }
  }
}
