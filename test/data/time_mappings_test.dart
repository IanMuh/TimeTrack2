import 'package:flutter_test/flutter_test.dart';
import 'package:timetrack2/data/repositories/repository_mappings.dart';

/// 时间工具直接单测：锁定"字典序 = 时间序"这一核心不变式。
///
/// 该不变式是跨日拆分/重叠裁剪/LWW 的 SQL 字符串比较基础——一旦
/// `utcString` 输出宽度不稳（如 Dart `toIso8601String` 的变宽小数），
/// `'Z'`(0x5A) 会排在 `'.'`/数字 之前造成字典序反转，此处护栏必须守住。
class _MappingHost with RepositoryMappings {}

void main() {
  final m = _MappingHost();

  group('utcString 固定 6 位微秒', () {
    test('整秒/毫秒/微秒统一补到 6 位', () {
      expect(m.utcString(DateTime.utc(2026, 8, 10, 9)), '2026-08-10T09:00:00.000000Z');
      expect(
        m.utcString(DateTime.utc(2026, 8, 10, 9, 0, 0, 123)),
        '2026-08-10T09:00:00.123000Z',
      );
      expect(
        m.utcString(DateTime.utc(2026, 8, 10, 9, 0, 0, 0, 123456)),
        '2026-08-10T09:00:00.123456Z',
      );
    });

    test('字典序 = 时间序（跨毫秒/微秒边界）', () {
      final earlier = m.utcString(DateTime.utc(2026, 8, 10, 9, 0, 0)); // 整秒
      final later = m.utcString(
        DateTime.utc(2026, 8, 10, 9, 0, 0, 0, 1), // 1 微秒后
      );
      expect(earlier.compareTo(later), lessThan(0),
          reason: '固定宽度下字典序必须等于时间序');
      // 反向也成立
      final dayEnd = m.utcString(DateTime.utc(2026, 8, 10, 23, 59, 59, 999));
      final nextStart = m.utcString(DateTime.utc(2026, 8, 11));
      expect(dayEnd.compareTo(nextStart), lessThan(0));
    });

    test('round-trip：utcString → readUtc 绝对时刻不变', () {
      final original = DateTime(2026, 8, 10, 9, 0, 0, 123, 456); // 本地时区
      final restored = m.readUtc(m.utcString(original));
      expect(restored.isAtSameMomentAs(original), isTrue);
    });
  });

  group('readUtc 严格校验', () {
    test('无时区偏移字符串抛错（防时间漂移）', () {
      expect(
        () => m.readUtc('2026-08-10T09:00:00'),
        throwsFormatException,
      );
    });

    test('readNullableUtc：null/空白返回 null，非法非空抛错', () {
      expect(m.readNullableUtc(null), isNull);
      expect(m.readNullableUtc('   '), isNull);
      expect(m.readNullableUtc(''), isNull);
      expect(() => m.readNullableUtc('not-a-date'), throwsFormatException);
      expect(() => m.readNullableUtc('2026-08-10T09:00:00'),
          throwsFormatException, reason: '无偏移同样拒绝');
    });
  });
}
