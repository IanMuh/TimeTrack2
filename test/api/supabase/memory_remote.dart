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
  /// [idKey] 与 fetchRemoteUpdatedAt 的 idKey 对齐（profile_settings 用 user_id）；
  /// 需显式传 [userId] 归属（否则该行会因 fetchRowsSince 的缺失 user_id 放行
  /// 规则被当作完整远端行拉取，产生脏数据）。
  void seedRemoteOnly(String table, String id, DateTime updatedAt,
      {String idKey = 'id', String? userId}) {
    tables.putIfAbsent(table, () => {})[id] = {
      idKey: id,
      'user_id': ?userId,
      'updated_at': updatedAt.toUtc().toIso8601String(),
    };
  }

  /// 注入条件失败：设非 null 时，**指定调用序号**（从 0 计）的网关调用抛该异常
  /// （模拟"拉取中途/推送阶段失败"；序号按 callLog 计数）。
  Object? failOnCallIndex;
  int _callCount = 0;

  /// 重置调用计数（配合 [failOnCallIndex] 使用：先 reset 再设目标序号）。
  void resetCallCount() => _callCount = 0;

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
      // 与真网关 .eq('user_id', userId) 过滤一致：有 user_id 的行须归属当前
      // 用户；**缺失 user_id**（历史宽松数据）放行——新落库行经 upsertRows
      // 注入强制归属，不产生新的无主行。
      final rowUser = row['user_id'];
      if (rowUser is String && rowUser != userId) return false;
      final updatedAt = DateTime.parse(row['updated_at']! as String);
      if (since == null) return true;
      return !updatedAt.isBefore(since);
    }).toList()
      ..sort((a, b) {
        // 按 instant 比较（防混入不同时区格式时字典序失真）；
        // 次级唯一键（与真网关 order('updated_at').order(tieBreakKey) 一致）。
        final aAt = DateTime.parse(a['updated_at']! as String);
        final bAt = DateTime.parse(b['updated_at']! as String);
        final byAt = aAt.compareTo(bAt);
        if (byAt != 0) return byAt;
        final aId = (a['id'] ?? a['user_id'])! as String;
        final bId = (b['id'] ?? b['user_id'])! as String;
        return aId.compareTo(bId);
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
      // 按 idKey 匹配行 + 按 userId 过滤（与真网关 eq('user_id') + inFilter
      // 一致；防跨用户数据存在时误报本用户不存在的行）。
      final row = tables[table]?.values
          .where((r) => r[idKey] == id)
          .where((r) {
            final rowUser = r['user_id'];
            return rowUser is! String || rowUser == userId;
          })
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
      // 模拟真网关"强制归属当前用户"：注入 user_id（防测试存下无主行）；
      // updated_at 缺失时补齐（防后续强制解包抛 null-check 异常）。
      final owned = {
        ...row,
        'user_id': userId,
        if (!row.containsKey('updated_at'))
          'updated_at': DateTime.now().toUtc().toIso8601String(),
      };
      // 行身份：常规表用 id；profile_settings 无 id 键（云端主键 user_id）。
      final id = (owned['id'] ?? owned['user_id'])! as String;
      target[id] = owned;
    }
  }

  void _maybeThrow() {
    final error = nextError;
    if (error != null) {
      nextError = null;
      failOnCallIndex = null; // 互斥：nextError 触发时清除条件失败钩子
      _callCount += 1; // 与 callLog 计数对齐（防 failOnCallIndex 相对偏移）
      throw error;
    }
    final indexError = failOnCallIndex;
    final isTarget = indexError != null && _callCount == indexError;
    _callCount += 1;
    if (isTarget) {
      failOnCallIndex = null; // 单次生效
      throw Exception('mock 条件失败（调用序号 ${_callCount - 1}）');
    }
  }
}

/// 校验推送顺序（先拉后推）：**所有**拉取早于首个推送。
void expectPullBeforePush(List<String> log) {
  var firstPush = -1;
  var lastPull = -1;
  for (var i = 0; i < log.length; i++) {
    if (log[i].startsWith('pull:')) lastPull = i;
    if (log[i].startsWith('push:') && firstPush == -1) firstPush = i;
  }
  if (firstPush == -1) return; // 无推送
  expect(lastPull, isNot(-1), reason: '推送之前必须存在拉取：$log');
  expect(lastPull, lessThan(firstPush),
      reason: '所有拉取必须早于首个推送：$log');
}
