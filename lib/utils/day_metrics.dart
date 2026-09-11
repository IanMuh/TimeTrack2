import '../viewmodels/time_entry.dart';

/// 单日指标口径（统一计算：今日页 4 指标 / 计时页焦点统计共用——批次 3 收口）。
///
/// 口径定义（与 StatsStore 的范围裁剪语义一致）：
/// - 条目时长：跨 0 点起点钳制到当日零点、运行中截至 [now]；
/// - 总时长 = 当日全部条目时长之和（含未分配）；
/// - 会话数 = 当日条目数（运行中计 1 条）；
/// - 专注 = 非未分配活动条目时长；休息 = 未分配活动条目时长；
/// - 未分配判定由调用方传入 [unassignedActivityId]（单例 id）。
class DayMetrics {
  const DayMetrics({
    required this.total,
    required this.sessions,
    required this.focus,
    required this.rest,
  });

  final Duration total;
  final int sessions;
  final Duration focus;
  final Duration rest;
}

/// H:MM 短格式（今日累计/卡片角标共用，如 10:42）。
String formatHm(Duration d) {
  final h = d.inHours;
  final m = d.inMinutes.remainder(60);
  return '$h:${m.toString().padLeft(2, '0')}';
}

/// 计算单日指标（纯函数：数据快照 + 日边界 + 未分配 id）。
DayMetrics computeDayMetrics(
  List<TimeEntry> entries, {
  required DateTime dayStart,
  required DateTime now,
  String? unassignedActivityId,
}) {
  var total = Duration.zero;
  var focus = Duration.zero;
  var rest = Duration.zero;
  for (final e in entries) {
    final start = e.startAt.isBefore(dayStart) ? dayStart : e.startAt;
    final end = e.endAt ?? now;
    final d = end.isAfter(start) ? end.difference(start) : Duration.zero;
    total += d;
    if (e.activityId == unassignedActivityId) {
      rest += d;
    } else {
      focus += d;
    }
  }
  return DayMetrics(
    total: total,
    sessions: entries.length,
    focus: focus,
    rest: rest,
  );
}
