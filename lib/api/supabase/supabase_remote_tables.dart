/// Supabase 远程表网关（PostgREST via supabase_flutter），供 CloudSyncEngine 使用。
///
/// - 增量拉取：`user_id=eq.X & updated_at=gte.since`，按 updated_at 升序分页；
/// - 推送防旧：批量查远端 `updated_at`（`id=in.(...)`，分批 50 防 URL 超长）；
/// - 批量 upsert：PostgREST `resolution=merge-duplicates`（按 id 合并，LWW 由
///   行内 updated_at 承载——服务端只做整行覆盖，比较在客户端完成）；
/// - 网络瞬断指数退避重试 3 次（校验/协议失败不重试）。
library;

import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:http/http.dart' as http;
import 'package:supabase_flutter/supabase_flutter.dart';

import 'remote_tables.dart';

/// Supabase 表网关实现。
class SupabaseRemoteTables implements RemoteTableGateway {
  SupabaseRemoteTables({SupabaseClient? client})
      : _client = client ?? Supabase.instance.client;

  final SupabaseClient _client;

  /// 允许访问的表（5 张业务表 + profile_settings）：防未知表名经 `.from()`
  /// 误操作非白名单表（纵深防御）。
  static const _allowedTables = <String>{
    'activities',
    'activity_categories',
    'activity_category_links',
    'time_entries',
    'action_logs',
    'profile_settings',
  };

  /// 拉取分页大小上限（PostgREST 单页 max-rows 由服务端配置，默认 1000）。
  static const _remoteMaxPageSize = 1000;

  /// `id in (...)` 分批大小（防 URL 过长）。
  static const _idBatchSize = 50;

  static const _maxAttempts = 3;
  static const _retryBaseDelay = Duration(milliseconds: 400);

  @override
  Future<RemoteRowsPage> fetchRowsSince({
    required String table,
    required String userId,
    DateTime? since,
    int pageSize = 1000,
    int page = 0,
  }) async {
    _assertAllowedTable(table);
    if (pageSize < 1) {
      throw ArgumentError.value(pageSize, 'pageSize', '必须为正数');
    }
    if (pageSize > _remoteMaxPageSize) {
      // 明确拒绝而非静默截断：调用方按自己的 pageSize 计算 page 偏移，
      // 静默截断会使 range 起点错位造成丢行/重行。
      throw ArgumentError.value(
        pageSize,
        'pageSize',
        '不能超过 $_remoteMaxPageSize',
      );
    }
    final effectivePageSize = pageSize;
    // filter 方法（eq/gte）在 transform 方法（order/range）之前调用：
    // 前者返回 PostgrestFilterBuilder，后者返回 PostgrestTransformBuilder。
    final builder = _client.from(table).select().eq('user_id', userId);
    final filtered = since != null
        ? builder.gte('updated_at', since.toUtc().toIso8601String())
        : builder;
    // 次级排序键（唯一列）保证偏移分页跨请求稳定：多条行 updated_at 相同时
    // 页边界不丢/重行。常规表用 id；profile_settings 无 id 列，用 user_id。
    final tieBreakKey = table == 'profile_settings' ? 'user_id' : 'id';
    final paged = filtered
        .order('updated_at')
        .order(tieBreakKey)
        .range(page * effectivePageSize, (page + 1) * effectivePageSize - 1);
    final rows = await _withRetry(
      () async => (await paged).cast<Map<String, Object?>>(),
    );
    return RemoteRowsPage(
      rows: rows,
      hasMore: rows.length == effectivePageSize,
    );
  }

  @override
  Future<Map<String, DateTime>> fetchRemoteUpdatedAt({
    required String table,
    required String userId,
    required List<String> ids,
    String idKey = 'id',
  }) async {
    _assertAllowedTable(table);
    final result = <String, DateTime>{};
    for (var start = 0; start < ids.length; start += _idBatchSize) {
      final end = start + _idBatchSize < ids.length
          ? start + _idBatchSize
          : ids.length;
      final chunk = ids.sublist(start, end);
      final rows = await _withRetry(() async {
        // idKey 为行身份列（默认 id；profile_settings 无 id 列，用 user_id）。
        final response = await _client
            .from(table)
            .select('$idKey,updated_at')
            .eq('user_id', userId)
            .inFilter(idKey, chunk);
        return response.cast<Map<String, Object?>>();
      });
      for (final row in rows) {
        final id = row[idKey];
        final updatedAt = row['updated_at'];
        if (id is String && updatedAt is String) {
          final parsed = DateTime.tryParse(updatedAt);
          // 返回 UTC（与网关其余路径 UTC 语义一致；toLocal 会让返回值随
          // 机器时区偏移，下游与 UTC 值比较时产生整段偏差）。
          if (parsed != null) result[id] = parsed.toUtc();
        }
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
    _assertAllowedTable(table);
    if (rows.isEmpty) return; // 防御：空数组无意义，防 PostgREST 空 body 4xx。
    await _withRetry(() async {
      // 强制将行归属当前用户（纵深防御：即使调用方漏注入/本地残留他人 user_id
      // 的行，也不会越权覆盖/写入其他用户数据；RLS 仍作最终防线）。
      final sanitized = rows
          .map((row) => {...row, 'user_id': userId})
          .toList();
      // PostgREST resolution=merge-duplicates：按主键合并（整行覆盖）。
      // onConflict 显式固化合并键（业务表 id；profile_settings 为 user_id），
      // 防 SDK 默认冲突列行为变化导致覆盖语义漂移。
      final onConflict = table == 'profile_settings' ? 'user_id' : 'id';
      await _client.from(table).upsert(sanitized, onConflict: onConflict);
    });
  }

  /// 指数退避重试：网络层瞬时失败（含 SocketException/ClientException 等）重试；
  /// 服务端已处理的 4xx（HTTP 状态码）与 PostgREST/PG 错误码（PGRST*/23505 等）
  /// 不重试——重试无意义。
  Future<T> _withRetry<T>(Future<T> Function() operation) async {
    var attempt = 0;
    while (true) {
      try {
        return await operation();
      } on PostgrestException catch (e) {
        if (_isNonRetryableCode(e.code)) rethrow;
        attempt += 1;
        if (attempt >= _maxAttempts) rethrow;
        await Future<void>.delayed(_retryBaseDelay * pow(2, attempt - 1));
      } on TimeoutException {
        attempt += 1;
        if (attempt >= _maxAttempts) rethrow;
        await Future<void>.delayed(_retryBaseDelay * pow(2, attempt - 1));
      } on SocketException {
        attempt += 1;
        if (attempt >= _maxAttempts) rethrow;
        await Future<void>.delayed(_retryBaseDelay * pow(2, attempt - 1));
      } on http.ClientException {
        attempt += 1;
        if (attempt >= _maxAttempts) rethrow;
        await Future<void>.delayed(_retryBaseDelay * pow(2, attempt - 1));
      }
    }
  }

  /// 表名白名单校验（防误操作非白名单表）。
  static void _assertAllowedTable(String table) {
    if (!_allowedTables.contains(table)) {
      throw ArgumentError.value(table, 'table', '不在白名单内');
    }
  }

  /// 判定错误码是否不可重试：HTTP 4xx、PostgREST 错误码（PGRST*）、
  /// PG SQLSTATE。SQLSTATE 类码通常**以数字开头**（23505、22P02、42P01），
  /// 格式为 5 位字母数字——用宽松字符集匹配而非"2 字母+3 数字"。
  /// 注意：SQLSTATE 中少数瞬时类（如 40001 序列化失败、40P01 死锁、
  /// 57P01/57P03 停机、08006 连接失败）本应可重试，但 PostgREST 通常已把
  /// 网络层错误转成 HTTP 5xx/连接异常走其它分支——此处对 SQLSTATE 一律
  /// 视为不可重试（保守：避免对永久性错误空等 3 次退避）。
  static bool _isNonRetryableCode(String? code) {
    if (code == null) return false;
    final statusCode = int.tryParse(code);
    if (statusCode != null && statusCode >= 400 && statusCode < 500) {
      return true;
    }
    if (code.startsWith('PGRST')) return true;
    return RegExp(r'^[0-9A-Z]{5}$').hasMatch(code);
  }
}
