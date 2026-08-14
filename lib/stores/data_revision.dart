/// dataRevision 机制：UI 派生缓存失效的单一事实来源（保留不变式 9）。
///
/// 约定：任何领域数据变更（分类/活动/条目/设置…）写库成功后必须经
/// [DataRevision.bump] 递增修订号；UI/派生缓存监听 [value] 变化后失效重算。
/// 分类变更必须递增（老项目已知坑：分类改完统计不刷新）。
library;

import 'package:flutter/foundation.dart';

/// 单调递增的修订号（从 0 起，每次写库成功 +1）。
///
/// 用 [ValueNotifier] 承载（官方推荐：单标量/版本号用 ValueNotifier，`==`
/// 比较触发通知）：int 版本号天然值语义，相同值不重复通知。
class DataRevision extends ValueNotifier<int> {
  DataRevision() : super(0);

  /// 递增修订号并通知监听者。幂等由调用方保证（无变更不 bump）。
  void bump() => value += 1;

  /// 收敛 value 写入：禁止外部回退修订号（UI 缓存可能按"新号 > 旧号"顺序
  /// 比较失效，回退会漏失效）。debug 下断言报错；release 下静默拒绝并记
  /// debug 日志（被拒的写入在 release 无返回值可见，日志提供可观测信号防
  /// 静默不一致难以排查）。
  @override
  set value(int newValue) {
    assert(newValue >= value, '修订号必须单调递增，不允许回退');
    if (newValue < value) {
      debugPrint('DataRevision: 拒绝回退 newValue=$newValue current=$value');
      return;
    }
    super.value = newValue;
  }
}
