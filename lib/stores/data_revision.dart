/// dataRevision 机制：UI 派生缓存失效的单一事实来源（保留不变式 9）。
///
/// 约定：任何领域数据变更（分类/活动/条目/设置…）写库成功后必须经
/// [DataRevision.bump] 递增修订号；UI/派生缓存监听 `dataRevisionProvider`
/// （见 `providers/foundation.dart`）后失效重算。分类变更必须递增
/// （老项目已知坑：分类改完统计不刷新）。
library;

import 'package:flutter/foundation.dart';

/// 单调递增的修订号（从 0 起，每次写库成功 +1）。
///
/// 值语义：相同值不重复通知（与 `ValueNotifier` 一致，派生缓存不会因无变化
/// 的写入白重建）。订阅方经 [addChangeListener] / [removeChangeListener]
/// 显式配对；`providers/foundation.dart` 把它映射为 Riverpod 的
/// `dataRevisionProvider`，UI 一律 `ref.watch`，不直接订阅本类。
class DataRevision {
  DataRevision();

  int _value = 0;

  final List<void Function()> _listeners = [];

  /// 当前修订号。
  int get value => _value;

  /// 注册变更监听（幂等：同一引用重复注册只保留一次）。
  void addChangeListener(void Function() listener) {
    if (!_listeners.contains(listener)) _listeners.add(listener);
  }

  /// 移除变更监听。
  void removeChangeListener(void Function() listener) {
    _listeners.remove(listener);
  }

  /// 递增修订号并通知监听者。幂等由调用方保证（无变更不 bump）。
  void bump() => value = _value + 1;

  /// 收敛 value 写入：禁止外部回退修订号（UI 缓存可能按"新号 > 旧号"顺序
  /// 比较失效，回退会漏失效）。debug 下断言报错；release 下静默拒绝并记
  /// debug 日志（被拒的写入在 release 无返回值可见，日志提供可观测信号防
  /// 静默不一致难以排查）。相同值不重复通知。
  set value(int newValue) {
    assert(newValue >= _value, '修订号必须单调递增，不允许回退');
    if (newValue < _value) {
      debugPrint('DataRevision: 拒绝回退 newValue=$newValue current=$_value');
      return;
    }
    if (newValue == _value) return;
    _value = newValue;
    _notify();
  }

  /// 逐监听者异常隔离：一个派生缓存的刷新失败不应阻断其他订阅者。
  void _notify() {
    for (final listener in List<void Function()>.of(_listeners)) {
      try {
        listener();
      } catch (e, st) {
        FlutterError.reportError(
          FlutterErrorDetails(
            exception: e,
            stack: st,
            library: 'data_revision',
            context: ErrorDescription('DataRevision 变更通知'),
          ),
        );
      }
    }
  }

  /// 容器释放：清空监听，防悬挂引用。
  void dispose() {
    _listeners.clear();
  }
}
