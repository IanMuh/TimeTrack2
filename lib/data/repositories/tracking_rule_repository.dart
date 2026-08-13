import 'package:drift/drift.dart';

import '../../utils/result.dart';
import '../../viewmodels/tracking_rule.dart';
import '../database/app_database.dart';
import 'repository_mappings.dart';

/// 后台自动记录映射规则仓储（模块 2c'）。
///
/// - `sync_enabled = true` 的规则参与云同步（引擎行级过滤）；
///   `false` 仅存本地（不进远端、不被远端覆盖）；
/// - 软删统一 `deleted_at`（LWW 删除永远赢）。
class TrackingRuleRepository with RepositoryMappings {
  TrackingRuleRepository({
    required this.database,
  });

  final AppDatabase database;

  // ---------------------------------------------------------------------------
  // 查询
  // ---------------------------------------------------------------------------

  /// 全部规则（含已删除，bundle 导出/全量处理用；updated_at 升序）。
  Future<AppResult<List<TrackingRule>>> allRules() async {
    try {
      final query = database.select(database.trackingRules)
        ..orderBy([(t) => OrderingTerm.asc(t.updatedAt)]);
      final rows = await query.get();
      return AppSuccess(rows.map(trackingRuleFromRow).toList());
    } catch (e) {
      return AppFailure('查询映射规则失败：$e');
    }
  }

  /// 活跃规则（未删除；规则匹配器用）。
  Future<AppResult<List<TrackingRule>>> activeRules() async {
    try {
      final query = database.select(database.trackingRules)
        ..where((t) => t.deletedAt.isNull());
      final rows = await query.get();
      return AppSuccess(rows.map(trackingRuleFromRow).toList());
    } catch (e) {
      return AppFailure('查询映射规则失败：$e');
    }
  }

  /// 增量查询（云同步拉取用）：`updated_at >= since`（含已删除行）。
  /// **只返回 `sync_enabled = true` 的规则**（进同步的规则）——本地-only
  /// 规则不参与远端交换（防本地偏好泄漏/被远端覆盖）。
  Future<AppResult<List<TrackingRule>>> rulesSince(DateTime since) async {
    try {
      final query = database.select(database.trackingRules)
        ..where((t) =>
            t.updatedAt.isBiggerOrEqualValue(utcString(since)) &
            t.syncEnabled.equals(true))
        ..orderBy([(t) => OrderingTerm.asc(t.updatedAt)]);
      final rows = await query.get();
      return AppSuccess(rows.map(trackingRuleFromRow).toList());
    } catch (e) {
      return AppFailure('增量查询映射规则失败：$e');
    }
  }

  /// 按 id 查询。
  Future<TrackingRule?> ruleById(String ruleId) async {
    final query = database.select(database.trackingRules)
      ..where((t) => t.id.equals(ruleId));
    final row = await query.getSingleOrNull();
    return row == null ? null : trackingRuleFromRow(row);
  }

  // ---------------------------------------------------------------------------
  // 写
  // ---------------------------------------------------------------------------

  /// 新建/更新规则（整行 upsert）。
  ///
  /// 注意：与 TimeEntry 仓储语义一致——调用方持有 [TrackingRule.updatedAt]
  /// 的推进责任（LWW 合并以 updatedAt 决胜负，修改规则后须显式传新时间戳，
  /// 否则会被同步合并时远端版本覆盖）。
  Future<AppResult<TrackingRule>> saveRule(TrackingRule rule) async {
    try {
      await database.into(database.trackingRules).insert(
            trackingRuleToCompanion(rule),
            mode: InsertMode.insertOrReplace,
          );
      return AppSuccess(rule);
    } catch (e) {
      return AppFailure('保存映射规则失败：$e');
    }
  }

  /// 软删规则（LWW 删除永远赢）。
  Future<AppResult<void>> deleteRule(TrackingRule rule) async {
    try {
      final now = DateTime.now().toUtc();
      final tombstone =
          rule.copyWith(deletedAt: now, updatedAt: now);
      await database.into(database.trackingRules).insert(
            trackingRuleToCompanion(tombstone),
            mode: InsertMode.insertOrReplace,
          );
      return const AppSuccess(null);
    } catch (e) {
      return AppFailure('删除映射规则失败：$e');
    }
  }

  // ---------------------------------------------------------------------------
  // LWW（云同步拉取用）
  // ---------------------------------------------------------------------------

  /// LWW upsert（删除永远赢：deleted_at 随行 LWW）。
  Future<AppResult<void>> replaceIfRemoteNewer(TrackingRule remote) async {
    try {
      await database.transaction(() async {
        final local = await ruleById(remote.id);
        // **平局决胜分支**：updated_at 相等时远端删除墓碑仍应用（删除永远赢）——
        // 与 ActivityRepository 的 tie-break 对齐。规则可更新/可删除（不同于
        // 不可变的 action log），平局场景真实可达，须显式处理。
        final remoteWins = local == null ||
            local.updatedAt.isBefore(remote.updatedAt) ||
            (local.updatedAt.isAtSameMomentAs(remote.updatedAt) &&
                remote.isDeleted &&
                !local.isDeleted);
        if (remoteWins) {
          await database.into(database.trackingRules).insert(
                trackingRuleToCompanion(remote),
                mode: InsertMode.insertOrReplace,
              );
        }
      });
      return const AppSuccess(null);
    } catch (e) {
      return AppFailure('同步映射规则失败：$e');
    }
  }
}
