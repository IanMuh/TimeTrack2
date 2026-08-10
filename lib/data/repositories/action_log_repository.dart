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
