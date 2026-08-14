/// 全局时钟：驱动计时/今日/时间线等"按秒刷新"的 UI 与跨日滚转检查。
///
/// 技术选型（阶段 3 框架调研结论）：非帧同步的周期性 UI 更新用
/// `Timer.periodic`（官方动画概览：Periodic UI updates → Timer），不用
/// Ticker（逐帧动画用）/ Stream.periodic（对 UI tick 属过度设计）。
library;

import 'dart:async';

import 'package:flutter/foundation.dart';

/// 周期时钟：默认每秒 tick，通知订阅者"当前时刻已变化"。
///
/// 设计要点：
/// - **绝对时间重算**：tick 回调不维护自增累计状态，[now] 每次从注入源取
///   真实当前时刻（Timer 间隔只是近似，累加会漂移；跨日滚转/边界计算依赖
///   精确时刻）。注入源默认 [DateTime.now]。
/// - **生命周期**：owner（领域 store / AppStore）负责 [dispose] 取消 Timer——
///   Timer 必须持有引用并 cancel，否则泄漏（Flutter 官方 + 社区共识）。
/// - [now] / [interval] 可注入：测试固定时刻序列 + 短间隔 + fake_async 做
///   确定性验证。
class ClockStore extends ChangeNotifier {
  ClockStore({
    this.interval = const Duration(seconds: 1),
    DateTime Function()? now,
    bool autoStart = true,
  })  : _now = now ?? DateTime.now {
    // Timer.periodic 要求正时长；zero/负值会直接抛 ArgumentError，启动即崩
    // 且难排查——构造期显式校验，带清晰信息。
    if (interval <= Duration.zero) {
      throw ArgumentError.value(interval, 'interval', 'interval 必须为正时长');
    }
    if (autoStart) start();
  }

  /// 时钟间隔（只读；测试可注入短间隔 + fake_async 确定性推进）。
  final Duration interval;

  final DateTime Function() _now;

  Timer? _timer;

  /// 已 dispose：防 dispose 后误 start() 重建 Timer（永不取消的资源泄漏 +
  /// 对已销毁 ChangeNotifier 触发 notifyListeners 的调试断言难定位）。
  bool _disposed = false;

  /// 是否正在运行。
  bool get isRunning => _timer != null;

  /// 启动时钟；幂等（已在运行则不重启）。dispose 后调用无效（静默忽略）。
  void start() {
    if (_disposed || _timer != null) return;
    _timer = Timer.periodic(interval, (_) {
      // 绝对时间重算：不依赖 tick 累计，防漂移（见文件头）。
      notifyListeners();
    });
  }

  /// 停止时钟；幂等。dispose 后调用无效。
  void stop() {
    _timer?.cancel();
    _timer = null;
  }

  /// 当前时刻（来自注入源，默认真实时钟）。
  DateTime now() => _now();

  @override
  void dispose() {
    _disposed = true;
    stop();
    super.dispose();
  }
}
