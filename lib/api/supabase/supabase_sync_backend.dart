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

/// 构建 Supabase 后端：未配置时返回 [NoopSyncBackend]（应用离线可用）。
///
/// [engine] 由调用方（阶段 3 编排）注入（真引擎 + mock 网关等组合由测试构造）。
SyncBackend createSupabaseSyncBackend({required CloudSyncEngine engine}) {
  if (!AppBuildConfig.isSupabaseConfigured()) return const NoopSyncBackend();
  return SupabaseSyncBackend(engine: engine);
}

/// Supabase 同步后端。
class SupabaseSyncBackend implements SyncBackend {
  SupabaseSyncBackend({required this.engine});

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
  String _validatedUrl() {
    final raw = AppBuildConfig.getString(
      AppBuildConfig.supabaseUrlKey,
      defaultValue: '',
    ).trim();
    final uri = Uri.tryParse(raw);
    if (raw.isEmpty ||
        uri == null ||
        !uri.isAbsolute ||
        (uri.scheme != 'http' && uri.scheme != 'https') ||
        uri.host.isEmpty) {
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
      // Stream.multi：每个监听者订阅时立即重放 null（broadcast 不重放已发射
      // 事件，Stream.value(...).asBroadcastStream 会让晚订阅者静默收不到快照）。
      return Stream<String?>.multi(
        (controller) => controller.add(null),
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
    final userId = currentUserId;
    if (userId == null) {
      return const AppFailure('请先登录后再同步');
    }
    // currentUser 非空 ≠ token 有效：JWT 过期但 refresh token 仍有效的会话
    // 应先尝试刷新；刷新失败（服务端已撤销/网络不可用）才提示重登。
    final session = _lazyClient.auth.currentSession;
    if (session == null) {
      return const AppFailure('请先登录后再同步');
    }
    final expired = session.expiresAt != null &&
        DateTime.fromMillisecondsSinceEpoch(session.expiresAt! * 1000)
            .isBefore(DateTime.now());
    if (expired) {
      try {
        await _lazyClient.auth.refreshSession();
      } on Object {
        // 刷新失败：会话已失效，提示重登。
        return const AppFailure('登录已过期，请重新登录');
      }
    }
    return engine.syncNow(userId: userId);
  }
}
