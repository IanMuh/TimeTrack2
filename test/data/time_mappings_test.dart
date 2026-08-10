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

    test('本地→UTC 转换：显式断言固定 6 位期望串（不依赖环境时区）', () {
      // 本地时刻 9:00:00.123456 → 编码为对应 UTC 时刻的固定 6 位串。
      // 断言由 original.toUtc() 的分量构造，避免 UTC 时区环境掩盖 toUtc 回归。
      final original = DateTime(2026, 8, 10, 9, 0, 0, 123, 456); // 本地时区
      final utc = original.toUtc();
      final expected = '${utc.year.toString().padLeft(4, '0')}-'
          '${utc.month.toString().padLeft(2, '0')}-'
          '${utc.day.toString().padLeft(2, '0')}T'
          '${utc.hour.toString().padLeft(2, '0')}:'
          '${utc.minute.toString().padLeft(2, '0')}:'
          '${utc.second.toString().padLeft(2, '0')}.'
          // ISO 小数 = 毫秒(3位) + 微秒(3位) 拼接（如 123ms + 456µs → 123456）
          '${(utc.millisecond * 1000 + utc.microsecond).toString().padLeft(6, '0')}Z';
      expect(m.utcString(original), expected);
    });

    test('round-trip：utcString → readUtc 绝对时刻不变', () {
      final original = DateTime(2026, 8, 10, 9, 0, 0, 123, 456); // 本地时区
      final restored = m.readUtc(m.utcString(original));
      expect(restored.isAtSameMomentAs(original), isTrue);
    });

    test('readUtc 接受非零时区偏移（归一为 UTC 时刻）', () {
      final parsed = m.readUtc('2026-08-10T01:00:00.123456+08:00');
      expect(
        parsed.isAtSameMomentAs(DateTime.utc(2026, 8, 9, 17, 0, 0, 123, 456)),
        isTrue,
        reason: '带偏移字符串应解析为对应 UTC 时刻',
      );
    });

    test('年份边界：9999/10000 字典序不变式失效的已知边界（护栏显式化）', () {
      // toIso8601String 对年份 ≥10000 不再补零，'9999...' 与 '10000...' 字典序反转。
      // 业务时间不会触及（远 future 哨兵用 maxDateTime 而非此格式），此处仅
      // 显式记录该已知边界，防止未来误用。
      // Dart toIso8601String 对年份 >=10000 输出 `+010000-...`（带 + 号且 5 位），
      // 此时 '9999...' 与 '+010000...' 字典序反转——业务时间不会触及
      //（远 future 哨兵用 maxDateTime 而非此格式），此处仅显式记录该已知边界。
      final year9999 = m.utcString(DateTime.utc(9999, 12, 31, 23, 59, 59));
      final year10000 = m.utcString(DateTime.utc(10000, 1, 1));
      expect(year9999, startsWith('9999-12-31T'));
      expect(year10000, startsWith('+010000-01-01T'));
      expect(year9999.endsWith('.000000Z'), isTrue);
      expect(year10000.endsWith('.000000Z'), isTrue);
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
