/// AI（二期预留）默认值与阈值（编译期常量，纯 Dart 无 Flutter 依赖）。
///
/// 语义：骨架阶段的默认网络参数——真实密钥/模型选择由二期设置页配置
///（不编译期固化）；本文件只收敛"请求超时/重试"等机械默认值与 URL 约束。
library;

class AiConfig {
  AiConfig._();

  /// 单次 LLM 请求超时（连接/响应体共用一个值，慢网络场景防长时间挂起）。
  static const requestTimeout = Duration(seconds: 30);

  /// 网络瞬时失败最大重试次数（指数退避；骨架不实现重试细节，常量供
  /// 二期编排层引用——避免两处魔数漂移）。
  static const maxRetries = 2;

  /// 指数退避基础延迟（首次重试等待）。
  static const retryBaseDelay = Duration(milliseconds: 500);

  /// baseUrl 合法 scheme（OpenAI 兼容端点；http 仅限本地/内网自托管，
  /// 生产应 https——校验层放行两者，安全职责在配置侧，与 supabase 一致）。
  static const allowedUrlSchemes = {'https', 'http'};
}
