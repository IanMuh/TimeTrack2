import 'package:flutter_test/flutter_test.dart';
import 'package:timetrack2/utils/command_parser.dart';
import 'package:timetrack2/utils/result.dart';
import 'package:timetrack2/viewmodels/commands/command_definition.dart';
import 'package:timetrack2/viewmodels/commands/command_invocation.dart';

/// 模块 2 测试用指令定义（模块 3 提供正式定义；此处覆盖解析器全部路径）。
final _definitions = <CommandDefinition>[
  CommandDefinition(
    name: 'switch',
    aliases: ['切换', '开始'],
    minPositionalArgs: 1,
    maxPositionalArgs: 1,
    description: '切换到指定活动',
  ),
  CommandDefinition(
    name: 'stop',
    aliases: ['停止'],
    description: '停止当前活动',
  ),
  CommandDefinition(
    name: 'add',
    aliases: ['补记'],
    minPositionalArgs: 1,
    maxPositionalArgs: 1,
    allowedOptions: {'start', 'end', 'note'},
    timeOptions: {'start', 'end'},
    description: '补记时间段',
  ),
  CommandDefinition(
    name: 'category_create',
    aliases: ['新建分类'],
    minPositionalArgs: 1,
    maxPositionalArgs: 1,
    allowedOptions: {'parent', 'color'},
    description: '新建分类',
  ),
];

CommandParser _parser() => CommandParser(definitions: _definitions);

/// 从失败结果取可读消息（避免重复 when 样板）。
String failureMessage(AppResult<CommandInvocation> result) {
  return result.when(onSuccess: (_) => '', onFailure: (m) => m);
}

void main() {
  group('tokenize 与往返解析', () {
    test('基础分词', () {
      final result = _parser().parse('switch 学习');
      expect(result.isSuccess, isTrue);
      final invocation = result.valueOrNull!;
      expect(invocation.name, 'switch');
      expect(invocation.args, ['学习']);
    });

    test('选项 --key=value', () {
      final result = _parser().parse('add 开会 --start=15:00 --end=16:00 --note=周会');
      expect(result.isSuccess, isTrue);
      final invocation = result.valueOrNull!;
      expect(invocation.options, {'start': '15:00', 'end': '16:00', 'note': '周会'});
    });

    test('含空白/引号/反斜杠值往返无损（与 CommandInvocation.toString 互逆）', () {
      final parser = _parser();
      // 含空白值需加引号
      final withSpaceResult = parser.parse('switch "学 习"');
      expect(withSpaceResult.isSuccess, isTrue);
      expect(withSpaceResult.valueOrNull!.args, ['学 习']);
      // 含引号+反斜杠值（CLI 文本中反斜杠需写为 \\ 转义）
      final tricky = parser.parse(r'add "开 会" --note="周 会 \"正式\" C:\\dir"');
      expect(tricky.isSuccess, isTrue, reason: '引号+反斜杠应可解析');
      expect(tricky.valueOrNull!.options['note'], '周 会 "正式" C:\\dir');
      // toString 往返：parse(toString(x)) == x
      final original = CommandInvocation(
        name: 'add',
        args: ['开 会'],
        options: {'note': 'a"b\\c\nd\te'},
      );
      final roundTrip = parser.parse(original.toString());
      expect(roundTrip.isSuccess, isTrue);
      expect(roundTrip.valueOrNull, original);
    });

    test('控制字符转义往返', () {
      final parser = _parser();
      final original = CommandInvocation(
        name: 'add',
        args: ['x'],
        options: {'note': 'line1\nline2\ttab\rret'},
      );
      final roundTrip = parser.parse(original.toString());
      expect(roundTrip.isSuccess, isTrue);
      expect(roundTrip.valueOrNull!.options['note'], 'line1\nline2\ttab\rret');
    });

    test('空选项值往返：--note="" 显式空值', () {
      final parser = _parser();
      final original = CommandInvocation(
        name: 'add',
        args: ['x'],
        options: {'note': ''},
      );
      expect(original.toString(), 'add x --note=""');
      final roundTrip = parser.parse(original.toString());
      expect(roundTrip.isSuccess, isTrue, reason: '显式空值应可往返');
      expect(roundTrip.valueOrNull!.options['note'], '');
    });

    test('前导横线位置参数往返：--foo 加引号后按参数解析', () {
      final parser = _parser();
      final original = CommandInvocation(name: 'switch', args: ['--foo']);
      expect(original.toString(), 'switch "--foo"');
      final roundTrip = parser.parse(original.toString());
      expect(roundTrip.isSuccess, isTrue);
      expect(roundTrip.valueOrNull!.args, ['--foo']);
    });

    test('未闭合引号 → 语法错误', () {
      final result = _parser().parse('switch "学 习');
      expect(result.isSuccess, isFalse);
      expect(failureMessage(result), contains('引号未闭合'));
    });
  });

  group('结构校验', () {
    test('空输入', () {
      final result = _parser().parse('   ');
      expect(result.isSuccess, isFalse);
      expect(failureMessage(result),
          contains('空'));
    });

    test('未知指令（含候选提示）', () {
      final result = _parser().parse('fly 学习');
      expect(result.isSuccess, isFalse);
      final message =
          failureMessage(result);
      expect(message, contains('未知指令'));
      expect(message, contains('fly'));
      expect(message, contains('switch'));
    });

    test('别名归一化', () {
      for (final (input, expectedName) in [
        ('切换 学习', 'switch'),
        ('停止', 'stop'),
        ('补记 开会', 'add'),
      ]) {
        final result = _parser().parse(input);
        expect(result.isSuccess, isTrue, reason: '$input 应可解析');
        expect(result.valueOrNull!.name, expectedName);
      }
    });

    test('位置参数数量校验', () {
      // 缺参
      final missing = _parser().parse('switch');
      expect(missing.isSuccess, isFalse);
      expect(
        failureMessage(missing),
        contains('位置参数'),
      );
      // 超参
      final extra = _parser().parse('switch a b');
      expect(extra.isSuccess, isFalse);
      expect(
        failureMessage(extra),
        contains('位置参数'),
      );
    });

    test('未知选项拒绝', () {
      final result = _parser().parse('add 开会 --foo=bar');
      expect(result.isSuccess, isFalse);
      final message =
          failureMessage(result);
      expect(message, contains('不支持的选项'));
      expect(message, contains('--foo'));
    });

    test('必填选项缺失', () {
      // 用自定义 sync 定义验证必填选项缺失路径（category_create 暂无 requiredOptions）
      final withRequired = CommandDefinition(
        name: 'sync',
        requiredOptions: {'target'},
        allowedOptions: {'target'},
      );
      final parser = CommandParser(definitions: [..._definitions, withRequired]);
      final result = parser.parse('sync');
      expect(result.isSuccess, isFalse);
      expect(
        failureMessage(result),
        contains('缺少必填选项'),
      );
    });

    test('重复选项拒绝', () {
      final result = _parser().parse('add 开会 --start=15:00 --start=16:00');
      expect(result.isSuccess, isFalse);
      expect(
        failureMessage(result),
        contains('重复出现'),
      );
    });

    test('选项格式非法（--x / --=v / --key=）', () {
      for (final bad in ['add 开会 --x', 'add 开会 --=v', 'add 开会 --start=']) {
        final result = _parser().parse(bad);
        expect(result.isSuccess, isFalse, reason: '$bad 应被拒绝');
      }
    });
  });

  group('时间选项归一化', () {
    test('中文/英文/HH:MM 统一为 HH:MM 24h', () {
      final cases = {
        '15:00': '15:00',
        '下午3点': '15:00',
        '3pm': '15:00',
        '9am': '09:00',
        '上午9点30分': '09:30',
        // 12 小时制歧义边界（无修饰 12点 = 中午）
        '12pm': '12:00',
        '12am': '00:00',
        '下午12点': '12:00',
        '上午12点': '00:00',
        '晚上12点': '00:00',
        '12点': '12:00',
      };
      for (final entry in cases.entries) {
        final result = _parser().parse('add 开会 --start=${entry.key} --end=16:00');
        expect(result.isSuccess, isTrue, reason: '${entry.key} 应可解析');
        expect(
          result.valueOrNull!.options['start'],
          entry.value,
          reason: '${entry.key} 归一化为 ${entry.value}',
        );
      }
    });

    test('时间解析失败返回明确原因', () {
      final result = _parser().parse('add 开会 --start=abc');
      expect(result.isSuccess, isFalse);
      final message =
          failureMessage(result);
      expect(message, contains('时间无法解析'));
      expect(message, contains('--start'));
      expect(message, contains('abc'));
    });

    test('非时间选项不做归一化', () {
      final result = _parser().parse('add 开会 --note=15:00');
      expect(result.isSuccess, isTrue);
      expect(result.valueOrNull!.options['note'], '15:00');
    });
  });

  group('定义约束', () {
    test('触发名重复 → 构造期报错（配置错误早失败）', () {
      // 别名撞命令名
      expect(
        () => CommandParser(definitions: [
          CommandDefinition(name: 'switch'),
          CommandDefinition(name: 'x', aliases: ['switch']),
        ]),
        throwsArgumentError,
      );
      // 两个命令别名互相重复
      expect(
        () => CommandParser(definitions: [
          CommandDefinition(name: 'a', aliases: ['x']),
          CommandDefinition(name: 'b', aliases: ['x']),
        ]),
        throwsArgumentError,
      );
    });

    test('name/aliases 非单 token → 构造期报错', () {
      expect(
        () => CommandDefinition(name: 'category create'),
        throwsA(anyOf(isA<AssertionError>(), isA<ArgumentError>())),
      );
      expect(
        () => CommandDefinition(name: 'a', aliases: [' 有空格 ']),
        throwsA(anyOf(isA<AssertionError>(), isA<ArgumentError>())),
      );
      expect(
        () => CommandDefinition(name: '-x'),
        throwsA(anyOf(isA<AssertionError>(), isA<ArgumentError>())),
      );
      expect(
        () => CommandDefinition(name: 'a"b'),
        throwsA(anyOf(isA<AssertionError>(), isA<ArgumentError>())),
      );
    });

    test('requiredOptions 未在 allowedOptions 声明 → 构造期报错', () {
      expect(
        () => CommandParser(definitions: [
          CommandDefinition(
            name: 'sync',
            requiredOptions: {'target'},
          ),
        ]),
        throwsArgumentError,
      );
    });

    test('timeOptions 未在 allowedOptions 声明 → 构造期报错', () {
      expect(
        () => CommandParser(definitions: [
          CommandDefinition(
            name: 'add',
            timeOptions: {'start'},
          ),
        ]),
        throwsArgumentError,
      );
    });

    test('位置参数范围非法 → 报错（debug：CommandDefinition 断言；release：解析器构造校验）', () {
      expect(
        () => CommandParser(definitions: [
          CommandDefinition(name: 'x', minPositionalArgs: 3, maxPositionalArgs: 1),
        ]),
        throwsA(anyOf(isA<AssertionError>(), isA<ArgumentError>())),
      );
    });

    test('raw 保留原始输入', () {
      final result = _parser().parse('  switch 学习 ');
      expect(result.valueOrNull!.raw, '  switch 学习 ');
    });
  });
}
