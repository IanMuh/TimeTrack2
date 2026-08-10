/// `app_metadata` 表（key-value）的键名。
///
/// 技术选型无 shared_preferences：设备 id、同步游标、更新策略等本地
/// 持久化统一落 `app_metadata` 表（数据随库备份）。键名语义见各常量注释。
library;

class AppMetadataKeys {
  AppMetadataKeys._();

  /// 本设备稳定 id（UUID；LAN 配对/时间条目 device_id 来源）。
  static const deviceId = 'device_id';

  /// 最近一次云同步完成时刻（UTC ISO8601；增量同步游标起点）。
  static const lastSyncAt = 'last_sync_at';

  /// 被用户"忽略此版本"的更新版本号（更新系统：忽略版本持久化）。
  static const ignoredUpdateVersion = 'ignored_update_version';

  /// 最近一次成功检查更新的清单版本（判断"远端清单相对缓存是否有变化"）。
  static const lastCheckedManifestVersion = 'last_checked_manifest_version';

  /// 清理上次执行的保留期清理时间（控制清理频率）。
  static const lastCleanupAt = 'last_cleanup_at';

  /// 全部键名（与定义同处维护；测试遍历做唯一性/非空校验，新增键自动纳入）。
  static const all = <String>[
    deviceId,
    lastSyncAt,
    ignoredUpdateVersion,
    lastCheckedManifestVersion,
    lastCleanupAt,
  ];
}
