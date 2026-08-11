
import '../../utils/result.dart';
import '../../viewmodels/action_log.dart';
import '../../viewmodels/activity.dart';
import '../../viewmodels/activity_category.dart';
import '../../viewmodels/profile_settings.dart';
import '../../viewmodels/time_entry.dart';
import '../database/app_database.dart' hide ProfileSettings;
import '../repositories/action_log_repository.dart';
import '../repositories/activity_repository.dart';
import '../repositories/category_repository.dart';
import '../repositories/repository_mappings.dart';
import '../repositories/settings_repository.dart';
import '../repositories/time_entry_repository.dart';
import 'sync_bundle.dart';

/// 同步包仓储：全量导出（含软删）+ 行级 LWW 合并（单事务）。
///
/// LAN 与文件互通共用同一实现（老项目语义）：bundle 是全量快照，
/// 合并按行 `local.updatedAt < remote.updatedAt` 才整行替换（删除即软删行，
/// 靠 LWW 自然传播，无独立删除列表）。
class SyncBundleRepository with RepositoryMappings {
  SyncBundleRepository({
    required this.database,
    required this.activities,
    required this.categories,
    required this.timeEntries,
    required this.actionLogs,
    required this.settings,
  });

  final AppDatabase database;
  final ActivityRepository activities;
  final CategoryRepository categories;
  final TimeEntryRepository timeEntries;
  final ActionLogRepository actionLogs;
  final SettingsRepository settings;

  /// 全量导出（含软删行；删除记录随包传播）。
  Future<SyncBundle> exportBundle({
    required String sourceDeviceId,
    DateTime? exportedAt,
  }) async {
    final now = exportedAt ?? DateTime.now();
    final activityList = (await activities.activities(includeDeleted: true))
        .requireValue();
    final categoryList = (await categories.categories(includeDeleted: true))
        .requireValue();
    final categoryLinks = (await categories.links(includeDeleted: true))
        .requireValue();
    final entryList = await timeEntries.allEntries();
    final logList = (await actionLogs.allLogs()).requireValue();
    final settingValue = (await settings.settings()).requireValue();

    return SyncBundle(
      schemaVersion: SyncBundle.currentSchemaVersion,
      exportedAt: now,
      sourceDeviceId: sourceDeviceId,
      activities: activityList,
      categories: categoryList,
      categoryLinks: categoryLinks,
      timeEntries: entryList,
      actionLogs: logList,
      profileSettings: settingValue,
    );
  }

  /// 行级 LWW 合并（单事务）：按 id 查本地，`local.updatedAt < remote.updatedAt`
  /// 才整行替换；profile_settings 单例行同样 LWW。
  ///
  /// 表顺序与老项目一致：activities → categories → links → time_entries →
  /// action_logs → profile_settings（FK 依赖方向）。
  Future<AppResult<void>> mergeBundle(SyncBundle bundle) async {
    try {
      await database.transaction(() async {
        for (final activity in bundle.activities) {
          await _mergeActivity(activity);
        }
        for (final category in bundle.categories) {
          await _mergeCategory(category);
        }
        for (final link in bundle.categoryLinks) {
          await _mergeLink(link);
        }
        for (final entry in bundle.timeEntries) {
          await _mergeTimeEntry(entry);
        }
        for (final log in bundle.actionLogs) {
          await _mergeActionLog(log);
        }
        final settings = bundle.profileSettings;
        if (settings != null) {
          await _mergeSettings(settings);
        }
      });
      return const AppSuccess(null);
    } catch (e) {
      return AppFailure('合并同步包失败：$e');
    }
  }

  Future<void> _mergeActivity(Activity remote) async {
    final local = await _activityById(remote.id);
    if (local == null || local.updatedAt.isBefore(remote.updatedAt)) {
      await database.into(database.activities).insertOnConflictUpdate(
            activityToCompanion(remote),
          );
    }
  }

  Future<void> _mergeCategory(ActivityCategory remote) async {
    final local = await _categoryById(remote.id);
    if (local == null || local.updatedAt.isBefore(remote.updatedAt)) {
      await database.into(database.activityCategories).insertOnConflictUpdate(
            categoryToCompanion(remote),
          );
    }
  }

  Future<void> _mergeLink(ActivityCategoryLink remote) async {
    final query = database.select(database.activityCategoryLinks)
      ..where((t) => t.id.equals(remote.id));
    final row = await query.getSingleOrNull();
    final local = row == null ? null : linkFromRow(row);
    if (local == null || local.updatedAt.isBefore(remote.updatedAt)) {
      await database.into(database.activityCategoryLinks).insertOnConflictUpdate(
            linkToCompanion(remote),
          );
    }
  }

  Future<void> _mergeTimeEntry(TimeEntry remote) async {
    final query = database.select(database.timeEntries)
      ..where((t) => t.id.equals(remote.id));
    final row = await query.getSingleOrNull();
    final local = row == null ? null : timeEntryFromRow(row);
    if (local == null || local.updatedAt.isBefore(remote.updatedAt)) {
      // 复用仓储保存路径：跨日拆分 + 确定性段 id（LWW 覆盖不残留旧段）。
      await timeEntries.saveMergedEntry(remote);
    }
  }

  Future<void> _mergeActionLog(ActionLog remote) async {
    final query = database.select(database.actionLogs)
      ..where((t) => t.id.equals(remote.id));
    final row = await query.getSingleOrNull();
    final local = row == null ? null : actionLogFromRow(row);
    if (local == null || local.updatedAt.isBefore(remote.updatedAt)) {
      await database.into(database.actionLogs).insertOnConflictUpdate(
            actionLogToCompanion(remote),
          );
    }
  }

  Future<void> _mergeSettings(ProfileSettings remote) async {
    final query = database.select(database.profileSettings)
      ..where((t) => t.id.equals(1));
    final row = await query.getSingleOrNull();
    final local = row == null ? null : settingsFromRow(row);
    if (local == null || local.updatedAt.isBefore(remote.updatedAt)) {
      await database.into(database.profileSettings).insertOnConflictUpdate(
            settingsToCompanion(remote),
          );
    }
  }

  Future<Activity?> _activityById(String id) async {
    final query = database.select(database.activities)
      ..where((t) => t.id.equals(id));
    final row = await query.getSingleOrNull();
    return row == null ? null : activityFromRow(row);
  }

  Future<ActivityCategory?> _categoryById(String id) async {
    final query = database.select(database.activityCategories)
      ..where((t) => t.id.equals(id));
    final row = await query.getSingleOrNull();
    return row == null ? null : categoryFromRow(row);
  }

  /// 合并后归一化调用链（merge 之后执行，恢复本地数据不变量）。
  Future<void> normalizeAfterMerge() async {
    await timeEntries.normalizeRunningEntriesAfterMerge();
    await timeEntries.normalizeStoredCrossDayEntries();
    await timeEntries.backfillMissingEntrySnapshots();
    await activities.ensureUnassignedActivity();
    // 未分配条目合并（可能因合并带入新的相邻未分配段）。
    final unassigned = (await activities.unassignedActivity()).requireValue();
    await timeEntries.mergeAdjacentUnassignedEntries(unassigned.id);
  }
}
