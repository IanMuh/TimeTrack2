/// 应用级聚合 store（模块 3d②）：组装全部 store + 启动编排。
///
/// 设计：
/// - **只编排不转发通知**（防 rebuild 风暴——框架调研结论）：AppStore 持有
///   各 store 引用，UI 直接监听叶子 store，AppStore 自身不转发 notify；
/// - **启动编排**（[init]）：seed 活动 → 滚转/归一化 → 各 store reload →
///   静默更新检查（lastCheckedManifestVersion 限频）→ 清理限频（SyncStore
///   runCleanupIfDue）→ 登录态恢复（SyncStore 订阅自驱）；
/// - **可注入测试**：[create] 接受可选依赖（backend/now/windowsInstaller 等），
///   测试用内存库 + fake 后端绕过真实副作用。
library;

import 'dart:async';
import 'dart:io' show Directory, Platform;

import '../api/supabase/sync_backend.dart';
import '../api/supabase/sync_status_store.dart';
import '../api/update/update_downloader.dart';
import '../api/update/update_manifest_service.dart';
import '../api/update/update_verifier.dart';
import '../data/cleanup/cleanup_service.dart';
import '../data/database/app_database.dart' hide ProfileSettings;
import '../data/interop/file_interop_service.dart';
import '../data/repositories/action_log_repository.dart';
import '../data/repositories/activity_repository.dart';
import '../data/repositories/category_repository.dart';
import '../data/repositories/settings_repository.dart';
import '../data/repositories/stats_repository.dart';
import '../data/repositories/time_entry_repository.dart';
import '../data/repositories/tracking_rule_repository.dart';
import '../data/sync/sync_bundle_repository.dart';
import '../data/update/windows_installer.dart';
import '../utils/result.dart';
import 'category_store.dart';
import 'clock_store.dart';
import 'command_dispatcher.dart';
import 'data_revision.dart';
import 'settings_store.dart';
import 'stats_store.dart';
import 'sync_store.dart';
import 'timeline_store.dart';
import 'timer_store.dart';
import 'today_store.dart';
import 'tracking_store.dart';
import 'undo_store.dart';
import 'update_store.dart';

/// 应用级聚合 store。
class AppStore {
  AppStore._({
    required this.database,
    required this.activities,
    required this.undo,
    required this.clock,
    required this.dataRevision,
    required this.timer,
    required this.category,
    required this.settings,
    required this.today,
    required this.timeline,
    required this.stats,
    required this.sync,
    required this.update,
    required this.tracking,
    required this.dispatcher,
    required this.fileInterop,
  });

  final AppDatabase database;

  /// 活动仓储（启动 seed 与指令活动名解析共用）。
  final ActivityRepository activities;

  final UndoStore undo;
  final ClockStore clock;
  final DataRevision dataRevision;
  final TimerStore timer;
  final CategoryStore category;
  final SettingsStore settings;
  final TodayStore today;
  final TimelineStore timeline;
  final StatsStore stats;
  final SyncStore sync;
  final UpdateStore update;
  final TrackingStore tracking;
  final CommandDispatcher dispatcher;
  final FileInteropService fileInterop;

  /// 组装全部 store 并执行启动编排。
  ///
  /// 可注入依赖（测试用内存库 + fake 后端绕过真实副作用）：
  /// [backend]（SyncBackend，默认 Noop 离线）、[now]、[windowsInstaller]、
  /// [updateManifestUrl]。默认值指向真实配置。
  static Future<AppStore> create({
    required AppDatabase database,
    SyncBackend? backend,
    DateTime Function()? now,
    WindowsInstaller? windowsInstaller,
    Uri? updateManifestUrl,
    String currentVersion = '0.1.0',
    bool runStartupChecks = true,
  }) async {
    // ---- 仓储层 ----
    final activities = ActivityRepository(database: database);
    final categories = CategoryRepository(database: database);
    final settingsRepo = SettingsRepository(database: database);
    final entries = TimeEntryRepository(
      database: database,
      activityRepository: activities,
      settingsRepository: settingsRepo,
    );
    final rules = TrackingRuleRepository(database: database);
    final syncStatus = SyncStatusStore(database: database);
    final cleanup = CleanupService(database: database);
    final syncBundleRepo = SyncBundleRepository(
      database: database,
      activities: activities,
      categories: categories,
      timeEntries: entries,
      actionLogs: ActionLogRepository(database: database),
      settings: settingsRepo,
    );
    final fileInterop = FileInteropService(syncBundleRepository: syncBundleRepo);

    // ---- 基础 store ----
    final undo = UndoStore();
    final revision = DataRevision();
    final clock = ClockStore();

    // ---- 领域 store ----
    final timer = TimerStore(
      entries: entries,
      undo: undo,
      clock: clock,
      dataRevision: revision,
    );
    final category = CategoryStore(
      categories: categories,
      undo: undo,
      dataRevision: revision,
    );
    final settings = SettingsStore(
      settings: settingsRepo,
      undo: undo,
      dataRevision: revision,
    );
    final today = TodayStore(
      entries: entries,
      dataRevision: revision,
      clock: clock,
      now: now,
    );
    final timeline = TimelineStore(entries: entries, dataRevision: revision);
    final stats = StatsStore(
      repository: StatsRepository(
        activities: activities,
        categories: categories,
        entries: entries,
      ),
      dataRevision: revision,
    );

    // ---- 编排 store ----
    final sync = SyncStore(
      backend: backend ?? NoopSyncBackend(),
      syncStatus: syncStatus,
      cleanup: cleanup,
      dataRevision: revision, // 三类来源收口：同步成功后 bump
    );
    final manifestService = UpdateManifestService(
      database: database,
      currentVersion: currentVersion,
      manifestUrl: updateManifestUrl,
    );
    final update = UpdateStore(
      manifestService: manifestService,
      verifier: UpdateVerifier(downloader: UpdateDownloader()),
      windowsInstaller: windowsInstaller ?? _defaultWindowsInstaller(),
      database: database,
    );
    final tracking = TrackingStore(
      rules: rules,
      timer: timer,
      dataRevision: revision,
      clock: clock,
      now: now,
    );

    final dispatcher = CommandDispatcher(
      undo: undo,
      timer: timer,
      sync: sync,
      update: update,
      category: category,
      tracking: tracking,
      activities: activities,
      fileInterop: fileInterop,
      database: database,
      dataRevision: revision, // 三类来源收口：import 成功后 bump
    );

    final store = AppStore._(
      database: database,
      activities: activities,
      undo: undo,
      clock: clock,
      dataRevision: revision,
      timer: timer,
      category: category,
      settings: settings,
      today: today,
      timeline: timeline,
      stats: stats,
      sync: sync,
      update: update,
      tracking: tracking,
      dispatcher: dispatcher,
      fileInterop: fileInterop,
    );
    await store.init(runStartupChecks: runStartupChecks);
    return store;
  }

  /// 启动编排（create 末尾调用；测试也可显式重跑）。
  ///
  /// [runStartupChecks] = false：跳过网络触发的更新检查与清理编排
  ///（测试用内存库避免真实副作用/超时）。
  Future<void> init({bool runStartupChecks = true}) async {
    // 1. seed 活动（首次启动建 4 个默认活动）+ 运行条目滚转/归一化。
    await activities.seedActivities();
    await timer.entries.rolloverRunningEntriesIfNeeded();
    await timer.entries.normalizeStoredCrossDayEntries();
    // 2. 各 store 加载缓存。
    await category.reload();
    await settings.reload();
    await today.loadToday();
    await timer.refresh();
    if (!runStartupChecks) return; // 测试路径：跳过网络/清理编排
    // 3. 静默更新检查（失败静默，不阻塞启动）。
    unawaited(update.check().catchError(
      (Object e) => const AppFailure<UpdateCheckResult>('启动更新检查失败'),
    ));
    // 4. 清理限频（SyncStore 内部 last_cleanup_at 限频）。
    unawaited(sync.runCleanupIfDue().catchError(
      (Object e) => const AppFailure<void>('启动清理失败'),
    ));
    // 5. 登录态恢复：SyncStore 构造时已订阅 authStateStream（登录触发
    //    自动云同步），无需额外动作。
  }

  /// 默认 Windows 安装器（阶段 4 装配时 main 注入真实目录；此处用当前
  /// 运行目录占位——仅保证组装可用，不承诺路径正确性）。
  static WindowsInstaller _defaultWindowsInstaller() {
    final base = Directory.current.path;
    return WindowsInstaller(
      programDir: base,
      dataDir: '$base${Platform.pathSeparator}data',
    );
  }

  /// 释放全部 store（退出/测试清理）。
  void dispose() {
    tracking.dispose();
    update.dispose();
    sync.dispose();
    stats.dispose();
    timeline.dispose();
    today.dispose();
    settings.dispose();
    category.dispose();
    timer.dispose();
    clock.dispose();
    dataRevision.dispose();
    undo.dispose();
  }
}
