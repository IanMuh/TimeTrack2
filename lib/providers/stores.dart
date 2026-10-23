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
    ..onDispose(activity.dispose)
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
