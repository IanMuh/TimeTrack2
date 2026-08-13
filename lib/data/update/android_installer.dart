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

import 'dart:io'
    show File, FileSystemEntity, FileSystemEntityType, FileSystemException;

import '../../utils/result.dart';

/// Android 安装器（纯函数构造；真实 startActivity 由阶段 4 UI/平台层调用）。
class AndroidInstaller {
  const AndroidInstaller({this.providerAuthority = '$packageName.fileprovider'});

  /// 应用包名（FileProvider authority 后缀；与 android/app/build.gradle.kts 的
  /// applicationId 一致——阶段 4 Manifest 的 provider authority 基于它声明，
  /// 防测试锁死错误值导致真机安装 URI 授权失败）。
  static const packageName = 'com.github.ianmuh.timetrack2';
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
  /// 给外部安装器）。FileProvider 路径段固定为 `cache`（与阶段 4 file_paths.xml
  /// 的 cache-path 映射一致）。
  String apkContentUri(String apkFileName) {
    // **文件名显式拒绝（r2）**：Uri.encodeComponent 遵循 RFC 3986，`.` 属
    // 未保留字符不编码——裸 `..`/`.` 会产生带穿越段/当前段的 URI（FileProvider
    // 按路径段拼接会解析到 cache 根上级）。空串/`.`/`..`/路径分隔符一律拒绝。
    if (apkFileName.isEmpty ||
        apkFileName == '.' ||
        apkFileName == '..' ||
        apkFileName.contains('/') ||
        apkFileName.contains(r'\')) {
      throw ArgumentError.value(
        apkFileName,
        'apkFileName',
        '文件名不合法（不能为空、`.`、`..` 或含路径分隔符）',
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
  /// **authority 校验（r9）**：仅接受本应用 FileProvider 的 content:// URI——
  /// 防误传 `file://` 或其它 provider 的 URI 时，配合 GRANT 标志向系统安装器
  /// 授予对非预期文件的读取权限。
  ({String action, String dataUri, String mimeType, int flags})
      installIntentFor(String contentUri) {
    if (!contentUri.startsWith('content://$providerAuthority/')) {
      throw ArgumentError.value(
        contentUri,
        'contentUri',
        '必须是本应用 FileProvider 的 content:// URI',
      );
    }
    return (
      action: 'android.intent.action.VIEW',
      dataUri: contentUri,
      mimeType: apkMimeType,
      flags: 0x00000001, // FLAG_GRANT_READ_URI_PERMISSION
    );
  }

  /// 校验 APK 文件存在、为常规文件且非空（安装前置守卫；失败返回可读原因）。
  /// FileSystemException（并发删除/无权限）、目录与**符号链接**（statSync 跟随
  /// 链接、`type==link` 不会被常规文件判断拦住——防指向外部文件的链接绕过
  /// 守卫进入安装流程）均转失败。
  AppResult<void> ensureApkValid(String filePath) {
    try {
      // **显式拒绝符号链接（r9）**：`FileSystemEntity.typeSync(followLinks: false)`
      // 检测 link 类型——statSync 默认跟随链接，指向常规文件的链接 type 仍为
      // file 会被放行。
      if (FileSystemEntity.typeSync(filePath, followLinks: false) ==
          FileSystemEntityType.link) {
        return const AppFailure('安装文件路径不允许为符号链接');
      }
      final stat = File(filePath).statSync();
      if (stat.type != FileSystemEntityType.file) {
        return const AppFailure('安装文件路径不是常规文件');
      }
      if (stat.size == 0) {
        return const AppFailure('安装文件为空');
      }
      return const AppSuccess(null);
    } on FileSystemException {
      return const AppFailure('安装文件读取失败');
    }
  }
}
