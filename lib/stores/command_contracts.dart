/// 指令分发契约（模块 3d①）：Dispatcher 依赖的窄接口——与项目
/// SyncBackend 窄接口惯例一致，测试注入轻量 stub 免构造完整 store。
library;

import '../utils/result.dart';

/// 同步协调能力（[SyncStore] 实现；Dispatcher 只依赖"能 syncNow"）。
abstract interface class SyncNowProvider {
  Future<AppResult<dynamic>> syncNow();
}

/// 更新动作能力（[UpdateStore] 实现；Dispatcher 只依赖 check/install）。
abstract interface class UpdateActions {
  Future<AppResult<dynamic>> check();
  Future<AppResult<dynamic>> install();
}
