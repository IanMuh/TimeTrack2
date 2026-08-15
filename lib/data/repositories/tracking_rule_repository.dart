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

  /// 活跃规则（未删除；规则匹配器用）——**按 updated_at 升序 + id 次级键**
  ///（结果确定：后续"首个命中规则生效"的匹配器依赖稳定顺序；SQLite 不保证
  /// 同 updated_at 行间的相对顺序，须次级唯一键兜底）。
  Future<AppResult<List<TrackingRule>>> activeRules() async {
    try {
      final query = database.select(database.trackingRules)
        ..where((t) => t.deletedAt.isNull())
        ..orderBy([
          (t) => OrderingTerm.asc(t.updatedAt),
          (t) => OrderingTerm.asc(t.id),
        ]);
      final rows = await query.get();
      return AppSuccess(rows.map(trackingRuleFromRow).toList());
    } catch (e) {
      return AppFailure('查询映射规则失败：$e');
    }
  }

  /// 增量查询（云同步拉取用）：`updated_at >= since`（含已删除行）。
  /// **只返回 `sync_enabled = true` 的规则**（进同步的规则）——本地-only
  /// 规则不参与远端交换（防本地偏好泄漏/被远端覆盖）。
  /// **过滤 unknown 匹配类型（r1）**：match_kind=unknown 的规则是反序列化
  /// 兜底（未知值不落库），若放行进同步会在各端永久循环传播、且未来新增
  /// 匹配类型时当前版本拉取会降级为 unknown 再推回覆盖远端原值（跨版本
  /// 数据退化）——同步入口排除，未知规则仅存本地。
  Future<AppResult<List<TrackingRule>>> rulesSince(DateTime since) async {
    try {
      final query = database.select(database.trackingRules)
        ..where((t) =>
            t.updatedAt.isBiggerOrEqualValue(utcString(since)) &
            t.syncEnabled.equals(true) &
            (t.matchKind.equals(TrackingRuleMatchKind.process.storageValue) |
                t.matchKind.equals(TrackingRuleMatchKind.title.storageValue)))
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
      // **事务内重读 + 单调时间（r1，对齐 ActivityRepository.deleteActivity）**：
      // 墓碑时间必须单调推进（max(now, 当前 updatedAt + 1ms)）——若库内行
      // updatedAt 来自远端偏未来时间戳（设备时钟不同步），now 会早于原值形成
      // "时间倒退"，下次 LWW 判定墓碑为陈旧数据而被远端覆盖、删除丢失、规则
      // 复活。事务内重读拿权威行（防并发写入后拿陈旧副本写墓碑）。
      await database.transaction(() async {
        final current = await ruleById(rule.id);
        if (current == null || current.isDeleted) {
          return; // 幂等：不存在/已删
        }
        final now = DateTime.now().toUtc();
        final ts = now.isAfter(current.updatedAt)
            ? now
            : current.updatedAt.add(const Duration(milliseconds: 1));
        final tombstone = current.copyWith(deletedAt: ts, updatedAt: ts);
        await database.into(database.trackingRules).insert(
              trackingRuleToCompanion(tombstone),
              mode: InsertMode.insertOrReplace,
            );
      });
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
        // **本地-only 规则短路（r1 修复）**：sync_enabled=false 的规则永不接受
        // 远端覆盖——远端行恒为 sync_enabled=true，LWW 直接覆盖会把本地偏好
        //（含用户关闭同步的意图）改回同步，甚至被远端墓碑删除（删除丢失、
        // 规则复活）。远端表只承载同步规则，与本地-only 规则无交集。
        if (local != null && !local.syncEnabled) {
          return;
        }
        // **远端异常行防御短路**："远端表只承载 sync_enabled=true 规则"的
        // 不变量由推送侧 rulesSince 过滤维持——若远端出现 sync_enabled=false
        // 的异常行（legacy/异常客户端/手工修改），落地会把本地同步规则静默
        // 降级为本地-only，随后 rulesSince 不再返回、永不推回，云端与本地
        // 永久分叉且无法自愈——防御性跳过。
        if (!remote.syncEnabled) {
          return;
        }
        // **unknown 匹配类型防御短路**：match_kind=unknown 是反序列化兜底值
        //（未知值不落库）——远端行若为 unknown（未来版本新匹配类型被当前
        // 版本降级），落地会覆盖本地有效规则造成跨版本数据退化——跳过。
        // **仅对存活行跳过（r 修复）**：墓碑行（isDeleted）仍须参与 LWW——
        // 未来版本引入新类型后删除的规则，当前版本反序列化为 unknown 墓碑，
        // 若在此短路则删除不落地、本地旧规则永久存活（甚至被 rulesSince
        // 推回远端反向覆盖墓碑造成多端复活），破坏"LWW 删除永远赢"不变量。
        if (remote.matchKind == TrackingRuleMatchKind.unknown &&
            !remote.isDeleted) {
          return;
        }
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
