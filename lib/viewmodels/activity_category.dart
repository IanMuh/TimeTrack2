import '../utils/model_utils.dart';

/// 领域模型：活动分类（纯类型，零 Flutter 依赖）。
///
/// 一期全量支持层级分类：`parentId` 自引用（顶级分类为 null），
/// 删除父分类时事务内递归软删子孙及 links（见仓储层）。
class ActivityCategory {
  const ActivityCategory({
    required this.id,
    this.userId,
    required this.name,
    required this.color,
    required this.updatedAt,
    this.deletedAt,
    this.parentId,
  });

  /// 默认分类色（与 `constants/app_constants.dart` 保持一致）。
  static const defaultColor = 0xff0f766e;

  final String id;
  final String? userId;
  final String name;
  final int color;
  final DateTime updatedAt;
  final DateTime? deletedAt;

  /// 父分类 id；null 表示顶级分类。
  final String? parentId;

  bool get isDeleted => deletedAt != null;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ActivityCategory &&
          runtimeType == other.runtimeType &&
          id == other.id;

  @override
  int get hashCode => id.hashCode;

  ActivityCategory copyWith({
    String? id,
    String? userId,
    bool clearUserId = false,
    String? name,
    int? color,
    DateTime? updatedAt,
    DateTime? deletedAt,
    bool clearDeletedAt = false,
    String? parentId,
    bool clearParentId = false,
  }) {
    return ActivityCategory(
      id: id ?? this.id,
      userId: clearUserId ? null : userId ?? this.userId,
      name: name ?? this.name,
      color: color ?? this.color,
      updatedAt: updatedAt ?? this.updatedAt,
      deletedAt: clearDeletedAt ? null : deletedAt ?? this.deletedAt,
      parentId: clearParentId ? null : parentId ?? this.parentId,
    );
  }

  Map<String, Object?> toMap() {
    return {
      'id': id,
      'user_id': userId,
      'name': name,
      'color': color,
      'updated_at': updatedAt.toUtc().toIso8601String(),
      'deleted_at': deletedAt?.toUtc().toIso8601String(),
      'parent_id': parentId,
    };
  }

  static ActivityCategory fromMap(Map<String, Object?> map) {
    final id = map['id'];
    if (id is! String || id.isEmpty) {
      throw const FormatException('ActivityCategory.fromMap: id 缺失或非法');
    }
    return ActivityCategory(
      id: id,
      userId: readNullableString(map['user_id']),
      name: readString(map['name']),
      color: readInt(map['color'], fallback: defaultColor),
      // updated_at 语义必填（LWW 冲突判定关键字段）：缺失/非法即抛错，绝不伪造当前时刻。
      updatedAt: _strictDateTime(map, 'ActivityCategory'),
      deletedAt: readNullableDateTime(map['deleted_at']),
      parentId: readNullableString(map['parent_id']),
    );
  }

  /// 严格读取必填时间字段：缺失或不可解析抛 [FormatException]（防伪造时间戳）。
  static DateTime _strictDateTime(
    Map<String, Object?> map,
    String fromClass,
  ) {
    final value = map['updated_at'];
    final parsed = value is String ? DateTime.tryParse(value) : null;
    if (parsed == null) {
      throw FormatException('$fromClass.fromMap: updated_at 缺失或非法');
    }
    return parsed.toLocal();
  }
}

/// 领域模型：活动-分类关联（纯类型，零 Flutter 依赖）。
///
/// 一个活动可有多个分类：一个 primary（isPrimary=true）+ 若干 secondary，
/// secondary 按 sortOrder 排序。link id 由 `activityId + categoryId` 稳定生成（uuid v5）。
class ActivityCategoryLink {
  const ActivityCategoryLink({
    required this.id,
    this.userId,
    required this.activityId,
    required this.categoryId,
    this.isPrimary = false,
    this.sortOrder = 0,
    required this.updatedAt,
    this.deletedAt,
  });

  final String id;
  final String? userId;
  final String activityId;
  final String categoryId;
  final bool isPrimary;
  final int sortOrder;
  final DateTime updatedAt;
  final DateTime? deletedAt;

  bool get isDeleted => deletedAt != null;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ActivityCategoryLink &&
          runtimeType == other.runtimeType &&
          id == other.id;

  @override
  int get hashCode => id.hashCode;

  ActivityCategoryLink copyWith({
    String? id,
    String? userId,
    bool clearUserId = false,
    String? activityId,
    String? categoryId,
    bool? isPrimary,
    int? sortOrder,
    DateTime? updatedAt,
    DateTime? deletedAt,
    bool clearDeletedAt = false,
  }) {
    return ActivityCategoryLink(
      id: id ?? this.id,
      userId: clearUserId ? null : userId ?? this.userId,
      activityId: activityId ?? this.activityId,
      categoryId: categoryId ?? this.categoryId,
      isPrimary: isPrimary ?? this.isPrimary,
      sortOrder: sortOrder ?? this.sortOrder,
      updatedAt: updatedAt ?? this.updatedAt,
      deletedAt: clearDeletedAt ? null : deletedAt ?? this.deletedAt,
    );
  }

  Map<String, Object?> toMap() {
    return {
      'id': id,
      'user_id': userId,
      'activity_id': activityId,
      'category_id': categoryId,
      'is_primary': isPrimary ? 1 : 0,
      'sort_order': sortOrder,
      'updated_at': updatedAt.toUtc().toIso8601String(),
      'deleted_at': deletedAt?.toUtc().toIso8601String(),
    };
  }

  static ActivityCategoryLink fromMap(Map<String, Object?> map) {
    final id = map['id'];
    if (id is! String || id.isEmpty) {
      throw const FormatException('ActivityCategoryLink.fromMap: id 缺失或非法');
    }
    final updatedAtValue = map['updated_at'];
    final updatedAt = updatedAtValue is String
        ? DateTime.tryParse(updatedAtValue)
        : null;
    if (updatedAt == null) {
      throw const FormatException(
        'ActivityCategoryLink.fromMap: updated_at 缺失或非法',
      );
    }
    return ActivityCategoryLink(
      id: id,
      userId: readNullableString(map['user_id']),
      activityId: readString(map['activity_id']),
      categoryId: readString(map['category_id']),
      isPrimary: readBool(map['is_primary']),
      sortOrder: readInt(map['sort_order']),
      updatedAt: updatedAt.toLocal(),
      deletedAt: readNullableDateTime(map['deleted_at']),
    );
  }
}
