import '../utils/model_utils.dart';

/// 领域模型：时间条目（纯类型，零 Flutter 依赖）。
///
/// - `endAt == null` 表示运行中（未结束）。
/// - 携带活动名/色快照（`activityNameSnapshot` / `activityColorSnapshot`），
///   活动删除或改名后条目仍能还原展示（计划保留不变式 4）。
/// - `deletedAt` 替代老项目的 is_deleted 布尔位。
class TimeEntry {
  const TimeEntry({
    required this.id,
    this.userId,
    required this.activityId,
    this.activityNameSnapshot = '',
    this.activityColorSnapshot,
    required this.startAt,
    this.endAt,
    this.note = '',
    required this.deviceId,
    required this.updatedAt,
    this.deletedAt,
  });

  final String id;
  final String? userId;
  final String activityId;
  final String activityNameSnapshot;
  final int? activityColorSnapshot;
  final DateTime startAt;

  /// null 表示运行中。
  final DateTime? endAt;
  final String note;
  final String deviceId;
  final DateTime updatedAt;
  final DateTime? deletedAt;

  bool get isRunning => endAt == null;

  bool get isDeleted => deletedAt != null;

  /// 从 [startAt] 到实际结束（未结束时为 [now]）的时长。
  Duration durationUntil(DateTime now) {
    final effectiveEnd = endAt ?? now;
    if (effectiveEnd.isBefore(startAt)) return Duration.zero;
    return effectiveEnd.difference(startAt);
  }

  /// 落在 [windowStart, windowEnd) 时间窗内的时长（未结束时以 [now] 计）。
  Duration durationInWindow({
    required DateTime windowStart,
    required DateTime windowEnd,
    required DateTime now,
  }) {
    if (!windowStart.isBefore(windowEnd)) return Duration.zero;
    final effectiveEnd = endAt ?? now;
    if (!startAt.isBefore(windowEnd) || !effectiveEnd.isAfter(windowStart)) {
      return Duration.zero;
    }
    final clippedStart = startAt.isAfter(windowStart) ? startAt : windowStart;
    final clippedEnd = effectiveEnd.isBefore(windowEnd)
        ? effectiveEnd
        : windowEnd;
    if (!clippedStart.isBefore(clippedEnd)) return Duration.zero;
    return clippedEnd.difference(clippedStart);
  }

  /// 半开区间重叠判定：`endAt == null` 视为 +∞（运行中条目与任何后续条目重叠）。
  bool overlaps(TimeEntry other) {
    final thisEnd = endAt;
    final otherEnd = other.endAt;
    return (otherEnd == null || startAt.isBefore(otherEnd)) &&
        (thisEnd == null || other.startAt.isBefore(thisEnd));
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is TimeEntry && runtimeType == other.runtimeType && id == other.id;

  @override
  int get hashCode => id.hashCode;

  @override
  String toString() =>
      'TimeEntry(id: $id, activityId: $activityId, startAt: $startAt, '
      'endAt: $endAt, isDeleted: $isDeleted)';

  TimeEntry copyWith({
    String? id,
    String? userId,
    bool clearUserId = false,
    String? activityId,
    String? activityNameSnapshot,
    int? activityColorSnapshot,
    bool clearActivityColorSnapshot = false,
    DateTime? startAt,
    DateTime? endAt,
    bool clearEndAt = false,
    String? note,
    String? deviceId,
    DateTime? updatedAt,
    DateTime? deletedAt,
    bool clearDeletedAt = false,
  }) {
    return TimeEntry(
      id: id ?? this.id,
      userId: clearUserId ? null : userId ?? this.userId,
      activityId: activityId ?? this.activityId,
      activityNameSnapshot: activityNameSnapshot ?? this.activityNameSnapshot,
      activityColorSnapshot: clearActivityColorSnapshot
          ? null
          : activityColorSnapshot ?? this.activityColorSnapshot,
      startAt: startAt ?? this.startAt,
      endAt: clearEndAt ? null : endAt ?? this.endAt,
      note: note ?? this.note,
      deviceId: deviceId ?? this.deviceId,
      updatedAt: updatedAt ?? this.updatedAt,
      deletedAt: clearDeletedAt ? null : deletedAt ?? this.deletedAt,
    );
  }

  Map<String, Object?> toMap() {
    return {
      'id': id,
      'user_id': userId,
      'activity_id': activityId,
      'activity_name': activityNameSnapshot,
      'activity_color': activityColorSnapshot,
      'start_at': startAt.toUtc().toIso8601String(),
      'end_at': endAt?.toUtc().toIso8601String(),
      'note': note,
      'device_id': deviceId,
      'updated_at': updatedAt.toUtc().toIso8601String(),
      'deleted_at': deletedAt?.toUtc().toIso8601String(),
    };
  }

  static TimeEntry fromMap(Map<String, Object?> map) {
    final id = map['id'];
    if (id is! String || id.isEmpty) {
      throw const FormatException('TimeEntry.fromMap: id 缺失或非法');
    }
    // start_at 语义必填：缺失/不可解析即抛错，绝不伪造"当前时刻"的幽灵条目。
    final startAtValue = map['start_at'];
    final startAt = startAtValue is String
        ? DateTime.tryParse(startAtValue)
        : null;
    if (startAt == null) {
      throw const FormatException('TimeEntry.fromMap: start_at 缺失或非法');
    }
    return TimeEntry(
      id: id,
      userId: readNullableString(map['user_id']),
      // activity_id 缺省容忍为空串（旧数据/损坏记录不阻断整体反序列化），
      // 条目的展示可依赖 activityNameSnapshot 快照。
      activityId: readString(map['activity_id']),
      activityNameSnapshot: readString(map['activity_name']),
      activityColorSnapshot: readNullableInt(map['activity_color']),
      startAt: startAt.toLocal(),
      endAt: readNullableDateTime(map['end_at']),
      note: readString(map['note']),
      deviceId: readString(map['device_id'], fallback: 'unknown'),
      updatedAt: readDateTime(map['updated_at']),
      deletedAt: readNullableDateTime(map['deleted_at']),
    );
  }
}
