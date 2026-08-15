/// OpenAI 兼容 LLM 客户端（手写 http 薄封装，二期 AI 预留）。
///
/// 覆盖 DeepSeek/Kimi/通义/Ollama（均提供 OpenAI 兼容 `/chat/completions`
/// 端点）。请求体构造与响应解析为**静态纯函数**（可单测、与网络解耦）；
/// 网络段薄封装（超时 + 状态码检查 + 失败脱敏）。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io' show SocketException;

import 'package:http/http.dart' as http;

import '../../utils/result.dart';
import 'llm_client.dart';
import 'llm_types.dart';

/// OpenAI 兼容实现。
class OpenAiCompatibleLlmClient implements LlmClient {
  OpenAiCompatibleLlmClient({
    required this.config,
    http.Client? httpClient,
  })  : _http = httpClient ?? http.Client(),
        _ownsHttp = httpClient == null;

  /// 已关闭时的统一失败文案（chat 入口与 3 个 catch 分支共用单一事实来源）。
  static const closedError = '模型客户端已关闭，请重新创建';

  final LlmConfig config;
  final http.Client _http;
  /// 是否自建 http client（close 时释放；注入对象由调用方负责生命周期）。
  final bool _ownsHttp;

  /// 已关闭标记：close 后 chat() 明确拒绝（防"已关闭 client 抛
  /// ClientException 被误映射为网络不可用"的误导性错误；重复 close 幂等）。
  bool _closed = false;

  @override
  LlmCapability get capability => config.capability;

  @override
  void close() {
    if (_closed) return;
    _closed = true;
    if (_ownsHttp) {
      _http.close();
    }
  }

  @override
  Future<AppResult<String>> chat({
    required List<LlmMessage> messages,
    LlmRequestOptions options = const LlmRequestOptions.none(),
  }) async {
    if (_closed) {
      return const AppFailure(closedError);
    }
    // 能力组合校验（错误早失败）：通义 tools+stream 不可并用等。
    final incompatible = capability.validateRequest(options);
    if (incompatible != null) {
      return AppFailure(incompatible);
    }
    // **骨架阶段能力边界（r6 契约修正）**：二期落地前显式拒绝——
    // - `useTools`：真实 OpenAI 兼容端点对**空 tools 数组**通常返回 400
    //   （要求至少一项工具定义）；工具定义与 CommandInvocation 绑定前
    //   发送空数组必失败；
    // - `stream`：OpenAI 兼容流式端点返回 SSE（text/event-stream），骨架
    //   的 http.post + 普通 JSON 解析无法处理——发送 `stream: true` 会
    //   缓冲到流结束（慢生成大概率超时）且响应体非合法 JSON。
    // 能力标记已声明支持（二期落地后校验放行），此处是骨架实现边界。
    if (options.useTools) {
      return const AppFailure('当前暂不支持工具调用');
    }
    if (options.stream) {
      return const AppFailure('当前暂不支持流式输出');
    }
    // system role 不支持时的降级校验（Ollama 部分模型）。
    if (!capability.supportsSystemMessage &&
        messages.any((m) => m.role == LlmRole.system)) {
      return const AppFailure('当前 provider 不支持 system 消息');
    }

    final uri = Uri.parse('${config.baseUrl}/chat/completions');
    final body = buildChatRequestBody(
      config: config,
      messages: messages,
      options: options,
    );
    final headers = <String, String>{
      'content-type': 'application/json',
      if (config.apiKey != null) 'authorization': 'Bearer ${config.apiKey}',
    };
    try {
      // **jsonEncode 移出 try（r 修复）**：序列化失败抛 JsonUnsupportedObjectError
      //（继承 Error 非 Exception），下方 on Exception 分支捕获不到——一旦未来
      // body 出现不可序列化对象（二期工具定义绑定后），异常会逃逸出 chat()
      // 破坏"一律返回 AppResult"契约。在 try 外序列化，失败直接返回可读失败。
      final String encoded;
      try {
        encoded = jsonEncode(body);
      } on JsonUnsupportedObjectError {
        return const AppFailure('模型请求参数无法序列化');
      }
      final response = await _http
          .post(uri, headers: headers, body: encoded)
          .timeout(config.timeout);
      if (response.statusCode != 200) {
        // 不向用户透出响应体细节（可能含服务端内部错误信息）。
        return AppFailure('模型服务返回错误（${response.statusCode}），请稍后重试');
      }
      // **显式按 UTF-8 解码**：`response.body` 在响应头缺 charset 时按
      // ISO-8859-1（Latin-1）解码——OpenAI 兼容端点（DeepSeek/Kimi/Ollama 等）
      // 的 content-type 通常不带 charset，中文等非 ASCII 字节会被解码成乱码
      // 且 JSON 仍合法（jsonDecode 不报错，属静默损坏）。OpenAI 兼容端点一律
      // 返回 UTF-8，直接解码 bodyBytes。
      return parseChatResponseBody(utf8.decode(response.bodyBytes));
    } on TimeoutException {
      // 在途请求期间被 close（http.Client.close 会使在途 post 抛异常）——
      // 先判 _closed 再归因（防"已关闭"被误映射为网络故障）。
      if (_closed) return const AppFailure(closedError);
      return const AppFailure('模型请求超时，请稍后重试');
    } on SocketException {
      if (_closed) return const AppFailure(closedError);
      return const AppFailure('网络不可用，请稍后重试');
    } on http.ClientException {
      if (_closed) return const AppFailure(closedError);
      return const AppFailure('网络不可用，请稍后重试');
    } on FormatException catch (e) {
      // 响应体非法（非 JSON / choices 结构损坏）。
      return AppFailure('模型响应无法解析：${e.message}');
    }
  }

  /// 构造 OpenAI 兼容聊天请求体（**纯函数**，可单测）。
  ///
  /// - messages → `[{role, content}]`；
  /// - options.temperature/maxTokens 非空才携带；
  /// - `useTools` 仅当能力支持时携带占位 `tools` 字段（骨架不定义具体工具
  ///   模式——二期工具定义与 CommandInvocation 绑定；此处仅表达"请求了工具
  ///   能力"的契约）；
  /// - `stream` 仅当能力支持时携带；
  /// - `response_format` 仅当能力支持时携带（Ollama 缺此支持，省略）。
  static Map<String, Object?> buildChatRequestBody({
    required LlmConfig config,
    required List<LlmMessage> messages,
    LlmRequestOptions options = const LlmRequestOptions.none(),
  }) {
    final body = <String, Object?>{
      'model': config.model,
      'messages': [
        for (final m in messages)
          {'role': m.role.storageValue, 'content': m.content},
      ],
    };
    final temperature = options.temperature;
    if (temperature != null) {
      body['temperature'] = temperature;
    }
    final maxTokens = options.maxTokens;
    if (maxTokens != null) {
      body['max_tokens'] = maxTokens;
    }
    if (options.useTools && config.capability.supportsTools) {
      // **二期契约占位（r6）**：chat() 入口已显式拒绝 useTools（真实端点
      // 对空 tools 数组返 400）——此分支保留为纯函数序列化契约（二期工具
      // 定义与 CommandInvocation 绑定后启用真实 tools 载荷）。
      body['tools'] = <Object?>[];
    }
    if (options.stream && config.capability.supportsStreaming) {
      // **二期契约占位（r6）**：chat() 入口已显式拒绝 stream（骨架不解析
      // SSE）——此分支保留为纯函数序列化契约（二期流式接口落地后启用）。
      body['stream'] = true;
    }
    // **response_format 与 stream 正交（r1）**：JSON 模式是独立能力，由
    // useJsonMode 显式请求——不与流式耦合（旧实现把 response_format 绑在
    // stream 上：非流式永远无法请求结构化输出、流式被强制附带）。
    if (options.useJsonMode &&
        config.capability.supportsResponseFormat) {
      body['response_format'] = {'type': 'json_object'};
    }
    return body;
  }

  /// 解析 OpenAI 兼容补全响应体（**纯函数**，可单测）。
  ///
  /// 容错：choices 缺失/为空、message 缺失、content 缺失/非 String 一律
  /// 返回失败（不静默回退空串——空回复与解析失败须区分，防把损坏响应当
  /// 成功空回复推进流程）。
  static AppResult<String> parseChatResponseBody(String body) {
    final dynamic decoded;
    try {
      decoded = jsonDecode(body);
    } on FormatException catch (e) {
      return AppFailure('模型响应非合法 JSON：${e.message}');
    }
    if (decoded is! Map<String, dynamic>) {
      return const AppFailure('模型响应结构异常（顶层非对象）');
    }
    final choices = decoded['choices'];
    if (choices is! List || choices.isEmpty) {
      return const AppFailure('模型响应缺少 choices');
    }
    final first = choices.first;
    if (first is! Map<String, dynamic>) {
      return const AppFailure('模型响应 choices 结构异常');
    }
    final message = first['message'];
    if (message is! Map<String, dynamic>) {
      return const AppFailure('模型响应缺少 message');
    }
    final content = message['content'];
    if (content is! String) {
      return const AppFailure('模型响应缺少文本内容');
    }
    return AppSuccess(content);
  }
}
