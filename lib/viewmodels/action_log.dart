import '../utils/model_utils.dart';

/// 操作类型（持久化存储值统一为**小写 snake_case**，与 category 系列一致）。
///
/// `activityDelete` 在老项目历史数据中的存储值为 `'activityDelete'`（camelCase），
/// 新版统一为 `'activity_delete'`；读取端 [fromStorageValue] 对两者均能识别（兼容旧数据）。
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
  activityDelete('activity_delete'),
  categoryCreate('category_create'),
  categoryUpdate('category_update'),
  categoryDelete('category_delete'),
  /// 未知操作类型（读取到未来版本/其它设备写入的未知值）——避免反序列化时崩溃。
  /// 注意：重新序列化时会写入 `'unknown'`，原始未知值会丢失（数据损坏场景下
  /// 接受该损失；正常数据不会命中此分支）。
  unknown('unknown');

  const ActionType(this.storageValue);

  final String storageValue;

  /// 兼容读取：`unknown` 是唯一自带原始值的"保留桶"，见 [unknown] 注释。
  static ActionType fromStorageValue(Object? value) {
    final text = value is String ? value : null;
    // 兼容老项目历史数据：camelCase 旧值映射到统一后的 snake_case 枚举，
    // 避免旧数据被误判为 unknown 而丢失 activityDelete 语义。
    if (text == 'activityDelete') return ActionType.activityDelete;
    return ActionType.values.firstWhere(
      (type) => type.storageValue == text,
      orElse: () => ActionType.unknown,
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
