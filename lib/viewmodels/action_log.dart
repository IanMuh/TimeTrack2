import '../utils/model_utils.dart';

/// 操作类型（持久化存储值为小写英文，兼容老项目 storageValue）。
///
/// 新增 `category*` 系列覆盖层级分类操作；CLI 指令系统（阶段 3）执行的
/// 操作均落一条 ActionLog（计划：操作自动继承日志）。
enum ActionType {
  switch_('switch'),
  stop('stop'),
  edit('edit'),
  delete('delete'),
  undo('undo'),
  redo('redo'),
  merge('merge'),
  manual('manual'),
  split('split'),
  activityDelete('activityDelete'),
  categoryCreate('category_create'),
  categoryUpdate('category_update'),
  categoryDelete('category_delete');

  const ActionType(this.storageValue);

  final String storageValue;

  static ActionType fromStorageValue(Object? value) {
    final text = value is String ? value : null;
    return ActionType.values.firstWhere(
      (type) => type.storageValue == text,
      orElse: () => ActionType.switch_,
    );
  }
}

/// 领域模型：操作日志（纯类型，零 Flutter 依赖）。
///
/// 记录一次用户操作（切换/停止/编辑/删除/合并/切割…），
/// 用于时间线历史展示与同步。
class ActionLog {
  const ActionLog({
    required this.id,
    this.userId,
    required this.actionType,
    this.activityId,
    this.entryId,
    this.message = '',
    required this.occurredAt,
    required this.deviceId,
    required this.updatedAt,
    this.deletedAt,
  });

  final String id;
  final String? userId;
  final ActionType actionType;
  final String? activityId;
  final String? entryId;
  final String message;
  final DateTime occurredAt;
  final String deviceId;
  final DateTime updatedAt;
  final DateTime? deletedAt;

  bool get isDeleted => deletedAt != null;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ActionLog && runtimeType == other.runtimeType && id == other.id;

  @override
  int get hashCode => id.hashCode;

  ActionLog copyWith({
    String? id,
    String? userId,
    bool clearUserId = false,
    ActionType? actionType,
    String? activityId,
    bool clearActivityId = false,
    String? entryId,
    bool clearEntryId = false,
    String? message,
    DateTime? occurredAt,
    String? deviceId,
    DateTime? updatedAt,
    DateTime? deletedAt,
    bool clearDeletedAt = false,
  }) {
    return ActionLog(
      id: id ?? this.id,
      userId: clearUserId ? null : userId ?? this.userId,
      actionType: actionType ?? this.actionType,
      activityId: clearActivityId ? null : activityId ?? this.activityId,
      entryId: clearEntryId ? null : entryId ?? this.entryId,
      message: message ?? this.message,
      occurredAt: occurredAt ?? this.occurredAt,
      deviceId: deviceId ?? this.deviceId,
      updatedAt: updatedAt ?? this.updatedAt,
      deletedAt: clearDeletedAt ? null : deletedAt ?? this.deletedAt,
    );
  }

  Map<String, Object?> toMap() {
    return {
      'id': id,
      'user_id': userId,
      'action_type': actionType.storageValue,
      'activity_id': activityId,
      'entry_id': entryId,
      'message': message,
      'occurred_at': occurredAt.toUtc().toIso8601String(),
      'device_id': deviceId,
      'updated_at': updatedAt.toUtc().toIso8601String(),
      'deleted_at': deletedAt?.toUtc().toIso8601String(),
    };
  }

  static ActionLog fromMap(Map<String, Object?> map) {
    final id = map['id'];
    if (id is! String || id.isEmpty) {
      throw const FormatException('ActionLog.fromMap: id 缺失或非法');
    }
    return ActionLog(
      id: id,
      userId: readNullableString(map['user_id']),
      actionType: ActionType.fromStorageValue(map['action_type']),
      activityId: readNullableString(map['activity_id']),
      entryId: readNullableString(map['entry_id']),
      message: readString(map['message']),
      occurredAt: readDateTime(map['occurred_at']),
      deviceId: readString(map['device_id'], fallback: 'unknown'),
      updatedAt: readDateTime(map['updated_at']),
      deletedAt: readNullableDateTime(map['deleted_at']),
    );
  }
}
