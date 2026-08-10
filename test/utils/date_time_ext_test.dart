import 'package:flutter_test/flutter_test.dart';
import 'package:timetrack2/utils/date_time_ext.dart';

void main() {
  group('DateTimeDayBounds', () {
    final day = DateTime(2026, 8, 10, 15, 30, 45, 123);

    test('startOfDay / endOfDay / isSameDate', () {
      expect(day.startOfDay, DateTime(2026, 8, 10));
      expect(day.endOfDay, DateTime(2026, 8, 10, 23, 59, 59, 999));
      expect(day.isSameDate(DateTime(2026, 8, 10, 0, 1)), isTrue);
      expect(day.isSameDate(DateTime(2026, 8, 11)), isFalse);
      // 跨年/跨月边界
      expect(
        DateTime(2026, 1, 1).isSameDate(DateTime(2025, 12, 31)),
        isFalse,
      );
      expect(
        DateTime(2026, 2, 1).isSameDate(DateTime(2026, 1, 31)),
        isFalse,
      );
      // 闰年 2 月 29 日
      expect(
        DateTime(2024, 2, 29).isSameDate(DateTime(2024, 2, 29)),
        isTrue,
      );
      expect(
        DateTime(2024, 2, 29).isSameDate(DateTime(2024, 3, 1)),
        isFalse,
      );
    });
  });

  group('formatDurationCompact', () {
    test('小时/分钟/零', () {
      expect(formatDurationCompact(const Duration(minutes: 90)), '1h 30m');
      expect(formatDurationCompact(const Duration(minutes: 45)), '45m');
      expect(formatDurationCompact(Duration.zero), '0m');
      expect(formatDurationCompact(const Duration(hours: 2)), '2h 0m');
      expect(formatDurationCompact(const Duration(minutes: 1)), '1m');
      // 超过 24 小时
      expect(formatDurationCompact(const Duration(days: 1)), '24h 0m');
      // 秒/毫秒被 inMinutes 截断
      expect(formatDurationCompact(const Duration(minutes: 1, seconds: 59)),
          '1m');
      expect(formatDurationCompact(const Duration(seconds: 59)), '0m');
    });

    test('负时长按绝对值输出带 - 前缀', () {
      expect(formatDurationCompact(const Duration(minutes: -90)), '-1h 30m');
      expect(formatDurationCompact(const Duration(minutes: -45)), '-45m');
      expect(formatDurationCompact(const Duration(minutes: -1, seconds: -30)),
          '-1m');
      // 不足整分钟的负时长：截断为 0 → 输出 0m（不产生 -0m）
      expect(formatDurationCompact(const Duration(seconds: -59)), '0m');
      expect(formatDurationCompact(const Duration(seconds: -30)), '0m');
    });
  });

  group('parseTimeOfDay', () {
    test('HH:MM 24h 制', () {
      expect(parseTimeOfDay('15:00'), 15 * 60);
      expect(parseTimeOfDay('09:30'), 9 * 60 + 30);
      expect(parseTimeOfDay('0:05'), 5);
      expect(parseTimeOfDay(' 8:15 '), 8 * 60 + 15, reason: '忽略首尾空白');
    });

    test('英文 am/pm（忽略大小写）', () {
      expect(parseTimeOfDay('3pm'), 15 * 60);
      expect(parseTimeOfDay('9am'), 9 * 60);
      expect(parseTimeOfDay('12pm'), 12 * 60);
      expect(parseTimeOfDay('12am'), 0, reason: '12am = 0 点');
      expect(parseTimeOfDay('3 PM'), 15 * 60);
    });

    test('中文 上午/下午/晚上', () {
      expect(parseTimeOfDay('下午3点'), 15 * 60);
      expect(parseTimeOfDay('下午3点30分'), 15 * 60 + 30);
      expect(parseTimeOfDay('上午9点'), 9 * 60);
      expect(parseTimeOfDay('晚上8点'), 20 * 60);
      expect(parseTimeOfDay('3点'), 3 * 60, reason: '无修饰默认上午');
      expect(parseTimeOfDay('下午12点'), 12 * 60, reason: '下午12点 = 12 点');
      expect(parseTimeOfDay('上午12点'), 0, reason: '上午12点 = 0 点');
      expect(parseTimeOfDay('晚上12点'), 0,
          reason: '晚上12点 = 午夜 0 点（中文直觉）');
      expect(parseTimeOfDay('12点'), 12 * 60,
          reason: '无修饰 12点 = 中午 12:00（与 HH:MM 的 12:30 语义一致）');
      expect(parseTimeOfDay('0点'), 0, reason: '无修饰 0点 合法（24h 制 0-23）');
      expect(parseTimeOfDay('12点30分'), 12 * 60 + 30,
          reason: '无修饰 12点30分 = 12:30');
      expect(parseTimeOfDay('晚上12点30分'), 30,
          reason: '晚上12点30分 = 0:30（午夜后）');
      expect(parseTimeOfDay('下午12点30分'), 12 * 60 + 30);
      expect(parseTimeOfDay('上午12点30分'), 30);
    });

    test('12 小时制歧义边界（HH:MM 无后缀）', () {
      expect(parseTimeOfDay('12:00'), 12 * 60, reason: 'HH:MM 一律按 24h 制');
      // 混合格式不支持（下午3:30 不是合法输入）
      expect(parseTimeOfDay('下午3:30'), isNull);
    });

    test('非法/越界输入返回 null', () {
      for (final bad in [
        '', ' ', '24:00', '23:60', '12:5', 'abc', '下午13点', '3点99分',
        '3点5', '13pm', '0am-1', '15:00x', '下午', '3点x',
      ]) {
        expect(parseTimeOfDay(bad), isNull, reason: '$bad 应无法解析');
      }
    });
  });
}
