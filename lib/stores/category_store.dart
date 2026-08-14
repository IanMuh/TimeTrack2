/// 分类树 store（模块 3b）：层级分类的单一写路径 + 树缓存。
///
/// 职责：
/// - **写路径**：create/update/delete（递归级联软删子孙及 links）/
///   setActivityCategories 全部经仓储；
/// - **undo 包装**：删除分类的 [CategoryDeletion]（categories+links）整体
///   作为**一条** undo 记录（不变式 6——防 undo 半恢复，计划风险 10）；
/// - **dataRevision**：每次分类/link 变更成功递增（不变式 9，老项目已知坑：
///   分类改完统计不刷新）；
/// - **树缓存**：childrenByParent / descendantsOf / 祖先链 内存索引，写后
///   重建（分类数据量小，重建成本低；同步导入/undo 恢复经 dataRevision
///   监听触发的 [reload] 重建）。
///
/// undo 语义（与 TimerStore 一致：快照权威、updatedAt 推进参与同步）：
/// - 新建分类：undo 软删该分类，redo 恢复；
/// - 删除分类（级联）：undo 复活全部被删分类+links，redo 重软删；
/// - 修改分类：undo 写回旧快照，redo 写回新快照（分类级联 undo 记录的
///   CategoryDeletion 由仓储单事务原子恢复）。
library;

import 'package:flutter/foundation.dart';

import '../data/repositories/category_repository.dart';
import '../utils/result.dart';
import '../viewmodels/activity_category.dart';
import 'data_revision.dart';
import 'undo_store.dart';

/// 一次分类/链接恢复的复合操作（3a 契约：一条 undo 记录一个 change）。
class CategoryStateChange {
  const CategoryStateChange({
    required this.categories,
    required this.links,
  });

  /// 每项 entry 为**恢复目标状态**；softDelete=false 写该状态（推进
  /// updatedAt），true 软删该行。
  final List<({ActivityCategory entry, bool softDelete})> categories;
  final List<({ActivityCategoryLink entry, bool softDelete})> links;
}

/// 分类/链接恢复写库契约（3a [UndoApplier] 实现）。
class CategoryChangeApplier implements UndoApplier {
  CategoryChangeApplier(this._categories);

  final CategoryRepository _categories;

  /// 冲突预检（不写库）：按 [expected] 校验当前库状态——softDelete=false
  ///（预期当前未删）行必须存在且未删；softDelete=true（预期当前软删）行
  /// 必须存在且已删。任一不符 = 恢复前状态被并发改动，拒绝恢复。
  @override
  Future<AppResult<void>> validate(Object? expected) async {
    if (expected case CategoryStateChange change) {
      for (final op in change.categories) {
        final current = await _categories.categoryByIdIncludingDeleted(
          op.entry.id,
        );
        if (op.softDelete) {
          if (current == null || !current.isDeleted) {
            return const AppFailure('分类当前未处于软删态，无法撤销');
          }
        } else {
          if (current == null) return const AppFailure('分类已被删除，无法恢复');
          if (current.isDeleted) {
            return const AppFailure('分类当前已软删，无法恢复');
          }
        }
      }
      for (final op in change.links) {
        final current = await _categories.linkByIdIncludingDeleted(op.entry.id);
        if (op.softDelete) {
          if (current == null || !current.isDeleted) {
            return const AppFailure('分类关联当前未处于软删态，无法撤销');
          }
        } else {
          if (current == null) {
            return const AppFailure('分类关联已被删除，无法恢复');
          }
          if (current.isDeleted) {
            return const AppFailure('分类关联当前已软删，无法恢复');
          }
        }
      }
      return const AppSuccess(null);
    }
    return const AppFailure('未知恢复目标类型');
  }

  @override
  Future<AppResult<void>> apply(Object? target) async {
    if (target case CategoryStateChange change) {
      final result = await _categories.restoreCategoryStatesForUndo(
        change.categories,
        change.links,
      );
      if (result.isSuccess) {
        onApplied?.call();
      }
      return result;
    }
    return const AppFailure('未知恢复目标类型');
  }

  /// 恢复写库成功后的回调（store 注入：bump dataRevision + reload 树缓存）。
  void Function()? onApplied;
}

/// 分类树 store。
class CategoryStore extends ChangeNotifier {
  CategoryStore({
    required this.categories,
    required this.undo,
    required this.dataRevision,
  }) : _applier = CategoryChangeApplier(categories) {
    _applier.onApplied = () {
      if (_disposed) return;
      dataRevision.bump();
      reload();
    };
  }

  final CategoryRepository categories;
  final UndoStore undo;
  final DataRevision dataRevision;

  final CategoryChangeApplier _applier;

  bool _disposed = false;

  /// reload 序号守卫：_afterWrite/onApplied 以 fire-and-forget 触发 reload，
  /// 连续写/undo/redo 时并发 reload 可能乱序完成——仅应用最新一次启动的结果
  ///（防旧数据覆盖新缓存）。
  int _reloadSeq = 0;

  /// 全量未删分类（缓存；写后/数据变更后 [reload] 重建）。
  List<ActivityCategory> _all = const [];
  List<ActivityCategoryLink> _links = const [];

  /// 分类 id → 直属子分类列表（顶层分类 key = null）。
  Map<String?, List<ActivityCategory>> get childrenByParent =>
      _childrenByParent;
  Map<String?, List<ActivityCategory>> _childrenByParent = const {};

  /// 分类 id → 全部子孙（含自身）id。
  Map<String, Set<String>> get descendantsOf => _descendantsOf;
  Map<String, Set<String>> _descendantsOf = const {};

  /// 分类 id → 祖先链 id（根 → 父，不含自身）。
  Map<String, List<String>> get ancestorChains => _ancestorChains;
  Map<String, List<String>> _ancestorChains = const {};

  /// 全量未删分类（缓存视图；赋值时不可变，getter 零拷贝）。
  List<ActivityCategory> get all => _all;

  /// 全量未删链接（缓存视图；赋值时不可变，getter 零拷贝）。
  List<ActivityCategoryLink> get links => _links;

  /// 加载分类/链接并重建树索引（启动、数据变更后调用）。
  Future<void> reload() async {
    if (_disposed) return; // dispose 后静默跳过（防 async 恢复执行崩溃）
    final seq = ++_reloadSeq;
    final categoriesResult = await categories.categories();
    if (categoriesResult case AppFailure<List<ActivityCategory>> _) {
      return; // 加载失败保持旧缓存（下一轮数据变更再试）
    }
    if (_disposed || seq != _reloadSeq) return; // await 期间 dispose/更新的 reload
    final linksResult = await categories.links();
    if (linksResult case AppFailure<List<ActivityCategoryLink>> _) {
      return;
    }
    if (_disposed || seq != _reloadSeq) return;
    _all = List<ActivityCategory>.unmodifiable(categoriesResult.requireValue());
    _links = List<ActivityCategoryLink>.unmodifiable(linksResult.requireValue());
    _rebuildIndexes();
    notifyListeners();
  }

  /// 分类 id → 分类模型（缓存 map，UI 查询用）。
  Map<String, ActivityCategory> get categoryById => _categoryById;
  Map<String, ActivityCategory> _categoryById = const {};

  void _rebuildIndexes() {
    _categoryById = Map.unmodifiable({for (final c in _all) c.id: c});
    // children 的 key 为 parentId（顶层分类 = null）。
    final children = <String?, List<ActivityCategory>>{};
    final ancestors = <String, List<String>>{};
    for (final category in _all) {
      final parentId = category.parentId;
      children.putIfAbsent(parentId, () => []).add(category);
      if (parentId == null) {
        ancestors[category.id] = const [];
      } else {
        final chain = <String>[];
        String? current = parentId;
        final visited = <String>{};
        while (current != null &&
            _categoryById.containsKey(current) &&
            visited.add(current)) {
          chain.insert(0, current);
          current = _categoryById[current]!.parentId;
        }
        ancestors[category.id] = chain;
      }
    }
    // 确定性排序：children 按 name。
    for (final list in children.values) {
      list.sort((a, b) => a.name.compareTo(b.name));
    }
    // 两段式构造不可变索引（显式类型标注，规避 map literal + for 元素的
    // 值类型推断在部分运行时的 cast 问题）。
    final immutableChildren = <String?, List<ActivityCategory>>{};
    for (final entry in children.entries) {
      immutableChildren[entry.key] = List<ActivityCategory>.unmodifiable(entry.value);
    }
    _childrenByParent = Map.unmodifiable(immutableChildren);
    final immutableAncestors = <String, List<String>>{};
    for (final entry in ancestors.entries) {
      immutableAncestors[entry.key] = List<String>.unmodifiable(entry.value);
    }
    _ancestorChains = Map.unmodifiable(immutableAncestors);
    _descendantsOf = _buildDescendants();
  }

  Map<String, Set<String>> _buildDescendants() {
    final result = <String, Set<String>>{};
    // 自底向上：先收集直接子集，再逐层合并。
    for (final category in _all) {
      result[category.id] = {category.id};
    }
    bool changed = true;
    while (changed) {
      changed = false;
      for (final category in _all) {
        final parentId = category.parentId;
        if (parentId == null || !result.containsKey(parentId)) continue;
        final parentSet = result[parentId]!;
        final childSet = result[category.id]!;
        final before = parentSet.length;
        parentSet.addAll(childSet);
        if (parentSet.length != before) changed = true;
      }
    }
    final immutableDescendants = <String, Set<String>>{};
    for (final entry in result.entries) {
      immutableDescendants[entry.key] = Set<String>.unmodifiable(entry.value);
    }
    return Map.unmodifiable(immutableDescendants);
  }

  // ---------------------------------------------------------------------------
  // 写路径
  // ---------------------------------------------------------------------------

  /// 新建分类（可带 [parentId]）。
  Future<AppResult<ActivityCategory>> createCategory({
    required String name,
    required int color,
    String? parentId,
  }) async {
    final result = await categories.createCategory(
      name: name,
      color: color,
      parentId: parentId,
    );
    if (result case AppFailure<ActivityCategory> failure) {
      return failure;
    }
    final created = result.requireValue();
    undo.record(
      label: '新建分类',
      changes: [
        UndoChange(
          before: CategoryStateChange(
            categories: [(entry: created, softDelete: true)], // undo 软删新建
            links: const [],
          ),
          after: CategoryStateChange(
            categories: [(entry: created, softDelete: false)], // redo 恢复
            links: const [],
          ),
          applier: _applier,
        ),
      ],
    );
    _afterWrite();
    return result;
  }

  /// 更新分类（名/色/parentId）。undo 恢复旧快照。
  Future<AppResult<ActivityCategory>> updateCategory({
    required ActivityCategory category,
    String? name,
    int? color,
    String? parentId,
  }) async {
    final result = await categories.updateCategory(
      category: category,
      name: name,
      color: color,
      parentId: parentId,
    );
    if (result case AppFailure<ActivityCategory> failure) {
      return failure;
    }
    final updated = result.requireValue();
    undo.record(
      label: '修改分类',
      changes: [
        UndoChange(
          before: CategoryStateChange(
            categories: [(entry: category, softDelete: false)], // undo 写回旧
            links: const [],
          ),
          after: CategoryStateChange(
            categories: [(entry: updated, softDelete: false)], // redo 写新
            links: const [],
          ),
          applier: _applier,
        ),
      ],
    );
    _afterWrite();
    return result;
  }

  /// 删除分类（递归软删子孙及 links，一条 undo 记录）。
  Future<AppResult<CategoryDeletion>> deleteCategory(String categoryId) async {
    final category = _categoryById[categoryId];
    if (category == null) {
      return const AppFailure('分类不存在，无法删除');
    }
    final result = await categories.deleteCategory(category);
    if (result case AppFailure<CategoryDeletion> failure) {
      return failure;
    }
    final deletion = result.requireValue();
    undo.record(
      label: '删除分类',
      changes: [
        UndoChange(
          // undo：复活被删分类+links；redo：重软删（快照权威，不重查子孙）。
          before: CategoryStateChange(
            categories: [
              for (final c in deletion.categories)
                (entry: c, softDelete: false),
            ],
            links: [
              for (final l in deletion.links) (entry: l, softDelete: false),
            ],
          ),
          after: CategoryStateChange(
            categories: [
              for (final c in deletion.categories)
                (entry: c, softDelete: true),
            ],
            links: [
              for (final l in deletion.links) (entry: l, softDelete: true),
            ],
          ),
          applier: _applier,
        ),
      ],
    );
    _afterWrite();
    return result;
  }

  /// 设置活动分类（primary + secondary）。undo 恢复旧链接集。
  Future<AppResult<List<ActivityCategoryLink>>> setActivityCategories({
    required String activityId,
    String? primaryCategoryId,
    List<String> secondaryCategoryIds = const [],
  }) async {
    // before 采集含软删：操作可能软删旧链接（_links 缓存排除已删，须显式
    // 查含删集合并入 undo 记录，否则 undo 无法复活被软删的旧链接）。
    final oldLinksResult = await categories.links(includeDeleted: true);
    if (oldLinksResult case AppFailure<List<ActivityCategoryLink>> failure) {
      return AppFailure(failure.message);
    }
    final oldLinks =
        oldLinksResult.requireValue().where((l) => l.activityId == activityId).toList();
    final result = await categories.setActivityCategories(
      activityId: activityId,
      primaryCategoryId: primaryCategoryId,
      secondaryCategoryIds: secondaryCategoryIds,
    );
    if (result case AppFailure<List<ActivityCategoryLink>> failure) {
      return failure;
    }
    final saved = result.requireValue();
    undo.record(
      label: '设置分类',
      changes: [
        UndoChange(
          // undo：写回旧链接集（含被软删的旧链接复活）+ **本次新建链接软删**
          //（saved 中不属于 oldLinks 的——首次分配等场景，undo 须移除）；
          // redo：整个新链接集写回（含被重新激活的软删旧链接）+ 未保留
          // 旧链接软删——保证单条 undo 记录完整性。
          before: CategoryStateChange(
            categories: const [],
            links: [
              for (final l in oldLinks)
                (entry: l, softDelete: l.isDeleted),
              for (final s in saved)
                if (!oldLinks.any((l) => l.id == s.id))
                  (entry: s, softDelete: true),
            ],
          ),
          after: CategoryStateChange(
            categories: const [],
            links: [
              for (final s in saved) (entry: s, softDelete: false),
              for (final l in oldLinks)
                if (!saved.any((s) => s.id == l.id))
                  (entry: l, softDelete: true),
            ],
          ),
          applier: _applier,
        ),
      ],
    );
    _afterWrite();
    return result;
  }

  void _afterWrite() {
    dataRevision.bump();
    reload();
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}
