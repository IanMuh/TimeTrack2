/// Supabase 同步后端：组装 认证 + 表网关 + 云同步引擎，实现 [SyncBackend]。
///
/// - 未配置（SUPABASE_URL/ANON_KEY 未注入）→ 工厂返回 [NoopSyncBackend]（离线）；
/// - 配置后懒初始化 supabase client（首次使用时），登录态流/同步引擎即用即取；
/// - [SyncBackend.syncNow] 要求已登录（userId 来自会话）；登录成功后由上层
///   （阶段 3 编排）触发一次同步。
library;

import 'dart:async';
import 'dart:io' show stderr;

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../constants/build_config.dart';
import '../../utils/result.dart';
import 'cloud_sync_engine.dart';
import 'supabase_auth_service.dart';
import 'sync_backend.dart';

/// 构建 Supabase 后端：未配置或 URL 非法时返回 [NoopSyncBackend]（应用离线）。
///
/// [engine] 由调用方（阶段 3 编排）注入（真引擎 + mock 网关等组合由测试构造）。
///
/// URL 完整性校验前移到工厂：非空但非法的 URL（not-a-url / ftp:// 等）若放行
/// 到 [SupabaseSyncBackend]，会在首次访问 _lazyClient 时同步抛 ArgumentError，
/// 破坏 SyncBackend 的 AppResult 错误契约——故非法直接降级离线。
SyncBackend createSupabaseSyncBackend({
  required CloudSyncEngine engine,
  Duration syncTimeout = SupabaseSyncBackend.defaultSyncTimeout,
}) {
  // 工厂 = 读取编译期配置 + 委托核心决策 [SupabaseSyncBackend.buildBackend]
  //（决策逻辑可注入配置值单测，不依赖 String.fromEnvironment）。
  return SupabaseSyncBackend.buildBackend(
    isConfigured: AppBuildConfig.isSupabaseConfigured(),
    url: AppBuildConfig.getString(
      AppBuildConfig.supabaseUrlKey,
      defaultValue: '',
    ),
    engine: engine,
    syncTimeout: syncTimeout,
  );
}

/// Supabase 同步后端。
///
/// 构造私有：非法配置（URL 非空但非法）必须在进入方法前被拦截——工厂
/// [createSupabaseSyncBackend] 已做 URL 前置校验并降级 Noop；绕过工厂直接
/// 构造会使 isConfigured 放行非法 URL，首次访问 _lazyClient 时同步抛
/// ArgumentError 破坏 AppResult 契约。
class SupabaseSyncBackend implements SyncBackend {
  /// 后端构建核心决策（工厂委托；**可注入配置值单测**——不依赖编译期
  /// dart-define，见 supabase_sync_backend_test 的 buildBackend 用例）：
  /// - 未配置 → Noop（离线）；
  /// - URL 非法 → Noop + stderr 警告（含脱敏原因，防存量用户"已配置但
  ///   始终离线"难以排查）；
  /// - 合法 → 真后端（syncTimeout 非法值回退默认 + 警告）。
  @visibleForTesting
  static SyncBackend buildBackend({
    required bool isConfigured,
    required String url,
    required CloudSyncEngine engine,
    Duration syncTimeout = defaultSyncTimeout,
  }) {
    if (!isConfigured) return NoopSyncBackend();
    // syncTimeout 防御校验：工厂承诺"配置非法时降级离线、不抛异常"——非法
    // 注入值（零/负）回退默认而非透传给构造器抛 ArgumentError（破坏契约）。
    // **回退告警**：静默回退会掩盖调用方解析超时配置的传参错误——
    // release 下实际生效超时与期望不符时难以排查，回退时写 stderr 警告。
    if (syncTimeout <= Duration.zero) {
      // ignore: avoid_print
      stderr.writeln(
        '[supabase-sync] syncTimeout 非法（$syncTimeout），回退默认值'
        '（$defaultSyncTimeout）',
      );
      syncTimeout = defaultSyncTimeout;
    }
    if (!isValidSupabaseUrl(url)) {
      // 已配置但 URL 非法（r14 收窄：非根路径/带 query/fragment/凭据等）：
      // 静默降级 Noop 会让存量用户"已配置但始终离线"且难以排查（Noop 与
      // 未配置返回相同 unconfiguredError）——降级前写 stderr 警告（含原因）。
      // **日志脱敏（security）**：非法 URL 可能含 userInfo 凭据
      //（如 https://user:password@host——恰被校验判非法），打印原始 URL 会把
      // 密码写入日志（若接入崩溃收集/远程上报即泄露）——只输出 scheme://host
      //（脱敏逻辑单一事实来源见 [sanitizedUrlForLog]）。
      // ignore: avoid_print
      stderr.writeln(
        '[supabase-sync] SUPABASE_URL 非法，降级离线（仅接受 http(s) 根路径、'
        '无 query/fragment/凭据）：${sanitizedUrlForLog(url)}',
      );
      return NoopSyncBackend();
    }
    return SupabaseSyncBackend._(
      engine: engine,
      isConfigured: true, // 走到构造即已确认配置合法
      supabaseUrl: url, // 注入值存入实例（_lazyClient 构造时实际生效）
      syncTimeout: syncTimeout,
    );
  }

  /// URL 合法性校验（工厂降级与 [_validatedUrl] double-check 共用同一判定）。
  ///
  /// 加宽到**根路径约束**：path 为空或为 `/`、无 query/fragment、无 userInfo——
  /// SupabaseClient 会在该基址上拼接 `/auth/v1`、`/rest/v1` 等端点，非根路径/
  /// 带 query/fragment/凭据的地址会生成错误 URL（配置问题延迟到运行时请求才
  /// 暴露，与工厂"非法 URL 前置降级 Noop"的意图不符）。末尾斜杠由 Uri.parse
  /// 归一化。
  ///
  /// **破坏性行为变更（r14 收窄）**：此前带子路径（如自建代理
  /// `https://host/supabase`）或带参数的配置可被接受；收窄后这类配置将降级
  /// 为 Noop（离线）。如需子路径代理，应在应用侧配置反代（对外仍是根路径）——
  /// 判定规则统一由本方法收敛，配置文档须同步（见 AGENTS.md 安全与提交）。
  /// `@visibleForTesting` 仅用于测试锁定判定（生产调用点：工厂降级 +
  /// double-check，行为不变）。
  @visibleForTesting
  static bool isValidSupabaseUrl(String raw) {
    final trimmed = raw.trim();
    final uri = Uri.tryParse(trimmed);
    if (trimmed.isEmpty || uri == null || !uri.isAbsolute) return false;
    if (uri.scheme != 'http' && uri.scheme != 'https') return false;
    if (uri.host.isEmpty) return false;
    // 端口 0 无法建连（Uri.port 对未显式指定端口返回 scheme 默认值 80/443，
    // 仅显式 `:0` 时返回 0）——属非法配置，防运行时请求阶段才暴露。
    if (uri.port == 0) return false;
    if (uri.userInfo.isNotEmpty) return false; // user:pass@ 基址无法正确拼接端点
    final path = uri.path;
    if (path.isNotEmpty && path != '/') return false;
    if (uri.hasQuery || uri.hasFragment) return false;
    return true;
  }

  final CloudSyncEngine engine;

  /// 网络段超时（token 刷新 + engine 同步共用）：默认 [defaultSyncTimeout]；
  /// 可注入（测试用极小值快速触发超时分支）。本地游标读写/会话检查不涉及
  /// 网络，不受本超时约束。
  final Duration syncTimeout;

  /// 实例级配置标记：buildBackend 决策时注入——使配置分支可单测
  ///（接口 getter 不再直接读编译期 AppBuildConfig，工厂路径仍传编译期值，
  /// 行为不变）。
  @override
  final bool isConfigured;

  /// 校验通过的 SUPABASE_URL：buildBackend 决策时注入并**存入实例**——
  /// [_validatedUrl] 复用本字段，使注入值在 _lazyClient 构造时实际生效
  ///（防"决策用注入值、构造用编译期值"的不一致——测试注入合法 URL 后
  /// syncNow 仍按空配置抛错）。
  final String supabaseUrl;

  SupabaseSyncBackend._({
    required this.engine,
    required this.isConfigured,
    required this.supabaseUrl,
    this.syncTimeout = defaultSyncTimeout,
  }) : assert(syncTimeout > Duration.zero, 'syncTimeout 必须为正') {
    // release 下 assert 被剥离：零/负超时会让 Future.timeout 立即触发或抛
    // ArgumentError（负值）——运行时显式兜底。
    if (syncTimeout <= Duration.zero) {
      throw ArgumentError.value(syncTimeout, 'syncTimeout', '必须为正');
    }
  }

  /// 默认网络段超时：网络挂起时 in-flight 锁不会被永久占据（reset 保留在途
  /// 引用的阻塞兜底——见 [reset] 注释）；超时按失败处理，不清游标，下次
  /// 同步从上次成功点继续。注意 `Future.timeout` 不取消底层任务（边界见
  /// [engine] 调用处注释）。
  /// **性能边界（r24 文档化）**：本超时是包裹**整个 engine.syncNow**（含本地
  /// 库操作 + 全部网络往返）的**墙钟总时长**超时，非网络空闲超时——离线数日
  /// 的大积压全量同步/慢网络大批次同步，合法耗时可超 2 分钟而被判失败；失败
  /// 不清游标，重试会重新执行同一大批次，可能形成"永远超时、永远重试"活锁。
  /// 缓解：阶段 3 编排可注入更长超时或按数据量动态放大（[syncTimeout] 已可
  /// 注入）；当前默认值对常规增量同步（小批次）足够。
  static const defaultSyncTimeout = Duration(minutes: 2);

  SupabaseClient? _client;
  SupabaseAuthService? _auth;

  SupabaseClient get _lazyClient =>
      _client ??= SupabaseClient(
        _validatedUrl(),
        AppBuildConfig.getString(
          AppBuildConfig.supabaseAnonKeyKey,
          defaultValue: '',
        ),
      );

  /// 校验注入的 SUPABASE_URL（**[supabaseUrl] 实例字段**，buildBackend 决策时
  /// 已通过合法性校验——此处保留 double-check 防绕过工厂直接构造）。
  String _validatedUrl() {
    final raw = supabaseUrl.trim();
    if (!isValidSupabaseUrl(raw)) {
      // **脱敏（security）**：非法 URL 可能含 userInfo 凭据（恰被校验判
      // 非法）——异常消息只输出 scheme://host（与工厂降级日志共用
      // [sanitizedUrlForLog] 单一事实来源），防未来代码路径绕过工厂时凭据
      // 随异常进日志/崩溃上报。
      throw ArgumentError('SUPABASE_URL 配置非法：${sanitizedUrlForLog(raw)}');
    }
    return raw;
  }

  /// URL 日志/异常消息脱敏（**单一事实来源**，工厂降级日志与 [_validatedUrl]
  /// 异常消息共用——防两处漂移导致一处脱敏、另一处泄露 userInfo 凭据）。
  /// 只输出 scheme://host[:port]（可能含凭据的 userInfo/query/fragment 一律
  /// 不出现；**非默认端口保留**——同机多实例/非标准端口部署（如 :8443）时
  /// 日志须与默认端口区分，排障可诊断性；端口不含凭据，脱敏语义不受影响）；
  /// scheme 缺失或 host 为空（如 `//host/path`、`<unparseable>`）回退
  /// `<unparseable>`（防输出误导性 `://host`）。
  @visibleForTesting
  static String sanitizedUrlForLog(String raw) {
    final parsed = Uri.tryParse(raw.trim());
    if (parsed != null && parsed.scheme.isNotEmpty && parsed.host.isNotEmpty) {
      final isDefaultPort = (parsed.scheme == 'https' && parsed.port == 443) ||
          (parsed.scheme == 'http' && parsed.port == 80);
      // IPv6 host 需补方括号（Uri.host 返回裸 `::1`）——标准 URL 表示
      // `[::1]:8443`，防非法 IPv6 配置的降级日志/异常消息呈畸形地址。
      final hostDisplay = parsed.host.contains(':')
          ? '[${parsed.host}]'
          : parsed.host;
      // `hasPort` 判定是否显式端口（Uri.port 从不返回负值；未显式指定时
      // 返回 scheme 默认端口，如 ftp://host → port 21——用 hasPort 区分
      // 显式配置，防非 http(s) 非法 URL 输出误导性 `ftp://host:21`）。
      return isDefaultPort || !parsed.hasPort
          ? '${parsed.scheme}://$hostDisplay'
          : '${parsed.scheme}://$hostDisplay:${parsed.port}';
    }
    return '<unparseable>';
  }

  SupabaseAuthService get _lazyAuth => _auth ??= SupabaseAuthService(client: _lazyClient);

  /// 重置懒加载的 client/auth（登出清理会话/测试重建场景用）。
  ///
  /// **不中断在途同步**（已进入 engine 的网络请求无法安全取消），而是递增
  /// 会话代数：旧同步完成后其结果被 epoch 校验丢弃（不写库/不被采纳）。
  /// **保留 `_syncInFlight` 引用**（不清空）：reset/登出后新 syncNow 直接返回
  /// "旧同步仍在途"失败（**不 await/复用旧 Future**，见 syncNow 的
  /// `_syncInFlightEpoch` 前置判断）——直到旧同步结束释放引用后才放行新同步，
  /// 防登出后新旧身份同步重叠执行（互斥/去重保证不被绕过）。
  /// 阻塞兜底：旧同步若因网络挂起长期不返回，会一直占用 [_syncInFlight]；
  /// [_runSync] 对**网络段**（token 刷新 + engine 同步）施加 [syncTimeout]
  /// 超时，超时按失败处理（不清游标，下次可重试），防止在途锁被永久占据。
  void reset() {
    // **释放旧认证服务的底层 gotrue 订阅（r52）**：不释放则旧 client 及其
    // 底层资源被持续引用，每次登录/登出循环累积一条旧订阅与一个旧 client
    //（资源持续增长）；dispose 主动取消订阅/关闭流，解除"须等监听者全部
    // 取消"的隐式依赖（此后旧服务不可再用，调用方须丢弃引用）。
    _auth?.dispose();
    _client = null;
    _auth = null;
    _epoch += 1;
  }

  /// 未配置时的登录态流（单例广播，订阅即回放 null——符合接口契约）。
  late final Stream<String?> _noopAuthState = Stream<String?>.multi(
    (controller) => controller.add(null),
    isBroadcast: true,
  );

  // 注：构造仅经 buildBackend 的 isConfigured=true 分支，类内
  // `if (!isConfigured)` 防御分支为**纯防御性检查**（不存在 isConfigured=false
  // 的构造路径——配置决策已完全收敛到工厂/构建层；保留防御防未来构造路径
  // 扩展时遗漏）。

  @override
  Stream<String?> get authStateStream {
    if (!isConfigured) return _noopAuthState;
    return _lazyAuth.authStateStream;
  }

  @override
  String? get currentUserId {
    if (!isConfigured) return null;
    return _lazyAuth.currentUserId;
  }

  @override
  Future<AppResult<void>> sendMagicLink(String email) async {
    if (!isConfigured) return const AppFailure(SyncBackend.unconfiguredError, code: SyncBackend.unconfiguredCode);
    return _lazyAuth.sendMagicLink(email);
  }

  @override
  Future<AppResult<String>> verifyEmailOtp(String email, String token) async {
    if (!isConfigured) return const AppFailure(SyncBackend.unconfiguredError, code: SyncBackend.unconfiguredCode);
    return _lazyAuth.verifyEmailOtp(email, token);
  }

  @override
  Future<AppResult<void>> signOut() async {
    if (!isConfigured) return const AppFailure(SyncBackend.unconfiguredError, code: SyncBackend.unconfiguredCode);
    final result = await _lazyAuth.signOut();
    if (result is AppSuccess<void>) {
      // 仅成功时释放懒加载引用：失败时保留现有 client（其本地持久化会话仍
      // 存在，reset 后重建会重新水合旧会话，造成"登出失败但状态被清空随后
      // 又恢复登录"的不一致）。
      reset();
      // 在途同步不中断（无法安全取消）：epoch 已递增，旧同步返回后结果被
      // 丢弃；_syncInFlight 保留——并发新 syncNow 复用旧 Future 拿到
      // "会话已切换"结果，防新旧身份同步重叠。
    }
    return result;
  }

  @override
  Future<AppResult<SyncReport>> syncNow() async {
    if (!isConfigured) return const AppFailure(SyncBackend.unconfiguredError, code: SyncBackend.unconfiguredCode);
    // 互斥/去重：并发调用共享同一 in-flight Future（防并发双 refreshSession
    // 消费同一 refresh token 导致二次刷新失败、以及重复执行同一轮同步）。
    final inFlight = _syncInFlight;
    if (inFlight != null) {
      // **epoch 前置判断**：reset/登出后旧 in-flight 仍在运行（无法
      // 取消），新身份同步若复用旧 Future 只会拿到"会话已切换"失败——返回
      // **可区分**的"旧同步仍在途"提示（防新账号首次同步被误判为真实失败/
      // 卡顿，且与并发去重的正常复用区分开：同一会话代数内的并发调用仍
      // 共享 in-flight 结果）。
      // **哨兵语义（r45 加固）**：`_syncInFlightEpoch` 为 null = 未知代数——
      // **保守拒绝**（null != _epoch 恒成立）：若未来改动独立清空该字段而
      // `_syncInFlight` 非空，此处返回"旧同步仍在途"而非复用陈旧 Future，
      // epoch 保护不被绕过（成对设置/清空当前保证 null+非空组合不可达，
      // 防御性兜底防回归）。
      if (_syncInFlightEpoch != _epoch) {
        return const AppFailure('旧同步仍在途，请稍后重试');
      }
      return inFlight;
    }
    final future = _runSync();
    _syncInFlight = future;
    _syncInFlightEpoch = _epoch;
    try {
      return await future;
    } finally {
      if (identical(_syncInFlight, future)) {
        _syncInFlight = null;
        // 成对复位：与 _syncInFlight 一同置空——防后续改动独立读取
        // _syncInFlightEpoch 时拿到陈旧会话代数。
        _syncInFlightEpoch = null;
      }
    }
  }

  Future<AppResult<SyncReport>>? _syncInFlight;

  /// 在途同步所属的会话代数（**null = 无在途**）：与 [_syncInFlight] 成对记录——
  /// reset/登出递增 [_epoch] 后，旧在途引用的代数落后，新身份 syncNow 据此
  /// 返回可区分提示。用 `int?` 而非字面量哨兵（0 与真实 epoch-0 同值易误判）。
  int? _syncInFlightEpoch;

  /// 会话代数：登出/reset 时递增，在途同步返回后校验代数未变才提交结果——
  /// 防"已登出后旧同步仍以旧 userId 执行写库、其结果被新调用方采纳"。
  ///
  /// **已知边界（文档化）**：该机制只防**结果采纳**，不防**旧身份写库**——
  /// 已进入 [CloudSyncEngine.syncNow] 的旧同步（旧 token 仍有效）可能在
  /// 登出后继续完成云端写库（无法安全取消）。缓解：登出即清会话，新身份
  /// 同步前引擎不再使用旧游标；若要求严格"登出即停写"，需给引擎引入
  /// 写库前代数校验（本阶段未做，属阶段 3 编排的显式权衡）。
  int _epoch = 0;

  Future<AppResult<SyncReport>> _runSync() async {
    final epoch = _epoch;
    try {
      final userId = currentUserId;
      if (userId == null) {
        return const AppFailure('请先登录后再同步');
      }
      // currentUser 非空 ≠ token 有效：JWT 过期但 refresh token 仍有效的会话
      // 应先尝试刷新；刷新失败才提示重登。
      final session = _lazyClient.auth.currentSession;
      if (session == null) {
        return const AppFailure('请先登录后再同步');
      }
      final expiresAt = session.expiresAt;
      // expiresAt 缺失时无法确认 token 有效性：按需刷新兜底（防已过期/未知
      // 状态的 token 直接交给引擎读写）。提前 30s 视为过期——临界过期的 token
      // 可能在同步执行中途失效导致请求 401，提前刷新留出余量。
      final expired = expiresAt == null ||
          DateTime.fromMillisecondsSinceEpoch(expiresAt * 1000)
              .isBefore(DateTime.now().add(const Duration(seconds: 30)));
      if (expired) {
        // **捕获本次同步使用的 client 局部引用**：reset 会置空 [_client]，
        // 但迟到的刷新响应仍持有旧 client 引用——epoch 失配时须用该引用
        // 清除其已写回持久化存储的旧身份会话（防登出被迟到刷新撤销）。
        final client = _lazyClient;
        // **持有原始刷新 Future（r48）**：`Future.timeout` 不取消底层
        // refreshSession——超时后请求仍会在后台继续并把旧身份会话写回持久化
        // 存储；须在**原始 Future settle 之后**才做本地清理（见 TimeoutException
        // 分支），而非超时时刻立即清（清理先于迟到写回会无效、登出仍被撤销）。
        final refreshFuture = client.auth.refreshSession();
        try {
          // refresh 同样受网络超时约束（token 端点挂起会阻塞整轮同步、永久
          // 占据 in-flight 锁）——与 engine 段共用 [syncTimeout]。
          // **边界说明**：超时返回后底层刷新请求不取消——若请求实际已到达
          // 服务端并轮换了 refresh token，用户重试时旧 refresh_token 已失效
          // 会再次失败（需完整重登）；属可接受边界（超时意味着网络状态差，
          // 重登是更稳妥的恢复路径）。
          final refreshed = await refreshFuture.timeout(syncTimeout);
          // **刷新成功路径 epoch 校验**：登出/reset 发生在 refreshSession
          // 在途期间时，旧 client 的迟到刷新响应可能在 reset 之后把旧身份会话
          // 写回持久化存储——此后 currentUserId 会水合出旧身份、后续 engine
          // 同步以旧身份执行（云端写库已发生）；与 TimeoutException/AuthException
          // 分支统一，在刷新成功返回后立即校验代数（防旧身份继续同步）。
          // **身份守卫（r52）**：与 AuthException/超时分支统一走
          // [_guardClearPersistedSession]——刷新成功把旧会话写回共享存储的
          // 窗口同样可达秒/分钟级（慢网络下刷新成功返回前用户可能已重登新
          // 账号），裸 [_clearPersistedSession] 会误抹新会话。
          if (epoch != _epoch) {
            _guardClearPersistedSession(client, userId);
            return const AppFailure('会话已切换，本次同步结果已丢弃');
          }
          if (refreshed.session == null) {
            return const AppFailure('登录已过期，请重新登录');
          }
        } on TimeoutException {
          // 与 engine 段超时一致的失败语义：不清游标，下次重试。
          // **epoch 校验**：与 engine 段统一——登出发生在刷新超时
          // 之前时，调用方应拿到可区分的"会话已切换"（与真实网络超时区分）。
          // **迟到刷新续延（r44，r48 修正，r49 加身份守卫+上限）**：
          // `Future.timeout` 不取消底层 refreshSession——超时后请求仍可能在
          // 后台完成并把旧身份会话写回持久化存储（登出被撤销）。**时序修正
          // （r48）**：不能在超时时刻立即清理——底层刷新尚未 settle，随后的
          // 迟到写回会**在本清理之后**落盘、登出仍被撤销。修正：epoch 失配时
          // 把清理挂到**原始刷新 Future**（[refreshFuture]）的完成回调上。
          // **身份守卫 + 执行上限（r49）**：延迟清理的窗口取决于底层刷新实际
          // settle 的时间（网络挂起时可达分钟级）——若窗口内用户已重新登录
          // 新账号，无守卫的清理会从共享持久化存储抹掉新会话（比微任务窗口
          // 风险高一个数量级）。两重防护：
          // ① [_guardClearPersistedSession] 清理前校验当前会话身份——已是
          // 新账号则跳过（防误抹新会话）；
          // ② 延迟清理整体套 [syncTimeout] 上限——刷新超时未落定则放弃清理
          //（防无限窗口；极端场景残留旧身份会话属既有接受边界，reset 重建
          // client 时水合旧身份由 ① 的 epoch/身份校验兜底）。
          stderr.writeln('[supabase-sync] token 刷新超时（$syncTimeout）');
          if (epoch != _epoch) {
            // **执行上限真实生效（r52 修正）**：`.timeout(...)` 只能约束外层
            // Future 的完成时间，**无法阻止** `refreshFuture.then(...)` 回调在
            // 底层刷新迟到 settle（可能远超超时窗口）后仍执行——"刷新超时未
            // 落定则放弃清理"的上限语义须在**回调内部**判定：记录调度时刻的
            // 截止时间，回调落定时先校验是否仍在窗口内，超出则放弃清理
            //（防无限等待期间的清理窗口被同账号重登的新会话触发误抹）。
            final cleanupDeadline = DateTime.now().add(syncTimeout);
            void clearIfWithinWindow() {
              if (DateTime.now().isBefore(cleanupDeadline)) {
                _guardClearPersistedSession(client, userId);
              }
            }

            unawaited(refreshFuture.then(
              (_) => clearIfWithinWindow(),
              onError: (_) => clearIfWithinWindow(),
            ));
            return const AppFailure('会话已切换，本次同步结果已丢弃');
          }
          return const AppFailure('同步超时，请稍后重试');
        } on AuthException catch (e) {
          // **epoch 校验（r35）**：与 TimeoutException 分支一致——登出/重置后
          // 刷新已失效 refresh token 的 AuthException 归因"会话已切换"而非
          // "登录已过期"（防旧同步调用方拿到误导性重登提示，错误归因模糊）。
          // **身份守卫（r50）**：与超时分支统一走 [_guardClearPersistedSession]
          // ——刷新在途期间可能已发生"A 登出 → B 登录新账号写入共享存储"，
          // 无条件本地清除会误抹 B 的新会话（真实窗口是刷新在途的秒/分钟级，
          // 非微任务间隔）；清理前校验当前身份仍是旧账号才执行。
          if (epoch != _epoch) {
            _guardClearPersistedSession(client, userId);
            return const AppFailure('会话已切换，本次同步结果已丢弃');
          }
          // 区分"会话失效"与"网络瞬时故障"：优先用结构化错误码精确白名单判定
          //（文案易变；code 白名单**收窄**——不含宽泛 'token'/'invalid' 子串，
          // 防把 token 端点瞬时错误/网络故障误判为会话失效强制重登）。
          // **code 优先语义**：code 存在时**只用 code 判定**——message
          // 回退仅在 code 缺失/未知时启用（防 "cannot refresh token ..." 等
          // 网络故障文案因含 refresh_token 子串而覆盖精确的 code 判定、
          // 误判为会话失效强制重登）；GoTrue 不同版本错误码集合差异由
          // message 回退兜底（code 缺失路径）。
          // **空白 code 视为 null（r36）**：网关/自托管 GoTrue 变体可能返回
          // `error_code: ""` 配合会话失效消息——空串/纯空白 code 跳过精确
          // 判定、走 message 回退（防"应判登录已过期"被归因为瞬时状态异常）。
          final code = e.code?.trim().toLowerCase();
          if (code != null && code.isNotEmpty) {
            if (isSessionExpiredCode(code)) {
              return const AppFailure('登录已过期，请重新登录');
            }
            return const AppFailure('登录状态异常，请重新登录或稍后重试');
          }
          if (sessionExpiredMessage(e.message)) {
            return const AppFailure('登录已过期，请重新登录');
          }
          return const AppFailure('登录状态异常，请重新登录或稍后重试');
        } catch (_) {
          // 兜底：任何异常都转为 AppResult（遵守 SyncBackend 契约）。
          return const AppFailure('网络不可用，请稍后重试');
        }
      }
      // 刷新（或校验）后重新获取 userId：并发登出/换号（await 挂起点交错）
      // 时不得用刷新前的旧 userId 同步（防按已登出/已切换身份写入数据）。
      // **与刷新前 userId 比对**：会话切换到另一账号且未触发 reset（epoch
      // 不变）时，丢弃本轮同步（防旧会话本地数据写到新用户云端）。
      final effectiveUserId = currentUserId;
      if (effectiveUserId == null ||
          effectiveUserId != userId ||
          _lazyClient.auth.currentSession == null) {
        return const AppFailure('请先登录后再同步');
      }
      try {
        // await 同时捕获同步抛错与异步 error（遵守"任何异常都转 AppResult"契约）。
        // **engine 段超时兜底**：网络挂起时本轮同步按失败返回（不清游标），
        // 防 in-flight 锁被永久占据（reset 后新身份同步拿不到释放）。
        // 范围说明：`syncTimeout` 实际包裹**整个 engine.syncNow**（含本地库
        // 操作——本地操作毫秒级，超时主要防护网络挂起段，语义正确）。
        // 注意：`Future.timeout` **不取消底层任务**——超时返回后旧同步仍可能
        // 在后台继续完成云端写库（引擎无取消机制，属显式接受的边界；其结果
        // 不再被采纳，游标由下一轮新同步决定）。**数据分叉边界**：引擎超时
        // 后仍可能在后台完成 markSuccess 推进游标——用户看到"超时失败"但
        // 数据实际已同步；下一轮同步因游标已推进而跳过已同步数据，不会重复
        // 同步（LWW 幂等），仅失败提示与真实状态短暂分叉。**引擎内部
        // `_inFlight` 锁在旧同步自然结束前仍占用**（引擎无取消入口），新同步
        // 在此期间会被引擎以"同步进行中"拒绝——该占用时长**无上限**（取决于
        // 旧同步网络请求实际完成时间，可能远超超时阈值），属引擎设计边界；
        // 缓解方向是给引擎加取消/超时机制（阶段 3 编排集成时评估）。
        // **活锁风险（r50 补充）**：syncTimeout 是墙钟总时长（含本地库操作 +
        // 全部网络往返）——离线大积压全量同步或慢网络大批次同步合法耗时超
        // 时即被误判失败；失败不清游标、重试重跑同一批次，网络持续慢时可能
        // 形成"永远超时、永远重试"活锁。缓解方向：按数据量动态放大超时
        //（阶段 3 编排时评估）。
        final result = await engine
            .syncNow(userId: effectiveUserId)
            .timeout(syncTimeout);
        // 会话代数校验：登出/reset 已发生（epoch 递增）→ 旧同步结果丢弃。
        if (epoch != _epoch) {
          return const AppFailure('会话已切换，本次同步结果已丢弃');
        }
        return result;
      } on TimeoutException {
        // 超时与网络瞬时失败一致：转 AppResult 失败，不清游标（下次重试）。
        // **epoch 校验**：与成功路径一致——reset/登出发生在在途同步
        // 超时之前时，调用方应拿到"会话已切换"（与真实网络超时可区分，符合
        // r25 _syncInFlightEpoch 的意图）；否则新身份重试绕过"旧同步仍在途"
        // 拦截直接进引擎、错误归因被模糊。
        stderr.writeln('[supabase-sync] 同步超时（$syncTimeout）');
        if (epoch != _epoch) {
          return const AppFailure('会话已切换，本次同步结果已丢弃');
        }
        return const AppFailure('同步超时，请稍后重试');
      } catch (e) {
        // 异常细节写日志，不向用户透出（防泄露 SQL/URL/堆栈等内部信息）。
        // ignore: avoid_print
        stderr.writeln('[supabase-sync] 同步异常：$e');
        return const AppFailure('同步失败，请稍后重试');
      }
    } catch (e) {
      // 整段 _runSync 兜底（懒初始化/客户端构造/GoTrue 读取等异常也转 AppResult）。
      // ignore: avoid_print
      stderr.writeln('[supabase-sync] 同步初始化异常：$e');
      return const AppFailure('同步失败，请稍后重试');
    }
  }

  /// 清除旧 client 已持久化的会话（**fire-and-forget，best-effort**）：刷新
  /// 成功/超时/AuthException 三处 epoch 失配分支共用——迟到刷新响应可能已把
  /// 旧身份会话写回持久化存储，不清理则 reset 后重建 client 会水合出旧身份
  ///（登出被撤销、后续同步以旧身份执行）。
  /// **实现说明（r46 修正）**：gotrue `_signOut` 先同步 `_removeSession()` 清
  /// 本地再发 /logout 网络请求——本清理的本地清除不依赖网络（3s 超时只截
  /// 断网络段）；`scope: SignOutScope.local` 语义上明确"仅本地清除"。
  /// **边界声明（r49 更新）**：所有 SupabaseClient 共享同一持久化存储 key——
  /// 若 reset 后用户已重新登录新账号，旧 client 的本地清除可能抹掉新会话。
  /// **同步调用点（刷新成功/AuthException 分支）**的竞态窗口为 epoch 失配
  /// 分支到微任务执行的极小间隔；**延迟调用点（超时分支）**已加身份守卫与
  /// 执行上限（见 [_guardClearPersistedSession]），不再裸调本方法。
  void _clearPersistedSession(SupabaseClient client) {
    unawaited(
      client.auth
          .signOut(scope: SignOutScope.local)
          .timeout(const Duration(seconds: 3))
          .catchError((_) {}),
    );
  }

  /// 身份守卫版清理（**超时分支的延迟清理专用，r49**）：刷新 Future 落定后
  /// 执行清理前，先校验**当前** [_client] 的会话身份——reset 后用户可能已
  /// 重新登录新账号（新会话写入共享持久化存储 key），无守卫的清理会从存储
  /// 抹掉新会话（窗口可达分钟级）。守卫语义：
  /// - 当前无客户端（reset 后未重建，[_client] 为 null）→ 无新会话可误伤，
  ///   执行清理；
  /// - 当前会话与 [oldUserId]（刷新前的旧身份）相同 → 未切换账号，执行清理；
  /// - 当前会话已是新账号 → **跳过清理**（防误抹新会话；残留旧身份会话的
  ///   极端场景由 epoch/身份校验在下次同步时兜底——水合的旧身份无法通过
  ///   `effectiveUserId == userId` 比对）。
  void _guardClearPersistedSession(SupabaseClient oldClient, String oldUserId) {
    final current = _client;
    if (current != null) {
      final currentId = current.auth.currentSession?.user.id;
      if (currentId != null && currentId != oldUserId) return;
    }
    _clearPersistedSession(oldClient);
  }

  /// 结构化错误码白名单（收窄）：命中即"会话失效，需重新登录"。
  /// 不含宽泛 'token'/'invalid' 子串——防把 token 端点瞬时错误/网络故障
  /// 误判为会话失效强制重登。
  /// **精确匹配（r33 修正）**：GoTrue 错误码是结构化 snake_case 标识——
  /// 用**精确集合匹配**而非 `contains` 子串（`contains` 会把带前缀/后缀的
  /// 变体码如 `invalid_refresh_token_network_error`、`email_token_expired`
  /// 误判为会话失效强制重登，网络故障场景锁死体验）；如需新增变体码判失效
  /// 须显式加入集合（测试矩阵同步更新）。
  /// 为可测试性公开（`@visibleForTesting`），code 判定矩阵见
  /// supabase_sync_backend_test.dart（与 message 矩阵对称，防白名单误改回归）。
  static const _sessionExpiredCodes = <String>{
    'refresh_token_not_found',
    'refresh_token_already_used',
    'invalid_refresh_token',
    'invalid_grant',
    'session_not_found',
    'user_not_found',
    'bad_jwt',
    'token_expired',
  };

  @visibleForTesting
  static bool isSessionExpiredCode(String code) =>
      _sessionExpiredCodes.contains(code);

  /// message 关键词回退判定（code 缺失/未命中白名单时兜底）。
  /// **有意的不对称（r23 明确）**：code 白名单含 `token_expired`，message 回退
  /// 对裸 "token has expired" 判**非**会话失效（无 session/refresh 上下文——
  /// "password reset token has expired" 等非会话消息含同样子串，无法区分）。
  /// 设计权衡：code 是结构化信息（精确）；message 是自由文本（保守判定优于
  /// 误判强制重登——后者会锁死用户触发真实重登流程）。后果：同一错误在
  /// code 缺失/改名时提示"登录状态异常"而非"登录已过期"（两者都引导用户
  /// 重新登录，语义损失可控）。**收窄原则**：`expired` 仅在与 refresh/session
  /// 上下文同时出现时判定；"jwt expired" 单独收窄匹配（无上下文词但明确是
  /// 会话令牌失效）。
  /// 为可测试性公开（`@visibleForTesting`），真实 GoTrue 消息样本见
  /// supabase_sync_backend_test.dart 的 message 判定矩阵用例。
  /// **标点归一化**：连续非字母数字（空格/连字符/**冒号/句点**等）
  /// 统一为单下划线——"Refresh Token: Not Found" 归一化为
  /// "refresh_token_not_found" 才命中收窄判定（仅空格/连字符会保留冒号
  /// 造成假阴性）。
  static final _messageSeparatorRe = RegExp(r'[^a-z0-9]+');

  @visibleForTesting
  static bool sessionExpiredMessage(String message) {
    // GoTrue message 通常以空格分隔单词（如 "refresh_token already used"、
    // "Session from this device has been signed out"），而 code 白名单用
    // 下划线子串——把 message 中所有非字母数字分隔符归一化为单下划线后再
    // 匹配（防 "refresh token" / "Refresh Token:" / "refresh_token" 写法
    // 判定结果分叉）。
    final msg = message.toLowerCase().replaceAll(_messageSeparatorRe, '_');
    final expiredWithContext =
        msg.contains('expired') &&
        (msg.contains('session') || msg.contains('refresh'));
    // **refresh_token 收窄**：裸 `refresh_token` 子串无失效语境——
    // "Failed to refresh token: Network is unreachable" 等网络故障消息归一化
    // 后含该子串，会被误判为会话失效强制重登（锁死体验）——仅匹配明确
    // 失效语境（not_found / already_used / invalid，与 code 白名单对应）。
    final refreshTokenInvalid =
        msg.contains('refresh_token_not_found') ||
        msg.contains('refresh_token_already_used') ||
        msg.contains('invalid_refresh_token');
    return expiredWithContext ||
        (msg.contains('jwt') && msg.contains('expired')) ||
        refreshTokenInvalid ||
        msg.contains('invalid_grant') ||
        msg.contains('session_not_found') ||
        msg.contains('user_not_found') ||
        msg.contains('bad_jwt');
  }
}
