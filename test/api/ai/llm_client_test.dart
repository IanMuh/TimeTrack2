import 'dart:async';
import 'dart:convert';
import 'dart:io' show SocketException;

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:timetrack2/api/ai/llm_types.dart';
import 'package:timetrack2/api/ai/openai_compatible_llm_client.dart';

/// 记录 close 调用的 spy http client（r3）：MockClient 的 close() 是 no-op、
/// 不记录状态——无法区分"注入对象是否被错误关闭"；继承 [http.BaseClient]
/// 覆写 [http.BaseClient.close] 计数，才能对"注入不释放"语义形成真实回归保护。
class _CloseSpyClient extends http.BaseClient {
  int closeCount = 0;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final body = jsonEncode({
      'choices': [
        {'message': {'role': 'assistant', 'content': 'ok'}},
      ],
    });
    return http.StreamedResponse(
      Stream.value(utf8.encode(body)),
      200,
      contentLength: body.length,
      headers: {'content-type': 'application/json'},
      request: request,
    );
  }

  @override
  void close() {
    closeCount += 1;
    super.close();
  }
}

/// 可挂起的 http client（r4 竞态测试用）：send 等待 [gate] 完成才继续——
/// 模拟"请求在途时 close() 被并发调用，在途 post 随后抛 ClientException"。
class _HangClient extends http.BaseClient {
  final Completer<void> gate = Completer<void>();

  /// 释放挂起的 send（在途请求随后抛 ClientException）。
  void release() => gate.complete();

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    await gate.future;
    throw http.ClientException('client is closed');
  }
}

void main() {
  group('LlmCapability 能力标记与组合矩阵', () {
    test('预置 provider 能力快照', () {
      expect(LlmCapability.deepseek.supportsTools, isTrue);
      expect(LlmCapability.deepseek.supportsStreaming, isTrue);
      // **后续用例依赖标记显式锁定（r6）**：useJsonMode 用例依赖
      // deepseek.supportsResponseFormat==true、组合用例依赖 supportsToolsWithStream
      // ——在快照处断言，防能力声明与测试假设漂移时失败落在远端用例且原因不直观。
      expect(LlmCapability.deepseek.supportsResponseFormat, isTrue);
      expect(LlmCapability.deepseek.supportsToolsWithStream, isTrue);
      expect(LlmCapability.kimi.supportsTools, isTrue);
      expect(LlmCapability.kimi.supportsResponseFormat, isTrue);
      expect(LlmCapability.kimi.supportsToolsWithStream, isTrue);
      // 通义：tools/stream 均支持但**不可并用**（validateRequest 拒绝）
      expect(LlmCapability.qwen.supportsTools, isTrue);
      expect(LlmCapability.qwen.supportsStreaming, isTrue);
      expect(LlmCapability.qwen.supportsResponseFormat, isFalse);
      expect(LlmCapability.qwen.supportsToolsWithStream, isFalse);
      // Ollama：缺 tools/response_format/system
      expect(LlmCapability.ollama.supportsTools, isFalse);
      expect(LlmCapability.ollama.supportsStreaming, isTrue);
      expect(LlmCapability.ollama.supportsSystemMessage, isFalse);
      expect(LlmCapability.ollama.supportsResponseFormat, isFalse);
    });

    test('tools + stream 并用拒绝（通义 DashScope 限制）', () {
      final error = LlmCapability.qwen.validateRequest(
        LlmRequestOptions(useTools: true, stream: true),
      );
      expect(error, isNotNull, reason: '通义 tools+stream 并用必须拒绝');
    });

    test('deepseek/kimi tools+stream 可并用（r1：能力声明与校验一致）', () {
      // 旧实现无条件拒绝 useTools+stream——与 deepseek/kimi 预置声明"可并用"
      // 矛盾。supportsToolsWithStream 独立标记后，可并用 provider 放行。
      expect(
        LlmCapability.deepseek.validateRequest(
          LlmRequestOptions(useTools: true, stream: true),
        ),
        isNull,
        reason: 'DeepSeek tools+stream 可并用',
      );
      expect(
        LlmCapability.kimi.validateRequest(
          LlmRequestOptions(useTools: true, stream: true),
        ),
        isNull,
        reason: 'Kimi tools+stream 可并用',
      );
      // Ollama 无 tools：useTools+stream 先命中"不支持工具调用"文案
      expect(
        LlmCapability.ollama.validateRequest(
          LlmRequestOptions(useTools: true, stream: true),
        ),
        '当前 provider 不支持工具调用',
        reason: 'Ollama 先报单项不支持（校验顺序）',
      );
    });

    test('单项能力不支持时拒绝', () {
      // Ollama 无 tools
      expect(
        LlmCapability.ollama.validateRequest(
          LlmRequestOptions(useTools: true),
        ),
        isNotNull,
        reason: 'Ollama 不支持工具调用',
      );
      // 无 stream 的 provider（构造标记）
      const noStream = LlmCapability(
        supportsTools: false,
        supportsStreaming: false,
        supportsSystemMessage: true,
        supportsResponseFormat: false,
      );
      expect(
        noStream.validateRequest(LlmRequestOptions(stream: true)),
        isNotNull,
        reason: '不支持流式时请求流式拒绝',
      );
    });

    test('合法组合放行', () {
      expect(
        LlmCapability.deepseek.validateRequest(
          LlmRequestOptions(useTools: true),
        ),
        isNull,
      );
      expect(
        LlmCapability.deepseek.validateRequest(
          LlmRequestOptions(stream: true),
        ),
        isNull,
      );
      expect(
        LlmCapability.qwen.validateRequest(
          LlmRequestOptions(useTools: true),
        ),
        isNull,
        reason: '通义单独 tools 合法',
      );
    });

    test('useJsonMode 能力拒绝（r6：qwen/ollama 不支持 JSON 模式）', () {
      // 防 buildChatRequestBody 静默省略 response_format、调用方请求的
      // 结构化输出被无声降级为普通文本。
      for (final capability in [LlmCapability.qwen, LlmCapability.ollama]) {
        expect(
          capability.validateRequest(LlmRequestOptions(useJsonMode: true)),
          isNotNull,
          reason: '${identical(capability, LlmCapability.qwen) ? '通义' : 'Ollama'} '
              '不支持 JSON 结构化输出须拒绝',
        );
      }
      expect(
        LlmCapability.deepseek.validateRequest(
          LlmRequestOptions(useJsonMode: true),
        ),
        isNull,
        reason: 'DeepSeek 支持 JSON 模式放行',
      );
    });
  });

  group('LlmConfig baseUrl 校验', () {
    LlmConfig config(String baseUrl) => LlmConfig(
          baseUrl: baseUrl,
          apiKey: 'k',
          model: 'gpt-x',
          capability: LlmCapability.deepseek,
        );

    test('合法：https/http 根路径 / 单段 /v1 / 尾斜杠归一', () {
      expect(config('https://api.example.com').baseUrl, 'https://api.example.com');
      expect(
        config('https://api.example.com/').baseUrl,
        'https://api.example.com',
        reason: '尾斜杠归一',
      );
      expect(
        config('https://api.example.com/v1').baseUrl,
        'https://api.example.com/v1',
        reason: '单段 /v1 允许（OpenAI 兼容层前缀）',
      );
      expect(config('http://localhost:11434/v1').baseUrl, 'http://localhost:11434/v1');
    });

    test('非法：非 http(s)/空主机/子路径/query/fragment/userInfo/深层路径/双斜杠拒绝', () {
      for (final bad in [
        'ftp://api.example.com',
        'not-a-url',
        'http://', // 空主机
        'http:///path', // 空主机带路径
        'https://api.example.com/v1/chat/completions', // 深层路径
        'https://api.example.com/v1/extra',
        'https://api.example.com?x=1',
        'https://api.example.com#frag',
        'https://user:pass@api.example.com',
        'https://api.example.com//v1', // 双斜杠路径
        'https://api.example.com//', // 裸双斜杠尾路径
        'https://api.example.com/a%2Fb', // 编码斜杠（解码后为深层路径）
      ]) {
        expect(() => config(bad), throwsArgumentError,
            reason: '非法 baseUrl 应拒绝：$bad');
      }
    });

    test('temperature NaN 拒绝（NaN 比较恒 false 的漏检防护）', () {
      expect(() => LlmRequestOptions(temperature: double.nan),
          throwsA(anyOf(isA<AssertionError>(), isA<ArgumentError>())),
          reason: 'NaN 温度拒绝（防 JsonUnsupportedObjectError 逃逸）');
    });

    test('apiKey 空串/空白归一化为 null；timeout 非正运行时拒绝', () {
      final blank = LlmConfig(
        baseUrl: 'https://api.example.com',
        apiKey: '   ',
        model: 'm',
        capability: LlmCapability.deepseek,
      );
      expect(blank.apiKey, isNull, reason: '空白 apiKey 归一化为 null');
      expect(
        () => LlmConfig(
          baseUrl: 'https://api.example.com',
          apiKey: null,
          model: 'm',
          capability: LlmCapability.deepseek,
          timeout: Duration.zero,
        ),
        // debug 下 assert 先拦（AssertionError）；release 下运行时 throw 兜底
        throwsA(anyOf(isA<AssertionError>(), isA<ArgumentError>())),
        reason: 'timeout 非正拒绝（debug assert + release throw）',
      );
    });
  });

  group('buildChatRequestBody 纯函数', () {
    final deepseekConfig = LlmConfig(
      baseUrl: 'https://api.example.com',
      apiKey: 'key-1',
      model: 'deepseek-chat',
      capability: LlmCapability.deepseek,
    );

    test('基础消息映射与 role/content', () {
      final body = OpenAiCompatibleLlmClient.buildChatRequestBody(
        config: deepseekConfig,
        messages: const [
          LlmMessage(role: LlmRole.system, content: '你是助手'),
          LlmMessage(role: LlmRole.user, content: '你好'),
        ],
      );
      expect(body['model'], 'deepseek-chat');
      final messages = body['messages'] as List;
      expect(messages, [
        {'role': 'system', 'content': '你是助手'},
        {'role': 'user', 'content': '你好'},
      ]);
      // 未请求的能力字段不出现
      expect(body.containsKey('tools'), isFalse);
      expect(body.containsKey('stream'), isFalse);
      expect(body.containsKey('temperature'), isFalse);
    });

    test('options 携带：temperature/maxTokens/tools/stream 按能力', () {
      final body = OpenAiCompatibleLlmClient.buildChatRequestBody(
        config: deepseekConfig,
        messages: const [LlmMessage(role: LlmRole.user, content: 'x')],
        options: LlmRequestOptions(
          temperature: 0.7,
          maxTokens: 100,
          useTools: true,
          stream: true,
        ),
      );
      expect(body['temperature'], 0.7);
      expect(body['max_tokens'], 100);
      expect(body['tools'], isA<List>(), reason: '支持 tools 时携带占位');
      expect(body['stream'], isTrue);
      // response_format 与 stream 正交（r1）：未请求 useJsonMode 不携带
      expect(body.containsKey('response_format'), isFalse);
    });

    test('useJsonMode 独立请求 response_format（与 stream 正交，r1）', () {
      // JSON 模式是独立能力——非流式请求也可请求结构化输出。
      final body = OpenAiCompatibleLlmClient.buildChatRequestBody(
        config: deepseekConfig,
        messages: const [LlmMessage(role: LlmRole.user, content: 'x')],
        options: LlmRequestOptions(useJsonMode: true),
      );
      expect(body['response_format'], {'type': 'json_object'},
          reason: 'DeepSeek 支持 response_format，useJsonMode 独立携带');
      expect(body.containsKey('stream'), isFalse,
          reason: 'JSON 模式不强制流式');
      // 能力不支持时不携带（Ollama 无 response_format）
      final ollamaBody = OpenAiCompatibleLlmClient.buildChatRequestBody(
        config: LlmConfig(
          baseUrl: 'http://localhost:11434/v1',
          apiKey: null,
          model: 'llama3',
          capability: LlmCapability.ollama,
        ),
        messages: const [LlmMessage(role: LlmRole.user, content: 'x')],
        options: LlmRequestOptions(useJsonMode: true),
      );
      expect(ollamaBody.containsKey('response_format'), isFalse,
          reason: 'Ollama 无 response_format 不携带');
    });

    test('stream + useJsonMode 同时开启：两者均携带（正交组合，r2）', () {
      // 流式与 JSON 模式是独立能力——同时请求应同时携带，防未来把两者
      // 重新耦合的回归。
      final body = OpenAiCompatibleLlmClient.buildChatRequestBody(
        config: deepseekConfig,
        messages: const [LlmMessage(role: LlmRole.user, content: 'x')],
        options: LlmRequestOptions(stream: true, useJsonMode: true),
      );
      expect(body['stream'], isTrue, reason: '流式携带');
      expect(body['response_format'], {'type': 'json_object'},
          reason: 'JSON 模式独立携带（与 stream 正交）');
    });

    test('LlmRequestOptions 边界：temperature 越界 / maxTokens 非正拒绝', () {
      // debug 下 assert 先拦（AssertionError）；release 下运行时 throw 兜底。
      final rejects = throwsA(anyOf(isA<AssertionError>(), isA<ArgumentError>()));
      expect(() => LlmRequestOptions(temperature: 3), rejects,
          reason: 'temperature > 2 拒绝');
      expect(() => LlmRequestOptions(temperature: -0.1), rejects,
          reason: 'temperature < 0 拒绝');
      expect(() => LlmRequestOptions(maxTokens: 0), rejects,
          reason: 'maxTokens=0 拒绝');
      expect(() => LlmRequestOptions(maxTokens: -5), rejects,
          reason: 'maxTokens 负数拒绝');
    });

    test('能力不支持时不携带（Ollama：无 tools/response_format）', () {
      final ollamaConfig = LlmConfig(
        baseUrl: 'http://localhost:11434/v1',
        apiKey: null,
        model: 'llama3',
        capability: LlmCapability.ollama,
      );
      final body = OpenAiCompatibleLlmClient.buildChatRequestBody(
        config: ollamaConfig,
        messages: const [LlmMessage(role: LlmRole.user, content: 'x')],
        options: LlmRequestOptions(
          useTools: true,
          stream: true,
        ),
      );
      expect(body.containsKey('tools'), isFalse, reason: 'Ollama 无 tools 不携带');
      expect(body.containsKey('response_format'), isFalse);
      expect(body['stream'], isTrue, reason: 'Ollama 支持流式仍携带');
    });
  });

  group('parseChatResponseBody 纯函数', () {
    test('合法响应提取 content', () {
      final result = OpenAiCompatibleLlmClient.parseChatResponseBody(
        jsonEncode({
          'choices': [
            {'message': {'role': 'assistant', 'content': '你好'}},
          ],
        }),
      );
      expect(result.requireValue(), '你好');
    });

    test('容错：非 JSON / 非对象 / 缺 choices / choices 空 / 缺 message / content 非 String 均失败', () {
      for (final (label, body) in [
        ('非 JSON', 'not-json'),
        ('顶层非对象', jsonEncode([1, 2])),
        ('缺 choices', jsonEncode({'foo': 1})),
        ('choices 空', jsonEncode({'choices': []})),
        ('choices 非列表', jsonEncode({'choices': 1})),
        ('缺 message', jsonEncode({'choices': [{'x': 1}]})),
        ('message 非对象', jsonEncode({'choices': [{'message': 'hi'}]})),
        ('content 非 String', jsonEncode({
          'choices': [
            {'message': {'role': 'assistant', 'content': 123}},
          ],
        })),
      ]) {
        final result = OpenAiCompatibleLlmClient.parseChatResponseBody(body);
        expect(result.isSuccess, isFalse, reason: '$label 应失败');
      }
    });
  });

  group('OpenAiCompatibleLlmClient 网络层（MockClient）', () {
    LlmConfig config({LlmCapability? capability}) => LlmConfig(
          baseUrl: 'https://api.example.com',
          apiKey: 'key-1',
          model: 'model-x',
          capability: capability ?? LlmCapability.deepseek,
        );

    test('成功：POST 端点/头/请求体正确，解析 content', () async {
      http.Request? captured;
      final client = OpenAiCompatibleLlmClient(
        config: config(),
        httpClient: MockClient((request) async {
          captured = request;
          return http.Response(
            jsonEncode({
              'choices': [
                {'message': {'role': 'assistant', 'content': '回复'}},
              ],
            }),
            200,
            headers: {'content-type': 'application/json'},
            request: request,
          );
        }),
      );
      final result = await client.chat(
        messages: const [LlmMessage(role: LlmRole.user, content: 'hi')],
      );
      expect(result.requireValue(), '回复');
      expect(captured!.url.toString(), 'https://api.example.com/chat/completions');
      expect(captured!.method, 'POST');
      expect(captured!.headers['authorization'], 'Bearer key-1');
      final body = jsonDecode(captured!.body) as Map<String, dynamic>;
      expect(body['model'], 'model-x');
    });

    test('apiKey 为 null（Ollama/本地自托管）：请求不携带 Authorization 头（r6）', () async {
      // 防未来误拼接 'Bearer null' / 无条件带头——Ollama/本地场景最常见。
      http.Request? captured;
      final client = OpenAiCompatibleLlmClient(
        config: LlmConfig(
          baseUrl: 'http://localhost:11434/v1',
          apiKey: null,
          model: 'llama3',
          capability: LlmCapability.ollama,
        ),
        httpClient: MockClient((request) async {
          captured = request;
          return http.Response(
            jsonEncode({
              'choices': [
                {'message': {'role': 'assistant', 'content': 'ok'}},
              ],
            }),
            200,
            headers: {'content-type': 'application/json'},
            request: request,
          );
        }),
      );
      expect((await client.chat(
        messages: const [LlmMessage(role: LlmRole.user, content: 'x')],
      ))
          .isSuccess, isTrue);
      expect(captured!.headers.containsKey('authorization'), isFalse,
          reason: 'apiKey 为 null 时不得携带 Authorization 头');
    });

    test('能力组合非法：tools+stream 在发送前拒绝（不触达网络）', () async {
      var hit = false;
      final client = OpenAiCompatibleLlmClient(
        config: config(capability: LlmCapability.qwen),
        httpClient: MockClient((request) async {
          hit = true;
          return http.Response('{}', 200, request: request);
        }),
      );
      final result = await client.chat(
        messages: const [LlmMessage(role: LlmRole.user, content: 'x')],
        options: LlmRequestOptions(useTools: true, stream: true),
      );
      expect(result.isSuccess, isFalse, reason: '通义 tools+stream 拒绝');
      expect(hit, isFalse, reason: '非法组合不触达网络');
    });

    test('system 消息在 Ollama 降级拒绝（不支持 system role）', () async {
      var hit = false;
      final client = OpenAiCompatibleLlmClient(
        config: config(capability: LlmCapability.ollama),
        httpClient: MockClient((request) async {
          hit = true;
          return http.Response('{}', 200, request: request);
        }),
      );
      final result = await client.chat(
        messages: const [LlmMessage(role: LlmRole.system, content: 'sys')],
      );
      expect(result.isSuccess, isFalse, reason: 'Ollama 不支持 system 消息');
      expect(hit, isFalse);
    });

    test('非 200：返回可读失败且不泄露响应体细节', () async {
      final client = OpenAiCompatibleLlmClient(
        config: config(),
        httpClient: MockClient((request) async =>
            http.Response('{"error":"internal secret"}', 500, request: request)),
      );
      final result = await client.chat(
        messages: const [LlmMessage(role: LlmRole.user, content: 'x')],
      );
      expect(result.isSuccess, isFalse);
      final msg = result.when(onSuccess: (_) => '', onFailure: (m) => m);
      expect(msg.contains('internal secret'), isFalse,
          reason: '不泄露服务端响应体细节');
    });

    test('网络异常映射：ClientException → 可读失败', () async {
      final client = OpenAiCompatibleLlmClient(
        config: config(),
        httpClient: MockClient(
          (_) async => throw http.ClientException('connection reset'),
        ),
      );
      final result = await client.chat(
        messages: const [LlmMessage(role: LlmRole.user, content: 'x')],
      );
      expect(result.isSuccess, isFalse);
      final msg = result.when(onSuccess: (_) => '', onFailure: (m) => m);
      expect(
        msg.contains('ClientException') || msg.contains('SocketException'),
        isFalse,
        reason: '不泄露底层异常类型',
      );
    });

    test('网络异常映射：SocketException → 可读失败（r6）', () async {
      // SocketException 是真实网络故障（断网/DNS/连接拒绝）的常见异常——
      // 该 catch 分支回归（文案错误/未先判 _closed）须被拦截。
      final client = OpenAiCompatibleLlmClient(
        config: config(),
        httpClient: MockClient(
          (_) async => throw const SocketException('connection refused'),
        ),
      );
      final result = await client.chat(
        messages: const [LlmMessage(role: LlmRole.user, content: 'x')],
      );
      expect(result.isSuccess, isFalse);
      final msg = result.when(onSuccess: (_) => '', onFailure: (m) => m);
      expect(
        msg.contains('SocketException') || msg.contains('ClientException'),
        isFalse,
        reason: '不泄露底层异常类型',
      );
      expect(msg, contains('网络'), reason: '统一脱敏文案');
    });

    test('骨架能力边界（r6）：useTools/stream 在 chat 入口显式拒绝', () async {
      // 二期落地前：空 tools 数组必 400、SSE 骨架无法解析——显式拒绝而非
      // 发送必败请求（防"已发送但服务端 400/超时"的误导性失败）。
      var hit = false;
      final client = OpenAiCompatibleLlmClient(
        config: config(),
        httpClient: MockClient((request) async {
          hit = true;
          return http.Response('{}', 200, request: request);
        }),
      );
      final toolsResult = await client.chat(
        messages: const [LlmMessage(role: LlmRole.user, content: 'x')],
        options: LlmRequestOptions(useTools: true),
      );
      expect(toolsResult.isSuccess, isFalse, reason: 'useTools 骨架拒绝');
      expect(
        toolsResult.when(onSuccess: (_) => '', onFailure: (m) => m),
        contains('暂不支持工具调用'),
      );
      final streamResult = await client.chat(
        messages: const [LlmMessage(role: LlmRole.user, content: 'x')],
        options: LlmRequestOptions(stream: true),
      );
      expect(streamResult.isSuccess, isFalse, reason: 'stream 骨架拒绝');
      expect(
        streamResult.when(onSuccess: (_) => '', onFailure: (m) => m),
        contains('暂不支持流式输出'),
      );
      expect(hit, isFalse, reason: '骨架边界拒绝不触达网络');
    });

    test('close 生命周期：自建释放 / 注入不释放 / 关闭后 chat 拒绝（r3）', () async {
      // 注入对象所有权归调用方：close 不得关闭注入的 http client——用 spy
      // client 记录 close 调用（MockClient 的 close 是 no-op、无法观测）。
      final spy = _CloseSpyClient();
      final clientA = OpenAiCompatibleLlmClient(
        config: config(),
        httpClient: spy,
      );
      expect((await clientA.chat(
        messages: const [LlmMessage(role: LlmRole.user, content: 'x')],
      ))
          .isSuccess, isTrue);
      clientA.close();
      expect(spy.closeCount, 0,
          reason: '注入 client 的 close 从未被调用（所有权归调用方）');

      // 自建 client：close 后 chat 明确拒绝（非误导性"网络不可用"）。
      final ownClient = OpenAiCompatibleLlmClient(config: config());
      ownClient.close();
      final afterClose = await ownClient.chat(
        messages: const [LlmMessage(role: LlmRole.user, content: 'x')],
      );
      expect(afterClose.isSuccess, isFalse, reason: '关闭后 chat 失败');
      final msg = afterClose.when(onSuccess: (_) => '', onFailure: (m) => m);
      expect(msg, contains('已关闭'),
          reason: '明确提示已关闭（非误导性网络错误）');
      // 重复 close 幂等（不抛错）。
      ownClient.close();
    });

    test('在途请求并发 close：catch 归因为"已关闭"而非"网络不可用"（r4）', () async {
      // 核心竞态：chat() 已进入 await（在途 post 挂起）后 close() 被并发
      // 调用——在途请求随后抛 ClientException，须命中 catch 内 `_closed`
      // 判定映射为"已关闭"（防误报"网络不可用"）。
      final hang = _HangClient();
      final client = OpenAiCompatibleLlmClient(
        config: config(),
        httpClient: hang,
      );
      final future = client.chat(
        messages: const [LlmMessage(role: LlmRole.user, content: 'x')],
      );
      // 让 chat 进入 await（send 挂起中）。
      await pumpEventQueue();
      client.close(); // 在途期间关闭
      hang.release(); // 释放在途请求 → 抛 ClientException
      final result = await future;
      expect(result.isSuccess, isFalse);
      final msg = result.when(onSuccess: (_) => '', onFailure: (m) => m);
      expect(msg, contains('已关闭'),
          reason: '在途请求期间 close → 归因"已关闭"（非"网络不可用"）');
      expect(msg.contains('网络不可用'), isFalse,
          reason: '不误报网络故障');
    });
  });
}
