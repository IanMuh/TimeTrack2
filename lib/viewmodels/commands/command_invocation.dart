/// 指令系统类型（纯类型，零 Flutter 依赖）。
library;

/// 一次归一化后的指令调用（CLI 风格指令系统的输入形态）。
///
/// 由 `utils/command_parser.dart` 解析产生；UI 按钮 / 快捷键 / 深链 / 未来 AI
/// 全部收敛到同一分发通道（计划：全部操作经 CLI 指令系统统一分发）。
///
/// 约定：
/// - `args` / `options` 以不可变视图保存，防止构造后被外部修改（防篡改/确定性）。
/// - 解析器**禁止重复选项**（同名 `--key` 出现多次视为解析错误），故 `options` 用
///   单值 Map 即可表达；文档契约由此收敛。
/// - `toString()` 输出近 CLI 文本：含空白/引号的参数与选项值会用双引号包裹（内部
///   双引号转义），可被 `command_parser` 往返解析；`options` 按键字典序输出，确定性。
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
      buffer.write(' ${_quoteIfNeeded(arg)}');
    }
    final optionKeys = options.keys.toList()..sort();
    for (final key in optionKeys) {
      buffer.write(' --$key=${_quoteIfNeeded(options[key]!)}');
    }
    return buffer.toString();
  }

  /// 含空白或引号的值为保证可往返解析，用双引号包裹并转义内部双引号。
  static String _quoteIfNeeded(String value) {
    final needsQuote = value.contains(RegExp(r'\s|"'));
    if (!needsQuote) return value;
    return '"${value.replaceAll('"', r'\"')}"';
  }

  /// 值相等语义：比较 name/args/options（raw 仅作追溯，不参与相等性）。
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is CommandInvocation &&
          runtimeType == other.runtimeType &&
          name == other.name &&
          _listEquals(args, other.args) &&
          _mapEquals(options, other.options);

  @override
  int get hashCode => Object.hash(name, Object.hashAll(args), _hashMap(options));

  static bool _listEquals(List<String> first, List<String> second) {
    if (first.length != second.length) return false;
    for (var i = 0; i < first.length; i++) {
      if (first[i] != second[i]) return false;
    }
    return true;
  }

  static bool _mapEquals(
    Map<String, String> first,
    Map<String, String> second,
  ) {
    if (first.length != second.length) return false;
    for (final entry in first.entries) {
      if (second[entry.key] != entry.value) return false;
    }
    return true;
  }

  static int _hashMap(Map<String, String> map) {
    var hash = 0;
    for (final entry in map.entries) {
      hash = hash ^ Object.hash(entry.key, entry.value);
    }
    return hash;
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

/// 执行成功；[data] 为可选返回数据（类型化），[message] 为可选描述（供日志/提示）。
class CommandSuccess<T> extends CommandResult {
  const CommandSuccess({this.data, this.message});

  final T? data;
  final String? message;

  @override
  String toString() =>
      'CommandSuccess(data: $data, message: $message)';

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is CommandSuccess &&
          runtimeType == other.runtimeType &&
          data == other.data &&
          message == other.message;

  @override
  int get hashCode => Object.hash(data, message);
}

/// 执行失败；[reason] 必须为明确、可读的失败原因。
class CommandFailure extends CommandResult {
  const CommandFailure(this.reason);

  final String reason;

  @override
  String toString() => 'CommandFailure(reason: $reason)';

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is CommandFailure && runtimeType == other.runtimeType &&
          reason == other.reason;

  @override
  int get hashCode => Object.hash(runtimeType, reason);
}
