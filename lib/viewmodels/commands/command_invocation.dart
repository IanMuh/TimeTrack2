/// 指令系统类型（纯类型，零 Flutter 依赖）。
library;

/// 一次归一化后的指令调用（CLI 风格指令系统的输入形态）。
///
/// 由 `utils/command_parser.dart` 解析产生；UI 按钮 / 快捷键 / 深链 / 未来 AI
/// 全部收敛到同一分发通道（计划：全部操作经 CLI 指令系统统一分发）。
///
/// `args` / `options` 以不可变视图保存，防止构造后被外部修改（防篡改/确定性）。
class CommandInvocation {
  CommandInvocation({
    required this.name,
    List<String> args = const [],
    Map<String, String> options = const {},
    this.raw,
  })  : args = List.unmodifiable(args),
        options = Map.unmodifiable(options);

  /// 归一化后的指令名（如 `switch`、`category create`）。
  final String name;

  /// 位置参数（如 `switch 学习` → `['学习']`）。
  final List<String> args;

  /// 命名选项（如 `--start=15:00 --end=16:00` → `{'start': '15:00', ...}'）。
  final Map<String, String> options;

  /// 原始输入文本（供日志/追溯，可为空）。
  final String? raw;

  @override
  String toString() {
    final buffer = StringBuffer(name);
    for (final arg in args) {
      buffer.write(' $arg');
    }
    final optionKeys = options.keys.toList()..sort();
    for (final key in optionKeys) {
      buffer.write(' --$key=${options[key]}');
    }
    return buffer.toString();
  }
}

/// 指令执行结果。
///
/// 失败必须带明确原因（解析器边界：时间解析失败、重名歧义、缺参等
/// 都要有可读的失败原因，供调用方展示/日志）。
sealed class CommandResult {
  const CommandResult();

  R fold<R>({
    required R Function(CommandSuccess success) onSuccess,
    required R Function(CommandFailure failure) onFailure,
  }) {
    return switch (this) {
      final CommandSuccess success => onSuccess(success),
      final CommandFailure failure => onFailure(failure),
    };
  }
}

/// 执行成功；[data] 为可选返回数据，[message] 为可选描述（供日志/提示）。
class CommandSuccess extends CommandResult {
  const CommandSuccess({this.data, this.message});

  final Object? data;
  final String? message;

  @override
  String toString() => 'CommandSuccess(message: $message)';
}

/// 执行失败；[reason] 必须为明确、可读的失败原因。
class CommandFailure extends CommandResult {
  const CommandFailure(this.reason);

  final String reason;

  @override
  String toString() => 'CommandFailure(reason: $reason)';
}
