/// Riverpod 测试基座（迁移 B0 起）：用内存库 + 可控依赖装配 ProviderContainer。
///
/// 目标：新测试一律通过 [createTestContainer] 构造状态层，不再手工 new
/// AppStore/仓储；后续 B2-B4 把 store 拆成 provider 时，测试写法保持稳定。
library;

import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
// Riverpod 3 的公开入口拆分：`Override` 仅在 misc.dart 导出
// （flutter_riverpod.dart 不再导出它）。
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:timetrack2/api/supabase/sync_backend.dart';
import 'package:timetrack2/data/database/app_database.dart';
import 'package:timetrack2/providers/app.dart';
import 'package:timetrack2/providers/engines.dart';
import 'package:timetrack2/providers/foundation.dart';
import 'package:timetrack2/providers/infrastructure.dart';
import 'package:timetrack2/stores/app_store.dart';

/// 当前用例装配出的 AppStore（`appStoreInstanceProvider` 的测试绑定源）。
///
/// 生产由 main 的 `late bootStore` 绑定；测试里 store 在容器创建之后才由
/// [pumpAppStore] 装配，故用模块级变量承接（每个测试文件独立 isolate，文件内
/// 用例串行执行，teardown 复位）。
AppStore? _bootStore;

/// 每个用例独立的内存库（不落磁盘）。
AppDatabase createTestDatabase() => AppDatabase(NativeDatabase.memory());

/// 创建测试容器：内存库 + Noop 后端 + 关闭启动网络编排。
///
/// - [database] 传入时由调用方负责关闭；不传则用内存库并在 teardown 关闭；
/// - [now] 固定时钟（不传 = 系统时钟）；
/// - [overrides] 追加覆盖（优先级最高），用于替换仓储/后端/引擎。
///
/// 容器本身在 teardown 释放（触发 [appStoreProvider] 的 `ref.onDispose`，
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
      // B4a：壳层引擎快照的实例源（pumpAppStore 装配后赋值）。
      appStoreInstanceProvider.overrideWith((ref) {
        final store = _bootStore;
        if (store == null) {
          throw StateError('pumpAppStore 尚未装配：请在读取引擎快照前调用');
        }
        return store;
      }),
      // 测试默认不让 1Hz 时钟空转（需要 tick 的用例自行覆盖更短间隔）。
      clockIntervalProvider.overrideWithValue(const Duration(hours: 1)),
      if (now != null) nowProvider.overrideWithValue(now),
      ...overrides,
    ],
  );
  addTearDown(container.dispose);
  return container;
}

/// 装配 AppStore（等价于启动期 main 的 `await container.read(...future)`）。
///
/// 装配完成后绑定 [appStoreInstanceProvider]，使壳层引擎快照 provider 可用。
Future<AppStore> pumpAppStore(ProviderContainer container) async {
  final store = await container.read(appStoreProvider.future);
  _bootStore = store;
  addTearDown(() {
    if (identical(_bootStore, store)) _bootStore = null;
  });
  return store;
}
