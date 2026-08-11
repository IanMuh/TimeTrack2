/// Supabase 邮箱 OTP 认证服务（薄封装 supabase_flutter）。
///
/// - 登录：`sendMagicLink(email)` 发送验证码 → `verifyEmailOtp(email, otp)` 完成登录
///   （supabase_flutter 的 OTP 流程：`signInWithOTP` + `verifyOTP`）；
/// - 登出 / 登录态流（当前用户 id）；
/// - 登录成功后由上层（阶段 3 编排）触发一次同步。
library;

import 'dart:async';

import 'package:supabase_flutter/supabase_flutter.dart';

import '../../utils/result.dart';

/// Supabase 认证服务。
class SupabaseAuthService {
  SupabaseAuthService({SupabaseClient? client})
      : _client = client ?? Supabase.instance.client;

  final SupabaseClient _client;

  /// 登录态流（当前用户 id；null = 未登录）。
  ///
  /// 先订阅底层流、再补发快照：supabase 的 onAuthStateChange 是 broadcast 流，
  /// 新订阅者不会立即收到当前状态；且「读快照 → 订阅」窗口内到达的登录/登出
  /// 事件会被 async* 生成器永久丢失。用 Stream.multi 先监听再补快照；
  /// **distinct 置于合并流之外**——快照与后续事件一并去重（只对底层流做
  /// distinct 会漏掉快照与首条同 id 事件的重复下发）。
  Stream<String?> get authStateStream => Stream<String?>.multi((controller) {
        final sub = _client.auth.onAuthStateChange
            .map((data) => data.session?.user.id)
            .listen(controller.add);
        controller.add(currentUserId);
        controller.onCancel = sub.cancel;
      }).distinct();

  /// 当前登录用户 id（未登录为 null）。
  String? get currentUserId => _client.auth.currentUser?.id;

  /// 发送邮箱 OTP（验证码/魔法链接，由服务端配置决定）。
  Future<AppResult<void>> sendMagicLink(String email) async {
    try {
      final trimmed = email.trim();
      if (trimmed.isEmpty || !_looksLikeEmail(trimmed)) {
        return const AppFailure('邮箱地址非法');
      }
      await _client.auth.signInWithOtp(email: trimmed);
      return const AppSuccess(null);
    } on AuthException {
      // 远端错误细节不向用户透出（防泄露服务端内部信息）。
      return const AppFailure('发送验证码失败，请稍后重试');
    }
    // 非 AuthException（编程/网络/平台异常）：重新抛出保留原始堆栈，由上层
    // 统一处理——不包装成无 cause 的新异常，也不吞成通用提示掩盖真实 bug。
  }

  /// 校验邮箱 OTP 验证码并登录；成功返回用户 id。
  Future<AppResult<String>> verifyEmailOtp(String email, String token) async {
    try {
      final trimmedEmail = email.trim();
      final trimmedToken = token.trim();
      if (trimmedEmail.isEmpty || !_looksLikeEmail(trimmedEmail)) {
        return const AppFailure('邮箱地址非法');
      }
      if (trimmedToken.isEmpty) {
        return const AppFailure('验证码不能为空');
      }
      final response = await _client.auth.verifyOTP(
        email: trimmedEmail,
        token: trimmedToken,
        type: OtpType.email,
      );
      final userId = response.user?.id;
      if (userId == null) {
        return const AppFailure('登录成功但未取得用户信息');
      }
      return AppSuccess(userId);
    } on AuthException {
      return const AppFailure('验证失败，请检查验证码或稍后重试');
    }
    // 非 AuthException 重新抛出保留堆栈（与 sendMagicLink 一致）。
  }

  /// 登出。
  Future<AppResult<void>> signOut() async {
    try {
      await _client.auth.signOut();
      return const AppSuccess(null);
    } on AuthException {
      return const AppFailure('登出失败，请稍后重试');
    }
    // 非 AuthException 重新抛出保留堆栈（与 sendMagicLink 一致）。
  }

  /// 极简邮箱形态校验（supabase 服务端仍会最终校验）：单个 @、本地部分/域名
  /// 非空且无空格、域名含点。
  static final _emailRe = RegExp(r'^[^@\s]+@[^@\s]+\.[^@\s]+$');

  bool _looksLikeEmail(String value) => _emailRe.hasMatch(value);
}
