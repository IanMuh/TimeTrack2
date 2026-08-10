/// 日期/时间工具：本地日边界、时长格式化、一天内时间点解析（CLI 用）。
library;

/// 本地日边界扩展（老项目语义，跨天拆分/统计窗口依赖）。
extension DateTimeDayBounds on DateTime {
  /// 当日 00:00:00.000（本地）。
  DateTime get startOfDay => DateTime(year, month, day);

  /// 当日 23:59:59.999（本地，毫秒精度上限）。
  ///
  /// 注意：Dart [DateTime] 支持微秒，此值为**包含性毫秒上界**；跨天/统计比较
  /// 如需覆盖微秒粒度，应改用下一天 `startOfDay.add(Duration(days: 1))` 的排他上界。
  DateTime get endOfDay => DateTime(year, month, day, 23, 59, 59, 999);

  /// 是否与 [other] 同年月日。
  bool isSameDate(DateTime other) =>
      year == other.year && month == other.month && day == other.day;
}

/// 紧凑时长格式化：`1h 30m` / `45m` / `0m`；负时长输出 `-1h 30m`（按绝对值）。
/// 不足整分钟（如 -59 秒）按 0 输出 `0m`（不产生无意义的 `-0m`）。
String formatDurationCompact(Duration duration) {
  final negative = duration.isNegative;
  final totalMinutes = duration.inMinutes.abs();
  final hours = totalMinutes ~/ 60;
  final minutes = totalMinutes % 60;
  if (hours == 0) {
    return minutes == 0 ? '0m' : '${negative ? '-' : ''}${minutes}m';
  }
  return '${negative ? '-' : ''}${hours}h ${minutes}m';
}

final _hhmmPattern = RegExp(r'^(\d{1,2}):(\d{2})$');
final _ampmPattern = RegExp(r'^(\d{1,2})\s*(am|pm)$', caseSensitive: false);
final _chinesePattern = RegExp(r'^(上午|下午|晚上)?(\d{1,2})点(?:(\d{1,2})分)?$');

/// 解析"一天内的时间点"，返回自 0 点起的分钟数（0-1439），无法解析返回 null。
///
/// 支持格式（CLI 指令 `--start=15:00` 等的时间参数）：
/// - `HH:MM`（24 小时制，如 `15:00`、`09:30`）
/// - 中文：`上午/下午/晚上 X点[Y分]`（12 点制；`晚上12点`/`上午12点` 归一为 0 点；
///   无修饰按 24h 制直读，`12点`=中午 12:00）
/// - 英文：`H am/pm`（12 点制，如 `3pm`、`9am`；`12am`=0 点）
///
/// 严格校验：`24:00`、`13pm`、`下午13点` 等越界输入返回 null。
int? parseTimeOfDay(String input) {
  final text = input.trim();
  if (text.isEmpty) return null;

  // 1) HH:MM（24h）
  final hhmm = _hhmmPattern.firstMatch(text);
  if (hhmm != null) {
    final hour = int.parse(hhmm.group(1)!);
    final minute = int.parse(hhmm.group(2)!);
    return _minutesOrNull(hour, minute);
  }

  // 2) 英文 am/pm（忽略大小写；12 点制，小时 1-12）
  final ampm = _ampmPattern.firstMatch(text);
  if (ampm != null) {
    var hour = int.parse(ampm.group(1)!);
    if (hour < 1 || hour > 12) return null; // 13pm / 0am 等越界
    final isPm = ampm.group(2)!.toLowerCase() == 'pm';
    if (isPm && hour < 12) hour += 12;
    if (!isPm && hour == 12) hour = 0; // 12am = 0 点
    return _minutesOrNull(hour, 0);
  }

  // 3) 中文：`[上午|下午|晚上]X点[Y分]`（分钟数必须带"分"字，避免 `3点5` 歧义）。
  //    有修饰（上午/下午/晚上）时采用 12 点制（小时 1-12，`下午13点` 非法）；
  //    `晚上12点` 归一为 0 点（午夜，与中文直觉一致）；
  //    无修饰时按 24h 制直读（`12点`=中午 12:00，与 HH:MM 的 `12:30` 语义一致）。
  final cn = _chinesePattern.firstMatch(text);
  if (cn != null) {
    final period = cn.group(1);
    var hour = int.parse(cn.group(2)!);
    final minute = cn.group(3) == null ? 0 : int.parse(cn.group(3)!);
    if (period != null) {
      if (hour < 1 || hour > 12) return null; // 12 点制范围
      if (period == '下午' || period == '晚上') {
        if (hour < 12) hour += 12; // 下午1点=13 点；下午12点=12 点
        if (period == '晚上' && hour == 12) hour = 0; // 晚上12点 → 0 点（午夜）
      } else if (hour == 12) {
        hour = 0; // 上午12点 → 0 点
      }
    } else {
      if (hour > 23) return null;
      // 无修饰 12 点 = 中午 12:00（中文直觉），不做 12 小时制转换。
    }
    return _minutesOrNull(hour, minute);
  }

  return null;
}

/// 校验小时/分钟范围并换算为分钟数；越界返回 null。
int? _minutesOrNull(int hour, int minute) {
  if (hour < 0 || hour > 23 || minute < 0 || minute > 59) return null;
  return hour * 60 + minute;
}
