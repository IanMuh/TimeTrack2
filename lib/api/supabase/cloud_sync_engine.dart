/// 云同步编排：**先拉后推** + 行级 LWW（复用阶段 1 仓储）+ 游标语义。
///
/// 流程（计划模块 2c）：
/// 1. 读游标 `lastSuccessfulSyncAt`（null = 从未同步 → 全量）；
/// 2. **拉取**：逐表按 `(user_id, updated_at) >= since` 分页 1000 → 逐行
///    `replaceXxxIfRemoteNewer`（复用仓储 LWW，删除永远赢）；
/// 3. **推送**：逐表本地 `xxxSince(since)` → 批量查远端 updated_at 过滤
///    **更旧行**（远端更新则跳过）→ 批量 100 upsert（幂等）；
/// 4. 全部成功 → `markSuccess(now, target: supabase)` 推进游标 + 清错误；
///    任一失败 → `markFailure(msg)`（**不清游标**，下次从上次成功点继续）。
///
/// 表顺序与 FK 依赖方向一致：activities → activity_categories →
/// activity_category_links → time_entries → action_logs → profile_settings。
library;

import '../../data/database/app_database.dart' hide ProfileSettings;
import '../../data/repositories/action_log_repository.dart';
import '../../data/repositories/activity_repository.dart';
import '../../data/repositories/category_repository.dart';
import '../../data/repositories/settings_repository.dart';
import '../../data/repositories/time_entry_repository.dart';
import '../../utils/result.dart';
import '../../viewmodels/action_log.dart';
import '../../viewmodels/activity.dart';
import '../../viewmodels/activity_category.dart';
import '../../viewmodels/profile_settings.dart';
import '../../viewmodels/time_entry.dart';
import 'remote_tables.dart';
import 'sync_backend.dart';
import 'sync_status_store.dart';

/// 云端表名（与 schema.sql 一致）。
abstract final class RemoteTables {
  static const activities = 'activities';
  static const categories = 'activity_categories';
  static const links = 'activity_category_links';
  static const timeEntries = 'time_entries';
  static const actionLogs = 'action_logs';
  static const profileSettings = 'profile_settings';
}

/// 云同步引擎（依赖 [RemoteTableGateway] 与本地仓储，可注入 mock 网关测试）。
class CloudSyncEngine {
  CloudSyncEngine({
    required this.database,
    required this.gateway,
    required this.statusStore,
    required this.activities,
    required this.categories,
    required this.timeEntries,
    required this.actionLogs,
    required this.settings,
    this.pageSize = 1000,
    this.pushBatchSize = 100,
  });

  final AppDatabase database;
  final RemoteTableGateway gateway;
  final SyncStatusStore statusStore;

  final ActivityRepository activities;
  final CategoryRepository categories;
  final TimeEntryRepository timeEntries;
  final ActionLogRepository actionLogs;
  final SettingsRepository settings;

  final int pageSize;
  final int pushBatchSize;

  /// 在途同步锁：防并发 syncNow 交错拉推/回退游标（后结束的旧同步不得用更早
  /// 的时间戳覆盖新同步写入的游标）。并发调用直接返回"同步进行中"。
  bool _inFlight = false;

  /// 一次完整同步（先拉后推）。返回报告；失败返回可读原因。
  ///
  /// [userId] 由调用方（登录会话）传入；本地行缺失 user_id 时推送补填。
  /// 游标推进为**本次实际处理的最大行 updated_at**（而非墙钟）——防拉取后、
  /// 游标写入前远端插入的行（updated_at < 墙钟）被永久漏同步。
  Future<AppResult<SyncReport>> syncNow({required String userId}) async {
    if (_inFlight) {
      return const AppFailure('同步正在进行中，请稍后再试');
    }
    _inFlight = true;
    try {
      final statusResult = await statusStore.read();
      if (statusResult case AppFailure<SyncStatus> failure) {
        return AppFailure('读取同步状态失败：${failure.message}');
      }
      final status = statusResult.requireValue();
      final since = status.lastSuccessfulSyncAt;
      final wasFullSync = since == null;

      var pulledRows = 0;
      var pushedRows = 0;
      // 本次拉取所见的最大 updated_at（游标推进基准；null = 本轮无拉取）。
      DateTime? maxSeen;

      // ---- 拉取（先拉）----
      final activitiesPull =
          await _pullTable(
            table: RemoteTables.activities,
            userId: userId,
            since: since,
            apply: (row) => activities.replaceIfRemoteNewer(Activity.fromMap(row)),
          );
      pulledRows += activitiesPull.count;
      maxSeen = _laterOf(maxSeen, activitiesPull.maxSeen);
      final categoriesPull =
          await _pullTable(
            table: RemoteTables.categories,
            userId: userId,
            since: since,
            apply: (row) => categories
                .replaceCategoryIfRemoteNewer(ActivityCategory.fromMap(row)),
          );
      pulledRows += categoriesPull.count;
      maxSeen = _laterOf(maxSeen, categoriesPull.maxSeen);
      final linksPull =
          await _pullTable(
            table: RemoteTables.links,
            userId: userId,
            since: since,
            apply: (row) => categories.replaceLinkIfRemoteNewer(
                ActivityCategoryLink.fromMap(row)),
          );
      pulledRows += linksPull.count;
      maxSeen = _laterOf(maxSeen, linksPull.maxSeen);
      final entriesPull =
          await _pullTable(
            table: RemoteTables.timeEntries,
            userId: userId,
            since: since,
            apply: (row) =>
                timeEntries.replaceIfRemoteNewer(TimeEntry.fromMap(row)),
          );
      pulledRows += entriesPull.count;
      maxSeen = _laterOf(maxSeen, entriesPull.maxSeen);
      final logsPull =
          await _pullTable(
            table: RemoteTables.actionLogs,
            userId: userId,
            since: since,
            apply: (row) => actionLogs.replaceIfRemoteNewer(ActionLog.fromMap(row)),
          );
      pulledRows += logsPull.count;
      maxSeen = _laterOf(maxSeen, logsPull.maxSeen);
      // profile_settings 单例行（每用户至多一行；分页逻辑与其余表一致）。
      final settingsPull =
          await _pullTable(
            table: RemoteTables.profileSettings,
            userId: userId,
            since: since,
            apply: (row) async {
              final applied = await settings.applyIfRemoteNewer(
                ProfileSettings.fromMap(row),
              );
              if (applied case AppFailure<ProfileSettings> failure) {
                throw StateError('拉取表 profile_settings 失败：${failure.message}');
              }
              return const AppSuccess(null);
            },
          );
      pulledRows += settingsPull.count;
      maxSeen = _laterOf(maxSeen, settingsPull.maxSeen);

      // ---- 推送（后推）----
      pushedRows += await _pushTable(
        userId: userId,
        since: since,
        table: RemoteTables.activities,
        localRows: (await activities.activitiesSince(since ?? DateTime(0)))
            .requireValue()
            .map((a) => _withUserId(a, userId).toMap())
            .toList(),
      );
      pushedRows += await _pushTable(
        userId: userId,
        since: since,
        table: RemoteTables.categories,
        localRows: (await categories.categoriesSince(since ?? DateTime(0)))
            .requireValue()
            .map((c) => _withUserId(c, userId).toMap())
            .toList(),
      );
      pushedRows += await _pushTable(
        userId: userId,
        since: since,
        table: RemoteTables.links,
        localRows: (await categories.linksSince(since ?? DateTime(0)))
            .requireValue()
            .map((l) => _withUserId(l, userId).toMap())
            .toList(),
      );
      pushedRows += await _pushTable(
        userId: userId,
        since: since,
        table: RemoteTables.timeEntries,
        localRows: (await timeEntries.entriesSince(since ?? DateTime(0)))
            .map((e) => _withUserId(e, userId).toMap())
            .toList(),
      );
      pushedRows += await _pushTable(
        userId: userId,
        since: since,
        table: RemoteTables.actionLogs,
        localRows: (await actionLogs.logsSince(since ?? DateTime(0)))
            .requireValue()
            .map((l) => _withUserId(l, userId).toMap())
            .toList(),
      );
      // profile_settings：仅当本地已有记录、且属于当前用户（或从未归属任何用户）
      // 才推送——防把其他用户遗留的单例配置串写进当前用户远端行。
      // 同时按 since 过滤：本地配置更新早于游标（上轮已同步）则不重复推送。
      final settingsRow = await (database.select(database.profileSettings)
            ..where((t) => t.id.equals(1)))
          .getSingleOrNull();
      if (settingsRow != null &&
          (settingsRow.userId == null || settingsRow.userId == userId)) {
        final localSettings =
            (await settings.settings()).requireValue();
        if (since == null || localSettings.updatedAt.isAfter(since)) {
          pushedRows += await _pushTable(
            userId: userId,
            since: since,
            table: RemoteTables.profileSettings,
            localRows: [
              _withUserId(localSettings, userId).toMap(),
            ],
            idKey: 'user_id',
          );
        }
      }

      // 全部成功 → 推进游标（本次实际处理的最大行 updated_at；无拉取时保持
      // 原游标）+ 清错误 + 记目标。
      final effectiveCursor = maxSeen ?? since ?? DateTime.now();
      final markResult = await statusStore.markSuccess(
        syncedAt: effectiveCursor,
        target: SyncTarget.supabase,
      );
      if (markResult case AppFailure<void> failure) {
        return AppFailure('保存同步游标失败：${failure.message}');
      }
      return AppSuccess(SyncReport(
        target: SyncTarget.supabase,
        wasFullSync: wasFullSync,
        pulledRows: pulledRows,
        pushedRows: pushedRows,
      ));
    } catch (e) {
      // 任何未预期异常：记失败（不清游标），返回可读原因。
      await statusStore.markFailure('同步失败：$e');
      return AppFailure('同步失败：$e');
    } finally {
      _inFlight = false;
    }
  }

  // ---------------------------------------------------------------------------
  // 内部
  // ---------------------------------------------------------------------------

  /// 拉取单表：分页直到无更多，逐行 LWW 应用。
  ///
  /// 返回应用行数与**本轮所见最大 updated_at**（游标推进基准——防拉取后、
  /// 游标写入前远端插入的行被永久漏同步）。
  Future<({int count, DateTime? maxSeen})> _pullTable({
    required String table,
    required String userId,
    required DateTime? since,
    required Future<AppResult<void>> Function(Map<String, Object?> row) apply,
  }) async {
    var page = 0;
    var count = 0;
    DateTime? maxSeen;
    while (true) {
      final result = await gateway.fetchRowsSince(
        table: table,
        userId: userId,
        since: since,
        pageSize: pageSize,
        page: page,
      );
      for (final row in result.rows) {
        final applied = await apply(row);
        if (applied case AppFailure<void> failure) {
          throw StateError('拉取表 $table 失败：${failure.message}');
        }
        count += 1;
        final rowUpdatedAt = DateTime.parse(row['updated_at']! as String);
        maxSeen = _laterOf(maxSeen, rowUpdatedAt);
      }
      if (!result.hasMore) break;
      page += 1;
    }
    return (count: count, maxSeen: maxSeen);
  }

  static DateTime? _laterOf(DateTime? a, DateTime? b) {
    if (a == null) return b;
    if (b == null) return a;
    return a.isAfter(b) ? a : b;
  }

  /// 推送单表：批量查远端 updated_at 过滤更旧行 → 批量 upsert；返回推送行数。
  ///
  /// [idKey] 为行身份字段（默认 `id`；profile_settings 用 `user_id`——配置表
  /// 无 id 键，云端主键即 user_id）。
  Future<int> _pushTable({
    required String table,
    required String userId,
    required DateTime? since,
    required List<Map<String, Object?>> localRows,
    String idKey = 'id',
  }) async {
    var pushed = 0;
    for (var start = 0; start < localRows.length; start += pushBatchSize) {
      final batch = localRows.sublist(
        start,
        (start + pushBatchSize) < localRows.length
            ? start + pushBatchSize
            : localRows.length,
      );
      final ids = batch.map((row) => row[idKey]! as String).toList();
      final remoteUpdatedAt = await gateway.fetchRemoteUpdatedAt(
        table: table,
        userId: userId,
        ids: ids,
        idKey: idKey,
      );
      final toPush = <Map<String, Object?>>[];
      for (final row in batch) {
        final localUpdatedAt = DateTime.parse(row['updated_at']! as String);
        final remoteAt = remoteUpdatedAt[row[idKey]];
        // 远端**不早于**本地即跳过（含相等时间戳——先拉后推中本轮刚拉取的
        // 行保留远端 updatedAt，相等即已是最新，无需重复写回；LWW upsert
        // 幂等，不丢数据）。
        if (remoteAt != null && !remoteAt.isBefore(localUpdatedAt)) continue;
        toPush.add(row);
      }
      if (toPush.isNotEmpty) {
        await gateway.upsertRows(table: table, userId: userId, rows: toPush);
      }
      pushed += toPush.length;
    }
    return pushed;
  }

  /// 补填 user_id（本地未登录时创建的行推送前归属当前用户）。
  T _withUserId<T>(T model, String userId) {
    return switch (model) {
      final Activity a when a.userId != userId =>
        a.copyWith(userId: userId) as T,
      final ActivityCategory c when c.userId != userId =>
        c.copyWith(userId: userId) as T,
      final ActivityCategoryLink l when l.userId != userId =>
        l.copyWith(userId: userId) as T,
      final TimeEntry e when e.userId != userId =>
        e.copyWith(userId: userId) as T,
      final ActionLog l when l.userId != userId =>
        l.copyWith(userId: userId) as T,
      final ProfileSettings s when s.userId != userId =>
        s.copyWith(userId: userId) as T,
      _ => model,
    };
  }
}
