import 'package:flutter_test/flutter_test.dart';
import 'package:timetrack2/utils/model_utils.dart';

void main() {
  group('readBool', () {
    test('兼容 bool / 0,1 数字 / null', () {
      expect(readBool(true), isTrue);
      expect(readBool(false), isFalse);
      expect(readBool(1), isTrue);
      expect(readBool(0), isFalse);
      expect(readBool(null), isFalse);
    });

    test('非法类型回退 false', () {
      expect(readBool('1'), isFalse);
      expect(readBool(2), isTrue, reason: '任意非零数字视为 true');
      expect(readBool('true'), isFalse);
    });
  });

  group('readString / readNullableString', () {
    test('合法值与回退', () {
      expect(readString('abc'), 'abc');
      expect(readString(null), '');
      expect(readString(123), '', reason: '非 String 回退空串');
      expect(readString('abc', fallback: 'x'), 'abc');
      expect(readString(123, fallback: 'x'), 'x');
    });

    test('可空版本：非 String 一律 null', () {
      expect(readNullableString('abc'), 'abc');
      expect(readNullableString(null), isNull);
      expect(readNullableString(123), isNull);
    });
  });

  group('readInt / readNullableInt', () {
    test('兼容 int/num/非法回退', () {
      expect(readInt(5), 5);
      expect(readInt(5.7), 5, reason: 'num 截断取整');
      expect(readInt(null), 0);
      expect(readInt('5'), 0);
      expect(readInt(null, fallback: 9), 9);
    });

    test('可空版本：非 num 一律 null', () {
      expect(readNullableInt(5), 5);
      expect(readNullableInt(5.7), 5);
      expect(readNullableInt(null), isNull);
      expect(readNullableInt('5'), isNull);
    });
  });

  group('readDateTime / readNullableDateTime', () {
    test('合法 ISO8601 字符串解析为本地', () {
      final parsed = readDateTime('2026-08-10T04:00:00Z');
      expect(parsed.isAtSameMomentAs(DateTime.utc(2026, 8, 10, 4)), isTrue);
    });

    test('非法/缺省回退 fallback 或当前时间', () {
      final fallback = DateTime.utc(2020);
      expect(readDateTime(null, fallback: fallback), fallback);
      expect(readDateTime('not-a-date', fallback: fallback), fallback);
      final now = readDateTime(null);
      expect(
        now.difference(DateTime.now()).abs(),
        lessThan(const Duration(minutes: 1)),
      );
    });

    test('readNullableDateTime：非法非空值返回 null，绝不伪造时间戳', () {
      expect(readNullableDateTime(null), isNull);
      expect(readNullableDateTime(''), isNull);
      expect(readNullableDateTime('not-a-date'), isNull);
      expect(readNullableDateTime(12345), isNull);
      final parsed = readNullableDateTime('2026-08-10T04:00:00Z');
      expect(parsed!.isAtSameMomentAs(DateTime.utc(2026, 8, 10, 4)), isTrue);
    });
  });
}
