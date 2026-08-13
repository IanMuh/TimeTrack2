/// 更新系统配置（计划"完整更新系统设计"）。
///
/// 管线：检查（update.json）→ 下载（流式+进度+指数退避重试）→ 校验（SHA-256）
/// → 安装（分平台：Windows staging+重启 / Android FileProvider+ACTION_VIEW）。
/// 数据目录与程序目录分离：待安装标记放数据目录。
library;

import 'build_config.dart';

class UpdateConfig {
  UpdateConfig._();

  /// 默认清单地址字面量（单一事实来源：defaultValue 与回退共用，防 URL 更新漏改）。
  static const _defaultManifestUrl =
      'https://raw.githubusercontent.com/IanMuh/TimeTrack2/main/update.json';

  /// 清单默认地址：本仓库 raw.githubusercontent（规避 Releases API 60 req/h 限额）。
  /// 可通过 `--dart-define=UPDATE_MANIFEST_URL=...` 覆盖；
  /// 注入串非法（不可解析/非绝对/非 http·https/无主机名）时回退默认仓库地址，
  /// 不因构建配置失误击穿更新流程。
  static final Uri defaultManifestUrl =
      resolveManifestUrl(
        AppBuildConfig.getString(
          AppBuildConfig.updateManifestUrlKey,
          defaultValue: _defaultManifestUrl,
        ),
      ) ??
      Uri.parse(_defaultManifestUrl);

  /// 校验清单 URL（纯函数，可独立单测）：合法返回 Uri，非法返回 null（调用方回退默认）。
  ///
  /// 合法性：绝对地址 + scheme 为 http/https + 含主机名
  /// （`Uri.tryParse` 对相对 URI（`foobar`）、scheme-only（`https:`）、
  /// 无 host（`https://`）也会返回非 null，故须额外校验）。
  static Uri? resolveManifestUrl(String raw) {
    final uri = Uri.tryParse(raw);
    if (uri != null &&
        uri.isAbsolute &&
        (uri.scheme == 'http' || uri.scheme == 'https') &&
        uri.hasAuthority &&
        uri.host.isNotEmpty) {
      return uri;
    }
    return null;
  }

  /// 检查超时（网络请求）。
  static const checkTimeout = Duration(seconds: 8);

  /// 下载失败指数退避重试次数（校验失败删重下，不占此次数）。
  static const downloadRetryCount = 3;

  /// 首次重试等待基时；每次失败等待 `base * 2^n`。
  static const retryBaseDelay = Duration(seconds: 2);

  /// **响应体流读取超时（r1）**：响应头已返回但流挂起/断流不报错会无限等待
  /// ——给整个流消费过程设独立超时（与检查超时语义区分：检查是头超时、
  /// 下载是体超时；慢网络下流式按块推进不会误触）。
  static const downloadStreamTimeout = Duration(seconds: 60);

  /// 下载分块大小（流式写临时目录）。
  static const downloadChunkBytes = 64 * 1024;

  /// Windows 安装 staging 目录名（程序目录下；exe 未锁定时整体替换）。
  static const windowsStagingDirName = 'staging';

  /// 待安装标记文件名（放**数据目录**，与程序目录分离——计划铁律 12）。
  static const pendingInstallMarkerFile = 'pending-install.json';

  /// 校验失败后的重下次数（先删本地文件再重下）。
  static const redownloadAfterVerificationFailure = 1;

  /// **zip bomb 防护上限（r9）**：单条目解压后体积上限（500 MB）。
  static const maxUncompressedEntryBytes = 500 * 1024 * 1024;

  /// **zip bomb 防护上限（r9）**：累计解压总体积上限（1 GB）。
  static const maxTotalUncompressedBytes = 1024 * 1024 * 1024;

  /// **zip bomb 防护上限（r13）**：压缩后文件大小上限（200 MB）。
  static const maxCompressedBytes = 200 * 1024 * 1024;

  /// **zip bomb 防护上限（r13）**：zip 条目数上限（10 万，防海量小条目攻击）。
  static const maxEntryCount = 100000;
}
