import 'package:flutter_test/flutter_test.dart';
import 'package:timetrack2/utils/model_utils.dart';

void main() {
  group('readBool', () {
    test('兼容 bool / 数字 / 字符串布尔 / null', () {
      expect(readBool(true), isTrue);
      expect(readBool(false), isFalse);
      expect(readBool(1), isTrue);
      expect(readBool(0), isFalse);
      expect(readBool(1.0), isTrue);
      expect(readBool(0.0), isFalse);
      expect(readBool(2), isTrue, reason: '任意非零数字视为 true');
      expect(readBool('true'), isTrue);
      expect(readBool('TRUE'), isTrue);
      expect(readBool(' false '), isFalse, reason: '忽略大小写与空白');
      expect(readBool(null), isFalse);
    });

    test('无法识别的值回退 false', () {
      expect(readBool('1'), isFalse, reason: '字符串 1 不识别为布尔');
      expect(readBool('是'), isFalse);
      expect(readBool([true]), isFalse);
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
      expect(readInt(5.7), 5, reason: 'num 向零截断取整');
      expect(readInt(-5.7), -5, reason: '向零截断（非 floor）');
      expect(readInt(null), 0);
      expect(readInt('5'), 0);
      expect(readInt(null, fallback: 9), 9);
    });

    test('非有限数（NaN/±Infinity）回退，不抛异常', () {
      expect(readInt(double.nan), 0);
      expect(readInt(double.infinity, fallback: 9), 9);
      expect(readInt(double.negativeInfinity), 0);
      expect(readNullableInt(double.nan), isNull);
      expect(readNullableInt(double.infinity), isNull);
    });

    test('可空版本：非 num 一律 null', () {
      expect(readNullableInt(5), 5);
      expect(readNullableInt(5.7), 5);
      expect(readNullableInt(null), isNull);
      expect(readNullableInt('5'), isNull);
    });
  });

  group('readDateTime / readNullableDateTime', () {
    test('合法 ISO8601 字符串解析为本地时区', () {
      final parsed = readDateTime('2026-08-10T04:00:00Z');
      expect(parsed.isUtc, isFalse, reason: '应转为本地时区');
      expect(parsed.isAtSameMomentAs(DateTime.utc(2026, 8, 10, 4)), isTrue);
    });

    test('缺键/非法：显式 fallback 则回退，否则抛 FormatException', () {
      final fallback = DateTime.utc(2020);
      expect(readDateTime(null, fallback: fallback), fallback);
      expect(readDateTime('', fallback: fallback), fallback);
      expect(readDateTime('not-a-date', fallback: fallback), fallback);
      expect(
        () => readDateTime(null),
        throwsA(isA<FormatException>()
            .having((e) => e.message, 'message', contains('时间字段'))),
      );
      expect(
        () => readDateTime('not-a-date'),
        throwsFormatException,
      );
      expect(() => readDateTime(12345), throwsFormatException);
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
