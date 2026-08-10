import '../utils/model_utils.dart';

/// 领域模型：活动分类（纯类型，零 Flutter 依赖）。
///
/// 一期全量支持层级分类：`parentId` 自引用（顶级分类为 null），
/// 删除父分类时事务内递归软删子孙及 links（见仓储层）。
/// 无环不变量：分类树不允许自引用（parentId == id）或成环——模型层防御自引用，
/// 深度成环由仓储层在落库前校验（parentId 环检测）。
class ActivityCategory {
  const ActivityCategory({
    required this.id,
    this.userId,
    required this.name,
    required this.color,
    required this.updatedAt,
    this.deletedAt,
    this.parentId,
  }) : assert(parentId != id, '分类不能是自身的父分类（自引用环）');

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
    final parentId = readNullableString(map['parent_id']);
    if (parentId == id) {
      throw const FormatException(
        'ActivityCategory.fromMap: 分类不能是自身的父分类（自引用环）',
      );
    }
    return ActivityCategory(
      id: id,
      userId: readNullableString(map['user_id']),
      name: readString(map['name']),
      color: readInt(map['color'], fallback: defaultColor),
      // updated_at 语义必填（LWW 冲突判定关键字段）：readDateTime 未传 fallback 时
      // 缺失/非法即抛 FormatException（不伪造当前时刻），与其他模型写法一致。
      updatedAt: readDateTime(map['updated_at']),
      deletedAt: readNullableDateTime(map['deleted_at']),
      parentId: parentId,
    );
  }
}

/// 领域模型：活动-分类关联（纯类型，零 Flutter 依赖）。
///
/// 一个活动可有多个分类：一个 primary（isPrimary=true）+ 若干 secondary，
/// secondary 按 sortOrder 排序。link id 由 `activityId + categoryId` 稳定生成
/// （uuid v5，见仓储层 `_stableLinkId`）。
/// 不变量：id 与关联键（activityId/categoryId）一一对应——调用方修改关联键时
/// 必须同步重算 id（或通过仓储的稳定 id 工厂创建），否则会产生 id 与关联关系
/// 不一致的脏数据（数据库主键冲突/更新错乱）。
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
    return ActivityCategoryLink(
      id: id,
      userId: readNullableString(map['user_id']),
      activityId: readString(map['activity_id']),
      categoryId: readString(map['category_id']),
      isPrimary: readBool(map['is_primary']),
      sortOrder: readInt(map['sort_order']),
      // updated_at 语义必填：readDateTime 未传 fallback 时缺失/非法抛 FormatException。
      updatedAt: readDateTime(map['updated_at']),
      deletedAt: readNullableDateTime(map['deleted_at']),
    );
  }
}
