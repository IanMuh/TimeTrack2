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
    this.pageSize = 999, // 与网关上限对齐（hasMore +1 探测不被服务端截断）
    this.pushBatchSize = 100,
  })  : assert(pageSize > 0, 'pageSize 必须为正'),
        assert(pushBatchSize > 0, 'pushBatchSize 必须为正');

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
    // 同步开始时刻（空全量同步的兜底游标基准）：同步期间新建行的 updated_at
    // 必然晚于该值，不会漏；用结束时刻墙钟兜底才会吞掉同步期间新建的行。
    final startedAt = DateTime.now();
    try {
      // 游标按 userId 分区：共享设备切换用户后不得复用上一用户游标
      //（否则增量窗口晚于新用户远端最新更新，拉取/推送永久漏行）。
      final statusResult = await statusStore.read(userId: userId);
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
      // 网关 fetchRowsSince 已按 user_id=userId 过滤：返回行必属当前用户，
      // 直接 LWW 应用——**不做本地归属跳过**（共享设备上前一用户遗留本地
      // 单例行时，若因本地归属他人而跳过，当前用户自己的远端配置永远拉
      // 不下来）。
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
      // 只推送属于当前用户（含未归属 null）的行：共享设备上前一用户遗留的
      // 本地行（userId != 当前用户）不改归属、不推送（网关按当前用户查不到、
      // RLS 也会拒绝——防跨用户数据污染，与 profile_settings 推送归属校验对称）。
      // 累加实际推送行的最大 updated_at（pushedMax）供游标推进覆盖。
      DateTime? pushedMax;
      var activitiesPush = await _pushTable(
        userId: userId,
        since: since,
        table: RemoteTables.activities,
        localRows: (await activities.activitiesSince(since ?? DateTime(0)))
            .requireValue()
            .where((a) => a.userId == null || a.userId == userId)
            .map((a) => _withUserId(a, userId).toMap())
            .toList(),
      );
      pushedRows += activitiesPush.count;
      pushedMax = _laterOf(pushedMax, activitiesPush.maxUpdatedAt);
      var categoriesPush = await _pushTable(
        userId: userId,
        since: since,
        table: RemoteTables.categories,
        localRows: (await categories.categoriesSince(since ?? DateTime(0)))
            .requireValue()
            .where((c) => c.userId == null || c.userId == userId)
            .map((c) => _withUserId(c, userId).toMap())
            .toList(),
      );
      pushedRows += categoriesPush.count;
      pushedMax = _laterOf(pushedMax, categoriesPush.maxUpdatedAt);
      var linksPush = await _pushTable(
        userId: userId,
        since: since,
        table: RemoteTables.links,
        localRows: (await categories.linksSince(since ?? DateTime(0)))
            .requireValue()
            .where((l) => l.userId == null || l.userId == userId)
            .map((l) => _withUserId(l, userId).toMap())
            .toList(),
      );
      pushedRows += linksPush.count;
      pushedMax = _laterOf(pushedMax, linksPush.maxUpdatedAt);
      var entriesPush = await _pushTable(
        userId: userId,
        since: since,
        table: RemoteTables.timeEntries,
        localRows: (await timeEntries.entriesSince(since ?? DateTime(0)))
            .where((e) => e.userId == null || e.userId == userId)
            .map((e) => _withUserId(e, userId).toMap())
            .toList(),
      );
      pushedRows += entriesPush.count;
      pushedMax = _laterOf(pushedMax, entriesPush.maxUpdatedAt);
      var logsPush = await _pushTable(
        userId: userId,
        since: since,
        table: RemoteTables.actionLogs,
        localRows: (await actionLogs.logsSince(since ?? DateTime(0)))
            .requireValue()
            .where((l) => l.userId == null || l.userId == userId)
            .map((l) => _withUserId(l, userId).toMap())
            .toList(),
      );
      pushedRows += logsPush.count;
      pushedMax = _laterOf(pushedMax, logsPush.maxUpdatedAt);
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
        // 包含式语义（与其它表 xxxSince 的 >= 一致）：相等时间戳照常写回
        //（LWW upsert 幂等；严格 isAfter 会让恰等于游标的更新永久跳过不推）。
        if (since == null || !localSettings.updatedAt.isBefore(since)) {
          final settingsPush = await _pushTable(
            userId: userId,
            since: since,
            table: RemoteTables.profileSettings,
            localRows: [
              _withUserId(localSettings, userId).toMap(),
            ],
            idKey: 'user_id',
          );
          pushedRows += settingsPush.count;
          pushedMax = _laterOf(pushedMax, settingsPush.maxUpdatedAt);
        }
      }

      // 全部成功 → 推进游标 + 清错误 + 记目标。
      // 游标须覆盖本轮**实际处理**的最大行 updated_at（拉取 maxSeen 与
      // 推送 pushedMax 取大）：防同步期间新建/更新的本地行（updated_at 晚于
      // 游标）未被覆盖而下一轮永久漏推。
      // 空全量同步（since=null 且本轮无拉取无推送）用**同步开始时刻**兜底：
      // 同步期间新建行的 updated_at 必然晚于该值（不会漏），同时清除上次
      // 失败遗留的 lastError、结束"永远全量重扫"状态。
      // **上限截断**：maxSeen 来自远端行时间戳（另一设备时钟），远端时钟快于
      // 本机 >5 分钟时 future 游标会被 markSuccess 拒绝（每轮全量重拉+永久
      // 失败），或 5 分钟内被写入 future 游标导致本地新行永久漏推——截断到
      // startedAt 防未来游标毒化。注：wasFullSync=false 时 since 必非 null，
      // wasFullSync=true 时 startedAt 非 null——effectiveCursor 恒非 null。
      final processedMax = _laterOf(maxSeen, pushedMax);
      final effectiveCursor = processedMax != null && processedMax.isAfter(startedAt)
          ? startedAt
          : (processedMax ?? (wasFullSync ? startedAt : since));
      final markResult = await statusStore.markSuccess(
        syncedAt: effectiveCursor,
        target: SyncTarget.supabase,
        userId: userId,
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
      // markFailure 自身失败不得掩盖原始同步异常（防 catch 内二次抛错）。
      try {
        await statusStore.markFailure('同步失败：$e', userId: userId);
      } catch (_) {
        // 状态写入失败：不影响原始错误返回。
      }
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
  /// [skipWhen]：返回 true 时跳过该行——**不计入 count/maxSeen**（防归属
  /// 冲突等跳过场景下游标推进吞掉增量窗口）。
  Future<({int count, DateTime? maxSeen})> _pullTable({
    required String table,
    required String userId,
    required DateTime? since,
    required Future<AppResult<void>> Function(Map<String, Object?> row) apply,
    Future<bool> Function(Map<String, Object?> row)? skipWhen,
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
        // 防御性归属校验：不信任网关过滤（RLS 误配/实现缺陷可能返回他人行）——
        // 归属他人的行跳过，且不计 count/maxSeen（防他人软删墓碑按"删除永远赢"
        // 删掉本地行、或游标吞掉归属冲突增量窗口）。
        final rowUser = row['user_id'];
        if (rowUser is String && rowUser != userId) {
          continue;
        }
        if (skipWhen != null && await skipWhen(row)) {
          continue; // 跳过：不计 count，也不推进 maxSeen。
        }
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

  /// 推送单表：批量查远端 updated_at 过滤更旧行 → 批量 upsert。
  ///
  /// 返回推送行数与**实际推送行的最大 updated_at**（游标推进基准——防同步
  /// 期间新建/更新的本地行因游标未覆盖而永久漏推）。
  /// [idKey] 为行身份字段（默认 `id`；profile_settings 用 `user_id`——配置表
  /// 无 id 键，云端主键即 user_id）。
  Future<({int count, DateTime? maxUpdatedAt})> _pushTable({
    required String table,
    required String userId,
    required DateTime? since,
    required List<Map<String, Object?>> localRows,
    String idKey = 'id',
  }) async {
    var pushed = 0;
    DateTime? maxUpdatedAt;
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
        // 远端**严格更新**（updated_at 更晚）才跳过；相等时间戳照常写回——
        // "相等"不保证内容一致（远端时间戳可能被截断/同精度修改），
        // 让 LWW upsert 决胜而不是静默丢弃本地更新。
        if (remoteAt != null && remoteAt.isAfter(localUpdatedAt)) continue;
        toPush.add(row);
        maxUpdatedAt = _laterOf(maxUpdatedAt, localUpdatedAt);
      }
      if (toPush.isNotEmpty) {
        await gateway.upsertRows(table: table, userId: userId, rows: toPush);
      }
      pushed += toPush.length;
    }
    return (count: pushed, maxUpdatedAt: maxUpdatedAt);
  }

  /// 补填 user_id：**仅**对 userId == null（未登录时创建）的行归属当前用户。
  ///
  /// 归属他人的遗留行（共享设备上前一登录用户留下的本地行）**不改归属**——
  /// 推送时行身份仍指向他人 userId，网关 eq(user_id, 当前用户) 查不到该行、
  /// RLS 也会拒绝写入（防跨用户数据污染）；本地该行由用户显式处理（后续
  /// 阶段提供多用户数据隔离/清除入口）。
  T _withUserId<T>(T model, String userId) {
    return switch (model) {
      final Activity a when a.userId == null =>
        a.copyWith(userId: userId) as T,
      final ActivityCategory c when c.userId == null =>
        c.copyWith(userId: userId) as T,
      final ActivityCategoryLink l when l.userId == null =>
        l.copyWith(userId: userId) as T,
      final TimeEntry e when e.userId == null =>
        e.copyWith(userId: userId) as T,
      final ActionLog l when l.userId == null =>
        l.copyWith(userId: userId) as T,
      final ProfileSettings s when s.userId == null =>
        s.copyWith(userId: userId) as T,
      _ => model,
    };
  }
}
