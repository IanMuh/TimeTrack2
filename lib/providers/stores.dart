/// 领域 store 的装配归属（Riverpod 迁移 PR4-a）。
///
/// 迁移前这些 store 由 `AppStore.create` 内部 `new` 出来并交给 CommandDispatcher；
/// Notifier 实例只能由 `NotifierProvider` 创建，故先把“谁创建、谁释放”搬到
/// provider 层：本文件构造领域 store，`appStoreProvider` 以 override 参数注入
/// `AppStore.create`（不再内部创建），释放由 `ref.onDispose` 负责。
///
/// PR4-b…PR4-f 逐个把这里的 `Provider<XxxStore>` 换成
/// `NotifierProvider<XxxNotifier, XxxState>` 时，`AppStore` 的字段类型随之下线，
/// 页面/测试只依赖 provider。
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

/// 活动变更状态（PR4-b 第一步）：`ActivityStore` 已去 `ChangeNotifier`，
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
