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

  /// 是否放行缺失 user_id 的无主行（默认 true 兼容直接 seed 无归属行的
  /// LWW 语义测试；**有 user_id 的行仍严格按归属过滤**——跨用户隔离测试
  /// 不受影响，且无需主行泄漏场景可显式设 false 验证严格模式）。
  bool allowUnownedRows = true;

  void seed(String table, Map<String, Object?> row) {
    if (row['updated_at'] is! String ||
        DateTime.tryParse(row['updated_at']! as String) == null) {
      throw ArgumentError('seed 行必须携带可解析的 updated_at（行内容：$row）');
    }
    // 行身份：常规表用 id；profile_settings 无 id 键（云端主键 user_id）。
    final id = row['id'] ?? row['user_id'];
    if (id == null) {
      throw ArgumentError('seed: 行必须携带 id 或 user_id（行内容：$row）');
    }
    // 浅拷贝（防测试 seed 后复用/修改原 Map 无提示改变 mock 状态）。
    tables.putIfAbsent(table, () => {})[id as String] = Map.of(row);
  }

  /// 记录在远端存在但未在本地 mock 中的行（fetchRemoteUpdatedAt 用）。
  /// [idKey] 与 fetchRemoteUpdatedAt 的 idKey 对齐（profile_settings 用 user_id）；
  /// [userId] **必填**（与真网关 eq('user_id') 一致——无主行会被任意用户
  /// 看到，掩盖跨用户数据泄漏类缺陷）。
  void seedRemoteOnly(String table, String id, DateTime updatedAt,
      {String idKey = 'id', required String userId}) {
    tables.putIfAbsent(table, () => {})[id] = {
      idKey: id,
      'user_id': userId,
      'updated_at': updatedAt.toUtc().toIso8601String(),
    };
  }

  /// 注入条件失败：设非 null 时，**指定调用序号**（从 0 计）的网关调用抛该异常
  /// （模拟"拉取中途/推送阶段失败"；序号按 callLog 计数）。
  Object? failOnCallIndex;
  int _callCount = 0;

  /// 重置调用计数 + 清除失败钩子（防残留钩子在下个测试误触发）。
  void resetCallCount() {
    _callCount = 0;
    failOnCallIndex = null;
    nextError = null;
  }

  @override
  Future<RemoteRowsPage> fetchRowsSince({
    required String table,
    required String userId,
    DateTime? since,
    int pageSize = 1000,
    int page = 0,
  }) async {
    // 与真网关对齐：非法 pageSize 显式抛错（而非 assert——release 下剥离）。
    if (pageSize < 1) {
      throw ArgumentError.value(pageSize, 'pageSize', '必须为正数');
    }
    if (pageSize > 999) {
      // 与真网关上限（_remoteMaxPageSize=999）对齐——mock 放行 1000 会让测试
      // 通过而生产抛 ArgumentError（假阳性）。
      throw ArgumentError.value(pageSize, 'pageSize', '不能超过 999');
    }
    if (page < 0) {
      throw ArgumentError.value(page, 'page', '不能为负数');
    }
    callLog.add('pull:$table');
    pullLog.add((table: table, since: since, page: page));
    _maybeThrow();
    final rows = (tables[table]?.values ?? const <Map<String, Object?>>[])
        .where((row) {
      // 与真网关 .eq('user_id', userId) 严格过滤一致：按值判定归属
      //（toMap 恒含 user_id 键但值可能为 null=无主；null 视为无主行按
      // allowUnownedRows 开关；非 null 他人值排除——防跨用户泄漏）。
      final rowUser = row['user_id'];
      if (rowUser != null && rowUser != userId) return false;
      if (rowUser == null && !allowUnownedRows) return false;
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
    // 每行浅拷贝（真网关返回 JSON 反序列化的独立副本——防调用方原地修改
    // mock 内部状态绕过写路径）。
    final pageRows =
        rows.sublist(start, end).map(Map<String, Object?>.of).toList();
    return RemoteRowsPage(
      rows: pageRows,
      hasMore: pageRows.length == pageSize,
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
      // 一致；防跨用户数据存在时误报本用户不存在的行）。与 fetchRowsSince 的
      // 过滤规则完全对齐（含 allowUnownedRows 严格模式）。
      final row = tables[table]?.values
          .where((r) => r[idKey] == id)
          .where((r) {
            // 与 fetchRowsSince 过滤规则完全对齐（含 allowUnownedRows 严格模式）。
            final rowUser = r['user_id'];
            if (rowUser != null && rowUser != userId) return false;
            if (rowUser == null && !allowUnownedRows) return false;
            return true;
          })
          .firstOrNull;
      if (row != null && row['updated_at'] is String) {
        final parsed = DateTime.parse(row['updated_at']! as String).toUtc();
        // 应用远端时间戳偏差（模拟"拉取后、推送检查时远端被并发更新"）。
        final bias = updatedAtBias[id];
        result[id] = bias == null ? parsed : parsed.add(bias);
      }
    }
    return result;
  }

  /// upsert 前钩子：在 fetchRemoteUpdatedAt 之后、写入之前被调用（模拟"拉取后、
  /// 推送前远端被并发更新"的竞态窗口——_pushTable 的跳过分支唯一可达路径）。
  void Function(String table, String userId)? onBeforePush;

  /// 最近一次 upsert 写入的行身份（断言推送跳过分支用）。
  final List<String> lastPushedIds = [];

  /// 远端时间戳偏差（id → 时差）：fetchRemoteUpdatedAt 返回存储值 + 偏差——
  /// 模拟"拉取后、推送检查时远端被并发更新"（跳过分支 `remoteAt.isAfter`
  /// 唯一可触发的构造）。
  final Map<String, Duration> updatedAtBias = {};

  @override
  Future<void> upsertRows({
    required String table,
    required String userId,
    required List<Map<String, Object?>> rows,
  }) async {
    callLog.add('push:$table');
    lastPushedIds.clear(); // 语义："本次调用尚未写入任何行"（失败路径也清空）
    _maybeThrow();
    onBeforePush?.call(table, userId);
    final target = tables.putIfAbsent(table, () => {});

    // 先对全部行做完整校验（防"先写 A 再抛 B"的部分写入——真网关同 chunk
    // 失败是整请求 4xx 不落任何行；mock 应与之对齐）。
    final prepared = <(String, Map<String, Object?>)>[];
    for (final row in rows) {
      // 与真网关一致：强制注入 user_id；**显式要求 updated_at 存在且可解析**
      //（真网关不会补齐——静默补会让"调用方漏传 updated_at"的 bug 在测试
      // 通过而在真实链路才暴露）。
      if (row['updated_at'] is! String ||
          DateTime.tryParse(row['updated_at']! as String) == null) {
        throw ArgumentError('upsertRows: 行必须携带可解析的 updated_at（行内容：$row）');
      }
      final owned = {...row, 'user_id': userId};
      // 行身份：常规表用 id；profile_settings 无 id 键（云端主键 user_id）。
      final id = owned['id'] ?? owned['user_id'];
      if (id == null) {
        throw ArgumentError('upsertRows: 行必须携带 id 或 user_id（行内容：$row）');
      }
      // 归属校验（写入前统一检查，防部分写入）：
      // - 目标行归属他人 → 拒绝覆盖（与 fetch 严格过滤对齐，模拟 RLS 拒绝）；
      // - 严格模式下目标行为无主行（user_id 为 null）→ 拒绝认领（防任意用户
      //   覆盖无主行，与 fetch 严格模式过滤对称）。
      final existing = target[id as String];
      final existingUser = existing?['user_id'];
      final claimedConflict =
          existing != null && existingUser is String && existingUser != userId;
      final unownedConflict =
          existing != null && existingUser == null && !allowUnownedRows;
      if (claimedConflict || unownedConflict) {
        throw StateError(
          'upsertRows: 目标行 $id 归属冲突（${existingUser ?? '无主'}），拒绝覆盖',
        );
      }
      prepared.add((id, owned));
    }
    for (final (id, owned) in prepared) {
      target[id] = Map.of(owned); // 深拷贝（防外部改原 Map 影响 mock 状态）
      lastPushedIds.add(id);
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
