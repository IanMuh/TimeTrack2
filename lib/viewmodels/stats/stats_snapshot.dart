/// 统计聚合结果（纯类型）：指定范围 + 维度 + 有效时刻的不可变视图。
///
/// B3 迁移：原 [StatsStore.snapshot] 的载体；缓存/失效语义已由
/// `statsProvider` + family 键取代，类型下沉 viewmodels。
library;

import 'stats_models.dart';

class StatsSnapshot {
  const StatsSnapshot({
    required this.start,
    required this.end,
    required this.dimension,
    required this.rows,
    required this.totalDuration,
    required this.containsRunningEntry,
    this.categoryFilterIds,
    this.includeAuto = false,
  });

  final DateTime start;
  final DateTime end;
  final StatsDimension dimension;

  /// 聚合行（id 为 `activity:<id>` / `category:<id>` / `bucket:<label>` 等）。
  final List<StatsGroupRow> rows;

  /// 范围内全部条目裁剪后的总时长（含无归属维度）。
  final Duration totalDuration;

  /// 计算时范围内是否存在运行中条目（endAt == null）——存在时该快照
  /// 时间敏感（随时钟增长），调用方须传 effectiveNow 重算。
  final bool containsRunningEntry;

  /// 计算时生效的分类过滤（null/空 = 未过滤）。
  final Set<String>? categoryFilterIds;

  /// 计算时是否计入自动条目。
  final bool includeAuto;
}
