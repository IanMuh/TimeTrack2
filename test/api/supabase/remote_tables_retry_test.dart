import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:timetrack2/api/supabase/remote_tables.dart';
import 'package:timetrack2/api/supabase/supabase_remote_tables.dart';

/// SupabaseRemoteTables 网关网络容错测试：注入真 SDK + MockClient（http/testing）
/// 模拟传输层瞬时失败（SocketException / TLS 握手 IOException / TimeoutException /
/// ClientException），锁定 `_withRetry` 的退避重试语义（含 TLS 握手等
/// IOException 分支）。
///
/// 构造要点：
/// - `postgrestOptions: PostgrestClientOptions(retryEnabled: false)` 关闭
///   postgrest 内部重试层（对 **POST 路径完全生效**——`_executeWithRetry`
///   只对 GET/HEAD 重试，POST 每次都透传到 `_withRetry`，故计数断言用
///   POST 路径；GET 路径存在 SDK 内层重试叠加，无法关闭，只做语义断言）；
/// - `retryBaseDelay: Duration.zero` 注入零延迟，免真实指数退避等待。
///
/// **已知依赖（测试有效性边界，r53 更新）**：精确计数断言（attempts == 3）
/// 依赖 postgrest-dart 的**内部实现行为**（POST 请求不被 SDK 内层重试、每次
/// send 失败都透传到 `_withRetry`）——postgrest **已直接固定在 pubspec.yaml
///（2.9.1，依赖 supabase_flutter → supabase 2.16.0 的精确传递版本）**；
/// 升级 postgrest 改变内部重试策略时断言会失败提示（而非静默通过，仍具回归
/// 价值，但需核验版本行为）。
/// 退避**公式**（base * 2^(n-1)）由实现单一来源 [_retryBackoff] 承载，本文件
/// 用零延迟注入覆盖语义；非零 base 的等待行为由 [_retryBackoff] 自身逻辑
/// 保证（公式直读，无独立延迟断言）。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  // **存储隔离**：buildGateway 的 calls 计数器假设 SupabaseClient
  // 构造期间不发出请求——GoTrueClient 构造会异步恢复持久化会话（经
  // shared_preferences 平台存储），有会话时构造期请求会偏移 calls 计数、
  // 使"失败 N 次后重试恢复"用例静默假通过；重置 mock 存储消除该隐式依赖。
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  /// 构造网关：transport 按调用次数返回（前 [failures] 次抛 [error]，之后
  /// 返回 200 空 JSON 数组）。PostgREST 对空数组响应解析为 []。
  /// [retryBaseDelay]/[maxAttempts] 注入网关（测试用零延迟免真实等待，
  /// 计数断言精确锁定 _maxAttempts 语义）；[onCall] 每次 send 回调（计数）；
  /// [retryDelay] 注入可替换退避等待执行器（时序断言用录制式假延迟，
  /// 见"非零 base 退避时序"用例）。
  SupabaseRemoteTables buildGateway({
    required Exception Function() error,
    required int failures,
    Duration retryBaseDelay = Duration.zero,
    int maxAttempts = 3,
    void Function()? onCall,
    Future<void> Function(Duration delay)? retryDelay,
  }) {
    // **仅统计 PostgREST 请求（r49）**：calls 计数器若统计 MockClient 上
    // 全部请求，测试执行期间 auth 层异步发起的会话恢复/刷新请求会消耗失败
    // 额度或偏移计数——轻则精确计数用例大声失败，重则"失败 N 次后恢复"
    // 用例因单次失败被 auth 请求消耗而静默假通过。按 URL path 过滤，只对
    // `/rest/v1/` 的 PostgREST 请求施加失败额度/计数（GoTrue 路径 `/auth/v1/*`
    // 一律放行且不计入）。
    var calls = 0;
    final client = MockClient((request) async {
      final isPostgrest = request.url.path.startsWith('/rest/v1/');
      if (isPostgrest) {
        calls += 1;
        onCall?.call();
      }
      if (isPostgrest && calls <= failures) {
        // 模拟传输层失败（在 send 阶段抛出，与真网络异常同源）。
        throw error();
      }
      // 必须携带 request：postgrest `_parseResponse` 依赖 `response.request!`，
      // MockClient 原样透传 Response.request（默认 null 会触发空检查崩溃）。
      return http.Response('[]', 200,
          headers: {'content-type': 'application/json'}, request: request);
    });
    final supabase = SupabaseClient(
      'https://example.supabase.co',
      'test-anon-key',
      httpClient: client,
      postgrestOptions: const PostgrestClientOptions(retryEnabled: false),
      authOptions: const AuthClientOptions(
        autoRefreshToken: false,
        authFlowType: AuthFlowType.implicit,
      ),
    );
    // **构造期零请求断言（r29，r30 改运行时，r49 限定 PostgREST）**：calls
    // 计数依赖"SupabaseClient 构造期间不发 PostgREST 请求"——当前 SDK 因空
    // 存储不触发会话恢复请求，但该行为不受本项目控制；若未来构造期发请求，
    // calls 被偏移会导致"失败 1 次后重试恢复"等用例静默假通过（构造期请求
    // 消耗掉失败额度）。用**运行时检查**（非 assert——release/--no-assert
    // 模式下同样生效），假设失效时立即报错。注：r49 起只统计 `/rest/v1/`
    // 请求，GoTrue 认证路径（/auth/v1/*）不消耗失败额度，本检查语义为
    // "构造期不得发起任何 PostgREST 请求"。
    if (calls != 0) {
      throw StateError('SupabaseClient 构造期间不应发出请求（calls=$calls）');
    }
    return SupabaseRemoteTables(
      client: supabase,
      retryBaseDelay: retryBaseDelay,
      maxAttempts: maxAttempts,
      retryDelay: retryDelay,
    );
  }

  /// 触发一次拉取并**校验返回数据正确性**（重试成功路径的返回数据不被丢弃）：
  /// 断言空页 + hasMore=false——防"重试成功但响应解析/返回数据出错（mock
  /// 非 `[]`/字段丢失）时用例仍通过"。
  Future<void> fetchOnce(SupabaseRemoteTables gateway) async {
    final page = await gateway.fetchRowsSince(
      table: 'activities',
      userId: 'user-1',
    );
    expect(page.rows, isEmpty, reason: '重试成功后返回空页（数据正确）');
    expect(page.hasMore, isFalse, reason: '重试成功后 hasMore=false');
  }

  /// 触发一次推送（upsertRows，POST 路径）——postgrest SDK 内部重试
  ///（`PostgrestBuilder._executeWithRetry`）只对 GET/HEAD 生效，POST 每次
  /// send 失败都透传到 `_withRetry`，故 handler 调用次数 = `_withRetry`
  /// 尝试次数 **精确等于 maxAttempts**（可确定性断言；GET 路径有 SDK 内层
  /// 重试叠加，无法关闭——见文件头注释）。
  Future<void> pushOnce(SupabaseRemoteTables gateway) => gateway.upsertRows(
        table: 'activities',
        userId: 'user-1',
        rows: [
          {
            'id': 'row-1',
            'user_id': 'user-1',
            'name': 'x',
            'color': 0,
            'updated_at': '2026-08-11T10:00:00.000000Z',
          },
        ],
      );

  group('_withRetry 传输层瞬时失败', () {
    test('SocketException：失败 1 次后重试恢复', () async {
      final recover = buildGateway(
        error: () => const SocketException('connection reset'),
        failures: 1,
      );
      await pushOnce(recover); // 不抛 → 重试生效
    });

    test('恢复型 POST：恰好 failures+1 次 send（防成功前额外尝试）', () async {
      // POST 路径可确定性计数（SDK 内层不重试）——补充"恰好失败 N 次后
      // 成功"的精确性验证：若 _withRetry 误引入额外循环（成功前多试若干次
      // 但未耗尽），仅断言"不抛"的用例会通过，此断言可检出。
      var attempts = 0;
      final recover = buildGateway(
        error: () => const SocketException('connection reset'),
        failures: 2,
        onCall: () => attempts += 1,
      );
      await pushOnce(recover);
      expect(attempts, 3, reason: '2 次失败 + 1 次成功 = 恰好 3 次 send');
    });

    test('SocketException：持续失败耗尽重试后上抛原异常', () async {
      // failures 必须 ≥ maxAttempts 才触发耗尽路径（首次 + 重试全失败）；
      // 用 maxAttempts 表达（非魔法数字——失败次数再多语义不变，只是确保
      // 永不成功），且足够大以抵御 postgrest 内部兜底尝试的叠加。
      final exhaust = buildGateway(
        error: () => const SocketException('connection reset'),
        failures: 20,
      );
      await expectLater(
        pushOnce(exhaust),
        throwsA(isA<SocketException>()),
        reason: '瞬时失败耗尽重试后必须上抛原始异常（不静默吞掉）',
      );
    });

    test('GET 拉取路径（fetchRowsSince）在瞬时失败后同样重试恢复', () async {
      // GET 路径会叠加 SDK 内层重试（含真实退避延迟），只验证语义（恢复成功、
      // 不抛），不做精确计数。
      // **failures=5 + maxAttempts=6 + 退避录制器（r48/r49/r50）**：不能只注入
      // 1 次失败——若 SDK 内层重试会吸收单次瞬时失败，`_withRetry` 的 GET
      // 重试分支根本没被触发，即使本实现 GET 重试逻辑失效用例仍通过（静默
      // 假通过）。注入超过 SDK 内层重试次数的失败（5 次）确保异常穿透到
      // `_withRetry`；**maxAttempts: 6（r50）** 让 `_withRetry` 容量覆盖
      // 0~4 次漏透失败（SDK 内层吸收全部 5 次时 requestedDelays 为空、本用例
      // 失败提示）——通过区间为"SDK 内层重试 < 5 次"，不再收窄成"恰好重试
      // 3~4 次"的窄带；**并用注入的录制式假延迟断言 `_withRetry` 确实执行过
      // 退避**（把"穿透到 _withRetry"从隐含假设变为显式断言）。
      final requestedDelays = <Duration>[];
      final gateway = buildGateway(
        error: () => const SocketException('connection reset'),
        failures: 5,
        maxAttempts: 6,
        retryDelay: (delay) async {
          requestedDelays.add(delay);
        },
      );
      await fetchOnce(gateway);
      expect(requestedDelays, isNotEmpty,
          reason: 'GET 重试必须实际执行过 _withRetry 退避（穿透到本实现重试分支）');
    });

    test('GET 拉取路径持续失败：耗尽重试后上抛网络类异常（不静默吞掉）', () async {
      // 读路径（云同步主读路径）耗尽后原始异常必须透传——failures 足够大 +
      // throwsA(网络类异常) 确定性断言；断言用 `isA<SocketException>()` 或
      // `isA<http.ClientException>()` 任一（SDK 内层耗尽时可能包装异常类型，
      // 放宽到网络类避免因无关原因误报——防读路径重试耗尽后异常被吞掉/
      // 改写导致同步静默失败）。
      final exhaust = buildGateway(
        error: () => const SocketException('connection reset'),
        failures: 100,
      );
      await expectLater(
        fetchOnce(exhaust),
        throwsA(anyOf(
          isA<SocketException>(),
          isA<http.ClientException>(),
          isA<HandshakeException>(),
        )),
        reason: 'GET 路径耗尽重试后必须上抛网络类异常',
      );
    });

    test('耗尽重试：恰好 maxAttempts 次尝试（守护 _maxAttempts=3 语义）', () async {
      // 用 POST 路径（upsertRows）精确计数：postgrest SDK 内层重试只对
      // GET/HEAD 生效（POST 每次失败都透传），handler 调用次数 = _withRetry
      // 尝试次数 = 恰好 maxAttempts——即使实现把重试上限回退为 1/2，测试
      // 也会失败（守护语义不被静默削弱）。
      var attempts = 0;
      final exhaust = buildGateway(
        error: () => const SocketException('connection reset'),
        failures: 20,
        maxAttempts: 3,
        onCall: () => attempts += 1,
      );
      await expectLater(
        pushOnce(exhaust),
        throwsA(isA<SocketException>()),
        reason: '耗尽重试后必须上抛原始异常（不静默吞掉）',
      );
      expect(attempts, 3,
          reason: 'maxAttempts=3（含首次）⇒ 恰好 3 次 send 尝试');
    });

    test('非零 base 退避时序：录制式假延迟确定性断言退避序列（r47 #9 终版）', () async {
      // **确定性方案（r47 #9，替代真实墙钟）**：注入录制式假延迟（记录请求
      // 的等待时长、立即返回不等待），直接断言**退避序列** `[base, 2base,
      // 4base]`——彻底消除真实时钟时序断言对调度噪声的敏感性（旧方案
      // Stopwatch + 比例阈值在 CI 高负载/GC/JIT 下拉长前序间隔会误报）。
      // 公式（base * 2^(n-1)）仍由 _retryBackoff 单一实现承载，本用例锁定
      // 实际请求的等待序列精确等于公式值（含次序），公式回归立即暴露。
      final requestedDelays = <Duration>[];
      final gateway = buildGateway(
        error: () => const SocketException('connection reset'),
        failures: 3,
        maxAttempts: 4,
        retryBaseDelay: const Duration(milliseconds: 120),
        retryDelay: (delay) async {
          requestedDelays.add(delay);
          // 不真实等待——只记录请求的时长（退避语义由引擎等待、测试断言
          // 请求值，双方互不依赖墙钟）。
        },
      );
      await pushOnce(gateway); // 3 次失败 + 1 次成功 = 4 次 send
      // 精确断言指数退避序列：120ms（2^0×base）/ 240ms（2^1×base）/
      // 480ms（2^2×base）——任何公式回归（base 缩放错、位移错、次序错）
      // 都会逐项暴露。
      expect(requestedDelays, const [
        Duration(milliseconds: 120),
        Duration(milliseconds: 240),
        Duration(milliseconds: 480),
      ], reason: '退避序列必须精确等于 base * 2^(n-1)（n 从 1 计）');
    });

    test('IOException（TLS 握手，如 HandshakeException）：纳入退避重试', () async {
      // HandshakeException 是 IOException 子类、非 SocketException 子类——
      // 第 11 轮新增分支的核心覆盖点。
      final gateway = buildGateway(
        error: () => const HandshakeException('TLS handshake failed'),
        failures: 2,
      );
      await pushOnce(gateway); // 2 次失败 + 重试成功
    });

    test('IOException 耗尽重试后上抛原异常（与 SocketException 分支同语义）', () async {
      final exhaust = buildGateway(
        error: () => const HandshakeException('TLS handshake failed'),
        failures: 20,
      );
      await expectLater(
        pushOnce(exhaust),
        throwsA(isA<HandshakeException>()),
        reason: 'IOException 分支耗尽重试后上抛原始异常（不静默吞掉）',
      );
    });

    test('证书类失败（message 含 CERTIFICATE_VERIFY_FAILED）→ 不重试、立即上抛', () async {
      // 证书校验失败是确定性永久故障（Android/iOS 常以 HandshakeException
      // 直接抛出、消息含 CERTIFICATE_VERIFY_FAILED）——重试无意义，立即上抛
      //（不消耗额外尝试；与 23505 永久码用例断言方式对齐）。
      var attempts = 0;
      final gateway = buildGateway(
        error: () => const HandshakeException(
          'CERTIFICATE_VERIFY_FAILED: hostname mismatch',
        ),
        failures: 100,
        onCall: () => attempts += 1,
      );
      await expectLater(
        pushOnce(gateway),
        throwsA(isA<HandshakeException>()),
        reason: '证书类失败立即上抛（不静默吞掉）',
      );
      expect(attempts, 1, reason: '证书类失败只尝试一次（无重试）');
    });

    test('证书变体正样本：certificate has expired / bad certificate 均不重试', () async {
      // 覆盖 _isCertificateFailureMessage 其余关键词子集（防某一关键词回归
      // 丢失时该变体被误归入瞬时重试分支）。
      for (final message in [
        'certificate has expired',
        'bad certificate',
        'unable to verify the first certificate',
        'self signed certificate',
        'certificate is not yet valid',
      ]) {
        var attempts = 0;
        final gateway = buildGateway(
          error: () => HandshakeException(message),
          failures: 100,
          onCall: () => attempts += 1,
        );
        await expectLater(
          pushOnce(gateway),
          throwsA(isA<HandshakeException>()),
          reason: '证书变体立即上抛：$message',
        );
        expect(attempts, 1, reason: '证书变体只尝试一次（无重试）：$message');
      }
    });

    test('裸 TlsException 含证书关键词 → 不重试立即上抛（r48 补覆盖）', () async {
      // `on TlsException` 分支兜底 CertificateException / 裸 TlsException
      //（非 HandshakeException 子类、不匹配上方分支）——复用同一证书 message
      // 判定做永久/瞬时分流。本文件其余 TLS 用例注入的都是 HandshakeException
      // 或 http.ClientException，该分支此前无直接覆盖。
      var attempts = 0;
      final gateway = buildGateway(
        error: () => TlsException(
          'CERTIFICATE_VERIFY_FAILED: hostname mismatch',
        ),
        failures: 100,
        onCall: () => attempts += 1,
      );
      await expectLater(
        pushOnce(gateway),
        throwsA(isA<TlsException>()),
        reason: '裸 TlsException 证书类失败立即上抛（不静默吞掉）',
      );
      expect(attempts, 1, reason: '裸 TlsException 证书类失败只尝试一次');
    });

    test('裸 TlsException 无证书关键词 → 纳入退避重试后恢复（r48 补覆盖）', () async {
      // 瞬时 TLS 失败（弱网/切换网络握手中断）走退避重试——与 HandshakeException
      // 瞬时分支同语义，防 TlsException 兜底分支误判瞬时为证书类上抛。
      var attempts = 0;
      final gateway = buildGateway(
        error: () => TlsException('handshake interrupted by network'),
        failures: 2,
        onCall: () => attempts += 1,
      );
      await pushOnce(gateway); // 不抛 → 重试生效
      expect(attempts, 3,
          reason: '2 次失败 + 1 次成功 = 恰好 3 次 send（瞬时 TLS 走重试）');
    });

    test('ClientException 含证书关键词 → 不重试（生产 IOClient 包装路径）', () async {
      // 生产 IOClient 会把 TlsException 包装为 ClientException 子类抛出——
      // 证书类永久故障按 message 识别直接上抛（attempts==1）。
      var attempts = 0;
      final gateway = buildGateway(
        error: () =>
            http.ClientException('TLS exception: CERTIFICATE_VERIFY_FAILED'),
        failures: 100,
        onCall: () => attempts += 1,
      );
      await expectLater(
        pushOnce(gateway),
        throwsA(isA<http.ClientException>()),
        reason: 'ClientException 证书类失败立即上抛',
      );
      expect(attempts, 1, reason: 'ClientException 证书类失败只尝试一次');
    });

    test('非证书握手失败（HANDSHAKE_FAILURE_ALERT）→ 仍走退避重试（r30 修正）', () async {
      // HANDSHAKE_FAILURE_ALERT（TLS alert 40）可由无共享密码套件等非证书
      // 原因触发，属可自愈的瞬时握手失败——须纳入退避重试（防 r30 收窄后
      // 误伤瞬时失败、降低同步自愈率）。
      final gateway = buildGateway(
        error: () => const HandshakeException('HANDSHAKE_FAILURE_ALERT'),
        failures: 1,
      );
      await pushOnce(gateway); // 1 次失败 + 重试成功
    });

    test('TimeoutException / ClientException：同样退避重试', () async {
      final timeoutGateway = buildGateway(
        error: () => TimeoutException('request timed out'),
        failures: 1,
      );
      await pushOnce(timeoutGateway);

      final clientErrorGateway = buildGateway(
        error: () => http.ClientException('connection closed'),
        failures: 1,
      );
      await pushOnce(clientErrorGateway);
    });

    test('TimeoutException / 非证书 ClientException 耗尽：上抛原异常（r49 补覆盖）', () async {
      // 三个瞬时分支（SocketException/TimeoutException/非证书 ClientException）
      // 共用 _retryBackoff 耗尽逻辑，但各分支的 rethrow 行为（尤其 on
      // http.ClientException 的证书 message 判定前置）未被耗尽路径验证——若
      // 某分支误吞异常或耗尽后改写类型，仅"失败 1 次后恢复"用例无法检出。
      // **耗尽语义**：连续失败耗尽 maxAttempts 后上抛**原始异常类型**（防
      // 分支误吞/改写导致同步静默失败）。断言用 `isA<T>()` 类型匹配而非精确
      // runtimeType 相等（r50 放宽）——若传输层/SDK 对异常做合法包装（如
      // IOClient 把超时包成 ClientException），精确相等会误报；isA 守护的是
      // "不吞/不改写为不相关类型"的本实现语义。
      for (final (label, error, matcher) in [
        ('TimeoutException', TimeoutException('request timed out'),
            isA<TimeoutException>()),
        ('ClientException', http.ClientException('connection closed'),
            isA<http.ClientException>()),
      ]) {
        final gateway = buildGateway(
          error: () => error,
          failures: 20,
          maxAttempts: 3,
        );
        await expectLater(
          pushOnce(gateway),
          throwsA(matcher),
          reason: '$label 耗尽后必须上抛原类型异常（不静默吞掉/改写）',
        );
      }
    });

    test('PostgrestException（可重试 code，如 429）：纳入退避重试', () async {
      // 429 限流为瞬时错误（isNonRetryableCode=false）——走 PostgrestException
      // 分支退避重试；恢复后成功。
      final gateway = buildGateway(
        error: () => const PostgrestException(
          message: 'rate limit exceeded',
          code: '429',
        ),
        failures: 1,
      );
      await pushOnce(gateway);
    });

    test('PostgrestException（可重试 code）耗尽：上抛原异常（r49 补覆盖）', () async {
      // 429 分支的耗尽路径：连续 429 耗尽 maxAttempts 后必须上抛原
      // PostgrestException（防该分支误吞异常/耗尽后改写类型导致同步静默失败
      //——与 SocketException 耗尽用例同语义）。
      final gateway = buildGateway(
        error: () => const PostgrestException(
          message: 'rate limit exceeded',
          code: '429',
        ),
        failures: 20,
        maxAttempts: 3,
      );
      await expectLater(
        pushOnce(gateway),
        throwsA(isA<PostgrestException>()),
        reason: '可重试 PostgrestException 耗尽后上抛原类型（不静默吞掉）',
      );
    });

    test('PostgrestException（不可重试 code，如 23505 唯一冲突）：不重试直接上抛', () async {
      // 23505 为永久错误（isNonRetryableCode=true）——重试无意义，立即上抛
      //（不消耗额外尝试）。
      var attempts = 0;
      final gateway = buildGateway(
        error: () => const PostgrestException(
          message: 'duplicate key value violates unique constraint',
          code: '23505',
        ),
        failures: 100,
        onCall: () => attempts += 1,
      );
      await expectLater(
        pushOnce(gateway),
        throwsA(isA<PostgrestException>()),
        reason: '永久错误不重试，直接上抛',
      );
      expect(attempts, 1, reason: '永久错误只尝试一次（无重试）');
    });
  });

  group('接口默认值与实现上限一致性', () {
    test('RemoteTableGateway.defaultPageSize 在合法区间（>0 且 ≤ 实现上限）', () {
      // 真实契约：接口默认值**不得超过**最大实现的上限（否则调用方省略
      // pageSize 会被实现以 ArgumentError 拒绝、同步失败）且**必须为正**
      //（≤0 同样会被 `pageSize < 1` 校验拒绝）。用区间断言而非 ==：实现
      // 上限上调（服务端 max-rows 提高）或策略性调低默认分页都不应被误判
      // 为回归——单一事实来源 + 跨文件一致性锁定。
      expect(
        RemoteTableGateway.defaultPageSize,
        allOf(
          greaterThan(0),
          lessThanOrEqualTo(SupabaseRemoteTables.remoteMaxPageSize),
        ),
        reason: '接口默认 pageSize 必须为正且 ≤ Supabase 实现上限',
      );
    });
  });

  group('_isNonRetryableCode 判定矩阵（r14 锁定，防重试策略回归）', () {
    test('不可重试：缺失 code / HTTP 4xx（除 429）/ PGRST* / 永久 SQLSTATE', () {
      for (final code in [
        null, // 协议/解析失败
        '400', // 权限/校验
        '401', // 鉴权失效
        '403',
        '404',
        '408', // Request Timeout（语义偏瞬时，但当前实现按 4xx 判不可重试）
        '409', // 冲突
        '422', // 语义错误
        'PGRST116', // 无数据
        'PGRST204',
        '23505', // 唯一冲突
        '23503', // 外键冲突
        '40002', // transaction_integrity_constraint_violation（永久）
        '40P02', // transaction_snapshot_too_old（永久）
        '42883', // 未定义函数
        '22007', // 非法日期时间
      ]) {
        expect(SupabaseRemoteTables.isNonRetryableCode(code), isTrue,
            reason: '应判不可重试：$code');
      }
    });

    test('可重试：429 / HTTP 5xx / 瞬时 SQLSTATE / 40 类豁免 / 未知格式', () {
      for (final code in [
        '429', // 限流
        // HTTP 5xx（网关超时/上游不可用/限流）是云同步最典型的瞬时故障——
        // 当前实现落入"未知格式→保守可重试"分支；显式列出锁定该语义（防
        // 未来实现误将 5xx 归为不可重试而回归）。
        '500',
        '502',
        '503',
        '504',
        '08P01', // 连接失败
        '57P03', // 运维干预
        '40001', // serialization_failure（瞬时豁免）
        '40P01', // deadlock_detected（瞬时豁免）
        '40000', // transaction_rollback 通用回滚（r48 豁免——网关幂等重试安全）
        '40003', // statement_completion_unknown（r48 豁免——结果未知建议重试）
        'weird-code', // 未知格式：保守可重试
      ]) {
        expect(SupabaseRemoteTables.isNonRetryableCode(code), isFalse,
            reason: '应判可重试：$code');
      }
    });
  });

  group('fetchRowsSince 入参校验（网络前 fail-fast）', () {
    test('page 负数 / pageSize 非法 → ArgumentError（不触达网络）', () async {
      // 校验发生在任何请求之前：handler 若被调用即测试失败。
      // **统计口径（r53）**：与 buildGateway 统一——只对 `/rest/v1/` 的
      // PostgREST 请求置 networkHit（auth 层 /auth/v1/* 请求与"入参校验不
      // 触达网络"语义无关，混入会误报/掩盖真实回归）。
      var networkHit = false;
      final client = MockClient((request) async {
        if (request.url.path.startsWith('/rest/v1/')) networkHit = true;
        return http.Response('[]', 200,
            headers: {'content-type': 'application/json'}, request: request);
      });
      final supabase = SupabaseClient(
        'https://example.supabase.co',
        'k',
        httpClient: client,
        postgrestOptions: const PostgrestClientOptions(retryEnabled: false),
        authOptions: const AuthClientOptions(
          autoRefreshToken: false,
          authFlowType: AuthFlowType.implicit,
        ),
      );
      final gateway = SupabaseRemoteTables(client: supabase);

      await expectLater(
        gateway.fetchRowsSince(table: 'activities', userId: 'u', page: -1),
        throwsA(isA<ArgumentError>()),
        reason: 'page < 0 显式拒绝',
      );
      await expectLater(
        gateway.fetchRowsSince(table: 'activities', userId: 'u', pageSize: 0),
        throwsA(isA<ArgumentError>()),
        reason: 'pageSize = 0 拒绝',
      );
      await expectLater(
        gateway.fetchRowsSince(table: 'activities', userId: 'u', pageSize: -5),
        throwsA(isA<ArgumentError>()),
        reason: 'pageSize < 0 拒绝',
      );
      await expectLater(
        gateway.fetchRowsSince(
          table: 'activities',
          userId: 'u',
          pageSize: SupabaseRemoteTables.remoteMaxPageSize + 1,
        ),
        throwsA(isA<ArgumentError>()),
        reason: 'pageSize 超过网关上限（${SupabaseRemoteTables.remoteMaxPageSize}）拒绝',
      );
      expect(networkHit, isFalse, reason: '入参校验必须在任何网络请求之前');
      // 合法侧临界值：page=0、pageSize=上限（恰为默认）正常执行（不触达网络
      // 校验外——这里 handler 会命中返回空页，仅验证不抛校验错误）。
      final okPage = await gateway.fetchRowsSince(
        table: 'activities',
        userId: 'u',
        pageSize: SupabaseRemoteTables.remoteMaxPageSize,
        page: 0,
      );
      expect(okPage.rows, isEmpty);
    });

    test('构造参数校验：maxAttempts <= 0/超上限、负/超限 retryBaseDelay 拒绝', () {
      final client = MockClient(
        (request) async => http.Response('[]', 200,
            headers: {'content-type': 'application/json'}, request: request),
      );
      final supabase = SupabaseClient(
        'https://example.supabase.co',
        'k',
        httpClient: client,
        authOptions: const AuthClientOptions(
          autoRefreshToken: false,
          authFlowType: AuthFlowType.implicit,
        ),
      );
      // debug 下运行时校验抛 ArgumentError（r29 起无 assert 冗余路径）。
      // 边界值**按公开上限常量生成**（单一事实来源，防与实现漂移）：
      // maxAttempts: 0/-1（下界）、上限+1；retryBaseDelay: -1s（下界）、
      // 上限+1；**组合级**：10 × 2s = 1022s 超预算（2 分钟）拒绝。
      for (final bad in [
        () => SupabaseRemoteTables(client: supabase, maxAttempts: 0),
        () => SupabaseRemoteTables(client: supabase, maxAttempts: -1),
        () => SupabaseRemoteTables(
          client: supabase,
          maxAttempts: SupabaseRemoteTables.maxAttemptsCap + 1,
        ),
        () => SupabaseRemoteTables(
          client: supabase,
          retryBaseDelay: const Duration(seconds: -1),
        ),
        () => SupabaseRemoteTables(
          client: supabase,
          retryBaseDelay: SupabaseRemoteTables.maxRetryBaseDelayCap +
              const Duration(seconds: 1),
        ),
        // 组合级总等待超预算：各参数单独合法、组合非法。
        () => SupabaseRemoteTables(
          client: supabase,
          maxAttempts: SupabaseRemoteTables.maxAttemptsCap,
          retryBaseDelay: SupabaseRemoteTables.maxRetryBaseDelayCap,
        ),
      ]) {
        expect(
          bad,
          throwsA(isA<ArgumentError>()),
          reason: '重试参数越界/组合超预算必须拒绝',
        );
      }
      // 合法侧临界值：单一上限内 + **组合预算内**的组合被接受（含端点）。
      // 用 returnsNormally 直接表达"构造不抛异常"（构造意外抛错时保留
      // 自定义 reason，诊断更清晰）。
      expect(
        () => SupabaseRemoteTables(
          client: supabase,
          maxAttempts: SupabaseRemoteTables.maxAttemptsCap,
          retryBaseDelay: const Duration(milliseconds: 20),
          // 10 次尝试 × 20ms base：指数退避总等待 = 20ms × (2^9 - 1) = 10.22s < 预算(2min)
        ),
        returnsNormally,
        reason: '上限内且组合预算内的参数合法（含端点）',
      );
      expect(
        () => SupabaseRemoteTables(
          client: supabase,
          maxAttempts: 6,
          retryBaseDelay: SupabaseRemoteTables.maxRetryBaseDelayCap,
          // 6 次尝试 × 2s base：指数退避总等待 = 2s × (2^5 - 1) = 62s < 预算(2min)
        ),
        returnsNormally,
        reason: '组合预算内的上限 base 合法',
      );
    });
  });
}
