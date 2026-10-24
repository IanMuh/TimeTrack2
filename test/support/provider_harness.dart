/// Riverpod 测试基座：用内存库 + 可控依赖装配 ProviderContainer。
///
/// PR5 起生产侧已无 `AppStore`；本文件提供 [TestStore] 作为测试用的只读门面
/// （按需从容器读取 store/服务），旧测试的 `store.timer` 等写法无需重写。
library;

import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
// Riverpod 3 的公开入口拆分：`Override` 仅在 misc.dart 导出
// （flutter_riverpod.dart 不再导出它）。
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:timetrack2/api/supabase/sync_backend.dart';
import 'package:timetrack2/data/database/app_database.dart';
import 'package:timetrack2/data/repositories/activity_repository.dart';
import 'package:timetrack2/providers/bootstrap.dart';
import 'package:timetrack2/providers/data.dart';
import 'package:timetrack2/providers/foundation.dart';
import 'package:timetrack2/providers/infrastructure.dart';
import 'package:timetrack2/providers/services.dart';
import 'package:timetrack2/providers/stores.dart';
import 'package:timetrack2/stores/activity_store.dart';
import 'package:timetrack2/stores/category_store.dart';
import 'package:timetrack2/stores/clock_store.dart';
import 'package:timetrack2/stores/command_dispatcher.dart';
import 'package:timetrack2/stores/lan_store.dart';
import 'package:timetrack2/stores/reminder_store.dart';
import 'package:timetrack2/stores/settings_store.dart';
import 'package:timetrack2/stores/sync_store.dart';
import 'package:timetrack2/stores/timer_store.dart';
import 'package:timetrack2/stores/tracking_store.dart';
import 'package:timetrack2/stores/undo_store.dart';
import 'package:timetrack2/stores/update_store.dart';
import 'package:timetrack2/stores/data_revision.dart';

/// 每个用例独立的内存库（不落磁盘）。
AppDatabase createTestDatabase() => AppDatabase(NativeDatabase.memory());

/// 创建测试容器：内存库 + Noop 后端 + 关闭启动网络编排。
///
/// - [database] 传入时由调用方负责关闭；不传则用内存库并在 teardown 关闭；
/// - [now] 固定时钟（不传 = 系统时钟）；
/// - [overrides] 追加覆盖（优先级最高），用于替换仓储/后端/引擎。
///
/// 容器本身在 teardown 释放（触发各 store provider 的 `ref.onDispose`，
/// 释放 ClockStore 定时器等），因此用例内不需要手工 dispose。
ProviderContainer createTestContainer({
  AppDatabase? database,
  SyncBackend? backend,
  DateTime Function()? now,
  List<Override> overrides = const [],
}) {
  final db = database ?? createTestDatabase();
  if (database == null) addTearDown(db.close);

  final container = ProviderContainer(
    overrides: [
      appDatabaseProvider.overrideWithValue(db),
      syncBackendProvider.overrideWithValue(backend ?? NoopSyncBackend()),
      runStartupChecksProvider.overrideWithValue(false),
      // 测试默认不让 1Hz 时钟空转（需要 tick 的用例自行覆盖更短间隔）。
      clockIntervalProvider.overrideWithValue(const Duration(hours: 1)),
      clockAutoStartProvider.overrideWithValue(false),
      if (now != null) nowProvider.overrideWithValue(now),
      ...overrides,
    ],
  );
  addTearDown(container.dispose);
  return container;
}

/// 装配套件并返回测试门面（等价启动期 main 的 `await startupProvider.future`）。
Future<TestStore> pumpAppStore(ProviderContainer container) async {
  await container.read(startupProvider.future);
  return TestStore(container);
}

/// 测试门面：**只读**容器里的实例，避免测试重复实现装配。
///
/// 释放全部交给容器 teardown；[dispose] 仅为兼容旧测试写法而保留（no-op）。
class TestStore {
  TestStore(this.container);

  final ProviderContainer container;

  DomainStores get _domain => container.read(domainStoresProvider);

  TimerStore get timer => _domain.timer;
  CategoryStore get category => _domain.category;
  SettingsStore get settings => _domain.settings;
  ActivityStore get activity => _domain.activity;

  ActivityRepository get activities => container.read(activityRepositoryProvider);
  CommandDispatcher get dispatcher => container.read(commandDispatcherProvider);
  SyncStore get sync => container.read(syncStoreProvider);
  UpdateStore get update => container.read(updateStoreProvider);
  TrackingStore get tracking => container.read(trackingStoreProvider);
  LanStore get lan => container.read(lanStoreProvider);
  ReminderStore get reminder => container.read(reminderStoreProvider);
  UndoStore get undo => container.read(undoStoreProvider);
  ClockStore get clock => container.read(clockStoreProvider);
  DataRevision get dataRevision => container.read(dataRevisionStoreProvider);
  AppDatabase get database => container.read(appDatabaseProvider);
  String get currentVersion => container.read(currentVersionProvider);

  /// 旧 AppStore 的所有权标志在 provider 装配下恒为 false（容器负责释放）。
  bool get ownsFoundation => false;
  bool get ownsDomain => false;

  void dispose() {}
}



