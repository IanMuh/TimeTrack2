/// 数据查询 provider（Riverpod 迁移 B2）。
///
/// 只读查询即 provider：页面 watch 查询结果，不再自持仓储副本。
/// 失效规则：
/// - 一切写路径（本地操作/指令/undo 恢复/云/LAN/文件导入/清库）统一 bump
///   [dataRevisionProvider]，本文件所有查询 watch 修订号兜底失效——全局
///   粒度，与迁移前三查询 store 监听修订号的语义一致（B3 设想的精准
///   `ref.invalidate` 未实施，按修订号全局失效并非退化）；
/// - 时钟 tick 不驱动查询：运行中条目的"当前时长"由时长叶子 widget watch
///   `clockTickProvider` 计算，查询结果本身不随时间变化。
library;

import 'package:flutter/foundation.dart' show setEquals;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/repositories/action_log_repository.dart';
import '../data/repositories/activity_repository.dart';
import '../data/repositories/category_repository.dart';
import '../data/repositories/settings_repository.dart';
import '../data/repositories/stats_repository.dart';
import '../data/repositories/time_entry_repository.dart';
import '../utils/date_time_ext.dart';
import '../utils/result.dart';
import '../viewmodels/action_log.dart';
import '../viewmodels/activity.dart';
import '../viewmodels/activity_category.dart';
import '../viewmodels/stats/stats_models.dart';
import '../viewmodels/stats/stats_snapshot.dart';
import '../viewmodels/time_entry.dart';
import 'foundation.dart';
import 'infrastructure.dart';

/// 查询失败（把仓储 [AppFailure] 转成 provider 的 error 态，供 UI 重试）。
class DataQueryException implements Exception {
  const DataQueryException(this.message);

  final String message;

  @override
  String toString() => 'DataQueryException: $message';
}

/// 取成功值，失败抛 [DataQueryException]（AsyncValue.error 可被 UI 捕获）。
T requireValue<T>(AppResult<T> result) {
  return switch (result) {
    AppSuccess<T>(:final value) => value,
    AppFailure<T>(:final message) => throw DataQueryException(message),
  };
}

// ---------------------------------------------------------------------------
// 仓储（供 provider 与迁移期页面共用；B4 删除 AppStore 后仍是唯一入口）
// ---------------------------------------------------------------------------

final activityRepositoryProvider = Provider<ActivityRepository>((ref) {
  return ActivityRepository(database: ref.watch(appDatabaseProvider));
});

final settingsRepositoryProvider = Provider<SettingsRepository>((ref) {
  return SettingsRepository(database: ref.watch(appDatabaseProvider));
});

final categoryRepositoryProvider = Provider<CategoryRepository>((ref) {
  return CategoryRepository(database: ref.watch(appDatabaseProvider));
});

final timeEntryRepositoryProvider = Provider<TimeEntryRepository>((ref) {
  return TimeEntryRepository(
    database: ref.watch(appDatabaseProvider),
    activityRepository: ref.watch(activityRepositoryProvider),
    settingsRepository: ref.watch(settingsRepositoryProvider),
  );
});

final statsRepositoryProvider = Provider<StatsRepository>((ref) {
  return StatsRepository(
    activities: ref.watch(activityRepositoryProvider),
    categories: ref.watch(categoryRepositoryProvider),
    entries: ref.watch(timeEntryRepositoryProvider),
  );
});

final actionLogRepositoryProvider = Provider<ActionLogRepository>((ref) {
  return ActionLogRepository(database: ref.watch(appDatabaseProvider));
});

// ---------------------------------------------------------------------------
// 查询
// ---------------------------------------------------------------------------

/// [day] 当天（本地日界）未删条目，startAt 升序。
///
/// 键为"当日零点"：跨午夜后 [currentDayProvider] 变化 → 页面换键自动取新日
/// 数据（不再出现页面停留在昨日、store 已滚到新日的双源问题）。
final dayEntriesProvider =
    FutureProvider.family<List<TimeEntry>, DateTime>((ref, day) async {
  // 数据变更（写路径/同步/undo）统一经修订号失效；查询本身不随时间变化。
  ref.watch(dataRevisionProvider);
  final start = DateTime(day.year, day.month, day.day);
  // DST 安全：固定 24h add 在切换日偏移一小时，用日历日 +1。
  final end = DateTime(start.year, start.month, start.day + 1);
  final result =
      await ref.watch(timeEntryRepositoryProvider).entriesForRange(start, end);
  return result;
}, isAutoDispose: true);

/// [range] 范围（起点含、终点不含）未删条目，用于时间线/统计明细。
final rangeEntriesProvider = FutureProvider.family<List<TimeEntry>,
    (DateTime, DateTime)>((ref, range) async {
  ref.watch(dataRevisionProvider);
  final result = await ref
      .watch(timeEntryRepositoryProvider)
      .entriesForRange(range.$1, range.$2);
  return result;
}, isAutoDispose: true);

/// 当前有效活动（未删，含收藏排序）——活动增删改由修订号驱动刷新。
final activitiesProvider = FutureProvider<List<Activity>>((ref) async {
  ref.watch(dataRevisionProvider);
  final result = await ref.watch(activityRepositoryProvider).activities();
  return switch (result) {
    AppSuccess<List<Activity>>(:final value) => value,
    AppFailure<List<Activity>>(:final message) => throw DataQueryException(message),
  };
});

/// 唯一未分配活动的 id（null = 数据异常/尚未 seed）。
final unassignedActivityIdProvider = FutureProvider<String?>((ref) async {
  ref.watch(dataRevisionProvider);
  final result = await ref.watch(activityRepositoryProvider).unassignedActivity();
  return switch (result) {
    AppSuccess<Activity>(:final value) => value.id,
    AppFailure<Activity>() => null,
  };
});

/// 最近 [limit] 条操作日志（时间倒序）。
///
/// 时间线日志视图用：此前页面用 `_logsLoaded` 永久守卫导致打开一次后永不
/// 刷新，改为 provider 后随修订号失效（写操作会 bump）。
final actionLogsProvider =
    FutureProvider.family<List<ActionLog>, int>((ref, limit) async {
  ref.watch(dataRevisionProvider);
  final result = await ref.watch(actionLogRepositoryProvider).logs(limit: limit);
  return switch (result) {
    AppSuccess<List<ActionLog>>(:final value) => value,
    AppFailure<List<ActionLog>>(:final message) => throw DataQueryException(message),
  };
}, isAutoDispose: true);

/// 当天零点（页面传入 [dayEntriesProvider] 前统一归一）。
DateTime dayStartOf(DateTime anyMoment) => anyMoment.startOfDay;

// ---------------------------------------------------------------------------
// 统计（B3：StatsStore 缓存语义由 provider + family 键取代）
// ---------------------------------------------------------------------------

/// 统计查询键：范围 × 维度 × 过滤参数 × 有效时刻。
///
/// [effectiveNow] 仅用于测试注入确定性时刻（键稳定可断言）；页面调用方
/// **不传**——运行中条目的裁剪终点由仓储在执行时取当前时刻（缺省 = now），
/// 重算时机由修订号/参数变更驱动。曾按 tick 传当前时刻使键每秒变化以
/// 「自动重算」，代价是每秒 SQL 重查 + 新键无旧值导致整页 loading 闪烁 +
/// 保活 offstage 分支空转（迁移审查判退化后移除）。
class StatsQuery {
  StatsQuery({
    required this.start,
    required this.end,
    required this.dimension,
    required this.includeAuto,
    Set<String>? categoryFilterIds,
    this.effectiveNow,
  }) : categoryFilterIds = (categoryFilterIds == null || categoryFilterIds.isEmpty)
            ? const <String>{}
            : Set<String>.unmodifiable(categoryFilterIds);

  final DateTime start;
  final DateTime end;
  final StatsDimension dimension;
  final bool includeAuto;
  final Set<String> categoryFilterIds;
  final DateTime? effectiveNow;

  @override
  bool operator ==(Object other) =>
      other is StatsQuery &&
      other.start == start &&
      other.end == end &&
      other.dimension == dimension &&
      other.includeAuto == includeAuto &&
      other.effectiveNow == effectiveNow &&
      setEquals(other.categoryFilterIds, categoryFilterIds);

  @override
  int get hashCode => Object.hash(
        start,
        end,
        dimension,
        includeAuto,
        effectiveNow,
        Object.hashAllUnordered(categoryFilterIds),
      );
}

/// 统计聚合：范围/维度/过滤参数变化即新 family 键；写路径 bump 修订号失效。
final statsProvider = FutureProvider.family<StatsSnapshot, StatsQuery>(
  (ref, query) async {
    ref.watch(dataRevisionProvider);
    final repo = ref.watch(statsRepositoryProvider);
    final sliceResult = await repo.slicesForRange(
      start: query.start,
      end: query.end,
      effectiveNow: query.effectiveNow,
      categoryFilterIds:
          query.categoryFilterIds.isEmpty ? null : query.categoryFilterIds,
      includeAuto: query.includeAuto,
    );
    final range = requireValue(sliceResult);
    // categoryTree 维度才需要分类映射（其余维度 aggregate 忽略）——惰性加载
    // 避免每次计算全量查分类表。
    final Map<String, ActivityCategory> categoryById =
        query.dimension == StatsDimension.categoryTree
            ? requireValue(await repo.categoryMap())
            : const {};
    final rows = repo.aggregate(
      range.slices,
      query.dimension,
      categoryById: categoryById,
    );
    var total = Duration.zero;
    for (final slice in range.slices) {
      total += slice.duration;
    }
    return StatsSnapshot(
      start: query.start,
      end: query.end,
      dimension: query.dimension,
      rows: List<StatsGroupRow>.unmodifiable(rows),
      totalDuration: total,
      containsRunningEntry: range.hasRunningEntry,
      categoryFilterIds: query.categoryFilterIds.isEmpty
          ? null
          : Set<String>.unmodifiable(query.categoryFilterIds),
      includeAuto: query.includeAuto,
    );
  },
  isAutoDispose: true,
);
