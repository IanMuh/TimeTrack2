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

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:http/http.dart' as http;
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../data/repositories/repository_mappings.dart';
import 'remote_tables.dart';

/// Supabase 表网关实现。
class SupabaseRemoteTables with RepositoryMappings implements RemoteTableGateway {
  SupabaseRemoteTables({
    SupabaseClient? client,
    this.retryBaseDelay = _defaultRetryBaseDelay,
    this.maxAttempts = _defaultMaxAttempts,
    Future<void> Function(Duration delay)? retryDelay,
  })  : _retryDelay = retryDelay ?? Future<void>.delayed {
    // **单一路径校验+ 校验前置**：validateRetryParams 在
    // **访问 Supabase.instance 之前**执行（late final _client 构造体赋值）——
    // 未传 client 且 Supabase.instance 未初始化时，非法参数仍恒抛 ArgumentError
    //（不被环境 StateError 掩盖，错误语义不受环境状态影响）；合法性判定由
    // [_isValidRetryParams] 单一事实来源承载，debug/release 行为一致。
    validateRetryParams(maxAttempts, retryBaseDelay);
    _client = client ?? Supabase.instance.client;
  }

  late final SupabaseClient _client;

  /// 重试参数合法性判定（**单一事实来源**，校验共用）：
  /// - [maxAttempts] 必须为正且不超过 [maxAttemptsCap]；
  /// - [retryBaseDelay] 非负且不超过 [maxRetryBaseDelayCap]；
  /// - **组合级总等待预算**：`base * (2^(maxAttempts-1) - 1)`（指数
  ///   退避最坏总等待）不得超过 [maxTotalBackoffBudget]——两上限独立时最坏
  ///   组合（10 × 2s ≈ 17 分钟）与"防同步长时间无响应"目标冲突，预算约束
  ///   使允许范围内任一合法组合的单调用总阻塞 ≤ 预算。
  static bool _isValidRetryParams(int maxAttempts, Duration retryBaseDelay) {
    if (maxAttempts <= 0 || maxAttempts > maxAttemptsCap) return false;
    if (retryBaseDelay.isNegative ||
        retryBaseDelay > maxRetryBaseDelayCap) {
      return false;
    }
    return _totalBackoff(maxAttempts, retryBaseDelay) <= maxTotalBackoffBudget;
  }

  /// 指数退避最坏总等待：`base * (2^(n-1) - 1)`（n 次尝试间的重试等待合计）。
  static Duration _totalBackoff(int maxAttempts, Duration base) {
    if (maxAttempts <= 1) return Duration.zero;
    return base * ((1 << (maxAttempts - 1)) - 1);
  }

  /// 组合级总等待预算上限（**单一事实来源**）：单次调用所有重试等待合计
  /// 不得超过该值——默认参数（3 次 × 400ms = 1.2s）远低于预算；允许范围内
  /// 最坏组合（如 10 次 × 20ms、6 次 × 2s）总等待 ≤ 预算。
  @visibleForTesting
  static const maxTotalBackoffBudget = Duration(minutes: 2);

  /// 运行时校验（非法值抛 ArgumentError）；**合法性判定委托 [_isValidRetryParams]**
  ///（单一事实来源——校验路径共用同一判定条件，防条件漂移）。
  static void validateRetryParams(int maxAttempts, Duration retryBaseDelay) {
    if (_isValidRetryParams(maxAttempts, retryBaseDelay)) return;
    if (maxAttempts <= 0 || maxAttempts > maxAttemptsCap) {
      throw ArgumentError.value(
        maxAttempts,
        'maxAttempts',
        '必须为正数且不超过 $maxAttemptsCap',
      );
    }
    if (retryBaseDelay.isNegative ||
        retryBaseDelay > maxRetryBaseDelayCap) {
      throw ArgumentError.value(
        retryBaseDelay,
        'retryBaseDelay',
        '不得为负且不超过 $maxRetryBaseDelayCap',
      );
    }
    throw ArgumentError.value(
      '$maxAttempts / $retryBaseDelay',
      '重试参数组合',
      '组合级总退避等待不得超过 $maxTotalBackoffBudget'
          '（base * (2^(maxAttempts-1)-1)）',
    );
  }

  /// 重试参数上限（防误配使指数退避总等待失控）。
  /// **组合级预算已生效（r33 注释更新）**：[maxTotalBackoffBudget]（2 分钟）
  /// 在 [_isValidRetryParams] 中强制实施——两上限独立的"最坏组合约 17 分钟"
  /// 已不可达（10×2s 组合被拒）；**真实可达的最坏组合**在预算约束内，如
  /// 10×20ms（总 10.2s）、6×2s（总 62s）——单调用总阻塞 ≤ 预算，与"防同步
  /// 长时间无响应"目标一致。
  /// 默认值（maxAttempts=3 即首次+2 次重试、base=400ms）合计等待 400+800=1200ms。
  /// 为可测试性公开（`@visibleForTesting`）：测试按单一事实来源引用上限值
  ///（防"越界值不再越界"的用例与实现上限漂移，见 remote_tables_retry_test）。
  @visibleForTesting
  static const maxAttemptsCap = 10;
  @visibleForTesting
  static const maxRetryBaseDelayCap = Duration(seconds: 2);
  @visibleForTesting
  static const remoteMaxPageSize = _remoteMaxPageSize;

  /// 允许访问的表（5 张业务表 + profile_settings + tracking_rules）：防未知表名
  /// 经 `.from()` 误操作非白名单表（纵深防御）。
  static const _allowedTables = <String>{
    'activities',
    'activity_categories',
    'activity_category_links',
    'time_entries',
    'action_logs',
    'profile_settings',
    'tracking_rules',
  };

  /// 拉取分页大小上限：**max(服务端 db-max-rows 1000) - 1**——hasMore 需探测
  /// pageSize+1 行，pageSize=1000 时服务端截断会恒返回 1000 行导致 hasMore 恒
  /// false 静默漏数据；上限 999 保证 +1 探测行总能被返回。
  static const _remoteMaxPageSize = 999;

  /// `id in (...)` 分批大小（防 URL 过长）。
  static const _idBatchSize = 50;

  /// 默认最多尝试次数（**含首次**；=3 表示首次 + 2 次重试）与默认首次重试
  /// 等待基时（每次失败等待 `base * 2^(n-1)`）。实例化可注入（测试传零延迟
  /// 免真实等待、可精确断言尝试次数），生产用默认值。
  static const _defaultMaxAttempts = 3;
  static const _defaultRetryBaseDelay = Duration(milliseconds: 400);

  final int maxAttempts;
  final Duration retryBaseDelay;

  /// 退避等待执行器（**可注入延迟函数**，默认 [Future.delayed]）：测试注入
  /// 零等待的录制函数即可**确定性断言**退避序列（不依赖墙钟——CI 高负载/
  /// GC/JIT 会拉长真实延迟导致比例断言 flaky，见 remote_tables_retry_test
  /// 时序用例），生产恒为默认值。
  final Future<void> Function(Duration delay) _retryDelay;

  @override
  Future<RemoteRowsPage> fetchRowsSince({
    required String table,
    required String userId,
    DateTime? since,
    int pageSize = _remoteMaxPageSize,
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
    if (page < 0) {
      throw ArgumentError.value(page, 'page', '不能为负数');
    }
    final effectivePageSize = pageSize;
    // filter 方法（eq/gte）在 transform 方法（order/range）之前调用：
    // 前者返回 PostgrestFilterBuilder，后者返回 PostgrestTransformBuilder。
    final builder = _client.from(table).select().eq('user_id', userId);
    final filtered = since != null
        // since 用固定 6 位微秒 UTC ISO8601（utcString 单一转换点）：
        // Dart toIso8601String 在微秒为 0 时省略小数位，与云端恒定
        // 6 位微秒值做字典序 gte 比较时 'Z' > '.' 会把同一秒的远端行
        // 全部排除（漏同步）——项目不变量"字典序=时间序"。
        ? builder.gte('updated_at', utcString(since))
        : builder;
    // 次级排序键（唯一列）保证偏移分页跨请求稳定：多条行 updated_at 相同时
    // 页边界不丢/重行。常规表用 id；profile_settings 无 id 列，用 user_id。
    final tieBreakKey = table == 'profile_settings' ? 'user_id' : 'id';
    // 请求 pageSize+1 行（range 闭区间含上界）：hasMore 探测行——若服务端
    // max-rows 配置小于 pageSize，响应会被截断为 max-rows 行（< pageSize），
    // 此时**任何**判定（== 或 >=）都会把 hasMore 判 false、静默漏后续行——
    // 该配置错误由 pageSize 上限约束防护（[_remoteMaxPageSize]=999 < 服务端
    // 默认 max-rows 1000，正常部署不触发）。下方 hasMore 统一用 `>=` 判定
    //（返回数**达到请求页大小**即认为可能还有下一页；末页恰好满页时多一次
    // 空请求以结束，属预期行为）。
    final paged = filtered
        .order('updated_at')
        .order(tieBreakKey)
        .range(
          page * effectivePageSize,
          (page + 1) * effectivePageSize, // 上界含（range 闭区间）+1 行
        );
    final rows = await _withRetry(
      () async => (await paged).cast<Map<String, Object?>>(),
    );
    // hasMore 判定：返回行数**达到请求页大小**即认为可能还有下一页——
    // 服务端 max-rows 截断场景下 >= 比 "返回数 > pageSize" 更安全（不静默漏
    // 数据）；末页恰好满页时多一次空页请求以结束（预期行为）。
    final hasMore = rows.length >= effectivePageSize;
    final pageRows = hasMore
        ? rows.sublist(0, effectivePageSize)
        : rows;
    return RemoteRowsPage(
      rows: pageRows,
      hasMore: hasMore,
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
    // 与 fetchRowsSince/upsertRows 的表级判定对齐：profile_settings 无 id 列，
    // 漏传 idKey 时自动回退 user_id（防 PGRST204 报错或空结果静默漏同步）。
    final effectiveIdKey = table == 'profile_settings' ? 'user_id' : idKey;
    // 列名白名单按表收紧（纵深防御 + fail-fast）：业务表仅 id、
    // profile_settings 仅 user_id——防误用 idKey 导致空查询被误判
    // "远端无此行"而推旧覆盖新。
    if (table == 'profile_settings') {
      if (effectiveIdKey != 'user_id') {
        throw ArgumentError.value(idKey, 'idKey', 'profile_settings 仅允许 user_id');
      }
    } else if (effectiveIdKey != 'id') {
      throw ArgumentError.value(idKey, 'idKey', '业务表仅允许 id');
    }
    final result = <String, DateTime>{};
    for (var start = 0; start < ids.length; start += _idBatchSize) {
      final end = start + _idBatchSize < ids.length
          ? start + _idBatchSize
          : ids.length;
      final chunk = ids.sublist(start, end);
      final rows = await _withRetry(() async {
        // effectiveIdKey 为行身份列（默认 id；profile_settings 自动用 user_id）。
        final response = await _client
            .from(table)
            .select('$effectiveIdKey,updated_at')
            .eq('user_id', userId)
            .inFilter(effectiveIdKey, chunk);
        return response.cast<Map<String, Object?>>();
      });
      for (final row in rows) {
        final id = row[effectiveIdKey];
        final updatedAt = row['updated_at'];
        // 类型不符（null/非 String）与不可解析字符串一律 fail-stop：
        // 调用方（推送防旧）会把"结果缺该 id"误判为"远端无此行"而推本地旧行
        // 覆盖远端新数据——保持与解析失败的 fail-stop 语义一致。
        if (id is! String || updatedAt is! String) {
          throw FormatException(
            '[$table] 行身份列/updated_at 类型异常：'
            'id=$id, updated_at=$updatedAt',
          );
        }
        final parsed = DateTime.tryParse(updatedAt);
        if (parsed == null) {
          // fail-stop：脏数据不可静默跳过——否则调用方误判"远端无此行"
          // 而推本地旧行覆盖远端新数据（LWW 数据静默丢失）。
          throw FormatException(
            '[$table] 行 $id 的 updated_at 无法解析：$updatedAt',
          );
        }
        // 返回 UTC（与网关其余路径 UTC 语义一致；toLocal 会让返回值随
        // 机器时区偏移，下游与 UTC 值比较时产生整段偏差）。
        result[id] = parsed.toUtc();
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
    // 分批 upsert（与 fetchRemoteUpdatedAt 的 _idBatchSize 分批一致）：首次
    // 全量/大批量变更时防单请求体过大触发 413/超时，且每批独立退避重试。
    for (var start = 0; start < rows.length; start += _idBatchSize) {
      final end = start + _idBatchSize < rows.length
          ? start + _idBatchSize
          : rows.length;
      final chunk = rows.sublist(start, end);
      await _withRetry(() async {
        // 强制将行归属当前用户（纵深防御：即使调用方漏注入/本地残留他人 user_id
        // 的行，也不会越权覆盖/写入其他用户数据；RLS 仍作最终防线）。
        final sanitized = chunk
            .map((row) => {...row, 'user_id': userId})
            .toList();
        // PostgREST resolution=merge-duplicates：按主键合并（整行覆盖）。
        // onConflict 显式固化合并键（业务表 id；profile_settings 为 user_id），
        // 防 SDK 默认冲突列行为变化导致覆盖语义漂移。
        final onConflict = table == 'profile_settings' ? 'user_id' : 'id';
        await _client.from(table).upsert(sanitized, onConflict: onConflict);
      });
    }
  }

  /// 指数退避重试：网络层瞬时失败（含 SocketException/ClientException/
  /// TimeoutException/TLS 握手等）重试；服务端已处理的 4xx（HTTP 状态码）与
  /// PostgREST/PG 错误码（PGRST*/23505 等）不重试——重试无意义。
  Future<T> _withRetry<T>(Future<T> Function() operation) async {
    var attempt = 0;
    while (true) {
      try {
        return await operation();
      } on PostgrestException catch (e) {
        if (isNonRetryableCode(e.code)) rethrow;
        attempt += 1;
        if (!await _retryBackoff(attempt)) rethrow;
      } on TimeoutException {
        attempt += 1;
        if (!await _retryBackoff(attempt)) rethrow;
      } on SocketException {
        attempt += 1;
        if (!await _retryBackoff(attempt)) rethrow;
      } on http.ClientException catch (e) {
        // **证书类失败识别**：生产路径默认 HttpClient（IOClient）会把
        // dart:io 的 TlsException（含 HandshakeException/证书校验失败）包装为
        // ClientException 子类——证书类永久故障（重试无意义）按 message 识别
        // 直接上抛；其余 ClientException（网络瞬时）走退避重试。
        if (_isCertificateFailureMessage(e.message)) rethrow;
        attempt += 1;
        if (!await _retryBackoff(attempt)) rethrow;
      } on HandshakeException catch (e) {
        // TLS 握手失败（HandshakeException implements TlsException，均为
        // IOException 子类、非 SocketException 子类）——弱网/切换网络场景
        // 握手瞬时失败很常见，纳入退避重试（防穿透）。
        // **收窄说明（r26/r27）**：Android/iOS 上证书校验失败（过期/自签名/
        // 域名不符）通常**直接以 HandshakeException 抛出**（消息含
        // CERTIFICATE_VERIFY_FAILED 等 OS 错误，而非 CertificateException）——
        // 属确定性永久故障，重试无法修复反而延迟真实错误上报：按 message
        // 关键词识别并直接上抛；其余握手失败（瞬时）走退避重试。
        if (_isCertificateFailure(e)) rethrow;
        attempt += 1;
        if (!await _retryBackoff(attempt)) rethrow;
      } on TlsException catch (e) {
        // **TlsException 兜底**：CertificateException / 裸 TlsException
        // 与 HandshakeException 是**同级**（均 implements TlsException）——
        // 非 HandshakeException 子类不匹配上方分支，直接逸出会失去退避重试/
        // 证书分类；此处复用同一 message 判定做证书/瞬时分流（HandshakeException
        // 子类已被上方分支捕获，本分支只兜剩余类型）。
        if (_isCertificateFailureMessage(e.message)) rethrow;
        attempt += 1;
        if (!await _retryBackoff(attempt)) rethrow;
      }
    }
  }

  /// 瞬时失败共用退避节奏（**单一事实来源**，防各异常分支延迟漂移）：
  /// [attempt] 为已失败次数（≥1）；返回 true 表示已按 `base * 2^(n-1)` 等待、
  /// 可继续下一轮；返回 false 表示已达最大尝试次数，调用方应 rethrow 原异常。
  Future<bool> _retryBackoff(int attempt) async {
    if (attempt >= maxAttempts) return false;
    // 整数位移统一指数计算（与 _totalBackoff 的 `1 << (n-1)` 一致——
    // 同一公式单一写法，防 pow/位移两套表达漂移；attempt ≤ 10 无精度差异）。
    await _retryDelay(retryBaseDelay * (1 << (attempt - 1)));
    return true;
  }

  /// HandshakeException 是否属**证书类永久失败**（过期/自签名/域名不符/
  /// 不受信 CA）：Android/iOS 通常以 HandshakeException 直接抛出（消息含
  /// CERTIFICATE_VERIFY_FAILED 等 OS 错误）——确定性故障重试无意义，直接
  /// 上抛；委托 [_isCertificateFailureMessage] 按 message 判定（单一事实来源）。
  static bool _isCertificateFailure(HandshakeException e) =>
      _isCertificateFailureMessage(e.message);

  /// 证书类失败 message 判定（**单一事实来源**，HandshakeException/TlsException/
  /// http.ClientException 分支共用——生产 IOClient 会把 TlsException 包装为
  /// ClientException 子类，多条路径须一致，见 _withRetry）。
  /// **归一化**：真实平台错误文本多为空格分隔（`CERTIFICATE_VERIFY_FAILED:
  /// hostname mismatch`、iOS `The certificate was not trusted`、OpenSSL
  /// `unable to verify the first certificate`）——先归一化分隔符为下划线再
  /// 匹配（与 supabase_sync_backend 的 sessionExpiredMessage 同一手法）。
  /// **收窄说明**：只匹配**明确的证书校验失败特征**——裸 `CERTIFICATE`/
  /// `TRUSTED` 子串过宽（弱网/切换网络时 TLS 握手在证书交换阶段因瞬时中断
  /// 失败的文本常含 "SSL … certificate" 类字样），会误伤本可恢复的瞬时失败
  /// 而放弃退避重试、降低同步自愈率；不匹配 `HANDSHAKE_FAILURE_ALERT`
  ///（TLS alert 40，可由无共享密码套件/协议版本不匹配等非证书原因触发）。
  /// 证书 message 归一化正则（**类级常量**）：异常处理路径（HandshakeException/
  /// TlsException/ClientException 分支）每次失败都会调用 [_isCertificateFailureMessage]
  /// ——常量避免热路径重复构造（单一事实来源语义更明确）。
  static final _nonAlnumRegExp = RegExp(r'[^A-Z0-9]+');

  static bool _isCertificateFailureMessage(String message) {
    final msg = message.toUpperCase().replaceAll(_nonAlnumRegExp, '_');
    return msg.contains('CERTIFICATE_VERIFY_FAILED') ||
        msg.contains('BAD_CERTIFICATE') ||
        msg.contains('UNKNOWN_CA') ||
        // OpenSSL "self signed certificate" / "certificate is not yet valid"
        // 变体（iOS 证书未生效、本地自签证书等确定性故障）。
        msg.contains('SELF_SIGNED_CERT') ||
        msg.contains('NOT_YET_VALID') ||
        msg.contains('CERTIFICATE_EXPIRED') ||
        // "certificate has expired" / "certificate is expired" 变体（归一化
        // 后不含 CERTIFICATE_EXPIRED 子串——补收窄关键词防此类确定性证书
        // 故障被当瞬时反复退避重试）。
        msg.contains('CERTIFICATE_HAS_EXPIRED') ||
        msg.contains('CERTIFICATE_IS_EXPIRED') ||
        msg.contains('HOSTNAME_MISMATCH') ||
        msg.contains('NOT_TRUSTED') ||
        // OpenSSL "unable to verify the first certificate" 等变体。
        msg.contains('UNABLE_TO_VERIFY') ||
        // iOS "The certificate is not valid for this host"（域名不符确定性失败）。
        msg.contains('IS_NOT_VALID_FOR_THIS_HOST') ||
        // OpenSSL "unable to get local issuer certificate"（不受信根 CA）。
        msg.contains('LOCAL_ISSUER_CERTIFICATE');
  }

  /// 表名白名单校验（防误操作非白名单表）。
  static void _assertAllowedTable(String table) {
    if (!_allowedTables.contains(table)) {
      throw ArgumentError.value(table, 'table', '不在白名单内');
    }
  }

  /// 判定错误码是否**不可重试**：HTTP 4xx、PostgREST 错误码（PGRST*）与
  /// **永久性 PG SQLSTATE**（23xxx 约束冲突、42xxx 语法/未定义对象、
  /// 22xxx 数据异常等）。缺失 code 视为协议/解析失败（不重试——网络瞬时
  /// 错误已由 SocketException/ClientException/TimeoutException 分支处理）。
  /// 瞬时类 SQLSTATE（08xxx 连接失败、53xxx 资源不足、57xxx 运维干预、
  /// **40xxx 中的 40001/40P01/40000/40003**——事务冲突/死锁/通用回滚/结果
  /// 未知）走退避重试（稍后重试很可能成功）；**40xxx 其余类（40002/40P02
  /// 等）按永久处理**——约束性事务失败与快照过旧重试无意义（保守不重试）。
  /// **40000/40003 豁免依据（r48）**：40000（transaction_rollback 通用回滚）
  /// 多为瞬时原因、40003（statement_completion_unknown）结果未知——标准
  /// 重试指引均建议重试；本网关 upsert 按主键幂等（merge-duplicates）、
  /// fetch 只读，重试安全（不产生重复副作用）。
  /// 为可测试性公开为静态方法（`@visibleForTesting` 标注）；同时作为
  /// **公共 API 表面**存在——重试策略的单一事实来源，改判矩阵须同步更新
  /// 测试（test/api/supabase/remote_tables_retry_test.dart 的判定矩阵用例）。
  @visibleForTesting
  static bool isNonRetryableCode(String? code) {
    if (code == null) return true;
    final statusCode = int.tryParse(code);
    // **HTTP 状态码分支仅接受 3 位码**（100-599）：5 位数字型 SQLSTATE
    //（如 40001 serialization_failure、23505 唯一冲突）无法满足
    // `code.length == 3`，不会落入 4xx 分支（即使 08001 等以 0 开头的码
    // int.tryParse 值 < 10000——靠的是 length 守卫而非数值前提）——显式
    // length 约束使"40001 落入 SQLSTATE
    // 豁免逻辑"成为结构上明确的事实（防未来范围改动把 5 位码误吸入 4xx 分支
    // 导致 40001/40P01 瞬时豁免变死代码）。
    if (statusCode != null &&
        code.length == 3 &&
        statusCode >= 400 &&
        statusCode < 500) {
      // 429（限流）是瞬时错误：在指数退避框架下应重试（遵循 Retry-After），
      // 其余 4xx（权限/校验/无数据）不可重试。
      if (statusCode == 429) return false;
      return true;
    }
    if (code.startsWith('PGRST')) return true;
    if (!RegExp(r'^[0-9A-Z]{5}$').hasMatch(code)) return false; // 未知格式：可重试
    // PG SQLSTATE 前两位为类码：永久类 → 不可重试；瞬时类 → 可重试。
    const permanentClasses = {
      '22', // 数据异常（非法值/非法文本表示）
      '23', // 约束冲突（唯一/外键/非空）
      '42', // 语法错误/未定义对象/列
      '2F', // 排序规则
      '28', // 权限
      '3D', // 非法目录名
      '3F', // 非法 schema 名
      '40', // 事务回滚类——其中 40001/40P01 为瞬时错误单独豁免（可重试），
      //        其余 40 类（40002/40P02 等）按永久处理（保守不重试）
      '25', // 非法事务状态
    };
    final cls = code.substring(0, 2);
    if (permanentClasses.contains(cls)) {
      // 40 类中的 40001（serialization_failure）/40P01（deadlock_detected）/
      // 40000（transaction_rollback 通用回滚）/40003（statement_completion_unknown）
      // 是瞬时/结果未知错误，应可重试（见方法头 r48 豁免依据——网关幂等，
      // 重试安全）。
      if (cls == '40' &&
          (code == '40001' ||
              code == '40P01' ||
              code == '40000' ||
              code == '40003')) {
        return false;
      }
      return true;
    }
    return false; // 其他（08/53/57 等瞬时类）→ 可重试
  }
}
