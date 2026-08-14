/// 应用级默认值与阈值（编译期常量，纯 Dart 无 Flutter 依赖）。
///
/// 迁移自老项目 `core/app_constants.dart`；数值语义保持一致。
/// 默认色在 `viewmodels` 中各有独立回退常量（模型层容错用），
/// 本文件为正式单一事实来源——一致性由测试 `test/constants/` 断言锁定。
library;

class AppConstants {
  AppConstants._();

  /// 默认事项色（与 `viewmodels/activity.dart` 的 `Activity.defaultColor` 一致）。
  static const defaultActivityColor = 0xff64748b;

  /// 默认分类色（与 `viewmodels/activity_category.dart` 的 `ActivityCategory.defaultColor` 一致）。
  static const defaultCategoryColor = 0xff0f766e;

  /// 开放结束条目（无 endAt）的哨兵日期：2100 足够覆盖任何实际记录，
  /// 仍在 Dart DateTime 范围内。
  static final farFutureDate = DateTime(2100);

  /// Dart 可表示的最大 DateTime，作为重叠计算中的"无限"哨兵。
  static final maxDateTime = DateTime.fromMillisecondsSinceEpoch(
    8640000000000000,
  );

  /// 单条运行中条目超过此时长视为可疑。
  static const suspiciousEntryHours = 12;

  /// 新建配置的默认提醒参数（分钟）。
  static const defaultReminderMinutes = 45;
  static const defaultReminderIntervalMinutes = 10;
  static const defaultReminderTimeOfDayMinutes = 540; // 9 * 60

  /// 相邻未分配条目合并判定阈值（分钟）默认值。
  static const defaultMergeNeighborThresholdMinutes = 1;

  /// LAN 同步默认端口（端口候选范围起点）。
  static const lanDefaultPort = 8787;

  /// LAN 同步端口候选范围（默认端口被占用时依次尝试到 8797）。
  static const lanPortRangeStart = 8787;
  static const lanPortRangeEnd = 8797;

  /// LAN 配对码有效期（6 位数字，超期即失效，防猜测复用）。
  static const lanPairingCodeTtl = Duration(minutes: 5);

  /// LAN 每 IP 每分钟请求限流次数（配对/同步端点共用，防暴力猜码/滥用）。
  static const lanRateLimitPerMinute = 5;

  /// LAN 请求超时（连接/响应头/响应体各阶段共用）。
  static const lanRequestTimeout = Duration(seconds: 8);

  /// LAN 请求/响应体大小上限（防内存耗尽；正常全量 bundle 远小于此）。
  static const lanMaxPayloadBytes = 256 * 1024 * 1024;

  /// LAN 配对码位数（6 位数字）。
  static const lanPairingCodeLength = 6;

  /// 软删行保留期（天）：软删超此天数才允许物理删除（模块 2f）。
  ///
  /// **默认值（单一事实来源）**：`CleanupService.retentionDays()` 的常量回退
  /// 取此值；阶段 4 设置页可经 `app_metadata[deletedRetentionDays]` 覆盖
  ///（读侧已就位，只加写入口）。
  static const defaultDeletedRetentionDays = 180;

  /// VACUUM 阈值（行）：单次清理物理删除超过此行数才执行 VACUUM +
  /// wal_checkpoint(TRUNCATE)——小删除/零删除不触发全库重写（空间回收与
  /// I/O 成本权衡）。
  static const cleanupVacuumThresholdRows = 1000;

  /// 清理自动触发限频间隔（小时）：`last_cleanup_at` 距今 ≥ 此值才允许
  /// 自动清理（模块 3c SyncStore 编排用）。墓碑保留期默认 180 天，24h 的
  /// 清扫粒度绰绰有余（成本 × 及时性平衡点）。手动清理不受限频约束。
  static const cleanupIntervalHours = 24;
}
