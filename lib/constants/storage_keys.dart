/// `app_metadata` 表（key-value）的键名。
///
/// 技术选型无 shared_preferences：设备 id、同步游标、更新策略等本地
/// 持久化统一落 `app_metadata` 表（数据随库备份）。键名语义见各常量注释。
library;

class AppMetadataKeys {
  AppMetadataKeys._();

  /// 本设备稳定 id（UUID；LAN 配对/时间条目 device_id 来源）。
  static const deviceId = 'device_id';

  /// 增量同步游标：最近一次成功同步**实际处理数据的最大 updated_at（高水位）**，
  /// 而非墙钟完成时刻（同步期间新增行的 updated_at ≤ 该值，下一轮
  /// `>= 游标` 才不漏行；字段名 lastSyncAt 为历史命名，语义见
  /// sync_status_store.dart 的 SyncStatus.lastSuccessfulSyncAt）。
  static const lastSyncAt = 'last_sync_at';

  /// 最近一次云同步失败原因（可读消息；**游标真正推进时**清除——相等/乱序
  /// 成功分支保留，防抹掉游标未推进期间的真实失败记录）。
  static const lastSyncError = 'last_sync_error';

  /// 最近一次成功同步的目标（`supabase` / `lan`；未同步为空）。
  static const lastSyncTarget = 'last_sync_target';

  /// 被用户"忽略此版本"的更新版本号（更新系统：忽略版本持久化）。
  static const ignoredUpdateVersion = 'ignored_update_version';

  /// 最近一次成功检查更新的清单版本（判断"远端清单相对缓存是否有变化"）。
  static const lastCheckedManifestVersion = 'last_checked_manifest_version';

  /// 清理上次执行的保留期清理时间（控制清理频率）。
  static const lastCleanupAt = 'last_cleanup_at';

  /// 软删行保留期覆盖值（天；阶段 4 设置页写入，`CleanupService.retentionDays`
  /// 读：无值/非法回退 [AppConstants.defaultDeletedRetentionDays]）。
  static const deletedRetentionDays = 'deleted_retention_days';

  /// 全部键名（与定义同处维护；测试遍历做唯一性/非空校验，新增键自动纳入）。
  static const all = <String>[
    deviceId,
    lastSyncAt,
    lastSyncError,
    lastSyncTarget,
    ignoredUpdateVersion,
    lastCheckedManifestVersion,
    lastCleanupAt,
    deletedRetentionDays,
  ];
}
