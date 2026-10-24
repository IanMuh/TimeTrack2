import 'dart:async';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../api/update/update_downloader.dart';
import '../api/update/update_manifest_service.dart';
import '../api/update/update_verifier.dart';
import '../data/update/windows_installer.dart';
import '../data/cleanup/cleanup_service.dart';
import '../data/interop/file_interop_service.dart';
import '../utils/result.dart';
import '../data/sync/sync_bundle_repository.dart';
import '../data/repositories/sync_peer_store.dart';
import '../api/supabase/sync_status_store.dart';
import '../data/repositories/tracking_rule_repository.dart';
import '../stores/command_dispatcher.dart';
import '../stores/lan_store.dart';
import '../stores/reminder_store.dart';
import '../stores/sync_store.dart';
import '../stores/tracking_store.dart';
import '../stores/update_store.dart';
import 'data.dart';
import 'engines.dart';
import 'foundation.dart';
import 'infrastructure.dart';
import 'services.dart';
import 'stores.dart';

/// 后台引擎与服务的装配（PR5：取代 `AppStore.create` 的组装职责）。
///
/// 依赖方向：本文件读仓储/基础服务/领域 store 的 provider 直接构造引擎，
/// 释放责任经 `ref.onDispose` 落到容器；页面不再触碰任何装配类。

/// 追踪规则仓储（`TrackingStore` 轮询用）。
final trackingRuleRepositoryProvider = Provider<TrackingRuleRepository>(
  (ref) => TrackingRuleRepository(database: ref.watch(appDatabaseProvider)),
);

/// 同步状态表读写。
final syncStatusStoreProvider = Provider<SyncStatusStore>(
  (ref) => SyncStatusStore(database: ref.watch(appDatabaseProvider)),
);

/// 保留期清理（同步成功后/启动时限频执行）。
final cleanupServiceProvider = Provider<CleanupService>(
  (ref) => CleanupService(database: ref.watch(appDatabaseProvider)),
);

/// 同步包仓库（云同步 / LAN 互通 / 文件导出导入共用）。
final syncBundleRepositoryProvider = Provider<SyncBundleRepository>((ref) {
  return SyncBundleRepository(
    database: ref.watch(appDatabaseProvider),
    activities: ref.watch(activityRepositoryProvider),
    categories: ref.watch(categoryRepositoryProvider),
    timeEntries: ref.watch(timeEntryRepositoryProvider),
    actionLogs: ref.watch(actionLogRepositoryProvider),
    settings: ref.watch(settingsRepositoryProvider),
  );
});

/// 文件互通（`.timetrack.json` 导入导出）。
final fileInteropServiceProvider = Provider<FileInteropService>(
  (ref) => FileInteropService(
    syncBundleRepository: ref.watch(syncBundleRepositoryProvider),
  ),
);

/// 云同步引擎（服务端 backend 可被测试覆盖为 Noop）。
final syncStoreProvider = Provider<SyncStore>((ref) {
  final store = SyncStore(
    backend: ref.watch(syncBackendProvider),
    syncStatus: ref.watch(syncStatusStoreProvider),
    cleanup: ref.watch(cleanupServiceProvider),
    dataRevision: ref.watch(dataRevisionStoreProvider),
  );
  ref.onDispose(store.dispose);
  return store;
});

/// 更新清单服务。
final updateManifestServiceProvider = Provider<UpdateManifestService>(
  (ref) => UpdateManifestService(
    database: ref.watch(appDatabaseProvider),
    currentVersion: ref.watch(currentVersionProvider),
    manifestUrl: ref.watch(updateManifestUrlProvider),
  ),
);

/// 应用更新引擎。
final updateStoreProvider = Provider<UpdateStore>((ref) {
  final store = UpdateStore(
    manifestService: ref.watch(updateManifestServiceProvider),
    verifier: UpdateVerifier(downloader: UpdateDownloader()),
    windowsInstaller: ref.watch(windowsInstallerProvider) ??
        _defaultWindowsInstaller(),
    database: ref.watch(appDatabaseProvider),
  );
  ref.onDispose(store.dispose);
  return store;
});

/// Windows 默认安装器占位（目录注入留待阶段 5 挂账；非 Windows 返回 null）。
WindowsInstaller? _defaultWindowsInstaller() {
  if (!Platform.isWindows) return null;
  final base = Directory.current.path;
  return WindowsInstaller(
    programDir: base,
    dataDir:
        '${Directory.systemTemp.path}${Platform.pathSeparator}'
        'timetrack2${Platform.pathSeparator}data',
  );
}

/// LAN 设备互通引擎（主机手动启动）。
final lanStoreProvider = Provider<LanStore>((ref) {
  final store = LanStore(
    bundleRepository: ref.watch(syncBundleRepositoryProvider),
    peerStore: SyncPeerStore(database: ref.watch(appDatabaseProvider)),
    database: ref.watch(appDatabaseProvider),
    dataRevision: ref.watch(dataRevisionStoreProvider),
    appVersion: ref.watch(currentVersionProvider),
  );
  ref.onDispose(store.dispose);
  return store;
});

/// 前台应用追踪引擎（轮询规则 → 自动切换活动）。
final trackingStoreProvider = Provider<TrackingStore>((ref) {
  final settings = ref.watch(settingsStoreProvider);
  final store = TrackingStore(
    rules: ref.watch(trackingRuleRepositoryProvider),
    timer: ref.watch(domainStoresProvider).timer,
    dataRevision: ref.watch(dataRevisionStoreProvider),
    clock: ref.watch(clockStoreProvider),
    now: ref.watch(nowProvider),
    detector: ref.watch(foregroundDetectorProvider),
    pollInterval: const Duration(seconds: 5),
    trackingEnabled: () =>
        settings.current?.backgroundTrackingEnabled ?? false,
  );
  ref.onDispose(store.dispose);
  return store;
});

/// 命令分发器（铁律 7：UI/快捷键/深链/AI 统一入口）。
final commandDispatcherProvider = Provider<CommandDispatcher>((ref) {
  final domain = ref.watch(domainStoresProvider);
  return CommandDispatcher(
    undo: ref.watch(undoStoreProvider),
    timer: domain.timer,
    sync: ref.watch(syncStoreProvider),
    update: ref.watch(updateStoreProvider),
    category: domain.category,
    activity: domain.activity,
    tracking: ref.watch(trackingStoreProvider),
    activities: ref.watch(activityRepositoryProvider),
    fileInterop: ref.watch(fileInteropServiceProvider),
    database: ref.watch(appDatabaseProvider),
    dataRevision: ref.watch(dataRevisionStoreProvider),
    now: ref.watch(nowProvider),
  );
});

/// 提醒引擎（依赖指令通道，「停止」经 stop 指令分发）。
final reminderStoreProvider = Provider<ReminderStore>((ref) {
  final activityRepository = ref.watch(activityRepositoryProvider);
  final store = ReminderStore(
    clock: ref.watch(clockStoreProvider),
    settings: ref.watch(settingsStoreProvider),
    timer: ref.watch(domainStoresProvider).timer,
    isUnassignedActivity: activityRepository.activityIdIsUnassigned,
    dispatch: ref.watch(commandDispatcherProvider).dispatch,
    now: ref.watch(nowProvider),
  );
  ref.onDispose(store.dispose);
  return store;
});

/// 启动编排（seed → 跨日滚转/归一化 → 三 store 加载 → 静默更新/清理）。
///
/// 取代 `AppStore.init`；`main` 等待本 provider 完成后再挂载 UI，失败仍走
/// 现有启动错误页。`runStartupChecks = false` 时跳过网络/清理（测试）。
final startupProvider = FutureProvider<void>((ref) async {
  final activities = ref.watch(activityRepositoryProvider);
  final entries = ref.watch(timeEntryRepositoryProvider);
  final domain = ref.watch(domainStoresProvider);
  await activities.seedActivities();
  await entries.rolloverRunningEntriesIfNeeded();
  await entries.normalizeStoredCrossDayEntries();
  await domain.category.reload();
  await domain.settings.reload();
  await domain.timer.refresh();
  if (!ref.watch(runStartupChecksProvider)) return;
  unawaited(
    ref
        .watch(updateStoreProvider)
        .check()
        .catchError(
          (Object _) => const AppFailure<UpdateCheckResult>('启动更新检查失败'),
        ),
  );
  unawaited(
    ref
        .watch(syncStoreProvider)
        .runCleanupIfDue()
        .catchError((Object _) => const AppFailure<void>('启动清理失败')),
  );
});




