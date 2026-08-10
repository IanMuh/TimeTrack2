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

    test('无参数指令 toString', () {
      final invocation = CommandInvocation(name: 'stop');
      expect(invocation.toString(), 'stop');
    });

    test('args/options 不可变：外部集合修改不影响实例', () {
      final args = ['学习'];
      final options = <String, String>{'start': '15:00'};
      final invocation = CommandInvocation(name: 'switch', args: args, options: options);
      args.add('被追加');
      options['end'] = '16:00';
      expect(invocation.args, ['学习']);
      expect(invocation.options, {'start': '15:00'});
      // 直接对不可变视图修改应抛错
      expect(() => invocation.args.add('x'), throwsUnsupportedError);
      expect(() => invocation.options['x'] = 'y', throwsUnsupportedError);
    });
  });

  group('CommandResult', () {
    test('fold 分发成功/失败', () {
      const success = CommandSuccess(message: 'ok');
      const failure = CommandFailure('时间解析失败');
      expect(
        success.fold(
          onSuccess: (s) => 'S:${s.message}',
          onFailure: (f) => 'F:${f.reason}',
        ),
        'S:ok',
      );
      expect(
        failure.fold(
          onSuccess: (s) => 'S:${s.message}',
          onFailure: (f) => 'F:${f.reason}',
        ),
        'F:时间解析失败',
      );
    });
  });
}
