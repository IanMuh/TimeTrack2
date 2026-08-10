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
  ProfileSettings({
    this.userId,
    this.reminderMinutes = defaultReminderMinutes,
    this.reminderIntervalMinutes = defaultReminderIntervalMinutes,
    this.reminderMethod = ReminderMethod.dialog,
    this.reminderTimeOfDayMinutes = defaultReminderTimeOfDayMinutes,
    this.mergeNeighborThresholdMinutes = defaultMergeNeighborThresholdMinutes,
    required this.timezone,
    required this.updatedAt,
  })  : assert(reminderMinutes >= 1 && reminderMinutes <= maxReminderMinutes),
        assert(reminderIntervalMinutes >= 1 &&
            reminderIntervalMinutes <= maxReminderMinutes),
        assert(
          reminderTimeOfDayMinutes >= 0 &&
              reminderTimeOfDayMinutes <= maxTimeOfDayMinutes,
        ),
        assert(mergeNeighborThresholdMinutes >= 0 &&
            mergeNeighborThresholdMinutes <=
                maxMergeNeighborThresholdMinutes),
        // timezone 语义上非空（fromMap/copyWith 均有空白兜底，直接构造是唯一旁路）。
        assert(timezone != '', 'timezone 不能为空') {
    // release 下 assert 被移除：直接构造空白 timezone 是绕过 fromMap/copyWith
    // 兜底的旁路，空白时区值会随 toMap 持久化污染数据。
    if (timezone.trim().isEmpty) {
      throw ArgumentError.value(timezone, 'timezone', 'timezone 不能为空');
    }
  }

  static const defaultReminderMinutes = 45;
  static const defaultReminderIntervalMinutes = 10;
  static const defaultReminderTimeOfDayMinutes = 540; // 9 * 60
  static const defaultMergeNeighborThresholdMinutes = 1;

  /// 提醒类分钟数的合理上界（24 小时）：防止极端大值导致异常调度结果。
  static const maxReminderMinutes = 24 * 60;

  /// 提醒时刻（分钟）上界：23:59。
  static const maxTimeOfDayMinutes = 23 * 60 + 59;

  /// 相邻未分配条目合并阈值（分钟）上界：24h——超出将近似合并所有相邻条目。
  static const maxMergeNeighborThresholdMinutes = 24 * 60;

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
    // 单次取 now：timezone 与 updatedAt 来自同一时刻（避免跨午夜边界快照不一致）。
    final now = DateTime.now();
    return ProfileSettings(
      timezone: now.timeZoneName,
      updatedAt: now,
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

  /// 复制并生成新实例。
  ///
  /// 注意：`copyWith` **不会自动推进 `updatedAt`**——LWW 合并以 updatedAt 决胜负，
  /// 修改业务字段后必须显式传入新的 updatedAt，否则修改会携带旧时间戳
  /// 在同步合并中被远端版本覆盖而丢失。
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
      // copyWith 与 fromMap 使用同一钳制：release 下同样保证不变量
      // （构造器 assert 在 release 被移除，故此处必须兜底）。
      reminderMinutes: _clampMinMax(
        reminderMinutes ?? this.reminderMinutes,
        min: 1,
        max: maxReminderMinutes,
      ),
      reminderIntervalMinutes: _clampMinMax(
        reminderIntervalMinutes ?? this.reminderIntervalMinutes,
        min: 1,
        max: maxReminderMinutes,
      ),
      reminderMethod: reminderMethod ?? this.reminderMethod,
      reminderTimeOfDayMinutes:
          _clampTimeOfDay(reminderTimeOfDayMinutes ?? this.reminderTimeOfDayMinutes),
      mergeNeighborThresholdMinutes: _clampMinMax(
        mergeNeighborThresholdMinutes ?? this.mergeNeighborThresholdMinutes,
        min: 0,
        max: maxMergeNeighborThresholdMinutes,
      ),
      // timezone 语义上应非空：空/空白串回退当前时区（防损坏数据持久化空值）。
      timezone: _nonEmptyOrFallback(timezone ?? this.timezone,
          fallback: DateTime.now().timeZoneName),
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
      reminderMinutes: _clampMinMax(
        readInt(map['reminder_minutes'], fallback: defaultReminderMinutes),
        min: 1,
        max: maxReminderMinutes,
      ),
      reminderIntervalMinutes: _clampMinMax(
        readInt(map['reminder_interval_minutes'],
            fallback: defaultReminderIntervalMinutes),
        min: 1,
        max: maxReminderMinutes,
      ),
      reminderMethod: ReminderMethod.fromStorageValue(map['reminder_method']),
      reminderTimeOfDayMinutes: _clampTimeOfDay(readInt(
          map['reminder_time_of_day_minutes'],
          fallback: defaultReminderTimeOfDayMinutes)),
      mergeNeighborThresholdMinutes: _clampMinMax(
          readInt(map['merge_neighbor_threshold_minutes'],
              fallback: defaultMergeNeighborThresholdMinutes),
          min: 0,
          max: maxMergeNeighborThresholdMinutes),
      timezone: _nonEmptyOrFallback(readString(map['timezone']),
          fallback: DateTime.now().timeZoneName),
      updatedAt: readDateTime(map['updated_at']),
    );
  }

  /// 返回 [value]（trim 后非空）否则 [fallback]；防空白时区值绕过兜底。
  static String _nonEmptyOrFallback(String value, {required String fallback}) {
    return value.trim().isEmpty ? fallback : value;
  }

  /// 将 [value] 钳制到 [min, max]。
  static int _clampMinMax(int value, {required int min, required int max}) {
    if (value < min) return min;
    if (value > max) return max;
    return value;
  }

  /// 将"分钟数"钳制到 [0, maxTimeOfDayMinutes]，防御损坏数据导致的越界提醒时间。
  static int _clampTimeOfDay(int value) {
    if (value < 0) return 0;
    if (value > maxTimeOfDayMinutes) return maxTimeOfDayMinutes;
    return value;
  }
}
