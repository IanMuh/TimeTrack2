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
  static final maxDateTime =
      DateTime.fromMillisecondsSinceEpoch(8640000000000000);

  /// 单条运行中条目超过此时长视为可疑。
  static const suspiciousEntryHours = 12;

  /// 新建配置的默认提醒参数（分钟）。
  static const defaultReminderMinutes = 45;
  static const defaultReminderIntervalMinutes = 10;
  static const defaultReminderTimeOfDayMinutes = 540; // 9 * 60

  /// 相邻未分配条目合并判定阈值（分钟）默认值。
  static const defaultMergeNeighborThresholdMinutes = 1;

  /// LAN 同步默认端口。
  static const lanDefaultPort = 8787;
}
