/// 今日 store（模块 3b）：当日条目的查询缓存。
///
/// 职责：
/// - [loadToday]：加载当日（本地日界）未删条目；
/// - 缓存失效：dataRevision 变更（用户操作/同步/undo 恢复）与时钟 tick
///   自动触发重新加载（今日条目随时间增长——运行中条目总时长）；
/// - 编辑走 TimerStore（本 store 无写路径）。
library;

import 'package:flutter/foundation.dart';

import '../data/repositories/time_entry_repository.dart';
import '../utils/date_time_ext.dart';
import '../viewmodels/time_entry.dart';
import 'clock_store.dart';
import 'data_revision.dart';

/// 今日 store：当日条目缓存 + dataRevision/tick 驱动刷新。
class TodayStore extends ChangeNotifier {
  TodayStore({
    required this.entries,
    required this.dataRevision,
    required this.clock,
    DateTime Function()? now,
  })  : _now = now ?? DateTime.now {
    _dataRevisionListener = () {
      loadToday();
    };
    dataRevision.addListener(_dataRevisionListener);
    _clockListener = () {
      // 时钟 tick：仅两种情形需要重新加载——
      // 1) 今日存在运行条目（总时长随时间增长）；
      // 2) 本地日已变更（查询窗口前移，否则 _today 停留昨日条目）。
      // 其余情形今日窗口内容与时长均不随时间变化：不查库也不通知
      //（避免每秒无谓 DB 查询与 UI 重建）。
      final now = _now();
      final hasRunning = _today.any((e) => e.endAt == null);
      final dayChanged = now.startOfDay != _lastLoadDay;
      if (hasRunning || dayChanged) {
        loadToday();
      }
    };
    clock.addListener(_clockListener);
  }

  final TimeEntryRepository entries;
  final DataRevision dataRevision;
  final ClockStore clock;
  final DateTime Function() _now;

  late final VoidCallback _dataRevisionListener;
  late final VoidCallback _clockListener;

  bool _disposed = false;
  int _requestSeq = 0; // loadToday 请求序号（并发乱序防护）
  List<TimeEntry> _today = const [];
  bool _loadFailed = false;
  /// 最近一次**尝试**加载的本地日（成功/失败均写入——失败也标记"已尝试
  /// 过该日"，防 DB 持续不可用时同日每秒重试；跨日 dayChanged=true 自动恢复。
  /// 首次加载即失败的边界：同日恢复依赖 dataRevision 事件或跨日 tick）。
  DateTime? _lastLoadDay;

  /// 今日条目（按 startAt 升序；dataRevision/tick 后自动刷新）。
  List<TimeEntry> get today => _today;

  /// 最近一次加载失败（供 UI 提示）。
  bool get loadFailed => _loadFailed;

  /// 加载今日（本地日界）条目并刷新缓存。
  ///
  /// 请求序号守卫：dataRevision 监听与时钟 tick 都可能触发 loadToday，
  /// 并发时仅最新一次请求的结果写入缓存（防旧请求晚完成覆盖新数据）。
  Future<void> loadToday() async {
    if (_disposed) return;
    final seq = ++_requestSeq;
    final now = _now();
    final todayStart = now.startOfDay;
    final tomorrowStart = todayStart.add(const Duration(days: 1));
    try {
      final loaded = await entries.entriesForRange(todayStart, tomorrowStart);
      if (_disposed || seq != _requestSeq) return;
      _today = List.unmodifiable(loaded);
      _lastLoadDay = todayStart;
      _loadFailed = false;
    } on Exception catch (_) {
      // 仅收敛 Exception（连接/IO 类）；Error 编程错误不吞，fail-fast 外抛。
      if (_disposed || seq != _requestSeq) return;
      // 失败也标记"已尝试过该日"：无运行条目时 dayChanged 不再触发，
      // 防 DB 持续不可用时每秒重试查询（跨日仍会自动恢复——新日
      // dayChanged=true 触发重载）。
      _lastLoadDay = todayStart;
      _loadFailed = true; // 加载失败：置位供 UI 提示（不抛未处理异常）
    }
    notifyListeners();
  }

  /// 今日总时长（运行中条目截至 now）。
  Duration totalDuration({DateTime? effectiveNow}) {
    final now = effectiveNow ?? _now();
    var total = Duration.zero;
    for (final entry in _today) {
      final end = entry.endAt ?? now;
      if (end.isAfter(entry.startAt)) {
        total += end.difference(entry.startAt);
      }
    }
    return total;
  }

  @override
  void dispose() {
    _disposed = true;
    dataRevision.removeListener(_dataRevisionListener);
    clock.removeListener(_clockListener);
    super.dispose();
  }
}
