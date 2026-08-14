/// 统计 store：按范围/维度聚合的缓存 + dataRevision 驱动的失效重算。
///
/// 设计（模块 3b）：
/// - 聚合计算全部下沉 [StatsRepository]（slicesForRange + aggregate），
///   store 只做缓存与失效编排（阶段 3 决策：SQL 聚合在库内/仓储层）；
/// - **缓存失效**：监听 [DataRevision]（不变式 9），任何数据变更
///   （用户操作/同步导入/undo 恢复——三类来源在各自写路径结束 bump）触发
///   缓存清空并通知（UI 监听 [StatsStore] 即可感知"已失效"）；
/// - **缓存命中约束**：
///   a) revision 未变（数据未变更）；
///   b) 范围/维度相同；
///   c) **上次计算范围内无运行中条目**——运行中条目随 effectiveNow/时钟
///      增长，含运行中条目的快照永不命中缓存（每次用当前时刻重算），
///      否则统计会随时间过期；
/// - **TOCTOU 防护**：await 期间 revision 可能被 bump（数据变更），完成后
///   校验 revision 未变才写入快照，否则丢弃本次结果（下次重算）；
/// - **并发序号**：多个 compute 并发时仅最新请求的结果写入快照（防旧请求
///   覆盖新请求）。
///
/// 变更检测注意（stats_models 文档）：[StatsGroupRow] 的 `==` 只按 id——
/// UI 刷新必须显式比较统计字段（totalDuration/count/label），勿依赖 `==`；
/// 本 store 以 revision 号驱动全量重算，不依赖行 `==`。
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
    required this.containsRunningEntry,
  });

  final DateTime start;
  final DateTime end;
  final StatsDimension dimension;

  /// 聚合行（id 为 `activity:<id>` / `category:<id>` / `bucket:<label>` 等）。
  final List<StatsGroupRow> rows;

  /// 范围内全部条目裁剪后的总时长（含无归属维度）。
  final Duration totalDuration;

  /// 计算时范围内是否存在运行中条目（endAt == null）——存在时该快照
  /// 时间敏感（随时钟增长），缓存命中逻辑据此拒绝复用。
  final bool containsRunningEntry;
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

  /// 并发请求序号：仅最新请求的结果写入快照（防旧请求覆盖新请求）。
  int _computeSeq = 0;

  /// 最近一次计算失败原因（供 UI/日志展示）；失效时一并清空。
  String? _lastError;

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
    // 缓存命中：数据未变 + 同范围同维度 + 上次计算无运行中条目
    //（运行中条目的快照时间敏感，永不复用缓存）。
    final cached = _snapshot;
    if (_snapshotRevision == _dataRevision.value &&
        cached != null &&
        !cached.containsRunningEntry &&
        cached.start == start &&
        cached.end == end &&
        cached.dimension == dimension) {
      return cached;
    }

    final seq = ++_computeSeq;
    // TOCTOU 基线：await 期间 revision 变化 → 本次结果丢弃（下次重算）。
    final revisionAtStart = _dataRevision.value;

    final sliceResult = await repository.slicesForRange(
      start: start,
      end: end,
      effectiveNow: effectiveNow,
    );
    if (sliceResult
        case AppFailure<({List<StatsEntrySlice> slices, bool hasRunningEntry})>
            failure) {
      return _staleOrFailure(
        failure.message,
        seq: seq,
        revisionAtStart: revisionAtStart,
        start: start,
        end: end,
        dimension: dimension,
      );
    }
    final range = sliceResult.requireValue();
    final categoryMap = await repository.categoryMap();
    if (categoryMap case AppFailure<Map<String, ActivityCategory>> failure) {
      return _staleOrFailure(
        failure.message,
        seq: seq,
        revisionAtStart: revisionAtStart,
        start: start,
        end: end,
        dimension: dimension,
      );
    }
    final rows = repository.aggregate(
      range.slices,
      dimension,
      categoryById: categoryMap.requireValue(),
    );
    var total = Duration.zero;
    for (final slice in range.slices) {
      total += slice.duration;
    }

    // 结果提交守卫：仅当数据未变（revision 同基线）且本请求仍是最新
    //（seq 未被更新的请求超过）时写入——否则丢弃（返回当前有效快照，
    // 若参数匹配）或 null（无有效快照），由下次 compute 重算。
    if (_dataRevision.value != revisionAtStart || seq != _computeSeq) {
      return _cachedMatching(start, end, dimension);
    }
    _lastError = null;
    _snapshot = StatsSnapshot(
      start: start,
      end: end,
      dimension: dimension,
      rows: rows,
      totalDuration: total,
      containsRunningEntry: range.hasRunningEntry,
    );
    _snapshotRevision = _dataRevision.value;
    notifyListeners();
    return _snapshot;
  }

  /// 失败/过期统一出口：
  /// - 过期请求（revision 变了 / 已被更新请求超过）：**不触碰 store 状态**
  ///   （防旧请求失败覆盖新请求已提交的快照/错误），返回当前有效快照
  ///   （若参数匹配）或 null；
  /// - 未过期：记录失败、清缓存并通知，返回 null。
  StatsSnapshot? _staleOrFailure(
    String message, {
    required int seq,
    required int revisionAtStart,
    required DateTime start,
    required DateTime end,
    required StatsDimension dimension,
  }) {
    if (_dataRevision.value != revisionAtStart || seq != _computeSeq) {
      return _cachedMatching(start, end, dimension);
    }
    _lastError = message;
    _snapshot = null;
    _snapshotRevision = -1;
    notifyListeners();
    return null;
  }

  /// 当前有效快照中与 [start]/[end]/[dimension] 匹配者（过期/并发丢弃时
  /// 供调用方复用）；无匹配返回 null。
  ///
  /// 与顶部缓存命中守卫保持一致：仅当 revision 未变（快照对应当前数据）
  /// 且非运行中快照（时间敏感）时才可复用——过期请求不得因此拿到旧
  /// revision 的统计或按更早 effectiveNow 计算的时间敏感数据。
  StatsSnapshot? _cachedMatching(
    DateTime start,
    DateTime end,
    StatsDimension dimension,
  ) {
    final current = _snapshot;
    if (current != null &&
        _snapshotRevision == _dataRevision.value &&
        !current.containsRunningEntry &&
        current.start == start &&
        current.end == end &&
        current.dimension == dimension) {
      return current;
    }
    return null;
  }

  /// 清空缓存并通知（外部显式失效；dataRevision 变更走 [_invalidate]）。
  void invalidate() {
    _invalidate();
  }

  void _invalidate() {
    // dataRevision 变更：清空缓存与错误（供 UI 感知"已失效"后重算）。
    _snapshot = null;
    _snapshotRevision = -1;
    _lastError = null;
    notifyListeners();
  }

  @override
  void dispose() {
    _dataRevision.removeListener(_invalidate);
    super.dispose();
  }
}
