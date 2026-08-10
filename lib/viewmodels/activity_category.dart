import '../utils/model_utils.dart';

/// 领域模型：活动分类（纯类型，零 Flutter 依赖）。
///
/// 一期全量支持层级分类：`parentId` 自引用（顶级分类为 null），
/// 删除父分类时事务内递归软删子孙及 links（见仓储层）。
/// 无环不变量：分类树不允许自引用（parentId == id）或成环——模型层防御自引用，
/// 深度成环由仓储层在落库前校验（parentId 环检测）。
class ActivityCategory {
  ActivityCategory({
    required this.id,
    this.userId,
    required this.name,
    required this.color,
    required this.updatedAt,
    this.deletedAt,
    this.parentId,
  }) : assert(parentId != id, '分类不能是自身的父分类（自引用环）') {
    // 自引用运行时硬校验（release 下 assert 被移除，此处兜底）：
    // 直接构造是绕过 fromMap/copyWith 的旁路入口，必须同样拦截自引用环，
    // 否则分类树遍历/递归软删可能无法终止。
    if (parentId == id) {
      throw ArgumentError.value(
        parentId,
        'parentId',
        '分类不能是自身的父分类（自引用环）',
      );
    }
  }

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
    final newId = id ?? this.id;
    final newParentId = clearParentId ? null : parentId ?? this.parentId;
    // 自引用运行时校验（不依赖 assert，release 下同样生效）：
    // copyWith 是旁路直接构造的常见入口，绕过它会静默产出自引用环。
    if (newParentId == newId) {
      throw ArgumentError.value(
        newParentId,
        'parentId',
        '分类不能是自身的父分类（自引用环）',
      );
    }
    return ActivityCategory(
      id: newId,
      userId: clearUserId ? null : userId ?? this.userId,
      name: name ?? this.name,
      color: color ?? this.color,
      updatedAt: updatedAt ?? this.updatedAt,
      deletedAt: clearDeletedAt ? null : deletedAt ?? this.deletedAt,
      parentId: newParentId,
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
    final rawId = map['id'];
    if (rawId is! String || rawId.trim().isEmpty) {
      throw const FormatException('ActivityCategory.fromMap: id 缺失或非法');
    }
    // id 与 parent_id 同样 trim 归一化，保持父子引用语义一致
    // （避免空白 id 绕过自引用检测或产生悬空父子引用）。
    final id = rawId.trim();
    final rawParentId = readNullableString(map['parent_id']);
    // 空串/空白串归一化为 null（顶级）——防止指向不存在父分类的无效父子关系。
    final trimmedParentId = rawParentId?.trim();
    final parentId =
        (trimmedParentId == null || trimmedParentId.isEmpty)
            ? null
            : trimmedParentId;
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

  /// copyWith 不允许修改关联键（activityId/categoryId/id）：
  /// link id 由 activityId+categoryId 稳定派生，键变更 = 新的关联关系，
  /// 必须通过仓储的稳定 id 工厂重建（避免 id 与关联关系不一致的脏数据）。
  ActivityCategoryLink copyWith({
    String? userId,
    bool clearUserId = false,
    bool? isPrimary,
    int? sortOrder,
    DateTime? updatedAt,
    DateTime? deletedAt,
    bool clearDeletedAt = false,
  }) {
    return ActivityCategoryLink(
      id: id,
      userId: clearUserId ? null : userId ?? this.userId,
      activityId: activityId,
      categoryId: categoryId,
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
