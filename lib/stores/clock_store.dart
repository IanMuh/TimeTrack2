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
/// - **生命周期**：owner（`providers/` 容器）负责 [dispose] 取消 Timer——
///   Timer 必须持有引用并 cancel，否则泄漏（Flutter 官方 + 社区共识）。
/// - **订阅**：[addChangeListener] / [removeChangeListener] 显式配对；由
///   `providers/foundation.dart` 映射为 Riverpod 状态（`clockTickProvider`），
///   UI 不直接订阅本服务。
/// - [now] / [interval] 可注入：测试固定时刻序列 + 短间隔 + fake_async 做
///   确定性验证。
class ClockStore {
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

  final List<void Function()> _listeners = [];

  Timer? _timer;

  /// 已 dispose：防 dispose 后误 start() 重建 Timer（永不取消的资源泄漏）。
  bool _disposed = false;

  /// 是否正在运行。
  bool get isRunning => _timer != null;

  /// 注册 tick 监听（幂等：同一引用重复注册只保留一次）。
  void addChangeListener(void Function() listener) {
    if (!_listeners.contains(listener)) _listeners.add(listener);
  }

  /// 移除 tick 监听。
  void removeChangeListener(void Function() listener) {
    _listeners.remove(listener);
  }

  /// 启动时钟；幂等（已在运行则不重启）。dispose 后调用无效（静默忽略）。
  void start() {
    if (_disposed || _timer != null) return;
    _timer = Timer.periodic(interval, (_) {
      // 绝对时间重算：不依赖 tick 累计，防漂移（见文件头）。
      _notify();
    });
  }

  /// 停止时钟；幂等。dispose 后调用无效。
  void stop() {
    _timer?.cancel();
    _timer = null;
  }

  /// 当前时刻（来自注入源，默认真实时钟）。
  DateTime now() => _now();

  /// 逐监听者异常隔离：任一订阅者抛异常不得取消周期 Timer（Dart 语义下
  /// Timer.periodic 回调抛错会取消该 Timer，全局时钟静默停止）。
  void _notify() {
    // 快照迭代：允许监听者在自身回调中增删监听。
    for (final listener in List<void Function()>.of(_listeners)) {
      try {
        listener();
      } catch (e, st) {
        FlutterError.reportError(
          FlutterErrorDetails(
            exception: e,
            stack: st,
            library: 'clock_store',
            context: ErrorDescription('ClockStore tick 通知'),
          ),
        );
      }
    }
  }

  /// 测试专用：手动触发一次 tick（不依赖真实 1Hz Timer）。
  @visibleForTesting
  void emitTick() => _notify();

  /// 释放：取消 Timer 并清空监听。
  void dispose() {
    _disposed = true;
    stop();
    _listeners.clear();
  }
}
