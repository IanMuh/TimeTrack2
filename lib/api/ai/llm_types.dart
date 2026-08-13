/// LLM 领域类型（纯类型，零 Flutter 依赖）。
///
/// 二期 AI 预留：LlmClient 单接口覆盖 DeepSeek/Kimi/通义/Ollama（执行计划
/// 决策 7）——provider 差异通过 [LlmCapability] 编译期标记表达，客户端骨架
/// （OpenAiCompatibleLlmClient）据此校验非法请求组合。
library;

import '../../constants/ai_config.dart';

/// 对话消息角色（OpenAI 兼容消息格式）。
enum LlmRole {
  system('system'),
  user('user'),
  assistant('assistant'),
  tool('tool');

  const LlmRole(this.storageValue);

  final String storageValue;
}

/// 一条对话消息（role + content）。
class LlmMessage {
  const LlmMessage({required this.role, required this.content});

  final LlmRole role;
  final String content;
}

/// 单次请求选项（可选：tools/stream 是"不可并用"组合校验的判定输入）。
class LlmRequestOptions {
  const LlmRequestOptions({
    this.temperature,
    this.maxTokens,
    this.useTools = false,
    this.stream = false,
  });

  /// 采样温度（null = 不传，服务端默认）。
  final double? temperature;

  /// 最大输出 token 数（null = 不传）。
  final int? maxTokens;

  /// 是否请求工具调用能力（function calling / tool use）。
  final bool useTools;

  /// 是否流式输出。
  final bool stream;
}

/// Provider 能力标记（编译期契约）：
/// - `tools` / `stream` **分开标记**——通义 tools 与 stream 不可并用、
///   Ollama（OpenAI 兼容层）缺 response_format 支持等差异在此显式建模；
/// - 客户端在**构造/调用时校验**请求与能力组合（错误早失败，防半途失败）。
class LlmCapability {
  const LlmCapability({
    required this.supportsTools,
    required this.supportsStreaming,
    required this.supportsSystemMessage,
    required this.supportsResponseFormat,
  });

  /// 是否支持工具调用（function calling）。
  final bool supportsTools;

  /// 是否支持流式输出。
  final bool supportsStreaming;

  /// 是否支持 system role 消息（部分 Ollama 模型/本地端点在 system 处理上
  /// 有差异——不支持时客户端应降级为 user 前缀或拒绝）。
  final bool supportsSystemMessage;

  /// 是否支持 `response_format`（json_object 等结构化输出）。
  final bool supportsResponseFormat;

  /// 预置：DeepSeek（OpenAI 兼容，tools/stream 可用且可并用）。
  static const deepseek = LlmCapability(
    supportsTools: true,
    supportsStreaming: true,
    supportsSystemMessage: true,
    supportsResponseFormat: true,
  );

  /// 预置：Kimi（Moonshot，OpenAI 兼容，tools/stream 可用）。
  static const kimi = LlmCapability(
    supportsTools: true,
    supportsStreaming: true,
    supportsSystemMessage: true,
    supportsResponseFormat: true,
  );

  /// 预置：通义千问（DashScope OpenAI 兼容层——**tools 与 stream 不可并用**）。
  static const qwen = LlmCapability(
    supportsTools: true,
    supportsStreaming: true,
    supportsSystemMessage: true,
    supportsResponseFormat: false,
  );

  /// 预置：Ollama（OpenAI 兼容层 `/v1/chat/completions`——缺 response_format，
  /// 部分模型对 system role 支持不一致，保守标记为不支持）。
  static const ollama = LlmCapability(
    supportsTools: false,
    supportsStreaming: true,
    supportsSystemMessage: false,
    supportsResponseFormat: false,
  );

  /// 校验"请求组合"是否在能力范围内：**tools 与 stream 不可并用**（通义
  /// DashScope 限制——同时请求会报错或静默降级）及其他单项不支持。
  /// 返回 null = 合法；否则返回可读的失败原因。
  String? validateRequest(LlmRequestOptions options) {
    if (options.useTools && options.stream) {
      return '当前 provider 不支持 tools 与 stream 并用';
    }
    if (options.useTools && !supportsTools) {
      return '当前 provider 不支持工具调用';
    }
    if (options.stream && !supportsStreaming) {
      return '当前 provider 不支持流式输出';
    }
    return null;
  }
}

/// LLM 客户端配置（baseUrl/key/model 可配；二期设置页输入）。
class LlmConfig {
  LlmConfig({
    required String baseUrl,
    required this.apiKey,
    required this.model,
    required this.capability,
    this.timeout = AiConfig.requestTimeout,
  })  : assert(timeout > Duration.zero, 'timeout 必须为正'),
        baseUrl = _normalizeBaseUrl(baseUrl) {
    if (model.trim().isEmpty) {
      throw ArgumentError.value(model, 'model', '模型名不能为空');
    }
  }

  /// 归一化 baseUrl：去尾部斜杠（拼接 `/chat/completions` 时避免双斜杠）；
  /// 仅接受 http(s) 根路径（无子路径/query/fragment/userInfo——与 supabase
  /// URL 约束同思路，防拼接端点产生错误 URL）。
  static String _normalizeBaseUrl(String value) {
    final trimmed = value.trim();
    final uri = Uri.tryParse(trimmed);
    if (uri == null ||
        !uri.isAbsolute ||
        !(uri.scheme == 'https' || uri.scheme == 'http') ||
        uri.hasQuery ||
        uri.hasFragment ||
        uri.hasAuthority == false ||
        uri.userInfo.isNotEmpty) {
      throw ArgumentError.value(
        value,
        'baseUrl',
        '必须为 http(s) 根路径（无子路径/query/fragment/userInfo）',
      );
    }
    // 允许根路径下的单段路径（如自托管 `https://host:8080/v1`——OpenAI
    // 兼容层常以 /v1 为前缀）；拒绝多段/深层路径。
    final segments = uri.pathSegments.where((s) => s.isNotEmpty).toList();
    if (segments.length > 1) {
      throw ArgumentError.value(
        value,
        'baseUrl',
        'baseUrl 至多一个路径段（如 /v1），不支持深层路径',
      );
    }
    return trimmed.endsWith('/') ? trimmed.substring(0, trimmed.length - 1) : trimmed;
  }

  /// OpenAI 兼容端点根（无尾斜杠；请求拼 `$baseUrl/chat/completions`）。
  final String baseUrl;

  /// API key（可空：本地自托管/Ollama 可能不需要；未配置时请求不带
  /// Authorization 头）。
  final String? apiKey;

  /// 模型名（非空）。
  final String model;

  /// Provider 能力标记（请求组合校验依据）。
  final LlmCapability capability;

  /// 单次请求超时。
  final Duration timeout;
}
