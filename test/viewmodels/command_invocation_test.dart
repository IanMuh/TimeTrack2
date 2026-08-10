import 'package:flutter_test/flutter_test.dart';
import 'package:timetrack2/viewmodels/commands/command_invocation.dart';

void main() {
  group('CommandInvocation', () {
    test('toString：options 按键排序，输出确定性', () {
      final invocation = CommandInvocation(
        name: 'add',
        args: ['开会'],
        options: {'note': '周会', 'end': '16:00', 'start': '15:00'},
      );
      // 传入顺序 note→end→start，输出按 key 字典序 end→note→start
      expect(
        invocation.toString(),
        'add 开会 --end=16:00 --note=周会 --start=15:00',
      );
    });

    test('toString：含空白/引号/反斜杠的值用双引号包裹并转义（供往返解析）', () {
      // 常规：空白 + 引号
      final invocation = CommandInvocation(
        name: 'switch',
        args: ['学 习'],
        options: {'note': '周 会 "正式"'},
      );
      expect(
        invocation.toString(),
        'switch "学 习" --note="周 会 \\"正式\\""',
      );
      // 反斜杠 + 引号混合：先转义反斜杠再转义引号（标准做法，可无损还原）
      final backslash = CommandInvocation(
        name: 'switch',
        args: [r'a\"b'],
        options: {'note': r'C:\dir\"x"'},
      );
      expect(
        backslash.toString(),
        r'switch "a\\\"b" --note="C:\\dir\\\"x\""',
      );
      // 空串与前导横线（会被分词丢弃/误判为选项）强制加引号
      final dash = CommandInvocation(
        name: 'add',
        args: ['', '-', '--x'],
        options: {'note': ''},
      );
      expect(
        dash.toString(),
        'add "" "-" "--x" --note=""',
      );
    });

    test('无参数指令 toString', () {
      final invocation = CommandInvocation(name: 'stop');
      expect(invocation.toString(), 'stop');
    });

    test('args/options 不可变：外部集合修改不影响实例，且全部变异操作抛错', () {
      final args = ['学习'];
      final options = <String, String>{'start': '15:00'};
      final invocation = CommandInvocation(
        name: 'switch',
        args: args,
        options: options,
      );
      args.add('被追加');
      options['end'] = '16:00';
      expect(invocation.args, ['学习']);
      expect(invocation.options, {'start': '15:00'});
      // 常见变异操作均应抛 UnsupportedError（防篡改/确定性契约）
      expect(() => invocation.args.add('x'), throwsUnsupportedError);
      expect(() => invocation.args.clear(), throwsUnsupportedError);
      expect(() => invocation.args.remove('学习'), throwsUnsupportedError);
      expect(() => invocation.args.removeAt(0), throwsUnsupportedError);
      expect(() => invocation.args.removeWhere((_) => true),
          throwsUnsupportedError);
      expect(() => invocation.options['x'] = 'y', throwsUnsupportedError);
      expect(() => invocation.options.clear(), throwsUnsupportedError);
      expect(() => invocation.options.remove('start'), throwsUnsupportedError);
      expect(() => invocation.options.removeWhere((_, _) => true),
          throwsUnsupportedError);
    });

    test('构造校验：非法 name / 选项键直接拒绝', () {
      // name 含空白 → ArgumentError（硬校验，release 下同样生效）
      expect(
        () => CommandInvocation(name: 'category create'),
        throwsArgumentError,
      );
      expect(
        () => CommandInvocation(name: '  '),
        throwsArgumentError,
      );
      // 非法选项键 → ArgumentError（含空白/= /以 - 开头 / 空键）
      expect(
        () => CommandInvocation(name: 'add', options: {'bad key': 'v'}),
        throwsArgumentError,
      );
      expect(
        () => CommandInvocation(name: 'add', options: {'a=b': 'v'}),
        throwsArgumentError,
      );
      expect(
        () => CommandInvocation(name: 'add', options: {'-x': 'v'}),
        throwsArgumentError,
      );
      expect(
        () => CommandInvocation(name: 'add', options: {'': 'v'}),
        throwsArgumentError,
      );
      // 合法构造不抛
      expect(
        () => CommandInvocation(name: 'category_create', options: {'note': 'v'}),
        returnsNormally,
      );
    });

    test('值相等语义：name/args/options 全同视为相等（raw 不参与）', () {
      final a = CommandInvocation(
        name: 'add',
        args: ['开会'],
        options: {'start': '15:00', 'end': '16:00'},
        raw: 'add 开会 --start=15:00 --end=16:00',
      );
      final b = CommandInvocation(
        name: 'add',
        args: ['开会'],
        options: {'end': '16:00', 'start': '15:00'},
        raw: '不同 raw',
      );
      expect(a == b, isTrue, reason: '选项键序无关，raw 不参与相等性');
      expect(a.hashCode, b.hashCode);
      expect(a == CommandInvocation(name: 'add', args: ['开会'],
              options: {'start': '15:00'}), isFalse,
          reason: '选项集不同');
      expect(a == CommandInvocation(name: 'stop'), isFalse);
      // 仅 args 不同
      expect(a == CommandInvocation(name: 'add', args: ['讨论'],
              options: {'start': '15:00', 'end': '16:00'}), isFalse);
      // args 顺序不同（顺序敏感）
      expect(CommandInvocation(name: 'x', args: ['a', 'b']) ==
          CommandInvocation(name: 'x', args: ['b', 'a']), isFalse);
      // options 同 key 不同 value
      expect(CommandInvocation(name: 'x', options: {'start': '15:00'}) ==
          CommandInvocation(name: 'x', options: {'start': '16:00'}), isFalse);
    });
  });

  group('CommandResult', () {
    test('fold 直传原实例（身份不变）+ 泛型 data 保留类型', () {
      final success = CommandSuccess<int>(data: 42, message: 'ok');
      final failure = CommandFailure('时间解析失败');
      expect(
        success.fold(
          onSuccess: (s) {
            expect(identical(s, success), isTrue, reason: '必须直传原实例');
            return 'S:${s.data! + 1}:${s.message}';
          },
          onFailure: (f) => 'F:${f.reason}',
        ),
        'S:43:ok',
      );
      expect(
        failure.fold(
          onSuccess: (s) => 'S:${s.message}',
          onFailure: (f) {
            expect(identical(f, failure), isTrue, reason: '必须直传原实例');
            return 'F:${f.reason}';
          },
        ),
        'F:时间解析失败',
      );
    });

    test('值相等语义（非 const 实例驱动 ==/hashCode 逻辑）', () {
      // 非 const：避免常量规范化使 identical 短路，真正验证值相等实现
      final failureA = CommandFailure('a');
      final failureB = CommandFailure('a');
      expect(failureA == failureB, isTrue);
      expect(failureA.hashCode, failureB.hashCode);
      expect(failureA == CommandFailure('b'), isFalse);
      final successA = CommandSuccess<int>(data: 1);
      final successB = CommandSuccess<int>(data: 1);
      expect(successA == successB, isTrue);
      expect(successA.hashCode, successB.hashCode);
      expect(successA == CommandSuccess<int>(data: 2), isFalse);
      // 不同泛型参数的实例视为不同（runtimeType 区分）
      expect(successA == CommandSuccess<num>(data: 1), isFalse);
    });
  });
}
