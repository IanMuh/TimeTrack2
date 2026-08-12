import 'dart:io';

import 'package:drift/drift.dart';
import 'package:uuid/uuid.dart';

import '../../utils/result.dart';
import '../../viewmodels/action_log.dart';
import '../database/app_database.dart';
import 'repository_mappings.dart';

/// 操作日志仓储：写入 + 查询（时间线历史展示用）。
///
/// 操作日志是 CLI 指令系统/同步包的组成部分（计划：操作自动继承日志）。
class ActionLogRepository with RepositoryMappings {
  ActionLogRepository({
    required this.database,
    Uuid? uuid,
  }) : _uuid = uuid ?? const Uuid();

  final AppDatabase database;
  final Uuid _uuid;

  /// 写入一条操作日志。
  Future<AppResult<ActionLog>> insert({
    required ActionType actionType,
    String? userId,
    String? activityId,
    String? entryId,
    String message = '',
    required DateTime occurredAt,
    required String deviceId,
  }) async {
    try {
      final log = ActionLog(
        id: _uuid.v4(),
        userId: userId,
        actionType: actionType,
        activityId: activityId,
        entryId: entryId,
        message: message,
        occurredAt: occurredAt,
        deviceId: deviceId,
        updatedAt: occurredAt,
      );
      await database.into(database.actionLogs).insert(
            actionLogToCompanion(log),
          );
      return AppSuccess(log);
    } catch (e) {
      return AppFailure('写入操作日志失败：$e');
    }
  }

  /// 分页查询（按发生时间倒序，默认排除已删除）。
  Future<AppResult<List<ActionLog>>> logs({
    int limit = 100,
    int offset = 0,
    bool includeDeleted = false,
  }) async {
    try {
      final query = database.select(database.actionLogs)
        ..orderBy([
          (t) => OrderingTerm.desc(t.occurredAt),
          (t) => OrderingTerm.asc(t.id), // 次级键：同时间戳时分页稳定
        ])
        ..limit(limit, offset: offset);
      if (!includeDeleted) {
        query.where((t) => t.deletedAt.isNull());
      }
      final rows = await query.get();
      return AppSuccess(rows.map(actionLogFromRow).toList());
    } catch (e) {
      return AppFailure('查询操作日志失败：$e');
    }
  }

  /// 增量查询日志（云同步拉取用）：`updated_at >= since`（含已删除行）。
  Future<AppResult<List<ActionLog>>> logsSince(DateTime since) async {
    try {
      final query = database.select(database.actionLogs)
        ..where((t) => t.updatedAt.isBiggerOrEqualValue(utcString(since)))
        ..orderBy([(t) => OrderingTerm.asc(t.updatedAt)]);
      final rows = await query.get();
      return AppSuccess(rows.map(actionLogFromRow).toList());
    } catch (e) {
      return AppFailure('增量查询操作日志失败：$e');
    }
  }

  /// LWW upsert（删除永远赢：deleted_at 随行 LWW）。云同步拉取用。
  Future<AppResult<void>> replaceIfRemoteNewer(ActionLog remote) async {
    try {
      // LWW 读-判-写同一事务：防比较后写入前本地新写入被旧远端覆盖。
      await database.transaction(() async {
        final query = database.select(database.actionLogs)
          ..where((t) => t.id.equals(remote.id));
        final row = await query.getSingleOrNull();
        final local = row == null ? null : actionLogFromRow(row);
        // **平局分支（r53，与 ActivityRepository 对齐）**：时间戳相等时远端
        // 删除墓碑仍应用（删除永远赢）。注：action log 行写入后不可变（无
        // 本地更新/删除路径，updatedAt 恒等于 occurredAt），远端墓碑必然
        // 晚于本地行，平局实际不可达——分支为语义一致性与防御深度保留。
        final remoteWins = local == null ||
            local.updatedAt.isBefore(remote.updatedAt) ||
            (local.updatedAt.isAtSameMomentAs(remote.updatedAt) &&
                remote.isDeleted &&
                !local.isDeleted);
        if (remoteWins) {
          await database.into(database.actionLogs).insertOnConflictUpdate(
                actionLogToCompanion(remote),
              );
        }
      });
      return const AppSuccess(null);
    } catch (e) {
      // **不拼接 $e（r53）**：同步链路失败消息会经 StateError 最终写入
      // statusStore 的 lastError 面向用户展示——内嵌数据库驱动/SQL 异常
      // 细节与 engine"失败消息脱敏"注释相悖；详细原因写 stderr 日志。
      stderr.writeln('[action-log] 同步操作日志失败：$e');
      return const AppFailure('同步操作日志失败');
    }
  }

  /// 全量日志（含已删除，bundle 导出用）。
  Future<AppResult<List<ActionLog>>> allLogs() async {
    try {
      final query = database.select(database.actionLogs)
        ..orderBy([(t) => OrderingTerm.asc(t.updatedAt)]);
      final rows = await query.get();
      return AppSuccess(rows.map(actionLogFromRow).toList());
    } catch (e) {
      return AppFailure('查询全部操作日志失败：$e');
    }
  }

  /// 指定活动/条目最近一条日志（时间线上下文定位）。
  Future<AppResult<ActionLog?>> latestFor({
    String? activityId,
    String? entryId,
  }) async {
    try {
      final query = database.select(database.actionLogs)
        ..orderBy([
          (t) => OrderingTerm.desc(t.occurredAt),
          (t) => OrderingTerm.asc(t.id),
        ])
        ..limit(1);
      if (activityId != null) {
        query.where((t) => t.activityId.equals(activityId));
      }
      if (entryId != null) {
        query.where((t) => t.entryId.equals(entryId));
      }
      query.where((t) => t.deletedAt.isNull());
      final row = await query.getSingleOrNull();
      return AppSuccess(row == null ? null : actionLogFromRow(row));
    } catch (e) {
      return AppFailure('查询操作日志失败：$e');
    }
  }
}
