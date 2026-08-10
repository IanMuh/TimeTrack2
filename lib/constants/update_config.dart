/// 更新系统配置（计划"完整更新系统设计"）。
///
/// 管线：检查（update.json）→ 下载（流式+进度+指数退避重试）→ 校验（SHA-256）
/// → 安装（分平台：Windows staging+重启 / Android FileProvider+ACTION_VIEW）。
/// 数据目录与程序目录分离：待安装标记放数据目录。
library;

import 'build_config.dart';

class UpdateConfig {
  UpdateConfig._();

  /// 清单默认地址：本仓库 raw.githubusercontent（规避 Releases API 60 req/h 限额）。
  /// 可通过 `--dart-define=UPDATE_MANIFEST_URL=...` 覆盖；
  /// 注入串非法时回退默认仓库地址（不因构建配置失误击穿更新流程）。
  static final Uri defaultManifestUrl =
      Uri.tryParse(
        AppBuildConfig.getString(
          AppBuildConfig.updateManifestUrlKey,
          defaultValue:
              'https://raw.githubusercontent.com/IanMuh/TimeTrack2/main/update.json',
        ),
      ) ??
      Uri.parse(
        'https://raw.githubusercontent.com/IanMuh/TimeTrack2/main/update.json',
      );

  /// 检查超时（网络请求）。
  static const checkTimeout = Duration(seconds: 8);

  /// 下载失败指数退避重试次数（校验失败删重下，不占此次数）。
  static const downloadRetryCount = 3;

  /// 首次重试等待基时；每次失败等待 `base * 2^n`。
  static const retryBaseDelay = Duration(seconds: 2);

  /// 下载分块大小（流式写临时目录）。
  static const downloadChunkBytes = 64 * 1024;

  /// Windows 安装 staging 目录名（程序目录下；exe 未锁定时整体替换）。
  static const windowsStagingDirName = 'staging';

  /// 待安装标记文件名（放**数据目录**，与程序目录分离——计划铁律 12）。
  static const pendingInstallMarkerFile = 'pending-install.json';

  /// 校验失败后的重下次数（先删本地文件再重下）。
  static const redownloadAfterVerificationFailure = 1;
}
