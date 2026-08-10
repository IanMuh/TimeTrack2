/// 指令定义类型（纯类型，零 Flutter 依赖）。
///
/// 声明式指令定义：`constants/commands/command_definitions.dart` 提供具体定义数据，
/// `utils/command_parser.dart` 解析器消费本类型做未知指令/缺参/别名校验，
/// `stores/command_store.dart` 分发器按 name 路由（计划：扩展 = 注册指令，不改核心代码）。
library;

/// 指令定义：声明指令的形态约束，供解析器校验与归一化。
class CommandDefinition {
  CommandDefinition({
    required this.name,
    this.aliases = const [],
    this.minPositionalArgs = 0,
    this.maxPositionalArgs = 0,
    this.allowedOptions = const {},
    this.requiredOptions = const {},
    this.timeOptions = const {},
    this.description = '',
  })  : assert(minPositionalArgs >= 0),
        assert(maxPositionalArgs >= minPositionalArgs),
        assert(_isSingleToken(name), 'name 必须为单 token（无空白/引号/反斜杠，不以 - 开头）'),
        assert(
          aliases.every(_isSingleToken),
          'aliases 必须均为单 token（无空白/引号/反斜杠，不以 - 开头）',
        ) {
    // 单 token 运行时硬校验（release 下 assert 被剥离，此处兜底）：
    // 解析器按空白分词，非单 token 触发名永远不可达——配置错误早失败。
    if (!_isSingleToken(name)) {
      throw ArgumentError.value(name, 'name', '指令名必须为单 token');
    }
    for (final alias in aliases) {
      if (!_isSingleToken(alias)) {
        throw ArgumentError.value(alias, 'aliases', '别名必须为单 token');
      }
    }
  }

  /// 单 token 校验（const 构造可用）：非空、无空白/引号/反斜杠、不以 `-` 开头。
  static bool _isSingleToken(String value) {
    return value.isNotEmpty &&
        !value.contains(RegExp(r'\s|"|\\')) &&
        !value.startsWith('-');
  }

  /// 归一化后的指令名（单 token，如 `switch`、`category_create`）。
  final String name;

  /// 别名（中英混合支持，如 `切换`、`开始`）；别名也必须是单 token。
  final List<String> aliases;

  /// 位置参数个数约束（min/max，含边界）。
  final int minPositionalArgs;
  final int maxPositionalArgs;

  /// 允许的选项键集合（`--start` 的键为 `start`）。
  final Set<String> allowedOptions;

  /// 必填选项键集合（缺任一即报错）。
  final Set<String> requiredOptions;

  /// 时间类选项键集合：解析器会将值归一化为 `HH:MM`（24h）标准形式。
  final Set<String> timeOptions;

  /// 指令说明（供诊断/日志）。
  final String description;

  /// 全部可触发的名称（name + aliases）。
  List<String> get triggerNames => [name, ...aliases];
}
