/// 保留期清理服务（计划模块 2f + 保留不变式 #11）。
///
/// 职责（**触发编排归阶段 3 stores**，本层只做"一次清理做什么"）：
/// 1. **软删行物理删除**：6 张业务表（activities / time_entries /
///    tracking_rules / activity_categories / activity_category_links /
///    action_logs）中 `deleted_at` **严格早于** 保留期截止（默认 180 天）的
///    行物理删除；
/// 2. **sync 感知守卫**（保留不变式 #5 删除永远赢的落地边界）：仅物理删除
///    **已传播到远端**的墓碑——`deleted_at` 须严格早于全局同步游标
///    （`last_sync_at`）；从未同步的设备（无游标）保守跳过物理删除（防
///    "本地先清、远端未来全量推送时缺口"的语义漂移）；
///    **cutoff = min(保留期截止, 最近同步时刻)**——`deleted_at < cutoff`
///    **严格小于**：恰等于游标时刻的墓碑视为"同步窗口边缘"（是否已传播到
///    远端不确定），保守留待下一轮（下一轮同步后游标推进即满足条件）；
/// 3. **FK 引用完整性（r2 修正）**：`PRAGMA foreign_keys=ON` 下物理删除父行
///    会被仍存在的引用行阻塞（整事务回滚）——删除前先清理引用：
///    - 引用将被删活动父的**软删**子行（links/tracking_rules/time_entries，
///      任意超期——父已物理移除，子墓碑失去参照价值）一并删除；
///    - **存活**子行引用将删父 → **跳过删除该父**（宁可留待下一轮，不制造
///      悬空条目/不回滚全部）；
///    - 分类：引用将被删分类的行（**含软删**，防自引用 FK）`parent_id` 置
///      NULL（存活子升级根分类、软删子置空无害），再删超期分类行；
/// 4. **VACUUM 阈值驱动**（空间回收与 I/O 成本权衡）：单次物理删除超过
///    [AppConstants.cleanupVacuumThresholdRows] 行才执行 `VACUUM` +
///    `wal_checkpoint(TRUNCATE)`（全库重写成本高，小删除不触发）；VACUUM
///    失败不阻塞清理主流程（如实标记未执行，已完成的物理删除不回滚）；
/// 5. 完成后写 `last_cleanup_at`（供阶段 3 编排层限频）。
///
/// **保留期可配置接缝（B 形态）**：[retentionDays] 是读侧最终形态——
/// `app_metadata[deletedRetentionDays]` 优先、无值/非法回退
/// [AppConstants.defaultDeletedRetentionDays]；阶段 4 设置 UI 只加写入口，
/// 读侧零改动。
///
/// **VACUUM 事务边界**：SQLite 禁止在事务内 VACUUM——物理删除在单事务内，
/// VACUUM/checkpoint 在事务提交后执行。
library;

import 'package:drift/drift.dart';

import '../../constants/app_constants.dart';
import '../../constants/storage_keys.dart';
import '../../data/database/app_database.dart';
import '../repositories/repository_mappings.dart';
import '../../utils/result.dart';

/// 清理报告（结果视图，供阶段 3 编排展示/日志）。
class CleanupReport {
  const CleanupReport({
    required this.deletedByTable,
    required this.vacuumed,
    this.skippedDueToNoSync = false,
  });

  /// 各表物理删除行数（键为表名常量，见 [CleanupService.tableNames]）。
  final Map<String, int> deletedByTable;

  /// 本次是否执行了 VACUUM（物理删除超阈值才 true；VACUUM 失败如实为 false）。
  final bool vacuumed;

  /// 是否因"从未同步（无全局游标）"保守跳过物理删除。
  final bool skippedDueToNoSync;

  int get deletedTotal => deletedByTable.values.fold(0, (sum, n) => sum + n);
}

/// 保留期清理服务。
class CleanupService with RepositoryMappings {
  CleanupService({required this.database, int? vacuumThreshold})
    : _vacuumThreshold =
          vacuumThreshold ?? AppConstants.cleanupVacuumThresholdRows;

  final AppDatabase database;

  /// VACUUM 阈值（行）：物理删除超过此值才全库重建；测试注入小值。
  final int _vacuumThreshold;

  /// 清理涉及的 6 张业务表（含软删列；报告按此键名）。
  static const tableNames = <String>[
    'activityCategoryLinks',
    'trackingRules',
    'timeEntries',
    'actionLogs',
    'activityCategories',
    'activities',
  ];

  /// 读取保留期（天）：`app_metadata[deletedRetentionDays]` 优先（阶段 4 设置
  /// UI 写入），无值/非法/DB 异常回退 [AppConstants.defaultDeletedRetentionDays]。
  /// **读侧最终形态**——阶段 4 加可配置只改写侧。
  Future<int> retentionDays() async {
    try {
      final row =
          await (database.select(database.appMetadata)..where(
                (t) => t.key.equals(AppMetadataKeys.deletedRetentionDays),
              ))
              .getSingleOrNull();
      final parsed = row == null ? null : int.tryParse(row.value);
      if (parsed != null && parsed > 0) return parsed;
      return AppConstants.defaultDeletedRetentionDays;
    } catch (_) {
      // DB 异常回退默认（清理不可因配置读取失败而崩溃）。
      return AppConstants.defaultDeletedRetentionDays;
    }
  }

  /// 执行一次保留期清理。
  ///
  /// 流程：读保留期 → 读全局同步游标（sync 守卫）→ 单事务物理删除（引用表
  /// 软删行清理 + 存活引用者跳过 + 分类悬空处理）→ 事务外阈值驱动 VACUUM →
  /// 写 last_cleanup_at。
  Future<AppResult<CleanupReport>> run() async {
    try {
      final retention = await retentionDays();
      final now = DateTime.now().toUtc();

      // ---- sync 感知守卫（保留不变式 #5 落地）----
      // 全局游标 `last_sync_at`（未登录/未配置云同步时由 SyncStatusStore 写）。
      // 仅当"最近同步时刻"存在才允许物理删除——从未同步（无游标）保守跳过
      //（墓碑未经任何同步通道传播，先物理清除会造成本地与远端语义缺口）。
      final syncRow =
          await (database.select(database.appMetadata)
                ..where((t) => t.key.equals(AppMetadataKeys.lastSyncAt)))
              .getSingleOrNull();
      final lastSyncAt = syncRow == null
          ? null
          : DateTime.tryParse(syncRow.value);
      if (lastSyncAt == null) {
        return AppSuccess(
          const CleanupReport(
            deletedByTable: {},
            vacuumed: false,
          ).copyWithSkippedNoSync(),
        );
      }
      // **cutoff = min(保留期截止, 最近同步时刻)**：deleted_at **严格小于**
      // cutoff（r1/r2 统一）——恰等于游标时刻的墓碑视为同步窗口边缘（是否
      // 已传播不确定），保守留待下一轮；设备停止同步时 cutoff 恒等于游标、
      // 恰等于游标的行也永远满足 `< cutoff` 的上界（不会永久滞留）。
      final retentionCutoff = now.subtract(Duration(days: retention));
      final cutoff = lastSyncAt.isBefore(retentionCutoff)
          ? lastSyncAt
          : retentionCutoff;
      final cutoffStr = utcString(cutoff);

      // ---- 物理删除（单事务；FK 引用先清理、存活引用者跳过）----
      final deleted = <String, int>{};
      await database.transaction(() async {
        // 待删活动父 id 集（超期软删 activities）。
        final expiredActivityIds = await _expiredActivityIds(cutoffStr);
        // 引用表：删除引用将删父的**软删**行（任意超期——父已移除，子墓碑
        // 失去参照价值）+ 超期软删行。
        deleted['activityCategoryLinks'] = await _deleteExpiredLinks(
          cutoffStr,
          expiredActivityIds,
        );
        deleted['trackingRules'] = await _deleteExpiredTrackingRules(
          cutoffStr,
          expiredActivityIds,
        );
        deleted['timeEntries'] = await _deleteExpiredTimeEntries(
          cutoffStr,
          expiredActivityIds,
        );
        deleted['actionLogs'] = await _deleteExpiredActionLogs(cutoffStr);
        // 分类：引用将删分类集的行（**含软删**——软删子 parentId 指向将被
        // 物理删除的父同样触发自引用 FK）parent_id 置 NULL，再删超期分类。
        deleted['activityCategories'] = await _deleteExpiredCategories(
          cutoffStr,
          now,
        );
        // activities：可删 = 待删 − 存活引用者（防悬空条目、不回滚全部）。
        deleted['activities'] = await _deleteExpiredActivities(
          cutoffStr,
          expiredActivityIds,
        );
      });

      // ---- VACUUM（事务外 + 阈值驱动；SQLite 禁止事务内 VACUUM）----
      // **await + 失败隔离（r2）**：customStatement 返回 Future——不 await 会
      // 让 VACUUM 失败成为未处理异步错误（绕过 run() 的 catch、报告声称已
      // 重建而实际未执行）；VACUUM 失败不阻塞清理主流程（已完成的物理删除
      // 不回滚），如实标记未执行。
      var vacuumed = false;
      final total = deleted.values.fold(0, (a, b) => a + b);
      if (total > _vacuumThreshold) {
        try {
          await database.customStatement('VACUUM');
          // TRUNCATE 模式把 WAL 截断回主库（比 PASSIVE 更彻底地归还空间）。
          await database.customStatement('PRAGMA wal_checkpoint(TRUNCATE)');
          vacuumed = true;
        } catch (_) {
          // VACUUM 失败不阻塞清理主流程（已完成的物理删除不回滚）。
          vacuumed = false;
        }
      }

      // 记录清理时刻（供阶段 3 编排层限频）。
      await database
          .into(database.appMetadata)
          .insert(
            AppMetadataCompanion.insert(
              key: AppMetadataKeys.lastCleanupAt,
              value: utcString(now),
            ),
            mode: InsertMode.insertOrReplace,
          );

      return AppSuccess(
        CleanupReport(deletedByTable: deleted, vacuumed: vacuumed),
      );
    } catch (e) {
      return AppFailure('保留期清理失败：$e');
    }
  }

  // ---------------------------------------------------------------------------
  // 各表物理删除（软删行；deleted_at 为 utcString 存储，字典序 = 时间序；
  // 谓词统一：`deletedAt < cutoff` 严格小于）
  // ---------------------------------------------------------------------------

  /// activities：可删 = 待删集 − 存活引用者（3 张引用表中 `deleted_at IS NULL`
  /// 且 `activity_id` 指向待删父的行——父被物理删除会制造悬空条目，宁可留待
  /// 下一轮）。引用表的软删行已在各自方法中清理。
  Future<int> _deleteExpiredActivities(
    String cutoff,
    List<String> expiredIds,
  ) async {
    if (expiredIds.isEmpty) return 0;
    final surviving = <String>{}
      ..addAll(await _survivingTimeEntryReferents(expiredIds))
      ..addAll(await _survivingRuleReferents(expiredIds))
      ..addAll(await _survivingLinkReferents(expiredIds));
    final deletable = expiredIds
        .where((id) => !surviving.contains(id))
        .toList();
    if (deletable.isEmpty) return 0;
    final query = database.delete(database.activities)
      ..where((t) => t.id.isIn(deletable));
    return query.go();
  }

  /// 超期软删 activities 的 id 集（引用清理/存活引用者判定用）。
  Future<List<String>> _expiredActivityIds(String cutoff) async {
    final rows =
        await (database.selectOnly(database.activities)
              ..addColumns([database.activities.id])
              ..where(
                database.activities.deletedAt.isNotNull() &
                    database.activities.deletedAt.isSmallerThanValue(cutoff),
              ))
            .get();
    return rows.map((r) => r.read(database.activities.id)!).toList();
  }

  /// 存活 time_entries 引用者 id 集：`deleted_at IS NULL AND activity_id IN (ids)`。
  Future<Set<String>> _survivingTimeEntryReferents(List<String> ids) async {
    final rows =
        await (database.selectOnly(database.timeEntries)
              ..addColumns([database.timeEntries.activityId])
              ..where(
                database.timeEntries.deletedAt.isNull() &
                    database.timeEntries.activityId.isIn(ids),
              ))
            .get();
    return rows.map((r) => r.read(database.timeEntries.activityId)!).toSet();
  }

  /// 存活 tracking_rules 引用者（同 [_survivingTimeEntryReferents]）。
  Future<Set<String>> _survivingRuleReferents(List<String> ids) async {
    final rows =
        await (database.selectOnly(database.trackingRules)
              ..addColumns([database.trackingRules.activityId])
              ..where(
                database.trackingRules.deletedAt.isNull() &
                    database.trackingRules.activityId.isIn(ids),
              ))
            .get();
    return rows.map((r) => r.read(database.trackingRules.activityId)!).toSet();
  }

  /// 存活 links 引用者（同 [_survivingTimeEntryReferents]）。
  Future<Set<String>> _survivingLinkReferents(List<String> ids) async {
    final rows =
        await (database.selectOnly(database.activityCategoryLinks)
              ..addColumns([database.activityCategoryLinks.activityId])
              ..where(
                database.activityCategoryLinks.deletedAt.isNull() &
                    database.activityCategoryLinks.activityId.isIn(ids),
              ))
            .get();
    return rows
        .map((r) => r.read(database.activityCategoryLinks.activityId)!)
        .toSet();
  }

  /// timeEntries：删除引用将删父的软删行 + 超期软删行。
  Future<int> _deleteExpiredTimeEntries(
    String cutoff,
    List<String> expiredIds,
  ) async {
    var count = 0;
    if (expiredIds.isNotEmpty) {
      count +=
          await (database.delete(database.timeEntries)..where(
                (t) => t.deletedAt.isNotNull() & t.activityId.isIn(expiredIds),
              ))
              .go();
    }
    count +=
        await (database.delete(database.timeEntries)..where(
              (t) =>
                  t.deletedAt.isNotNull() &
                  t.deletedAt.isSmallerThanValue(cutoff),
            ))
            .go();
    return count;
  }

  /// trackingRules：同上。
  Future<int> _deleteExpiredTrackingRules(
    String cutoff,
    List<String> expiredIds,
  ) async {
    var count = 0;
    if (expiredIds.isNotEmpty) {
      count +=
          await (database.delete(database.trackingRules)..where(
                (t) => t.deletedAt.isNotNull() & t.activityId.isIn(expiredIds),
              ))
              .go();
    }
    count +=
        await (database.delete(database.trackingRules)..where(
              (t) =>
                  t.deletedAt.isNotNull() &
                  t.deletedAt.isSmallerThanValue(cutoff),
            ))
            .go();
    return count;
  }

  /// links：同上。
  Future<int> _deleteExpiredLinks(
    String cutoff,
    List<String> expiredIds,
  ) async {
    var count = 0;
    if (expiredIds.isNotEmpty) {
      count +=
          await (database.delete(database.activityCategoryLinks)..where(
                (t) => t.deletedAt.isNotNull() & t.activityId.isIn(expiredIds),
              ))
              .go();
    }
    count +=
        await (database.delete(database.activityCategoryLinks)..where(
              (t) =>
                  t.deletedAt.isNotNull() &
                  t.deletedAt.isSmallerThanValue(cutoff),
            ))
            .go();
    return count;
  }

  /// 分类：引用将删分类集的行（**含软删**——软删子 parentId 指向被物理删除
  /// 的父同样触发自引用 FK）parent_id 置 NULL，再删超期软删分类行。
  Future<int> _deleteExpiredCategories(String cutoff, DateTime now) async {
    final rows =
        await (database.selectOnly(database.activityCategories)
              ..addColumns([database.activityCategories.id])
              ..where(
                database.activityCategories.deletedAt.isNotNull() &
                    database.activityCategories.deletedAt.isSmallerThanValue(
                      cutoff,
                    ),
              ))
            .get();
    final expiredIds = rows
        .map((r) => r.read(database.activityCategories.id)!)
        .toList();
    if (expiredIds.isNotEmpty) {
      await (database.update(
        database.activityCategories,
      )..where((t) => t.parentId.isIn(expiredIds))).write(
        ActivityCategoriesCompanion(
          parentId: const Value(null),
          updatedAt: Value(utcString(now)),
        ),
      );
    }
    final query = database.delete(database.activityCategories)
      ..where(
        (t) => t.deletedAt.isNotNull() & t.deletedAt.isSmallerThanValue(cutoff),
      );
    return query.go();
  }

  /// actionLogs：无 FK references（activityId/entryId 为 nullable 无外键），
  /// 直接删超期软删行。
  Future<int> _deleteExpiredActionLogs(String cutoff) async {
    final query = database.delete(database.actionLogs)
      ..where(
        (t) => t.deletedAt.isNotNull() & t.deletedAt.isSmallerThanValue(cutoff),
      );
    return query.go();
  }
}

extension on CleanupReport {
  /// 从未同步跳过场景的构造（skippedDueToNoSync=true）。
  CleanupReport copyWithSkippedNoSync() => CleanupReport(
    deletedByTable: deletedByTable,
    vacuumed: vacuumed,
    skippedDueToNoSync: true,
  );
}
