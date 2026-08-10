import '../utils/model_utils.dart';

/// 领域模型：事项（纯类型，零 Flutter 依赖）。
///
/// `toMap` / `fromMap` 与传输格式（同步包 / 文件互通）共用，
/// 序列化缺键容错（`fromMap` 对缺失字段回退默认值）。
/// 例外（语义必填，缺失/非法抛 [FormatException]）：`id`、`updated_at`——
/// `updated_at` 是 LWW 冲突判定关键字段，绝不伪造时间戳。
class Activity {
  Activity({
    required this.id,
    this.userId,
    required this.name,
    required this.color,
    required this.isFavorite,
    required this.updatedAt,
    this.deletedAt,
    this.isUnassigned = false,
    this.isOneOff = false,
  }) : assert(id != '', 'id 不能为空') {
    // release 下 assert 被移除：直接构造/copyWith 传空 id 是绕过 fromMap 硬校验的
    // 旁路，空 id 会污染 ==/hashCode 且持久化后无法再反序列化（加载失败）。
    if (id.isEmpty) {
      throw ArgumentError.value(id, 'id', 'id 不能为空');
    }
  }

  /// 默认事项色（与 `constants/app_constants.dart` 的 `defaultActivityColor` 保持一致）。
  static const defaultColor = 0xff64748b;

  final String id;
  final String? userId;

  /// 名称快照（未分配活动名为"未安排"，具体文案由常量/ARB 提供）。
  final String name;
  final int color;
  final bool isFavorite;
  final DateTime updatedAt;

  /// 软删除时间戳；null 表示未删除。替代老项目的 is_deleted 布尔位。
  final DateTime? deletedAt;
  final bool isUnassigned;
  final bool isOneOff;

  bool get isDeleted => deletedAt != null;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is Activity && runtimeType == other.runtimeType && id == other.id;

  @override
  int get hashCode => id.hashCode;

  @override
  String toString() =>
      'Activity(id: $id, name: $name, color: $color, isDeleted: $isDeleted)';

  Activity copyWith({
    String? id,
    String? userId,
    bool clearUserId = false,
    String? name,
    int? color,
    bool? isFavorite,
    DateTime? updatedAt,
    DateTime? deletedAt,
    bool clearDeletedAt = false,
    bool? isUnassigned,
    bool? isOneOff,
  }) {
    return Activity(
      id: id ?? this.id,
      userId: clearUserId ? null : userId ?? this.userId,
      name: name ?? this.name,
      color: color ?? this.color,
      isFavorite: isFavorite ?? this.isFavorite,
      updatedAt: updatedAt ?? this.updatedAt,
      deletedAt: clearDeletedAt ? null : deletedAt ?? this.deletedAt,
      isUnassigned: isUnassigned ?? this.isUnassigned,
      isOneOff: isOneOff ?? this.isOneOff,
    );
  }

  Map<String, Object?> toMap() {
    return {
      'id': id,
      'user_id': userId,
      'name': name,
      'color': color,
      'is_favorite': isFavorite ? 1 : 0,
      'updated_at': updatedAt.toUtc().toIso8601String(),
      'deleted_at': deletedAt?.toUtc().toIso8601String(),
      'is_unassigned': isUnassigned ? 1 : 0,
      'is_one_off': isOneOff ? 1 : 0,
    };
  }

  static Activity fromMap(Map<String, Object?> map) {
    final id = map['id'];
    if (id is! String || id.isEmpty) {
      throw const FormatException('Activity.fromMap: id 缺失或非法');
    }
    return Activity(
      id: id,
      userId: readNullableString(map['user_id']),
      name: readString(map['name']),
      color: readInt(map['color'], fallback: defaultColor),
      isFavorite: readBool(map['is_favorite']),
      updatedAt: readDateTime(map['updated_at']),
      deletedAt: readNullableDateTime(map['deleted_at']),
      isUnassigned: readBool(map['is_unassigned']),
      isOneOff: readBool(map['is_one_off']),
    );
  }
}
