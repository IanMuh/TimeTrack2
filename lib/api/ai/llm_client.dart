/// LLM 客户端抽象接口（二期 AI 预留，执行计划决策 7）。
///
/// 单接口覆盖 DeepSeek/Kimi/通义/Ollama——provider 差异通过 [LlmCapability]
/// 能力标记表达；实现负责把请求映射到各自端点的 OpenAI 兼容协议。
library;

import '../../utils/result.dart';
import 'llm_types.dart';

/// LLM 客户端。
abstract interface class LlmClient {
  /// Provider 能力标记（请求组合校验依据）。
  LlmCapability get capability;

  /// 发起一次对话补全；成功返回助手回复文本。
  ///
  /// 失败返回可读原因（网络/服务端错误脱敏，不泄露 API key/URL 细节）。
  /// 二期接入点：AI 解析自然语言 → [CommandInvocation] → 命令分发器执行
  ///（本骨架只产出文本回复，指令解析归阶段 6）。
  Future<AppResult<String>> chat({
    required List<LlmMessage> messages,
    LlmRequestOptions options = const LlmRequestOptions.none(),
  });

  /// 释放底层资源（内部自建的 http client / 连接池）。注入外部 httpClient
  /// 的调用方对注入对象的生命周期负责（实现不得关闭非自有对象）。
  void close();
}
