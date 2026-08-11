/// Supabase 同步后端：组装 认证 + 表网关 + 云同步引擎，实现 [SyncBackend]。
///
/// - 未配置（SUPABASE_URL/ANON_KEY 未注入）→ 工厂返回 [NoopSyncBackend]（离线）；
/// - 配置后懒初始化 supabase client（首次使用时），登录态流/同步引擎即用即取；
/// - [SyncBackend.syncNow] 要求已登录（userId 来自会话）；登录成功后由上层
///   （阶段 3 编排）触发一次同步。
library;

import 'dart:async';

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
SyncBackend createSupabaseSyncBackend({required CloudSyncEngine engine}) {
  if (!AppBuildConfig.isSupabaseConfigured()) return const NoopSyncBackend();
  final url = AppBuildConfig.getString(
    AppBuildConfig.supabaseUrlKey,
    defaultValue: '',
  );
  if (!_isValidSupabaseUrl(url)) {
    return const NoopSyncBackend();
  }
  return SupabaseSyncBackend._(engine: engine);
}

/// URL 合法性校验（与 [_SupabaseSyncBackend._validatedUrl] 共用同一判定）。
bool _isValidSupabaseUrl(String raw) {
  final trimmed = raw.trim();
  final uri = Uri.tryParse(trimmed);
  return trimmed.isNotEmpty &&
      uri != null &&
      uri.isAbsolute &&
      (uri.scheme == 'http' || uri.scheme == 'https') &&
      uri.host.isNotEmpty;
}

/// Supabase 同步后端。
///
/// 构造私有：非法配置（URL 非空但非法）必须在进入方法前被拦截——工厂
/// [createSupabaseSyncBackend] 已做 URL 前置校验并降级 Noop；绕过工厂直接
/// 构造会使 isConfigured 放行非法 URL，首次访问 _lazyClient 时同步抛
/// ArgumentError 破坏 AppResult 契约。
class SupabaseSyncBackend implements SyncBackend {
  SupabaseSyncBackend._({required this.engine});

  final CloudSyncEngine engine;

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

  /// 校验注入的 SUPABASE_URL：非空 + 可解析 + http(s)；非法时给可读错误
  /// （SupabaseClient 构造/首请求会抛底层异常，定位困难——这里前置拦截）。
  /// 工厂已用 [_isValidSupabaseUrl] 前置降级，此处保留为 double-check。
  String _validatedUrl() {
    final raw = AppBuildConfig.getString(
      AppBuildConfig.supabaseUrlKey,
      defaultValue: '',
    ).trim();
    if (!_isValidSupabaseUrl(raw)) {
      throw ArgumentError('SUPABASE_URL 配置非法：$raw');
    }
    return raw;
  }

  SupabaseAuthService get _lazyAuth => _auth ??= SupabaseAuthService(client: _lazyClient);

  /// 重置懒加载的 client/auth（登出清理会话/测试重建场景用）。
  void reset() {
    _client = null;
    _auth = null;
  }

  @override
  bool get isConfigured => AppBuildConfig.isSupabaseConfigured();

  @override
  Stream<String?> get authStateStream {
    if (!isConfigured) {
      // Stream.multi（isBroadcast: true）：每个监听者订阅时立即重放 null
      // （broadcast 不重放已发射事件、getter 每次新建流会让晚订阅者静默
      // 收不到快照）。
      return Stream<String?>.multi(
        (controller) => controller.add(null),
        isBroadcast: true,
      );
    }
    return _lazyAuth.authStateStream;
  }

  @override
  String? get currentUserId {
    if (!isConfigured) return null;
    return _lazyAuth.currentUserId;
  }

  @override
  Future<AppResult<void>> sendMagicLink(String email) async {
    if (!isConfigured) return const AppFailure('云同步未配置');
    return _lazyAuth.sendMagicLink(email);
  }

  @override
  Future<AppResult<String>> verifyEmailOtp(String email, String token) async {
    if (!isConfigured) return const AppFailure('云同步未配置');
    return _lazyAuth.verifyEmailOtp(email, token);
  }

  @override
  Future<AppResult<void>> signOut() async {
    if (!isConfigured) return const AppFailure('云同步未配置');
    final result = await _lazyAuth.signOut();
    if (result is AppSuccess<void>) {
      // 仅成功时释放懒加载引用：失败时保留现有 client（其本地持久化会话仍
      // 存在，reset 后重建会重新水合旧会话，造成"登出失败但状态被清空随后
      // 又恢复登录"的不一致）。
      reset();
    }
    return result;
  }

  @override
  Future<AppResult<SyncReport>> syncNow() async {
    if (!isConfigured) return const AppFailure('云同步未配置');
    // 互斥/去重：并发调用共享同一 in-flight Future（防并发双 refreshSession
    // 消费同一 refresh token 导致二次刷新失败、以及重复执行同一轮同步）。
    final inFlight = _syncInFlight;
    if (inFlight != null) return inFlight;
    final future = _runSync();
    _syncInFlight = future;
    try {
      return await future;
    } finally {
      if (identical(_syncInFlight, future)) {
        _syncInFlight = null;
      }
    }
  }

  Future<AppResult<SyncReport>>? _syncInFlight;

  Future<AppResult<SyncReport>> _runSync() async {
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
      try {
        final refreshed = await _lazyClient.auth.refreshSession();
        if (refreshed.session == null) {
          return const AppFailure('登录已过期，请重新登录');
        }
      } on AuthException catch (e) {
        // 区分"会话失效"与"网络瞬时故障"：优先用结构化错误码判定（文案易变），
        // code 缺失时再以消息特征兜底。
        final code = e.code?.toLowerCase();
        if (code != null) {
          if (code.contains('refresh_token') ||
              code.contains('invalid_grant') ||
              code.contains('expired')) {
            return const AppFailure('登录已过期，请重新登录');
          }
          return const AppFailure('网络不可用，请稍后重试');
        }
        final msg = e.message.toLowerCase();
        if (msg.contains('expired') ||
            msg.contains('invalid') ||
            msg.contains('refresh_token')) {
          return const AppFailure('登录已过期，请重新登录');
        }
        return const AppFailure('网络不可用，请稍后重试');
      } catch (_) {
        // 兜底：任何异常都转为 AppResult（遵守 SyncBackend 契约）。
        return const AppFailure('网络不可用，请稍后重试');
      }
    }
    // 刷新（或校验）后重新获取 userId：并发登出/换号（await 挂起点交错）
    // 时不得用刷新前的旧 userId 同步（防按已登出/已切换身份写入数据）。
    final effectiveUserId = currentUserId;
    if (effectiveUserId == null || _lazyClient.auth.currentSession == null) {
      return const AppFailure('请先登录后再同步');
    }
    try {
      // await 同时捕获同步抛错与异步 error（遵守"任何异常都转 AppResult"契约）。
      return await engine.syncNow(userId: effectiveUserId);
    } catch (e) {
      return AppFailure('同步失败：$e');
    }
  }
}
