/// 时刻显示格式化（批次 4）：按用户偏好（ProfileSettings.use24HourFormat）
/// 输出 12/24 小时制时刻。所有用户可见的"几点几分"显示统一经此收敛，
/// 保证设置变更后跨页一致（不变式 7）。
library;

/// 格式化时刻。
///
/// - 24 小时制：`09:05` / `23:59`；
/// - 12 小时制：`09:05 AM` / `11:59 PM`（12 点制下 0 点 = 12 AM、
///   12 点 = 12 PM，与美国习惯一致）。
///
/// 数字恒两位补零（tabular figures 由调用方样式保证——契约 §8 实时数字
/// 稳定不跳动）。
String formatClock(int hour, int minute, {required bool use24}) {
  final mm = minute.toString().padLeft(2, '0');
  if (use24) {
    return '${hour.toString().padLeft(2, '0')}:$mm';
  }
  final suffix = hour < 12 ? 'AM' : 'PM';
  final h12 = hour % 12 == 0 ? 12 : hour % 12;
  return '${h12.toString().padLeft(2, '0')}:$mm $suffix';
}

/// 从 [DateTime] 取时刻文本（等价 [formatClock] 的 DateTime 便捷形式）。
String formatClockOf(DateTime time, {required bool use24}) {
  return formatClock(time.hour, time.minute, use24: use24);
}

/// 把 [text] 解析为分钟数（0..1439）；解析失败返回 null。
///
/// 接受 `HH:mm`（24 小时制，TimePicker 返回值由调用方拆分，此函数兜底
/// 手输场景）。
int? parseClockToMinutes(String text) {
  final match = RegExp(r'^(\d{1,2}):(\d{2})$').firstMatch(text.trim());
  if (match == null) return null;
  final hour = int.parse(match.group(1)!);
  final minute = int.parse(match.group(2)!);
  if (hour > 23 || minute > 59) return null;
  return hour * 60 + minute;
}
