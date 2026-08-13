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
    show
        Directory,
        File,
        FileSystemEntity,
        FileSystemEntityType,
        FileSystemException;

import '../../utils/result.dart';

/// Android 安装器（纯函数构造；真实 startActivity 由阶段 4 UI/平台层调用）。
class AndroidInstaller {
  const AndroidInstaller({
    this.providerAuthority = '$packageName.fileprovider',
  });

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
  /// **authority + 路径校验（r9/r14/r16）**：仅接受本应用 FileProvider 的
  /// `content://<authority>/cache/<单文件段>` URI——防误传 `file://` 或其它
  /// provider 的 URI，也防**同一 authority 下任意 path**（如未来 file_paths.xml
  /// 追加 files-path 映射、`%2E%2E` 编码穿越段）配合 GRANT 标志把 cache 根
  /// 目录之外的文件暴露给系统安装器。`pathSegments` 已做 percent-decode：
  /// `%2E%2E` 解码为 `..` 段、**`%2F` 解码为 `/` 但不触发重新分段**——
  /// `cache/..%2Ffoo` 得到单段 `../foo`，裸 `..` 检查会放行而 FileProvider 的
  /// `new File(cacheDir, '../foo')` 把文件定位到 cache 根目录之外（r16）——
  /// 须按"解码后段内含 `/`"一并拒绝。
  ({String action, String dataUri, String mimeType, int flags})
  installIntentFor(String contentUri) {
    final uri = Uri.tryParse(contentUri);
    final segments = uri == null ? const <String>[] : uri.pathSegments;
    if (uri == null ||
        uri.scheme != 'content' ||
        uri.authority != providerAuthority ||
        segments.length != 2 ||
        segments[0] != 'cache' ||
        segments[1].isEmpty ||
        segments[1] == '.' ||
        segments[1] == '..' ||
        // **r16**：percent-decode 后段内含 `/`（`%2F` 绕过，FileProvider
        // new File(cacheDir, '../foo') 逃逸到 cache 根目录之外）。
        segments[1].contains('/')) {
      throw ArgumentError.value(
        contentUri,
        'contentUri',
        '必须是本应用 FileProvider cache 根目录下的 content:// URI',
      );
    }
    return (
      action: 'android.intent.action.VIEW',
      dataUri: contentUri,
      mimeType: apkMimeType,
      flags: 0x00000001, // FLAG_GRANT_READ_URI_PERMISSION
    );
  }

  /// **单一安全入口（r19/r20/r21）**：内部依次 [ensureApkValid] → 父目录校验 →
  /// [apkContentUri] → [installIntentFor]，把"文件校验→cache 根内约束→URI
  /// 构造→Intent"固化为一条不可拆分路径，杜绝调用方绕过校验直接拿
  /// [installIntentFor] 构造 GRANT 意图暴露 cache 根之外的文件。任一环失败返回
  /// 可读原因（不产生部分结果）。
  ///
  /// **[cacheRoot]（r20/r21 修正）**：APK 必须**直接**位于应用 cache 根目录内
  ///（父目录与 cacheRoot **严格相等**，非前缀匹配）——产出的
  /// `content://…/cache/<名>` URI 只取单段文件名、FileProvider 解析为
  /// `$cacheRoot/<名>`；若允许子目录（`$cacheRoot/sub/app.apk`）会通过校验但
  /// URI 指向 `$cacheRoot/app.apk`（根下同名文件被误装/找不到文件），破坏
  /// "校验的文件 == GRANT 暴露/安装的文件"核心不变量。父目录按规范化绝对路径
  /// 比较（防相对路径/尾分隔符差异绕过）。
  ///
  /// **词法级约束边界（r21 注明）**：cacheRoot 由调用方传入、校验为词法级
  ///（absolute + 分隔符替换），**未解析符号链接**——调用方传真实 cache 根
  ///（平台惯例：PathProvider 等）；cache 根内指向外部的链接子目录逃逸属
  /// ensureApkValid 已知边界（只查末尾分量），最终兜底在阶段 4 [tryInstallApk]
  /// 平台守卫级实现。
  AppResult<({String action, String dataUri, String mimeType, int flags})>
  installValidatedApk(String apkFilePath, {required String cacheRoot}) {
    final check = ensureApkValid(apkFilePath);
    if (check is AppFailure<void>) {
      return AppFailure(check.message);
    }
    final fileParent = File(
      apkFilePath,
    ).parent.absolute.path.replaceAll(r'\', '/');
    // **尾分隔符归一化（r22）**：`Directory(cacheRoot).absolute.path` 在 cacheRoot
    // 以 `/` 结尾时保留尾斜杠（package:path normalize 保留尾部），而
    // File.parent.absolute.path 末尾不带——严格相等下带尾斜杠传入会被误拒。
    // 根目录为 `/` 时（长度 1）不裁剪。
    var root = Directory(cacheRoot).absolute.path.replaceAll(r'\', '/');
    if (root.length > 1 && root.endsWith('/')) {
      root = root.substring(0, root.length - 1);
    }
    if (fileParent != root) {
      return const AppFailure('安装文件必须位于应用 cache 根目录内');
    }
    final contentUri = apkContentUri(apkFileName(apkFilePath));
    final intent = installIntentFor(contentUri);
    return AppSuccess(intent);
  }

  /// **平台守卫级安装入口（r19，阶段 4 实现，r20 标记未实现）**：兜底
  /// [installValidatedApk] 无法覆盖的两类残余风险——(1) 校验与系统安装器读取
  /// 之间文件被替换（TOCTOU）；(2) cache 根目录本身或上级路径被替换为指向
  /// 外部的符号链接（守卫只查末尾分量）。平台层（阶段 4）须在**同一文件系统
  /// 快照内**完成：读取 cache 根目录的 FileProvider 实际文件路径（含上级路径
  /// 解析）→ stat/type 复核为常规文件且位于 cache 根内 → 再 startActivity。
  ///
  /// **r20 起显式抛 UnsupportedError（而非静默转发 installValidatedApk）**：
  /// 该入口命名易被误当作已加固的安装入口直接接入生产调用——在阶段 4 真正
  /// 实现前禁止无守卫静默调用。
  AppResult<({String action, String dataUri, String mimeType, int flags})>
  tryInstallApk(String apkFilePath, {required String cacheRoot}) {
    throw UnsupportedError(
      'tryInstallApk 为阶段 4 平台守卫级入口，尚未实现——请使用 installValidatedApk 并自行保证 cache 根内约束',
    );
  }

  /// 从文件路径提取文件名（`cache/<名>` URI 的构造依据）。
  static String apkFileName(String filePath) =>
      filePath.split(RegExp(r'[\\/]')).last;

  /// 校验 APK 文件存在、为常规文件且非空（安装前置守卫；失败返回可读原因）。
  /// FileSystemException（并发删除/无权限）、目录与**符号链接**（statSync 跟随
  /// 链接、`type==link` 不会被常规文件判断拦住——防指向外部文件的链接绕过
  /// 守卫进入安装流程）均转失败。
  ///
  /// **只校验路径最终分量（r19 注明）**：`followLinks: false` 仅对末尾分量
  /// 生效、不校验上级路径分量是否为符号链接（指向外部目录的父级链接仍会被
  /// 跟随）——文件实际解析位置与 TOCTOU（校验与 startActivity 之间被替换）的
  /// 最终兜底在平台层 [tryInstallApk]（系统安装器读取前文件仍是校验时文件）。
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
