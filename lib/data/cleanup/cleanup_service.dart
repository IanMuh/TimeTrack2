/// 保留期清理服务（计划模块 2f + 保留不变式 #11）。
///
/// 职责（**触发编排归阶段 3 stores**，本层只做"一次清理做什么"）：
/// 1. **软删行物理删除**：6 张业务表（activities / time_entries /
///    tracking_rules / activity_categories / activity_category_links /
///    action_logs）中 `deleted_at` 超保留期（默认 180 天）的行物理删除；
/// 2. **sync 感知守卫**（保留不变式 #5 删除永远赢的落地边界）：仅物理删除
///    **已传播到远端**的墓碑——`deleted_at` 须早于等于全局同步游标
///    （`last_sync_at`）；从未同步的设备（无游标）保守跳过物理删除（防
///    "本地先清、远端未来全量推送时缺口"的语义漂移）；
/// 3. **分类层级**：物理删除父分类前，将仍存活的子分类 `parent_id` 置 NULL
///    （子升级为根分类——父被物理清除后不留悬空引用，与 FK 约束语义一致）；
/// 4. **VACUUM 阈值驱动**（空间回收与 I/O 成本权衡）：单次物理删除超过
///    [AppConstants.cleanupVacuumThresholdRows] 行才执行 `VACUUM` +
///    `wal_checkpoint(TRUNCATE)`（全库重写成本高，小删除不触发）；
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

  /// 本次是否执行了 VACUUM（物理删除超阈值才 true）。
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
  /// 先删、分类悬空处理）→ 事务外阈值驱动 VACUUM → 写 last_cleanup_at。
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
      // cutoff = min(保留期截止, 最近同步时刻)：deleted_at 须**早于等于** cutoff
      //（严格小于——恰等于游标时刻的墓碑视为刚传播、留待下一轮）。
      final retentionCutoff = now.subtract(Duration(days: retention));
      final cutoff = lastSyncAt.isBefore(retentionCutoff)
          ? lastSyncAt
          : retentionCutoff;
      final cutoffStr = utcString(cutoff);

      // ---- 物理删除（单事务；引用表先删防 FK）----
      final deleted = <String, int>{};
      await database.transaction(() async {
        deleted['activityCategoryLinks'] = await _deleteExpiredLinks(cutoffStr);
        deleted['trackingRules'] = await _deleteExpiredTrackingRules(cutoffStr);
        deleted['timeEntries'] = await _deleteExpiredTimeEntries(cutoffStr);
        deleted['actionLogs'] = await _deleteExpiredActionLogs(cutoffStr);
        // 分类：先处理"存活子分类的 parentId 指向将被物理删除的父"——
        // 置 NULL（子升级根分类，不留悬空引用），再删超期分类行。
        final categoryIds = await _expiredCategoryIds(cutoffStr);
        if (categoryIds.isNotEmpty) {
          await (database.update(database.activityCategories)..where(
                (t) => t.parentId.isIn(categoryIds) & t.deletedAt.isNull(),
              ))
              .write(
                ActivityCategoriesCompanion(
                  parentId: const Value(null),
                  updatedAt: Value(utcString(now)),
                ),
              );
        }
        deleted['activityCategories'] = await _deleteExpiredCategories(
          cutoffStr,
        );
        deleted['activities'] = await _deleteExpiredActivities(cutoffStr);
      });

      // ---- VACUUM（事务外 + 阈值驱动；SQLite 禁止事务内 VACUUM）----
      var vacuumed = false;
      final total = deleted.values.fold(0, (a, b) => a + b);
      if (total > _vacuumThreshold) {
        database.customStatement('VACUUM');
        // TRUNCATE 模式把 WAL 截断回主库（比 PASSIVE 更彻底地归还空间）。
        database.customStatement('PRAGMA wal_checkpoint(TRUNCATE)');
        vacuumed = true;
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
  // 各表物理删除（软删超期行；deleted_at 为 utcString 存储，字典序 = 时间序）
  // ---------------------------------------------------------------------------

  Future<int> _deleteExpiredActivities(String cutoff) async {
    final query = database.delete(database.activities)
      ..where(
        (t) => t.deletedAt.isNotNull() & t.deletedAt.isSmallerThanValue(cutoff),
      );
    return query.go();
  }

  Future<int> _deleteExpiredTimeEntries(String cutoff) async {
    final query = database.delete(database.timeEntries)
      ..where(
        (t) => t.deletedAt.isNotNull() & t.deletedAt.isSmallerThanValue(cutoff),
      );
    return query.go();
  }

  Future<int> _deleteExpiredTrackingRules(String cutoff) async {
    final query = database.delete(database.trackingRules)
      ..where(
        (t) => t.deletedAt.isNotNull() & t.deletedAt.isSmallerThanValue(cutoff),
      );
    return query.go();
  }

  Future<int> _deleteExpiredCategories(String cutoff) async {
    final query = database.delete(database.activityCategories)
      ..where(
        (t) => t.deletedAt.isNotNull() & t.deletedAt.isSmallerThanValue(cutoff),
      );
    return query.go();
  }

  Future<int> _deleteExpiredLinks(String cutoff) async {
    final query = database.delete(database.activityCategoryLinks)
      ..where(
        (t) => t.deletedAt.isNotNull() & t.deletedAt.isSmallerThanValue(cutoff),
      );
    return query.go();
  }

  Future<int> _deleteExpiredActionLogs(String cutoff) async {
    final query = database.delete(database.actionLogs)
      ..where(
        (t) => t.deletedAt.isNotNull() & t.deletedAt.isSmallerThanValue(cutoff),
      );
    return query.go();
  }

  /// 软删超期分类的 id 集合（悬空 parentId 处理用）。
  Future<List<String>> _expiredCategoryIds(String cutoff) async {
    final rows =
        await (database.selectOnly(database.activityCategories)
              ..addColumns([database.activityCategories.id])
              ..where(
                database.activityCategories.deletedAt.isNotNull() &
                    database.activityCategories.deletedAt.isSmallerThanValue(cutoff),
              ))
            .get();
    return rows.map((r) => r.read(database.activityCategories.id)!).toList();
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
