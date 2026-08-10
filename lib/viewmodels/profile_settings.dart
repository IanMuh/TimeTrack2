import 'dart:math' as math;

import '../utils/model_utils.dart';

/// 提醒方式（持久化存储值为小写英文，见 [ReminderMethod.storageValue]）。
enum ReminderMethod {
  dialog('dialog'),
  banner('banner'),
  silent('silent');

  const ReminderMethod(this.storageValue);

  final String storageValue;

  static ReminderMethod fromStorageValue(Object? value) {
    final text = value is String ? value : null;
    return ReminderMethod.values.firstWhere(
      (method) => method.storageValue == text,
      orElse: () => ReminderMethod.dialog,
    );
  }
}

/// 领域模型：配置文件（单例，纯类型，零 Flutter 依赖）。
///
/// 本地库中为 id=1 的单行；含提醒设置与"相邻未分配条目合并阈值"。
class ProfileSettings {
  const ProfileSettings({
    this.userId,
    this.reminderMinutes = defaultReminderMinutes,
    this.reminderIntervalMinutes = defaultReminderIntervalMinutes,
    this.reminderMethod = ReminderMethod.dialog,
    this.reminderTimeOfDayMinutes = defaultReminderTimeOfDayMinutes,
    this.mergeNeighborThresholdMinutes = defaultMergeNeighborThresholdMinutes,
    required this.timezone,
    required this.updatedAt,
  })  : assert(reminderMinutes >= 1),
        assert(reminderIntervalMinutes >= 1),
        assert(
          reminderTimeOfDayMinutes >= 0 &&
              reminderTimeOfDayMinutes <= 23 * 60 + 59,
        ),
        assert(mergeNeighborThresholdMinutes >= 0);

  static const defaultReminderMinutes = 45;
  static const defaultReminderIntervalMinutes = 10;
  static const defaultReminderTimeOfDayMinutes = 540; // 9 * 60
  static const defaultMergeNeighborThresholdMinutes = 1;

  final String? userId;
  final int reminderMinutes;
  final int reminderIntervalMinutes;
  final ReminderMethod reminderMethod;
  final int reminderTimeOfDayMinutes;

  /// 相邻未分配条目合并判定阈值（分钟），见不变式 7。
  final int mergeNeighborThresholdMinutes;
  /// 时区标识。注意：`DateTime.now().timeZoneName` 通常为缩写（如 CST），
  /// 非稳定 IANA 标识，跨设备/DST 还原能力有限——当前仅作展示与兼容用途，
  /// 一期不依赖它做跨时区调度；如需精确时区（IANA）留待二期随登录/多时区需求处理。
  final String timezone;
  final DateTime updatedAt;

  static ProfileSettings defaults() {
    return ProfileSettings(
      timezone: DateTime.now().timeZoneName,
      updatedAt: DateTime.now(),
    );
  }

  /// 值相等语义：单例配置无稳定 id，逐字段比较（供变更检测/测试断言）。
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ProfileSettings &&
          runtimeType == other.runtimeType &&
          userId == other.userId &&
          reminderMinutes == other.reminderMinutes &&
          reminderIntervalMinutes == other.reminderIntervalMinutes &&
          reminderMethod == other.reminderMethod &&
          reminderTimeOfDayMinutes == other.reminderTimeOfDayMinutes &&
          mergeNeighborThresholdMinutes ==
              other.mergeNeighborThresholdMinutes &&
          timezone == other.timezone &&
          updatedAt == other.updatedAt;

  @override
  int get hashCode => Object.hash(
        userId,
        reminderMinutes,
        reminderIntervalMinutes,
        reminderMethod,
        reminderTimeOfDayMinutes,
        mergeNeighborThresholdMinutes,
        timezone,
        updatedAt,
      );

  ProfileSettings copyWith({
    String? userId,
    bool clearUserId = false,
    int? reminderMinutes,
    int? reminderIntervalMinutes,
    ReminderMethod? reminderMethod,
    int? reminderTimeOfDayMinutes,
    int? mergeNeighborThresholdMinutes,
    String? timezone,
    DateTime? updatedAt,
  }) {
    return ProfileSettings(
      userId: clearUserId ? null : userId ?? this.userId,
      reminderMinutes: reminderMinutes ?? this.reminderMinutes,
      reminderIntervalMinutes:
          reminderIntervalMinutes ?? this.reminderIntervalMinutes,
      reminderMethod: reminderMethod ?? this.reminderMethod,
      reminderTimeOfDayMinutes:
          reminderTimeOfDayMinutes ?? this.reminderTimeOfDayMinutes,
      mergeNeighborThresholdMinutes:
          mergeNeighborThresholdMinutes ?? this.mergeNeighborThresholdMinutes,
      timezone: timezone ?? this.timezone,
      updatedAt: updatedAt ?? this.updatedAt,
    );
  }

  Map<String, Object?> toMap() {
    return {
      'user_id': userId,
      'reminder_minutes': reminderMinutes,
      'reminder_interval_minutes': reminderIntervalMinutes,
      'reminder_method': reminderMethod.storageValue,
      'reminder_time_of_day_minutes': reminderTimeOfDayMinutes,
      'merge_neighbor_threshold_minutes': mergeNeighborThresholdMinutes,
      'timezone': timezone,
      'updated_at': updatedAt.toUtc().toIso8601String(),
    };
  }

  static ProfileSettings fromMap(Map<String, Object?> map) {
    return ProfileSettings(
      userId: readNullableString(map['user_id']),
      reminderMinutes: math.max(1,
          readInt(map['reminder_minutes'], fallback: defaultReminderMinutes)),
      reminderIntervalMinutes: math.max(1,
          readInt(map['reminder_interval_minutes'],
              fallback: defaultReminderIntervalMinutes)),
      reminderMethod: ReminderMethod.fromStorageValue(map['reminder_method']),
      reminderTimeOfDayMinutes: _clampTimeOfDay(readInt(
          map['reminder_time_of_day_minutes'],
          fallback: defaultReminderTimeOfDayMinutes)),
      mergeNeighborThresholdMinutes: math.max(
          0,
          readInt(map['merge_neighbor_threshold_minutes'],
              fallback: defaultMergeNeighborThresholdMinutes)),
      timezone: readString(map['timezone'],
          fallback: DateTime.now().timeZoneName),
      updatedAt: readDateTime(map['updated_at']),
    );
  }

  /// 将"分钟数"钳制到 [0, 23*60+59]，防御损坏数据导致的越界提醒时间。
  static int _clampTimeOfDay(int value) {
    if (value < 0) return 0;
    if (value > 23 * 60 + 59) return 23 * 60 + 59;
    return value;
  }
}
