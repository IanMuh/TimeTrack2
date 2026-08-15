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
      // 时钟 tick：三种情形需要重新加载——
      // 1) 今日存在运行条目（总时长随时间增长）；
      // 2) 本地日已变更（查询窗口前移，否则 _today 停留昨日条目）；
      // 3) 上次加载失败且已达退避间隔（有界重试自愈——单次瞬时 DB 故障
      //    不导致整日数据缺失，同时防每秒重试风暴）。
      // 其余情形今日窗口内容与时长均不随时间变化：不查库也不通知
      //（避免每秒无谓 DB 查询与 UI 重建）。
      final now = _now();
      final hasRunning = _today.any((e) => e.endAt == null);
      final dayChanged = now.startOfDay != _lastLoadDay;
      final retryDue = _loadFailed &&
          now.difference(_lastFailTime) >= retryInterval;
      // 失败态隔离（模块门禁 medium）：_loadFailed 时 hasRunning 分支不得
      // 触发 DB 查询（防 DB 故障持续时每秒重试风暴）——仅按 retryInterval
      // 有界重试；运行条目时长仍每秒刷新（notifyListeners 不查库）。
      if (_loadFailed) {
        if (hasRunning) {
          notifyListeners(); // 计时展示每秒刷新，DB 查询交给 retryDue
        }
        if (dayChanged || retryDue) {
          loadToday();
        }
        return;
      }
      if (hasRunning || dayChanged) {
        loadToday();
      }
    };
    clock.addListener(_clockListener);
  }

  /// 失败后重试间隔（有界退避：瞬时故障在若干秒后自动重试一次）。
  final Duration retryInterval = const Duration(seconds: 30);

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
  DateTime _lastFailTime = DateTime.fromMillisecondsSinceEpoch(0); // 失败退避基准
  /// 最近一次**尝试**加载的本地日（成功/失败均写入——失败也标记"已尝试
  /// 过该日"，防 DB 持续不可用时同日每秒重试；跨日 dayChanged=true 自动恢复。
  /// 失败后由 [retryInterval] 有界退避自动重试（防单次瞬时故障整日缺失）。
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
    // DST 安全的下一天本地零点（固定 24h add 在切换日偏移一小时——
    // 与 rolloverRunningEntriesIfNeeded 的 DateTime(year, month, day+1) 一致）。
    final tomorrowStart = DateTime(todayStart.year, todayStart.month, todayStart.day + 1);
    try {
      final loaded = await entries.entriesForRange(todayStart, tomorrowStart);
      if (_disposed || seq != _requestSeq) return;
      _today = List.unmodifiable(loaded);
      _lastLoadDay = todayStart;
      _loadFailed = false;
    } on Exception catch (_) {
      // 仅收敛 Exception（连接/IO 类）；Error 编程错误不吞，fail-fast 外抛。
      if (_disposed || seq != _requestSeq) return;
      // 失败也标记"已尝试过该日"（无运行条目时 dayChanged 不再触发，
      // 防 DB 持续不可用时每秒重试）+ 记录失败时刻（retryInterval 有界
      // 退避自愈——单次瞬时故障不导致整日数据缺失）。
      _lastLoadDay = todayStart;
      _lastFailTime = now;
      _loadFailed = true; // 加载失败：置位供 UI 提示（不抛未处理异常）
    }
    notifyListeners();
  }

  /// 今日总时长（运行中条目截至 now）。
  Duration totalDuration({DateTime? effectiveNow}) {
    final now = effectiveNow ?? _now();
    final todayStart = now.startOfDay;
    var total = Duration.zero;
    for (final entry in _today) {
      // 起点钳制到今日零点：跨日运行条目（如昨日 23:00 起未滚转）只计
      // 今日时段，防昨日时段高估进今日总时长。
      final start =
          entry.startAt.isBefore(todayStart) ? todayStart : entry.startAt;
      final end = entry.endAt ?? now;
      if (end.isAfter(start)) {
        total += end.difference(start);
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
