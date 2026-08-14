/// 统计聚合仓储：范围切片（SQL 过滤条目 + 当前活动/分类组装）+ 维度聚合。
///
/// 设计（模块 3b，决策：SQL 聚合到范围，层级归并在仓储层完成）：
/// - [slicesForRange]：范围内时间条目经 SQL 查询（entriesForRange 已按
///   `[startAt, endAt)` 过滤未删行），活动/分类/links 各一次全量查询后
///   内存组装切片——统计只拉范围条目（一天/一周/一月），聚合成本可控，
///   与老项目 TimeRangeStats 语义一致；
/// - [aggregate]：**纯函数**聚合（可独立单测），不含任何 IO。
///
/// 主分类语义（沿用老项目）：活动可有多个分类 link（isPrimary 唯一主 +
/// 若干 secondary 按 sortOrder），主分类 = isPrimary 的 link 对应分类；
/// 无主链接时取排序后第一个 link。
///
/// categoryTree（阶段 3 新增）：切片归并到主分类祖先链**每个节点**（含自身）
/// ——父分类行 = 自身活动 + 全部子孙分类活动；label 拼接路径（"工作 / 项目A"）、
/// depth 缩进层级、ancestorIds 祖先链供 UI 折叠/展开。
library;

import '../../constants/app_constants.dart';
import '../../utils/result.dart';
import '../../viewmodels/activity.dart';
import '../../viewmodels/activity_category.dart';
import '../../viewmodels/stats/stats_models.dart';
import 'activity_repository.dart';
import 'category_repository.dart';
import 'time_entry_repository.dart';

/// 无主分类的归并兜底文案（老项目语义一致；本地化归阶段 4 ARB）。
const String unassignedCategoryLabel = '未分类';

/// 活动名缺失兜底（老项目语义一致；本地化归阶段 4 ARB）。
const String unknownActivityLabel = '未知事项';

/// 统计聚合仓储。
class StatsRepository {
  StatsRepository({
    required this.activities,
    required this.categories,
    required this.entries,
  });

  final ActivityRepository activities;
  final CategoryRepository categories;
  final TimeEntryRepository entries;

  /// 加载 [start, end) 范围内的统计切片（未删条目经 SQL 过滤）。
  ///
  /// [effectiveNow]：运行中条目（endAt == null）的裁剪终点，默认取当前时刻
  /// （可注入固定时刻做确定性测试）。范围非法（end <= start）返回空列表。
  Future<AppResult<List<StatsEntrySlice>>> slicesForRange({
    required DateTime start,
    required DateTime end,
    DateTime? effectiveNow,
  }) async {
    if (!start.isBefore(end)) {
      return const AppSuccess([]);
    }
    final now = effectiveNow ?? DateTime.now();
    final activityResult = await activities.activities();
    if (activityResult case AppFailure<List<Activity>> failure) {
      return AppFailure('加载统计活动失败：${failure.message}');
    }
    final categoryResult = await categories.categories();
    if (categoryResult case AppFailure<List<ActivityCategory>> failure) {
      return AppFailure('加载统计分类失败：${failure.message}');
    }
    final linkResult = await categories.links();
    if (linkResult case AppFailure<List<ActivityCategoryLink>> failure) {
      return AppFailure('加载统计分类关联失败：${failure.message}');
    }

    final activityById = {
      for (final a in activityResult.requireValue()) a.id: a,
    };
    final categoryById = {
      for (final c in categoryResult.requireValue()) c.id: c,
    };
    // 每条目按 activityId 分组的活跃链接，排序：isPrimary 优先 + sortOrder asc
    //（与老项目 TimeRangeStats 一致——主分类取排序后首个 isPrimary 链接）。
    final linksByActivity = <String, List<ActivityCategoryLink>>{};
    for (final link in linkResult.requireValue()) {
      if (link.isDeleted || !categoryById.containsKey(link.categoryId)) {
        continue;
      }
      linksByActivity
          .putIfAbsent(link.activityId, () => [])
          .add(link);
    }
    for (final links in linksByActivity.values) {
      links.sort((a, b) {
        final primaryCompare =
            (b.isPrimary ? 1 : 0).compareTo(a.isPrimary ? 1 : 0);
        if (primaryCompare != 0) return primaryCompare;
        return a.sortOrder.compareTo(b.sortOrder);
      });
    }

    final slices = <StatsEntrySlice>[];
    final rangeEntries = await entries.entriesForRange(start, end);
    for (final entry in rangeEntries) {
      final clippedStart = entry.startAt.isAfter(start) ? entry.startAt : start;
      final effectiveEnd = entry.endAt ?? now;
      final clippedEnd = effectiveEnd.isBefore(end) ? effectiveEnd : end;
      if (!clippedEnd.isAfter(clippedStart)) {
        continue;
      }
      final activity = activityById[entry.activityId];
      final links = linksByActivity[entry.activityId] ?? const [];
      // 主分类：排序后首个链接（isPrimary 优先）；无链接时无主分类。
      final primaryCategory =
          links.isEmpty ? null : categoryById[links.first.categoryId];
      slices.add(
        StatsEntrySlice(
          activityId: entry.activityId,
          activityLabel: activity?.name ??
              (entry.activityNameSnapshot.trim().isEmpty
                  ? entry.activityNameSnapshot
                  : entry.activityNameSnapshot.trim()),
          activityColor: activity?.color ??
              entry.activityColorSnapshot ??
              AppConstants.defaultActivityColor,
          primaryCategoryId: primaryCategory?.id,
          primaryCategoryLabel: primaryCategory?.name,
          primaryCategoryColor: primaryCategory?.color,
          linkedCategoryIds: {for (final link in links) link.categoryId},
          categoryAncestorIds: primaryCategory == null
              ? const []
              : _ancestorChain(primaryCategory.id, categoryById),
          duration: clippedEnd.difference(clippedStart),
        ),
      );
    }
    return AppSuccess(slices);
  }

  /// 当前未删分类的 id → 模型 映射（categoryTree 聚合解析祖先名用）。
  Future<AppResult<Map<String, ActivityCategory>>> categoryMap() async {
    final result = await categories.categories();
    if (result case AppFailure<List<ActivityCategory>> failure) {
      return AppFailure('加载分类失败：${failure.message}');
    }
    return AppSuccess({for (final c in result.requireValue()) c.id: c});
  }

  /// 按维度聚合切片（纯函数，无 IO）。
  ///
  /// [categoryById] 仅 [StatsDimension.categoryTree] 需要（解析祖先链节点名/
  /// 色）；其余维度忽略。无主分类切片：primaryCategory 维度归并到
  /// [unassignedCategoryLabel]，categoryTree 归并到根节点。
  List<StatsGroupRow> aggregate(
    List<StatsEntrySlice> slices,
    StatsDimension dimension, {
    Map<String, ActivityCategory> categoryById = const {},
  }) {
    final byKey = <String, _Accum>{};
    for (final slice in slices) {
      final keys = _groupKeys(slice, dimension, categoryById);
      for (final key in keys) {
        final accum = byKey.putIfAbsent(key.id, () => _Accum(
          label: key.label,
          color: key.color,
          depth: key.depth,
          ancestorIds: key.ancestorIds,
        ));
        accum.duration += slice.duration;
        accum.count += 1;
      }
    }
    return [
      for (final entry in byKey.entries)
        StatsGroupRow(
          id: entry.key,
          label: entry.value.label,
          totalDuration: entry.value.duration,
          count: entry.value.count,
          color: entry.value.color,
          depth: entry.value.depth,
          ancestorIds: entry.value.ancestorIds,
        ),
    ];
  }

  /// 切片 → 一个或多个聚合 key（categoryTree 每个祖先节点一个 key）。
  List<_GroupKey> _groupKeys(
    StatsEntrySlice slice,
    StatsDimension dimension,
    Map<String, ActivityCategory> categoryById,
  ) {
    return switch (dimension) {
      StatsDimension.activity => [
        _GroupKey(
          id: 'activity:${slice.activityId}',
          label: slice.activityLabel.trim().isEmpty
              ? unknownActivityLabel
              : slice.activityLabel.trim(),
          color: slice.activityColor,
        ),
      ],
      StatsDimension.primaryCategory => [
        _GroupKey(
          id: 'category:${slice.primaryCategoryId ?? 'none'}',
          label: slice.primaryCategoryLabel ?? unassignedCategoryLabel,
          color:
              slice.primaryCategoryColor ?? AppConstants.defaultActivityColor,
        ),
      ],
      StatsDimension.durationBucket => [
        _GroupKey(
          id: 'bucket:${slice.durationBucketLabel}',
          label: slice.durationBucketLabel,
          color: slice.durationBucketColor,
        ),
      ],
      StatsDimension.primaryCategoryAndDurationBucket => [
        _GroupKey(
          id: 'category:${slice.primaryCategoryId ?? 'none'}'
              ':bucket:${slice.durationBucketLabel}',
          label: '${slice.primaryCategoryLabel ?? unassignedCategoryLabel} / '
              '${slice.durationBucketLabel}',
          color:
              slice.primaryCategoryColor ?? AppConstants.defaultActivityColor,
        ),
      ],
      StatsDimension.categoryTree => _categoryTreeKeys(slice, categoryById),
    };
  }

  /// categoryTree：每个祖先节点（含自身）一个 key——父行累加全部子孙。
  ///
  /// label = 根→该节点的路径拼接；depth = 节点在祖先链中的索引（0=顶层）；
  /// ancestorIds = 该节点的祖先链（根→父）。无主分类 → 根节点 key
  /// （id=''、label=未分类、depth 0、无祖先）。
  List<_GroupKey> _categoryTreeKeys(
    StatsEntrySlice slice,
    Map<String, ActivityCategory> categoryById,
  ) {
    final chain = slice.categoryAncestorIds;
    if (chain.isEmpty) {
      return [
        _GroupKey(
          id: 'category:none',
          label: unassignedCategoryLabel,
          color: AppConstants.defaultActivityColor,
          depth: 0,
        ),
      ];
    }
    final keys = <_GroupKey>[];
    for (var i = 0; i < chain.length; i++) {
      final category = categoryById[chain[i]];
      final label = [
        for (var j = 0; j <= i; j++)
          categoryById[chain[j]]?.name ?? chain[j],
      ].join(' / ');
      keys.add(
        _GroupKey(
          id: 'category:${chain[i]}',
          label: label,
          color: category?.color ?? AppConstants.defaultActivityColor,
          depth: i,
          ancestorIds: List.unmodifiable(chain.sublist(0, i)),
        ),
      );
    }
    return keys;
  }

  /// 主分类祖先链（根 → … → 自身，含自身）：沿 parentId 向上，visited 防环、
  /// 悬空父（已删/不存在）即停。
  static List<String> _ancestorChain(
    String categoryId,
    Map<String, ActivityCategory> categoryById,
  ) {
    final chain = <String>[];
    final visited = <String>{};
    String? current = categoryId;
    while (current != null &&
        categoryById.containsKey(current) &&
        visited.add(current)) {
      chain.insert(0, current);
      current = categoryById[current]!.parentId;
    }
    return chain;
  }
}

/// 聚合分组键（id 唯一；label/color/depth/ancestors 取首个切片的快照）。
class _GroupKey {
  _GroupKey({
    required this.id,
    required this.label,
    required this.color,
    this.depth = 0,
    List<String> ancestorIds = const [],
  }) : ancestorIds = List.unmodifiable(ancestorIds);

  final String id;
  final String label;
  final int color;
  final int depth;
  final List<String> ancestorIds;
}

/// 累加器。
class _Accum {
  _Accum({
    required this.label,
    required this.color,
    required this.depth,
    required this.ancestorIds,
  });

  final String label;
  final int color;
  final int depth;
  final List<String> ancestorIds;
  Duration duration = Duration.zero;
  int count = 0;
}
