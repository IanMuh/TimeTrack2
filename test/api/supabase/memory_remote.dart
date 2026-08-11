import 'package:flutter_test/flutter_test.dart';
import 'package:timetrack2/api/supabase/remote_tables.dart';

/// 内存版远程表（mock 网关）：按表存 `id → row`，模拟分页/since 过滤/排序。
///
/// 说明：行按 id 全局存储（未按 userId 二级隔离）——跨用户隔离由真网关的
/// `eq('user_id', ...)` 过滤 + 云端 RLS 保证，引擎单用户测试不依赖该维度；
/// 若需验证跨用户场景，请扩展为 `tables[table][userId][id]` 结构。
class MemoryRemote implements RemoteTableGateway {
  final Map<String, Map<String, Map<String, Object?>>> tables = {};

  /// 调用日志：`pull:<table>` / `push:<table>` / `updated_at:<table>`。
  final List<String> callLog = <String>[];

  /// 拉取调用明细（表 / since / page），供分页与增量语义断言。
  final List<({String table, DateTime? since, int page})> pullLog = [];

  /// 抛出异常（模拟网络故障）：设非 null 时下次调用抛该异常。
  Object? nextError;

  void seed(String table, Map<String, Object?> row) {
    assert(row['updated_at'] is String, 'seed 行必须携带 updated_at');
    // 行身份：常规表用 id；profile_settings 无 id 键（云端主键 user_id）。
    final id = (row['id'] ?? row['user_id'])! as String;
    tables.putIfAbsent(table, () => {})[id] = row;
  }

  /// 记录在远端存在但未在本地 mock 中的行（fetchRemoteUpdatedAt 用）。
  void seedRemoteOnly(String table, String id, DateTime updatedAt) {
    tables
        .putIfAbsent(table, () => {})[id] = {
      'id': id,
      'updated_at': updatedAt.toUtc().toIso8601String(),
    };
  }

  @override
  Future<RemoteRowsPage> fetchRowsSince({
    required String table,
    required String userId,
    DateTime? since,
    int pageSize = 1000,
    int page = 0,
  }) async {
    assert(pageSize > 0 && page >= 0,
        'fetchRowsSince: pageSize 必须为正、page 非负');
    callLog.add('pull:$table');
    pullLog.add((table: table, since: since, page: page));
    _maybeThrow();
    final rows = (tables[table]?.values ?? const <Map<String, Object?>>[])
        .where((row) {
      final updatedAt = DateTime.parse(row['updated_at']! as String);
      if (since == null) return true;
      return !updatedAt.isBefore(since);
    }).toList()
      ..sort((a, b) {
        // 按 instant 比较（防混入不同时区格式时字典序失真）
        final aAt = DateTime.parse(a['updated_at']! as String);
        final bAt = DateTime.parse(b['updated_at']! as String);
        return aAt.compareTo(bAt);
      });
    final start = page * pageSize;
    if (start >= rows.length) {
      return RemoteRowsPage(rows: const [], hasMore: false);
    }
    final end = (start + pageSize) < rows.length ? start + pageSize : rows.length;
    // hasMore 语义与真网关一致：末页恰好满页时返回 true（触发一次多余空页
    // 请求以结束），忠实模拟契约。
    return RemoteRowsPage(
      rows: rows.sublist(start, end),
      hasMore: rows.sublist(start, end).length == pageSize,
    );
  }

  @override
  Future<Map<String, DateTime>> fetchRemoteUpdatedAt({
    required String table,
    required String userId,
    required List<String> ids,
    String idKey = 'id',
  }) async {
    callLog.add('updated_at:$table');
    _maybeThrow();
    final result = <String, DateTime>{};
    for (final id in ids) {
      // 按 idKey 匹配行（与真网关 select(idKey,updated_at) + inFilter 一致；
      // 存储键为 id ?? user_id，但查询键按 idKey 比较）。
      final row = tables[table]?.values
          .where((r) => r[idKey] == id)
          .firstOrNull;
      if (row != null && row['updated_at'] is String) {
        result[id] = DateTime.parse(row['updated_at']! as String).toUtc();
      }
    }
    return result;
  }

  @override
  Future<void> upsertRows({
    required String table,
    required String userId,
    required List<Map<String, Object?>> rows,
  }) async {
    callLog.add('push:$table');
    _maybeThrow();
    final target = tables.putIfAbsent(table, () => {});
    for (final row in rows) {
      // 行身份：常规表用 id；profile_settings 无 id 键（云端主键 user_id）。
      final id = (row['id'] ?? row['user_id'])! as String;
      target[id] = row;
    }
  }

  void _maybeThrow() {
    final error = nextError;
    if (error != null) {
      nextError = null;
      throw error;
    }
  }
}

/// 校验推送顺序（先拉后推）：至少一次拉取，且首个拉取早于首个推送。
void expectPullBeforePush(List<String> log) {
  var firstPull = -1;
  var firstPush = -1;
  for (var i = 0; i < log.length; i++) {
    if (log[i].startsWith('pull:') && firstPull == -1) firstPull = i;
    if (log[i].startsWith('push:') && firstPush == -1) firstPush = i;
  }
  if (firstPush == -1) return; // 无推送
  expect(firstPull, isNot(-1), reason: '推送之前必须存在拉取：$log');
  expect(firstPull, lessThan(firstPush), reason: '推送应发生在所有拉取之后：$log');
}
