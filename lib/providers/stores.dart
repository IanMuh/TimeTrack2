/// 领域 store 的装配与释放（唯一装配入口）。
///
/// 领域 store（Timer/Category/Activity/Settings）是可变服务对象：本文件负责
/// 创建并由 `ref.onDispose` 释放；通知经 `engines.dart` 的变更计数 provider
/// 映射为 Riverpod 状态，页面只 `ref.watch` 计数、`ref.read` 取服务。
///
/// 后台引擎（Sync/Update/Tracking/Lan/Reminder/Dispatcher 等）的装配见
/// `bootstrap.dart`。
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../stores/activity_store.dart';
import '../stores/category_store.dart';
import '../stores/settings_store.dart';
import '../stores/timer_store.dart';
import '../utils/result.dart';
import '../viewmodels/activity.dart';
import 'data.dart';
import 'foundation.dart';

/// 领域 store 集合（PR4-a 过渡载体；随各 store 转 Notifier 逐步缩小）。
class DomainStores {
  const DomainStores({
    required this.timer,
    required this.category,
    required this.activity,
    required this.settings,
  });

  final TimerStore timer;
  final CategoryStore category;
  final ActivityStore activity;
  final SettingsStore settings;
}

/// 领域 store 唯一实例（容器持有；按注册逆序释放，timer → settings →
/// category → activity）。
final domainStoresProvider = Provider<DomainStores>((ref) {
  final activity = ActivityStore(
    activities: ref.watch(activityRepositoryProvider),
    undo: ref.watch(undoStoreProvider),
    dataRevision: ref.watch(dataRevisionStoreProvider),
  );
  final category = CategoryStore(
    categories: ref.watch(categoryRepositoryProvider),
    undo: ref.watch(undoStoreProvider),
    dataRevision: ref.watch(dataRevisionStoreProvider),
  );
  final settings = SettingsStore(
    settings: ref.watch(settingsRepositoryProvider),
    undo: ref.watch(undoStoreProvider),
    dataRevision: ref.watch(dataRevisionStoreProvider),
  );
  final timer = TimerStore(
    entries: ref.watch(timeEntryRepositoryProvider),
    undo: ref.watch(undoStoreProvider),
    clock: ref.watch(clockStoreProvider),
    dataRevision: ref.watch(dataRevisionStoreProvider),
  );
  ref
    ..onDispose(category.dispose)
    ..onDispose(settings.dispose)
    ..onDispose(timer.dispose);
  return DomainStores(
    timer: timer,
    category: category,
    activity: activity,
    settings: settings,
  );
});

/// 活动写路径服务（容器唯一实例；`activity_create` 指令与 Notifier 共用）。
final activityStoreProvider = Provider<ActivityStore>(
  (ref) => ref.watch(domainStoresProvider).activity,
);

/// 活动变更状态：`ActivityStore` 不继承 `ChangeNotifier`，
/// 写成功/撤销恢复后经 [ActivityStore.onChanged] 推进本状态。
///
/// 页面目前仍依赖 `dataRevision` 刷新（活动列表是查询结果），本 provider 供
/// PR4-g 把 Dispatcher/活动选择器的读取面切过来后直接 watch。
final activityProvider =
    NotifierProvider<ActivityNotifier, int>(ActivityNotifier.new);

class ActivityNotifier extends Notifier<int> {
  @override
  int build() {
    final store = ref.watch(activityStoreProvider);
    void onChanged() {
      if (!ref.mounted) return;
      state = state + 1;
    }

    store.onChanged = onChanged;
    ref.onDispose(() {
      if (identical(store.onChanged, onChanged)) store.onChanged = null;
    });
    return 0;
  }

  /// 新建活动（与 `activity_create` 指令同一写路径）。
  Future<AppResult<Activity>> createActivity({
    required String name,
    required int color,
    bool isOneOff = false,
  }) {
    return ref
        .read(activityStoreProvider)
        .createActivity(name: name, color: color, isOneOff: isOneOff);
  }
}
