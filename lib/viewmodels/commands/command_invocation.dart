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
/// - `toString()` 输出近 CLI 文本：含空白/引号/反斜杠/空串/前导横线的参数与选项值
///   会用双引号包裹（转义顺序：反斜杠 → 双引号），可被 `command_parser` 往返解析；
///   `options` 按键字典序输出，确定性。
/// - `name` 必须为单 token（不允许多词/前后空白），多词指令名用点分/连字符形式
///   （如 `category_create`）。
class CommandInvocation {
  CommandInvocation({
    required String name,
    List<String> args = const [],
    Map<String, String> options = const {},
    this.raw,
  })  : name = _validateName(name),
        args = List.unmodifiable(args),
        options = Map.unmodifiable(options) {
    for (final key in options.keys) {
      if (!_validOptionKeyPattern.hasMatch(key) || key.startsWith('-')) {
        throw ArgumentError.value(
          key,
          'options',
          '选项键非法（含空白/等号/引号/反斜杠或以 - 开头），将产生不可解析的 CLI 文本：$key',
        );
      }
    }
  }

  /// 归一化后的指令名（如 `switch`、`category_create`）。
  final String name;

  /// 位置参数（如 `switch 学习` → `['学习']`）。
  final List<String> args;

  /// 命名选项（如 `--start=15:00 --end=16:00` → `{'start': '15:00', ...}'）。
  final Map<String, String> options;

  /// 原始输入文本（供日志/追溯，可为空）。
  final String? raw;

  /// name 硬校验（release 下同样生效）：trim 后非空、无内部/前后空白、不含引号/
  /// 反斜杠、不以 `-` 开头（避免被解析器误判为选项）——保证 toString 输出的
  /// 指令名始终是干净的单 token。
  static String _validateName(String name) {
    final trimmed = name.trim();
    if (name != trimmed ||
        trimmed.isEmpty ||
        trimmed.contains(RegExp(r'\s')) ||
        trimmed.contains(RegExp(r'"|\\')) ||
        trimmed.startsWith('-')) {
      throw ArgumentError.value(
        name,
        'name',
        '指令名必须为单 token（无空白/引号/反斜杠，不以 - 开头，多词请用点分/连字符形式）',
      );
    }
    return trimmed;
  }

  /// 合法选项键：非空、仅 [0-9A-Za-z_.-]（不含空白/等号/引号/反斜杠）。
  static final _validOptionKeyPattern = RegExp(r'^[0-9A-Za-z_.-]+$');

  /// 需要加引号包裹的字符（空白/双引号/反斜杠）。
  static final _needsQuotePattern = RegExp(r'\s|"|\\');

  @override
  String toString() {
    // name 已由 _validateName 保证为干净单 token，此处双保险走引号包裹。
    final buffer = StringBuffer(_quoteIfNeeded(name));
    for (final arg in args) {
      buffer.write(' ${_quoteIfNeeded(arg)}');
    }
    final optionKeys = options.keys.toList()..sort();
    for (final key in optionKeys) {
      buffer.write(' --$key=${_quoteIfNeeded(options[key]!)}');
    }
    return buffer.toString();
  }

  /// 含空白/引号/反斜杠/空串/前导横线的值为保证可往返解析，用双引号包裹；
  /// 转义顺序：反斜杠 → 双引号 → 控制字符（\n → \\n、\t → \\t、\r → \\r），
  /// 保证无损还原（解析器按转义规则反转义）。
  static String _quoteIfNeeded(String value) {
    final needsQuote = value.isEmpty ||
        value.startsWith('-') ||
        value.contains(_needsQuotePattern);
    if (!needsQuote) return value;
    return '"${value
        .replaceAll('\\', r'\\')
        .replaceAll('"', r'\"')
        .replaceAll('\n', r'\n')
        .replaceAll('\t', r'\t')
        .replaceAll('\r', r'\r')}"';
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
    return Object.hashAllUnordered(
      map.entries.map((entry) => Object.hash(entry.key, entry.value)),
    );
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
///
/// 注意：
/// - `data` 为 List/Map 等集合类型时，[operator ==] 采用 Dart 默认引用相等
///   （值相等仅对不可变标量/值类型有意义）。
/// - `toString` **不输出 data 内容**（只输出类型/状态与 message）——data 可能承载
///   token/路径等敏感信息，直接进日志会泄露；需要展示 data 时请显式读取字段。
class CommandSuccess<T> extends CommandResult {
  const CommandSuccess({this.data, this.message});

  final T? data;
  final String? message;

  @override
  String toString() => '$runtimeType(message: $message)';

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
