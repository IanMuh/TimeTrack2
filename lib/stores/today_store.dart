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
      // 时钟 tick：今日运行条目总时长随时间增长，静默刷新（不阻塞 UI）。
      loadToday();
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
  List<TimeEntry> _today = const [];
  bool _loadFailed = false;

  /// 今日条目（按 startAt 升序；dataRevision/tick 后自动刷新）。
  List<TimeEntry> get today => _today;

  /// 最近一次加载失败（供 UI 提示）。
  bool get loadFailed => _loadFailed;

  /// 加载今日（本地日界）条目并刷新缓存。
  Future<void> loadToday() async {
    if (_disposed) return;
    final now = _now();
    final todayStart = now.startOfDay;
    final tomorrowStart = todayStart.add(const Duration(days: 1));
    final loaded = await entries.entriesForRange(todayStart, tomorrowStart);
    if (_disposed) return;
    _today = List.unmodifiable(loaded);
    _loadFailed = false;
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
