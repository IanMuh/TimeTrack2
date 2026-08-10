import 'package:drift/drift.dart';
import 'package:uuid/uuid.dart';

import '../../utils/result.dart';
import '../../viewmodels/activity.dart';
import '../../viewmodels/time_entry.dart';
import '../database/app_database.dart';
import 'repository_mappings.dart';

/// 活动仓储：CRUD + 软删 + 未分配单例 + one-off 自动清理 + LWW。
class ActivityRepository with RepositoryMappings {
  ActivityRepository({
    required this.database,
    Uuid? uuid,
  }) : _uuid = uuid ?? const Uuid();

  final AppDatabase database;
  final Uuid _uuid;

  // ---------------------------------------------------------------------------
  // 查询
  // ---------------------------------------------------------------------------

  /// 全部活动（默认排除已删除；按收藏、名称排序）。
  Future<AppResult<List<Activity>>> activities({
    bool includeDeleted = false,
  }) async {
    try {
      final query = database.select(database.activities)
        ..orderBy([
          (t) => OrderingTerm.desc(t.isFavorite),
          (t) => OrderingTerm.asc(t.name),
        ]);
      if (!includeDeleted) {
        query.where((t) => t.deletedAt.isNull());
      }
      final rows = await query.get();
      return AppSuccess(rows.map(activityFromRow).toList());
    } catch (e) {
      return AppFailure('加载活动失败：$e');
    }
  }

  /// 未分配活动（单例，必要时创建——老项目"未安排"语义）。
  Future<AppResult<Activity>> unassignedActivity() async {
    try {
      return AppSuccess(await ensureUnassignedActivity());
    } catch (e) {
      return AppFailure('获取未分配活动失败：$e');
    }
  }

  // ---------------------------------------------------------------------------
  // 写操作
  // ---------------------------------------------------------------------------

  /// 新建活动（isOneOff 时默认非收藏）。
  Future<AppResult<Activity>> createActivity({
    required String name,
    required int color,
    String? userId,
    bool isOneOff = false,
  }) async {
    try {
      final now = DateTime.now();
      final trimmedName = name.trim();
      if (trimmedName.isEmpty) {
        return const AppFailure('活动名不能为空');
      }
      final activity = Activity(
        id: _uuid.v4(),
        userId: userId,
        name: trimmedName,
        color: color,
        isFavorite: !isOneOff,
        updatedAt: now,
        isOneOff: isOneOff,
      );
      await _upsert(activity);
      return AppSuccess(activity);
    } catch (e) {
      return AppFailure('新建活动失败：$e');
    }
  }

  /// 更新活动名/色（未分配活动不可改名，返回未分配单例）。
  Future<AppResult<Activity>> updateActivity({
    required Activity activity,
    required String name,
    required int color,
  }) async {
    try {
      if (activity.isUnassigned || await activityIdIsUnassigned(activity.id)) {
        return AppSuccess(await ensureUnassignedActivity());
      }
      // 重读-判-写同一事务：防重读后并发 LWW 写入被本地旧时间戳覆盖。
      return await database.transaction(() async {
        final current = await _activityById(activity.id);
        if (current == null || current.isDeleted) {
          return AppFailure('活动不存在或已删除：${activity.id}');
        }
        final trimmedName = name.trim();
        if (trimmedName.isEmpty) {
          return const AppFailure('活动名不能为空');
        }
        final updated = current.copyWith(
          name: trimmedName,
          color: color,
          updatedAt: _monotonicNow(current.updatedAt),
        );
        await _upsert(updated);
        return AppSuccess(updated);
      });
    } catch (e) {
      return AppFailure('更新活动失败：$e');
    }
  }

  /// 软删活动（未分配活动不可删）。
  Future<AppResult<void>> deleteActivity(Activity activity) async {
    try {
      if (activity.isUnassigned || await activityIdIsUnassigned(activity.id)) {
        return const AppSuccess(null);
      }
      // 重读-判-写同一事务：仅当库内仍存活才落墓碑（陈旧对象不复活已删/不覆盖远端删除）。
      return await database.transaction(() async {
        final current = await _activityById(activity.id);
        if (current == null || current.isDeleted) {
          return const AppSuccess(null); // 不存在/已删除：幂等
        }
        final now = _monotonicNow(current.updatedAt);
        await _upsert(current.copyWith(deletedAt: now, updatedAt: now));
        return const AppSuccess(null);
      });
    } catch (e) {
      return AppFailure('删除活动失败：$e');
    }
  }

  /// 恢复 one-off 活动（删除后重新激活）。
  Future<AppResult<Activity>> restoreOneOffActivity(Activity activity) async {
    try {
      if (!activity.isOneOff) {
        return const AppFailure('仅 one-off 活动可恢复');
      }
      // 重读-判-写同一事务：基于库内最新状态判定（陈旧对象不误判）。
      return await database.transaction(() async {
        final current = await _activityById(activity.id);
        if (current == null) {
          return AppFailure('活动不存在：${activity.id}');
        }
        if (!current.isDeleted) {
          return AppSuccess(current); // 未删除：幂等
        }
        final restored = current.copyWith(
          deletedAt: null,
          clearDeletedAt: true,
          isFavorite: false,
          isOneOff: true,
          updatedAt: _monotonicNow(current.updatedAt),
        );
        await _upsert(restored);
        return AppSuccess(restored);
      });
    } catch (e) {
      return AppFailure('恢复一次性活动失败：$e');
    }
  }

  // ---------------------------------------------------------------------------
  // 同步（LWW 整行替换）
  // ---------------------------------------------------------------------------

  /// LWW upsert：远端 updated_at 更新于本地才替换（删除永远赢——deleted_at 也是
  /// 行内字段，随 updated_at 一起 LWW，不会被并发更新复活）。
  Future<AppResult<void>> replaceIfRemoteNewer(Activity remote) async {
    try {
      // LWW 读-判-写同一事务：防比较后写入前本地新写入被旧远端覆盖。
      await database.transaction(() async {
        final local = await _activityById(remote.id);
        final remoteWins = local == null ||
            local.updatedAt.isBefore(remote.updatedAt) ||
            // 平局（时间戳相等）时远端为删除墓碑仍应用——删除永远赢。
            (local.updatedAt.isAtSameMomentAs(remote.updatedAt) &&
                remote.isDeleted &&
                !local.isDeleted);
        if (remoteWins) {
          await _upsert(remote);
        }
      });
      return const AppSuccess(null);
    } catch (e) {
      return AppFailure('同步活动失败：$e');
    }
  }

  // ---------------------------------------------------------------------------
  // 内部/跨仓储协作
  // ---------------------------------------------------------------------------

  /// 未分配活动单例：查未删的 → 无则查老数据"未安排"名 → 无则创建。
  /// 多余未分配（历史脏数据）软删只保留一个。
  ///
  /// 整体包在事务内：防并发首次访问（switch/stop 与同步同时触发）各自创建
  /// 多个未分配单例（无唯一约束兜底，事务是唯一防线）。
  Future<Activity> ensureUnassignedActivity() async {
    return database.transaction(() async {
      final query = database.select(database.activities)
        ..where((t) => t.isUnassigned.equals(true));
      final rows = await query.get();
      if (rows.isNotEmpty) {
        // 删除永远赢：若唯一未分配行已被软删（远端删除），不复活（复活会以新时间戳
        // 推回远端制造删除-复活冲突）；创建新未分配行替代。
        final active = rows.where((r) => r.deletedAt == null).toList();
        if (active.isNotEmpty) {
          var keep = activityFromRow(active.first);
          for (final row in active.skip(1)) {
            final duplicate = activityFromRow(row);
            // 每行独立单调时间戳：重复行 updatedAt 可能晚于 keep，
            // 共用 now 会造成该行墓碑时间倒退（远端副本判定获胜而复活）。
            final now = _monotonicNow(duplicate.updatedAt);
            await _upsert(
              duplicate.copyWith(deletedAt: now, updatedAt: now),
            );
          }
          return keep;
        }
        // 全部已删：清理陈旧已删副本后走创建路径。
        for (final row in rows) {
          await (database.delete(database.activities)
                ..where((t) => t.id.equals(row.id)))
              .go();
        }
      }
      // 老数据迁移兜底：名为"未安排"的未删活动升级为未分配单例。
      final legacy = database.select(database.activities)
        ..where((t) => t.name.equals('未安排') & t.deletedAt.isNull());
      final legacyRows = await legacy.get();
      if (legacyRows.isNotEmpty) {
        // 全部"未安排"未删行升级为未分配（多余者随后被单例清理软删）。
        for (final row in legacyRows) {
          // 单调性基于该行自身 updatedAt（时钟不同步的远端未来值也保持不回退）。
          final upgraded = activityFromRow(row).copyWith(
            isFavorite: false,
            isUnassigned: true,
            updatedAt: _monotonicNow(activityFromRow(row).updatedAt),
          );
          await _upsert(upgraded);
        }
        return ensureUnassignedActivity();
      }
      final now = DateTime.now();
      final activity = Activity(
        id: _uuid.v4(),
        name: '未安排',
        color: 0xff64748b,
        isFavorite: false,
        updatedAt: now,
        isUnassigned: true,
      );
      await _upsert(activity);
      return activity;
    });
  }

  /// 指定活动是否为未分配。
  Future<bool> activityIdIsUnassigned(String activityId) async {
    final row = await _activityById(activityId);
    return row?.isUnassigned ?? false;
  }

  /// 单调时间戳：max(now, 当前 updatedAt + 1ms)。
  ///
  /// 防"时间倒退"：本地行可能携带来自远端偏未来的 updatedAt（设备时钟不同步），
  /// 直接取 now 会小于原值，下次 LWW 判定本地为旧数据而被远端覆盖——
  /// 用户编辑丢失、删除墓碑被判定为陈旧导致活动复活（违反"删除永远赢"）。
  DateTime _monotonicNow(DateTime currentUpdatedAt) {
    final now = DateTime.now();
    return now.isAfter(currentUpdatedAt)
        ? now
        : currentUpdatedAt.add(const Duration(milliseconds: 1));
  }

  /// one-off 活动用完自动软删（switch/stop 后调用，不删未分配/普通活动）。
  Future<void> softDeleteOneOffActivityIfNeeded(
    String activityId, {
    required DateTime updatedAt,
  }) async {
    final activity = await _activityById(activityId);
    if (activity == null || !activity.isOneOff || activity.isDeleted) return;
    // 时间不倒退：回填的旧时刻不得早于活动当前 updatedAt（防生成时间倒退的
    // 删除记录干扰 LWW 时间序）。
    final effective = updatedAt.isAfter(activity.updatedAt)
        ? updatedAt
        : activity.updatedAt.add(const Duration(milliseconds: 1));
    await _upsert(
      activity.copyWith(deletedAt: effective, updatedAt: effective),
    );
  }

  /// 时间条目补全活动名/色快照（活动缺失/已删时保持条目原样）。
  Future<TimeEntry> entryWithActivitySnapshot(
    TimeEntry entry, {
    AppDatabase? executor,
  }) async {
    final activity = await _activityById(entry.activityId, executor: executor);
    // 活动缺失或已软删：保持条目原样（历史快照不被已删活动改写）。
    if (activity == null || activity.isDeleted) return entry;
    return entry.copyWith(
      activityNameSnapshot: activity.name,
      activityColorSnapshot: activity.color,
    );
  }

  /// 种子活动（首次启动无活动时：工作/学习/通勤/休息）。
  Future<void> seedActivities() async {
    final count = database.selectOnly(database.activities)
      ..addColumns([database.activities.id.count()]);
    final total = await count.getSingle();
    if ((total.read(database.activities.id.count()) ?? 0) != 0) return;

    final now = DateTime.now();
    const seeds = [
      ('工作', 0xff2563eb),
      ('学习', 0xff059669),
      ('通勤', 0xffd97706),
      ('休息', 0xff7c3aed),
    ];
    for (final (name, color) in seeds) {
      await _upsert(Activity(
        id: _uuid.v4(),
        name: name,
        color: color,
        isFavorite: true,
        updatedAt: now,
      ));
    }
  }

  /// 内部 upsert（不包 AppResult）。
  Future<void> _upsert(Activity activity) {
    return database.into(database.activities).insertOnConflictUpdate(
          activityToCompanion(activity),
        );
  }

  /// 内部按 id 查询（可传 executor 供事务内使用）。
  Future<Activity?> _activityById(
    String id, {
    AppDatabase? executor,
  }) async {
    final target = executor ?? database;
    final query = target.select(database.activities)
      ..where((t) => t.id.equals(id));
    final row = await query.getSingleOrNull();
    return row == null ? null : activityFromRow(row);
  }
}
