import 'package:drift/drift.dart';
import 'package:uuid/uuid.dart';

import '../../utils/result.dart';
import '../../viewmodels/activity_category.dart';
import '../database/app_database.dart';
import 'repository_mappings.dart';

/// 分类仓储：CRUD + **删除分类事务内递归级联软删**（子孙分类 + 各自 links +
/// 自身 links，返回被删集合供 undo 作一条记录）+ parentId 环检测 +
/// setActivityCategories（稳定 link id）+ LWW。
class CategoryRepository with RepositoryMappings {
  CategoryRepository({
    required this.database,
    Uuid? uuid,
  }) : _uuid = uuid ?? const Uuid();

  final AppDatabase database;
  final Uuid _uuid;

  // ---------------------------------------------------------------------------
  // 查询
  // ---------------------------------------------------------------------------

  /// 全部分类（默认排除已删除；名称升序）。
  Future<AppResult<List<ActivityCategory>>> categories({
    bool includeDeleted = false,
  }) async {
    try {
      final query = database.select(database.activityCategories)
        ..orderBy([(t) => OrderingTerm.asc(t.name)]);
      if (!includeDeleted) {
        query.where((t) => t.deletedAt.isNull());
      }
      final rows = await query.get();
      return AppSuccess(rows.map(categoryFromRow).toList());
    } catch (e) {
      return AppFailure('加载分类失败：$e');
    }
  }

  /// 全部分类关联（默认排除已删除）。
  Future<AppResult<List<ActivityCategoryLink>>> links({
    bool includeDeleted = false,
  }) async {
    try {
      final query = database.select(database.activityCategoryLinks)
        ..orderBy([
          (t) => OrderingTerm.asc(t.activityId),
          (t) => OrderingTerm.desc(t.isPrimary),
          (t) => OrderingTerm.asc(t.sortOrder),
        ]);
      if (!includeDeleted) {
        query.where((t) => t.deletedAt.isNull());
      }
      final rows = await query.get();
      return AppSuccess(rows.map(linkFromRow).toList());
    } catch (e) {
      return AppFailure('加载分类关联失败：$e');
    }
  }

  /// 指定活动的分类关联（primary 在前、sortOrder 升序）。
  Future<AppResult<List<ActivityCategoryLink>>> linksForActivity(
    String activityId, {
    bool includeDeleted = false,
  }) async {
    try {
      final query = database.select(database.activityCategoryLinks)
        ..where((t) => t.activityId.equals(activityId))
        ..orderBy([
          (t) => OrderingTerm.desc(t.isPrimary),
          (t) => OrderingTerm.asc(t.sortOrder),
        ]);
      if (!includeDeleted) {
        query.where((t) => t.deletedAt.isNull());
      }
      final rows = await query.get();
      return AppSuccess(rows.map(linkFromRow).toList());
    } catch (e) {
      return AppFailure('加载活动分类关联失败：$e');
    }
  }

  // ---------------------------------------------------------------------------
  // 写操作
  // ---------------------------------------------------------------------------

  /// 新建分类（可选 parentId；parentId 环检测在落库前完成）。
  Future<AppResult<ActivityCategory>> createCategory({
    required String name,
    required int color,
    String? userId,
    String? parentId,
  }) async {
    try {
      final trimmedParent = _normalizeParentId(parentId);
      if (trimmedParent != null) {
        final parentOk = await _parentExists(trimmedParent);
        if (!parentOk) {
          return AppFailure('父分类不存在：$trimmedParent');
        }
      }
      final trimmedName = name.trim();
      if (trimmedName.isEmpty) {
        return const AppFailure('分类名不能为空');
      }
      final now = DateTime.now();
      final category = ActivityCategory(
        id: _uuid.v4(),
        userId: userId,
        name: trimmedName,
        color: color,
        updatedAt: now,
        parentId: trimmedParent,
      );
      await _upsert(category);
      return AppSuccess(category);
    } catch (e) {
      return AppFailure('新建分类失败：$e');
    }
  }

  /// 更新分类名/色/parentId（含环检测：禁止挂到自身子孙下）。
  Future<AppResult<ActivityCategory>> updateCategory({
    required ActivityCategory category,
    String? name,
    int? color,
    String? parentId,
    bool clearParentId = false,
  }) async {
    try {
      // 更新语义：目标分类必须存在且未删（防陈旧状态把更新静默变成创建/复活）。
      final existing = await _categoryById(category.id);
      if (existing == null || existing.isDeleted) {
        return AppFailure('分类不存在或已删除：${category.id}');
      }
      final newParent = clearParentId ? null : _normalizeParentId(parentId);
      // 环检测：新父分类不能是自身或自身子孙（挂到子孙下形成环）。
      if (newParent != null) {
        final descendants = await _descendantIds(category.id);
        if (descendants.contains(newParent) || newParent == category.id) {
          return AppFailure('不能把分类挂到自身或自身子孙下（会形成环）');
        }
        final parentOk = await _parentExists(newParent);
        if (!parentOk) {
          return AppFailure('父分类不存在：$newParent');
        }
      }
      final effectiveName = (name ?? category.name).trim();
      if (effectiveName.isEmpty) {
        return const AppFailure('分类名不能为空');
      }
      final updated = category.copyWith(
        name: effectiveName,
        color: color ?? category.color,
        parentId: newParent,
        clearParentId: clearParentId && newParent == null,
        updatedAt: DateTime.now(),
      );
      await _upsert(updated);
      return AppSuccess(updated);
    } catch (e) {
      return AppFailure('更新分类失败：$e');
    }
  }

  /// 删除分类：事务内递归软删子孙分类 + 各自 links + 自身 links。
  ///
  /// 返回被删集合（分类 + links），供阶段 3 undo 作为**一条**快照记录
  /// （计划风险 #10：删除父分类递归级联必须是单条 undo）。
  Future<AppResult<CategoryDeletion>> deleteCategory(ActivityCategory category) async {
    try {
      final updatedAt = DateTime.now();
      final deletedCategories = <ActivityCategory>[];
      final deletedLinks = <ActivityCategoryLink>[];

      await database.transaction(() async {
        // 1) 查子孙 id 集合（WITH RECURSIVE，单次 SQL）。
        final descendantIds = await _descendantIds(category.id, executor: database);

        // 2) 软删自身 + 全部子孙分类（批量查询减少 N+1）。
        final allIds = {category.id, ...descendantIds};
        final rows = await _categoryRowsByIds(allIds, executor: database);
        for (final row in rows) {
          if (row.deletedAt != null) continue;
          final model = categoryFromRow(row);
          final deleted = model.copyWith(
            deletedAt: updatedAt,
            updatedAt: updatedAt,
          );
          await database.into(database.activityCategories).insertOnConflictUpdate(
                categoryToCompanion(deleted),
              );
          deletedCategories.add(deleted);
        }

        // 3) 软删涉及分类（含自身）的全部 links（批量 IN 查询避免 N+1）。
        final linkRows = await _linkRowsByCategoryIds(allIds, executor: database);
        for (final row in linkRows) {
          if (row.deletedAt != null) continue;
          final model = linkFromRow(row);
          final deleted = model.copyWith(
            deletedAt: updatedAt,
            updatedAt: updatedAt,
          );
          await database.into(database.activityCategoryLinks).insertOnConflictUpdate(
                linkToCompanion(deleted),
              );
          deletedLinks.add(deleted);
        }
      });

      return AppSuccess(CategoryDeletion(
        categories: deletedCategories,
        links: deletedLinks,
      ));
    } catch (e) {
      return AppFailure('删除分类失败：$e');
    }
  }

  /// 设置活动的分类（primary + secondary；稳定 link id 用 uuid v5）。
  ///
  /// 与老项目语义等价：旧 links 中不在目标集合的软删，目标集合缺失的补齐。
  Future<AppResult<List<ActivityCategoryLink>>> setActivityCategories({
    required String activityId,
    String? primaryCategoryId,
    List<String> secondaryCategoryIds = const [],
    String? userId,
  }) async {
    try {
      final updatedAt = DateTime.now();
      final normalizedPrimary = _normalizeParentId(primaryCategoryId);
      // 校验涉及分类存在且未删（防陈旧状态为已删分类建关联）。
      final allCategoryIds = <String>{
        ?normalizedPrimary,
        ...secondaryCategoryIds.whereType<String>(),
      }.map(_normalizeParentId).whereType<String>().toSet();
      for (final id in allCategoryIds) {
        if (!await _parentExists(id)) {
          return AppFailure('分类不存在或已删除：$id');
        }
      }
      final desired = <String, ({bool isPrimary, int sortOrder})>{};
      if (normalizedPrimary != null) {
        desired[normalizedPrimary] = (isPrimary: true, sortOrder: 0);
      }
      var order = 1;
      for (final id in secondaryCategoryIds) {
        final normalized = _normalizeParentId(id);
        if (normalized == null || normalized == normalizedPrimary) continue;
        desired.putIfAbsent(
          normalized,
          () => (isPrimary: false, sortOrder: order++),
        );
      }

      final saved = <ActivityCategoryLink>[];
      await database.transaction(() async {
        final existingRows = await _linkRowsByActivityId(activityId, executor: database);
        final existing = {
          for (final row in existingRows) linkFromRow(row).categoryId: linkFromRow(row),
        };

        for (final entry in desired.entries) {
          final old = existing[entry.key];
          final link = (old ??
                  ActivityCategoryLink(
                    id: _stableLinkId(activityId, entry.key),
                    userId: userId,
                    activityId: activityId,
                    categoryId: entry.key,
                    isPrimary: entry.value.isPrimary,
                    sortOrder: entry.value.sortOrder,
                    updatedAt: updatedAt,
                  ))
              .copyWith(
            userId: userId ?? old?.userId,
            isPrimary: entry.value.isPrimary,
            sortOrder: entry.value.sortOrder,
            updatedAt: updatedAt,
            deletedAt: null,
            clearDeletedAt: old?.isDeleted ?? false,
          );
          await database.into(database.activityCategoryLinks).insertOnConflictUpdate(
                linkToCompanion(link),
              );
          saved.add(link);
        }

        for (final link in existing.values) {
          if (desired.containsKey(link.categoryId) || link.isDeleted) continue;
          final deleted = link.copyWith(
            deletedAt: updatedAt,
            updatedAt: updatedAt,
          );
          await database.into(database.activityCategoryLinks).insertOnConflictUpdate(
                linkToCompanion(deleted),
              );
        }
      });

      saved.sort((a, b) {
        final primaryCompare = (b.isPrimary ? 1 : 0).compareTo(a.isPrimary ? 1 : 0);
        if (primaryCompare != 0) return primaryCompare;
        return a.sortOrder.compareTo(b.sortOrder);
      });
      return AppSuccess(saved);
    } catch (e) {
      return AppFailure('设置活动分类失败：$e');
    }
  }

  // ---------------------------------------------------------------------------
  // 同步（LWW 整行替换）
  // ---------------------------------------------------------------------------

  /// LWW upsert 分类（删除永远赢：deleted_at 随 updated_at 一起 LWW）。
  ///
  /// 同步落库前做父分类校验：避免远端数据把 parentId 指向本地子孙形成环
  /// （`_descendantIds` 递归会因此无法终止，delete/update 全部失败）。
  Future<AppResult<void>> replaceCategoryIfRemoteNewer(ActivityCategory remote) async {
    try {
      final local = await _categoryById(remote.id);
      if (local == null || local.updatedAt.isBefore(remote.updatedAt)) {
        final parentId = remote.parentId;
        // 远端已删除时跳过父校验：删除永远赢——父缺失/已删不应阻塞删除落地
        //（否则远端删除残留本地，违背 LWW 语义）。
        if (parentId != null && !remote.isDeleted) {
          final descendants = await _descendantIds(remote.id);
          if (descendants.contains(parentId) || parentId == remote.id) {
            return const AppFailure('同步分类失败：parentId 指向自身或子孙（环）');
          }
          if (!await _parentExists(parentId)) {
            return const AppFailure('同步分类失败：父分类不存在');
          }
        }
        await _upsert(remote);
      }
      return const AppSuccess(null);
    } catch (e) {
      return AppFailure('同步分类失败：$e');
    }
  }

  /// LWW upsert 分类关联。
  Future<AppResult<void>> replaceLinkIfRemoteNewer(ActivityCategoryLink remote) async {
    try {
      final local = await _linkById(remote.id);
      if (local == null || local.updatedAt.isBefore(remote.updatedAt)) {
        await database.into(database.activityCategoryLinks).insertOnConflictUpdate(
              linkToCompanion(remote),
            );
      }
      return const AppSuccess(null);
    } catch (e) {
      return AppFailure('同步分类关联失败：$e');
    }
  }

  // ---------------------------------------------------------------------------
  // 内部工具
  // ---------------------------------------------------------------------------

  /// 子孙 id 集合（WITH RECURSIVE；不含自身）。可传 executor 供事务内使用。
  Future<Set<String>> _descendantIds(
    String parentId, {
    AppDatabase? executor,
  }) async {
    final target = executor ?? database;
    final result = await target.customSelect(
      '''
      WITH RECURSIVE descendants(id) AS (
        SELECT id FROM activity_categories WHERE parent_id = ?1
        UNION
        SELECT c.id FROM activity_categories c
        JOIN descendants d ON c.parent_id = d.id
      )
      SELECT id FROM descendants
      ''',
      variables: [Variable(parentId)],
    ).get();
    return result.map((row) => row.read<String>('id')).toSet();
  }

  /// 父分类是否存在（未删）。
  Future<bool> _parentExists(String parentId) async {
    final row = await _categoryRowById(parentId);
    return row != null && row.deletedAt == null;
  }

  /// 批量按 id 查询分类行（递归软删用，避免 N+1）。
  Future<List<ActivityCategoryRow>> _categoryRowsByIds(
    Set<String> ids, {
    required AppDatabase executor,
  }) async {
    if (ids.isEmpty) return const [];
    final query = executor.select(executor.activityCategories)
      ..where((t) => t.id.isIn(ids));
    return query.get();
  }

  Future<ActivityCategoryRow?> _categoryRowById(
    String id, {
    AppDatabase? executor,
  }) async {
    final target = executor ?? database;
    final query = target.select(database.activityCategories)
      ..where((t) => t.id.equals(id));
    return query.getSingleOrNull();
  }

  Future<ActivityCategory?> _categoryById(String id) async {
    final row = await _categoryRowById(id);
    return row == null ? null : categoryFromRow(row);
  }

  /// 批量按分类 id 查 links（递归软删用，避免 N+1）。
  Future<List<ActivityCategoryLinkRow>> _linkRowsByCategoryIds(
    Set<String> categoryIds, {
    required AppDatabase executor,
  }) async {
    if (categoryIds.isEmpty) return const [];
    final query = executor.select(executor.activityCategoryLinks)
      ..where((t) => t.categoryId.isIn(categoryIds));
    return query.get();
  }

  Future<List<ActivityCategoryLinkRow>> _linkRowsByActivityId(
    String activityId, {
    required AppDatabase executor,
  }) async {
    final query = executor.select(database.activityCategoryLinks)
      ..where((t) => t.activityId.equals(activityId));
    return query.get();
  }

  Future<ActivityCategoryLink?> _linkById(String id) async {
    final query = database.select(database.activityCategoryLinks)
      ..where((t) => t.id.equals(id));
    final row = await query.getSingleOrNull();
    return row == null ? null : linkFromRow(row);
  }

  Future<void> _upsert(ActivityCategory category) {
    return database.into(database.activityCategories).insertOnConflictUpdate(
          categoryToCompanion(category),
        );
  }

  /// 稳定 link id：activityId + categoryId 的 uuid v5。
  String _stableLinkId(String activityId, String categoryId) {
    return _uuid.v5(
      Namespace.url.value,
      'timetrack:activity-category-link:$activityId:$categoryId',
    );
  }

  /// parentId 归一化：空白 → null。
  String? _normalizeParentId(String? value) {
    final trimmed = value?.trim();
    return (trimmed == null || trimmed.isEmpty) ? null : trimmed;
  }
}

/// 分类删除结果：被软删的分类 + links（供 undo 单条快照）。
class CategoryDeletion {
  const CategoryDeletion({
    required this.categories,
    required this.links,
  });

  final List<ActivityCategory> categories;
  final List<ActivityCategoryLink> links;

  bool get isEmpty => categories.isEmpty && links.isEmpty;
}
