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
  /// **实现契约（r 修复，接口层强制）**：
  /// 1. **必须先执行 `capability.validateRequest(options)`**：不支持的
  ///    能力组合（如 Ollama 的 supportsTools=false + useTools）必须在发起
  ///    网络请求前返回其可读原因，不得把不支持的能力请求发给服务端；
  /// 2. **必须捕获全部异常并映射为脱敏的 AppResult 失败**：底层异常
  ///   （超时/连接错误等）的堆栈/消息可能携带完整请求 URL 与 Authorization
  ///    头中的 API key——禁止把原始异常抛出接口边界（不透传、不 rethrow），
  ///    失败文案不得包含 baseUrl/apiKey/请求头细节；
  /// 3. **返回类型恒为 AppResult**：任何路径（含 close 后的调用）都返回
  ///    可读失败而非抛异常。
  ///
  /// 二期接入点：AI 解析自然语言 → [CommandInvocation] → 命令分发器执行
  ///（本骨架只产出文本回复，指令解析归阶段 6）。
  Future<AppResult<String>> chat({
    required List<LlmMessage> messages,
    LlmRequestOptions options = const LlmRequestOptions.none(),
  });

  /// 释放底层资源（内部自建的 http client / 连接池）。注入外部 httpClient
  /// 的调用方对注入对象的生命周期负责（实现不得关闭非自有对象）。
  ///
  /// **契约**：close 必须幂等（重复调用安全）；close 后调用 [chat] 应返回
  /// 明确的"客户端已关闭"失败而非未定义行为；close 与在途 [chat] 的交互由
  /// 实现自洽处理（在途请求的结果可被丢弃或正常返回，但不得抛异常逃逸）。
  void close();
}
