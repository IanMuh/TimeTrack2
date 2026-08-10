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
  });

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
  final String timezone;
  final DateTime updatedAt;

  static ProfileSettings defaults() {
    return ProfileSettings(
      timezone: DateTime.now().timeZoneName,
      updatedAt: DateTime.now(),
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ProfileSettings && runtimeType == other.runtimeType;

  @override
  int get hashCode => runtimeType.hashCode;

  ProfileSettings copyWith({
    String? userId,
    int? reminderMinutes,
    int? reminderIntervalMinutes,
    ReminderMethod? reminderMethod,
    int? reminderTimeOfDayMinutes,
    int? mergeNeighborThresholdMinutes,
    String? timezone,
    DateTime? updatedAt,
  }) {
    return ProfileSettings(
      userId: userId ?? this.userId,
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
      reminderMinutes: readInt(map['reminder_minutes'],
          fallback: defaultReminderMinutes),
      reminderIntervalMinutes: readInt(map['reminder_interval_minutes'],
          fallback: defaultReminderIntervalMinutes),
      reminderMethod: ReminderMethod.fromStorageValue(map['reminder_method']),
      reminderTimeOfDayMinutes: readInt(map['reminder_time_of_day_minutes'],
          fallback: defaultReminderTimeOfDayMinutes),
      mergeNeighborThresholdMinutes:
          readInt(map['merge_neighbor_threshold_minutes'],
              fallback: defaultMergeNeighborThresholdMinutes),
      timezone: readString(map['timezone'],
          fallback: DateTime.now().timeZoneName),
      updatedAt: readDateTime(map['updated_at']),
    );
  }
}
