import '../utils/result.dart';
import '../utils/date_time_ext.dart';
import '../viewmodels/commands/command_definition.dart';
import '../viewmodels/commands/command_invocation.dart';

/// CLI 风格指令解析器：把指令文本解析为归一化的 [CommandInvocation]。
///
/// 职责边界（计划：UI/快捷键/深链/AI 全部收敛到同一分发通道）：
/// - **词法**：tokenize（按空白切分、引号内空白保留、未闭合引号报错）
/// - **解引号**：位置参数整 token 引号包裹、选项值段引号包裹，统一反转义
/// - **结构校验**：未知指令、别名归一化、位置参数数量、必填/未知/重复选项
/// - **时间归一化**：时间类选项（定义于 [CommandDefinition.timeOptions]）经
///   [parseTimeOfDay] 归一化为 `HH:MM`（24h）标准形式，失败报明确原因
///
/// 与 [CommandInvocation.toString] 的转义规则互为逆：含空白/引号/反斜杠/控制字符
/// 的值加引号包裹并转义（`\`→`\\`、`"`→`\"`、`\n`→`\n`、`\t`→`\t`、`\r`→`\r`），
/// 本解析器解引号时按相同规则反转义，保证往返无损。
///
/// 往返契约细节：
/// - 选项值可为"部分引号"（`--note="周 会"`，值段引号包裹）或裸值（`--note=abc`）；
/// - 空选项值必须显式加引号（`--note=""`），裸 `--note=` 被拒绝（无法区分）；
/// - 以 `-` 开头的**位置参数**经 toString 会整 token 加引号（`"--foo"`），
///   整 token 引号包裹的内容不按选项解析；
/// - 未闭合引号直接返回语法错误。
///
/// 注意：活动名重名歧义（如 `switch 学习` 命中多个同名活动）需要活动数据，
/// 属于**语义层**（分发器）职责——解析器只做语法结构校验，歧义检测由分发器
/// 注入活动名列表完成（见 [CommandParser.resolveActivity] 钩子，可选）。
class CommandParser {
  CommandParser({List<CommandDefinition> definitions = const []})
      : _definitions = List.unmodifiable(definitions) {
    // 配置错误早失败：触发名去重 + 定义自身一致性（requiredOptions/timeOptions ⊆
    // allowedOptions、位置参数范围合法——后者在 release 下构造器 assert 被剥离）。
    final seen = <String>{};
    for (final definition in _definitions) {
      for (final trigger in definition.triggerNames) {
        if (!seen.add(trigger)) {
          throw ArgumentError(
            '指令触发名重复：$trigger（定义 ${definition.name} 与已有指令冲突）',
          );
        }
      }
      if (definition.minPositionalArgs < 0 ||
          definition.maxPositionalArgs < definition.minPositionalArgs) {
        throw ArgumentError(
          '指令 ${definition.name} 位置参数范围非法：'
          'min=${definition.minPositionalArgs} max=${definition.maxPositionalArgs}',
        );
      }
      for (final option in {
        ...definition.requiredOptions,
        ...definition.timeOptions,
      }) {
        if (!definition.allowedOptions.contains(option)) {
          throw ArgumentError(
            '指令 ${definition.name} 的选项 $option 未在 allowedOptions 中声明'
            '（requiredOptions/timeOptions 必须 ⊆ allowedOptions）',
          );
        }
      }
    }
  }

  final List<CommandDefinition> _definitions;

  /// 已注册指令定义（供诊断/分发器枚举）。
  List<CommandDefinition> get definitions => _definitions;

  /// 解析指令文本。
  ///
  /// 成功返回归一化后的 [CommandInvocation]；失败返回 [AppFailure] 并携带
  /// 明确的可读原因（未知指令/缺参/重复选项/未闭合引号/时间解析失败等）。
  AppResult<CommandInvocation> parse(String input) {
    final tokens = _tokenize(input);
    if (tokens == null) {
      return const AppFailure('引号未闭合：指令存在未闭合的双引号');
    }
    if (tokens.isEmpty) {
      return const AppFailure('指令为空');
    }

    final first = _unquoteToken(tokens.first);
    final definition = _resolveDefinition(first);
    if (definition == null) {
      return AppFailure(
          '未知指令：$first（可用指令：${_availableNames()}）');
    }

    final positional = <String>[];
    final options = <String, String>{};
    for (final raw in tokens.skip(1)) {
      // 仅未加引号的 `--` 前缀 token 按选项解析；
      // 整 token 引号包裹（`"--foo"`）是位置参数（与 toString 往返一致）。
      if (raw.startsWith('--') && !raw.startsWith('"')) {
        final equals = raw.indexOf('=');
        if (equals <= 2) {
          return AppFailure('选项格式非法：$raw（应为 --key=value）');
        }
        final key = raw.substring(2, equals);
        final valueRaw = raw.substring(equals + 1);
        if (key.isEmpty) {
          return AppFailure('选项格式非法：$raw（键不能为空）');
        }
        final value = _unquoteValue(valueRaw);
        if (value.isEmpty && !_isQuoted(valueRaw)) {
          // 裸 `--key=` 空值无法与 `--key=""` 区分（引号信息只在 valueRaw 形态），
          // 拒绝；显式空值须加引号。
          return AppFailure('选项格式非法：$raw（空值请用 --key="" 形式）');
        }
        if (!definition.allowedOptions.contains(key)) {
          return AppFailure(
            '指令 ${definition.name} 不支持的选项：--$key'
            '（允许：${definition.allowedOptions.join(', ')}）',
          );
        }
        if (options.containsKey(key)) {
          return AppFailure('选项重复出现：--$key（同一选项只能出现一次）');
        }
        options[key] = value;
      } else {
        positional.add(_unquoteToken(raw));
      }
    }

    // 位置参数数量校验（含边界）。
    if (positional.length < definition.minPositionalArgs ||
        positional.length > definition.maxPositionalArgs) {
      final expected = definition.minPositionalArgs ==
              definition.maxPositionalArgs
          ? '${definition.minPositionalArgs} 个'
          : '${definition.minPositionalArgs}-${definition.maxPositionalArgs} 个';
      return AppFailure(
        '指令 ${definition.name} 需要 $expected位置参数，实际 ${positional.length} 个',
      );
    }

    // 必填选项校验。
    for (final required in definition.requiredOptions) {
      if (!options.containsKey(required)) {
        return AppFailure('指令 ${definition.name} 缺少必填选项：--$required');
      }
    }

    // 时间选项归一化（`下午3点` → `15:00`）。
    for (final timeOption in definition.timeOptions) {
      final value = options[timeOption];
      if (value == null) continue;
      final minutes = parseTimeOfDay(value);
      if (minutes == null) {
        return AppFailure(
          '选项 --$timeOption 的时间无法解析：$value（支持 15:00 / 下午3点 / 3pm 等）',
        );
      }
      options[timeOption] = _formatMinutes(minutes);
    }

    return AppSuccess(
      CommandInvocation(
        name: definition.name,
        args: positional,
        options: options,
        raw: input,
      ),
    );
  }

  /// 指令名校验钩子（可选）：把位置参数中的活动名/分类名映射到稳定 id。
  ///
  /// 实现可注入重名歧义检测（命中多个候选返回失败，不静默取第一个）。
  /// 默认返回 null（不校验），由分发器自行决定。
  String? Function(String name)? resolveActivity;

  /// 按触发名（name + aliases）查找定义；null 表示未知指令。
  CommandDefinition? _resolveDefinition(String trigger) {
    for (final definition in _definitions) {
      if (definition.triggerNames.contains(trigger)) return definition;
    }
    return null;
  }

  String _availableNames() {
    return _definitions.map((d) => d.name).join(', ');
  }

  /// 分钟数 → `HH:MM`（24h，补零）。
  static String _formatMinutes(int minutes) {
    final hour = minutes ~/ 60;
    final minute = minutes % 60;
    return '${hour.toString().padLeft(2, '0')}:${minute.toString().padLeft(2, '0')}';
  }
}

/// 判断原始值段是否被双引号完整包裹（`"..."`）。
bool _isQuoted(String raw) {
  return raw.length >= 2 && raw.startsWith('"') && raw.endsWith('"');
}

/// 解引号位置参数/指令名：整 token 被双引号包裹时剥引号并反转义；否则原样。
String _unquoteToken(String raw) {
  return _isQuoted(raw) ? _unescape(raw.substring(1, raw.length - 1)) : raw;
}

/// 解引号选项值段：值段被双引号包裹时剥引号并反转义；否则原样（引号外无反义）。
String _unquoteValue(String raw) {
  return _unquoteToken(raw);
}

/// 反转义引号内序列（与 [CommandInvocation] 的转义规则互逆）：
/// `\\`→`\`、`\"`→`"`、`\n`→换行、`\t`→tab、`\r`→CR；其余 `\x` 还原为 `x`。
String _unescape(String input) {
  final buffer = StringBuffer();
  for (var i = 0; i < input.length; i++) {
    final char = input[i];
    if (char == r'\' && i + 1 < input.length) {
      final next = input[i + 1];
      buffer.write(
        switch (next) {
          'n' => '\n',
          't' => '\t',
          'r' => '\r',
          _ => next,
        },
      );
      i++;
    } else {
      buffer.write(char);
    }
  }
  return buffer.toString();
}

/// tokenize：按空白切分 token，**保留原始文本（含引号与转义序列）**。
///
/// 规则：
/// - 空白（空格/tab/换行/回车）分隔 token；双引号内空白保留
/// - 未闭合引号（输入结束仍 inQuotes）→ 返回 null（语法错误）
/// - 不剥引号、不反转义——解引号统一在 [CommandParser.parse] 内完成
///   （位置参数整 token 引号 vs 选项值段引号形态不同）
List<String>? _tokenize(String input) {
  final tokens = <String>[];
  final buffer = StringBuffer();
  var inQuotes = false;
  var hasToken = false;

  void flush() {
    if (hasToken) {
      tokens.add(buffer.toString());
      buffer.clear();
      hasToken = false;
    }
  }

  for (var i = 0; i < input.length; i++) {
    final char = input[i];
    if (inQuotes) {
      if (char == r'\' && i + 1 < input.length) {
        // 引号内转义序列整体保留（`\` + 下一字符），供解引号时反转义。
        buffer.write(char);
        buffer.write(input[i + 1]);
        i++;
      } else if (char == '"') {
        inQuotes = false;
        buffer.write(char); // 引号保留
      } else {
        buffer.write(char);
      }
      hasToken = true;
    } else if (char == '"') {
      inQuotes = true;
      buffer.write(char);
      hasToken = true;
    } else if (char == ' ' || char == '\t' || char == '\n' || char == '\r') {
      flush();
    } else {
      buffer.write(char);
      hasToken = true;
    }
  }
  if (inQuotes) {
    return null; // 未闭合引号：语法错误。
  }
  flush();
  return tokens;
}
