/// 统计 store：按范围/维度聚合的缓存 + dataRevision 驱动的失效重算。
///
/// 设计（模块 3b）：
/// - 聚合计算全部下沉 [StatsRepository]（slicesForRange + aggregate），
///   store 只做缓存与失效编排（阶段 3 决策：SQL 聚合在库内/仓储层）；
/// - **缓存失效**：监听 [DataRevision]（不变式 9），任何数据变更
///   （用户操作/同步导入/undo 恢复——三类来源在各自写路径结束 bump）触发
///   缓存清空；同一 revision 内重复请求命中缓存不重算。
///
/// 变更检测注意（stats_models 文档）：[StatsGroupRow] 的 `==` 只按 id——
/// 同 id 的新旧行判等。UI 刷新必须显式比较统计字段（totalDuration/count/
/// label），勿依赖 `==`；本 store 以 revision 号驱动全量重算，不依赖行 `==`。
library;

import 'package:flutter/foundation.dart';

import '../data/repositories/stats_repository.dart';
import '../utils/result.dart';
import '../viewmodels/activity_category.dart';
import '../viewmodels/stats/stats_models.dart';
import 'data_revision.dart';

/// 统计聚合结果：指定范围 + 维度 + 当前有效时刻 的不可变视图。
class StatsSnapshot {
  const StatsSnapshot({
    required this.start,
    required this.end,
    required this.dimension,
    required this.rows,
    required this.totalDuration,
  });

  final DateTime start;
  final DateTime end;
  final StatsDimension dimension;

  /// 聚合行（id 为 `activity:<id>` / `category:<id>` / `bucket:<label>` 等）。
  final List<StatsGroupRow> rows;

  /// 范围内全部条目裁剪后的总时长（含无归属维度）。
  final Duration totalDuration;
}

/// 统计 store：缓存最近一次聚合结果，数据变更（dataRevision）后失效。
class StatsStore extends ChangeNotifier {
  StatsStore({
    required this.repository,
    required this._dataRevision,
  }) {
    _dataRevision.addListener(_invalidate);
  }

  /// 统计聚合仓储（slicesForRange + aggregate 下沉）。
  final StatsRepository repository;

  final DataRevision _dataRevision;

  /// 当前聚合结果；null = 尚未计算或已失效。
  StatsSnapshot? _snapshot;

  /// 已计算快照对应的修订号（同 revision 内重复请求命中缓存）。
  int _snapshotRevision = -1;

  /// 上次计算是否失败（供 UI 提示）。
  String? _lastError;

  /// 最近一次计算失败原因（供 UI/日志展示）。
  String? get lastError => _lastError;

  /// 当前聚合结果（null = 未计算/已失效）。
  StatsSnapshot? get snapshot => _snapshot;

  /// 计算 [start, end) 范围内 [dimension] 维度的聚合。
  ///
  /// [effectiveNow] 可选：运行中条目的裁剪终点（默认当前时刻；测试注入
  /// 固定时刻做确定性断言）。
  /// 失败返回 null 并记 [lastError]（调用方展示）。
  Future<StatsSnapshot?> compute({
    required DateTime start,
    required DateTime end,
    required StatsDimension dimension,
    DateTime? effectiveNow,
  }) async {
    // 缓存命中：同 revision（数据未变）+ 同范围 + 同维度。
    final cached = _snapshot;
    if (_snapshotRevision == _dataRevision.value &&
        cached != null &&
        cached.start == start &&
        cached.end == end &&
        cached.dimension == dimension) {
      return cached;
    }

    final sliceResult = await repository.slicesForRange(
      start: start,
      end: end,
      effectiveNow: effectiveNow,
    );
    if (sliceResult case AppFailure<List<StatsEntrySlice>> failure) {
      _lastError = failure.message;
      _snapshot = null;
      _snapshotRevision = -1;
      notifyListeners();
      return null;
    }
    final slices = sliceResult.requireValue();
    final categoryMap = await repository.categoryMap();
    if (categoryMap case AppFailure<Map<String, ActivityCategory>> failure) {
      _lastError = failure.message;
      _snapshot = null;
      _snapshotRevision = -1;
      notifyListeners();
      return null;
    }
    final rows = repository.aggregate(
      slices,
      dimension,
      categoryById: categoryMap.requireValue(),
    );
    var total = Duration.zero;
    for (final slice in slices) {
      total += slice.duration;
    }
    _lastError = null;
    _snapshot = StatsSnapshot(
      start: start,
      end: end,
      dimension: dimension,
      rows: rows,
      totalDuration: total,
    );
    _snapshotRevision = _dataRevision.value;
    notifyListeners();
    return _snapshot;
  }

  /// 清空缓存并通知（dataRevision 变更触发；也供外部显式失效）。
  void invalidate() {
    _invalidate();
    notifyListeners();
  }

  void _invalidate() {
    _snapshot = null;
    _snapshotRevision = -1;
  }

  @override
  void dispose() {
    _dataRevision.removeListener(_invalidate);
    super.dispose();
  }
}
