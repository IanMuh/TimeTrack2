import 'package:flutter_test/flutter_test.dart';
import 'package:timetrack2/utils/result.dart';

void main() {
  group('AppResult', () {
    test('fold 分发成功/失败（直传原实例）', () {
      const success = AppSuccess<int>(42);
      const failure = AppFailure<int>('boom');
      expect(
        success.fold(
          onSuccess: (s) {
            expect(identical(s, success), isTrue);
            return 'S:${s.value}';
          },
          onFailure: (f) => 'F:${f.message}',
        ),
        'S:42',
      );
      expect(
        failure.fold(
          onSuccess: (s) => 'S:${s.value}',
          onFailure: (f) {
            expect(identical(f, failure), isTrue);
            return 'F:${f.message}';
          },
        ),
        'F:boom',
      );
    });

    test('when 直接取 value/message', () {
      const success = AppSuccess<int>(7);
      const failure = AppFailure<int>('err');
      expect(
        success.when(onSuccess: (v) => v * 2, onFailure: (m) => -1),
        14,
      );
      expect(
        failure.when(onSuccess: (v) => v, onFailure: (m) => m.length),
        3,
      );
    });

    test('isSuccess / valueOrNull / requireValue', () {
      const success = AppSuccess<int>(42);
      const failure = AppFailure<int>('err');
      expect(success.isSuccess, isTrue);
      expect(failure.isSuccess, isFalse);
      expect(success.valueOrNull, 42);
      expect(failure.valueOrNull, isNull);
      expect(success.requireValue(), 42);
      expect(
        () => failure.requireValue(),
        throwsA(isA<StateError>()),
      );
      // 失败原因保留在异常消息中
      try {
        failure.requireValue();
        fail('应抛异常');
      } on StateError catch (e) {
        expect(e.message, contains('err'));
      }
    });

    test('requireValue 替代 valueOrNull! 裸解包', () {
      const success = AppSuccess<int>(7);
      expect(success.requireValue() * 2, 14);
    });

    test('可空 T：valueOrNull 无法区分成功(null) 与失败', () {
      const successNull = AppSuccess<int?>(null);
      const failure = AppFailure<int?>('err');
      expect(successNull.valueOrNull, isNull);
      expect(failure.valueOrNull, isNull);
      // 语义区分依赖 isSuccess
      expect(successNull.isSuccess, isTrue);
      expect(failure.isSuccess, isFalse);
      // requireValue 对可空 T 同样可用
      expect(successNull.requireValue(), isNull);
      expect(() => failure.requireValue(), throwsStateError);
    });

    test('值相等：按 value/message 比较', () {
      const success = AppSuccess<int>(42);
      const otherSuccess = AppSuccess<int>(42);
      const failure = AppFailure<int>('err');
      const otherFailure = AppFailure<int>('err');
      // 非 const 实例避免常量规范化 identical 短路
      final s1 = AppSuccess<int>(1);
      final s2 = AppSuccess<int>(1);
      final f1 = AppFailure<int>('boom');
      final f2 = AppFailure<int>('boom');
      expect(s1 == s2, isTrue);
      expect(s1.hashCode, s2.hashCode);
      expect(f1 == f2, isTrue);
      expect(f1.hashCode, f2.hashCode);
      expect(success == otherSuccess, isTrue);
      expect(failure == otherFailure, isTrue);
      expect(s1 == AppSuccess<int>(2), isFalse);
      expect(f1 == AppFailure<int>('x'), isFalse);
      // 泛型类型不同视为不同（值相等语义，编译期类型约束）
      expect(AppSuccess<int>(1) == AppSuccess<num>(1), isFalse);
    });

    test('toString 输出', () {
      expect(const AppSuccess<int>(1).toString(), 'AppSuccess(value: 1)');
      expect(const AppFailure<int>('x').toString(), 'AppFailure(message: x)');
    });

    test('泛型类型保留', () {
      const str = AppSuccess<String>('abc');
      expect(str.value, 'abc');
      // 编译期类型约束：value 是 String 类型
      final String s = str.value;
      expect(s, 'abc');
    });
  });
}
