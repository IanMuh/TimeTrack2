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
  /// - 单例缓存（late final）：getter 多次访问返回**同一流实例**——多组件/
  ///   多订阅者可同时监听（broadcast）；
  /// - **每个新订阅者立即收到当前快照**：`Stream.multi` 的 onListen 回调
  ///   对**每个订阅者**各执行一次（首个位置参数），在此补发当前登录态
  ///   （未登录为 null）——broadcast 不重放已发射事件，不补发则晚订阅者
  ///   一直收不到快照直到下一次认证事件；
  /// - 先订阅底层流：supabase 的 onAuthStateChange 是 broadcast 流，「读快照
  ///   → 订阅」窗口内到达的登录/登出事件会被 async* 生成器永久丢失；
  /// - **distinct 置于合并流之外**：快照与后续事件一并去重（只对底层流做
  ///   distinct 会漏掉快照与首条同 id 事件的重复下发）；
  /// - onError/onDone 转发：底层认证流错误/关闭时上层可见，不静默丢弃。
  late final Stream<String?> authStateStream = Stream<String?>.multi(
    (controller) {
      // onListen（**每个订阅者**各执行一次）：订阅底层认证流转发事件 +
      // 补发当前登录态快照（未登录为 null）——broadcast 不重放已发射事件，
      // 不补发则晚订阅者一直收不到快照直到下一次认证事件。
      final sub = _client.auth.onAuthStateChange
          .map((data) => data.session?.user.id)
          .listen(
        controller.add,
        onError: controller.addError,
        onDone: controller.close,
      );
      // 底层流 onDone 后 controller 已关闭：再 add 会抛 StateError——
      // 已关闭时取消底层订阅即可。
      if (!controller.isClosed) {
        controller.add(currentUserId);
      }
      controller.onCancel = sub.cancel;
    },
    isBroadcast: true,
  ).distinct();

  /// 当前登录用户 id（未登录为 null）。
  String? get currentUserId => _client.auth.currentUser?.id;

  /// 发送邮箱 OTP（验证码/魔法链接，由服务端配置决定）。
  Future<AppResult<void>> sendMagicLink(String email) async {
    try {
      final trimmed = email.trim();
      if (trimmed.isEmpty || !_looksLikeEmail(trimmed)) {
        return const AppFailure('邮箱地址非法');
      }
      await _client.auth.signInWithOtp(email: trimmed, shouldCreateUser: false);
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
      var userId = response.user?.id;
      if (userId == null) {
        // OTP 一次性凭证已被消费：response.user 缺失时从当前会话兜底取值
        //（防"服务端已登录但 user 为空"被误判为失败，用户重试必然失败）。
        // 兜底前校验当前会话用户与本次 OTP 邮箱一致——防此前已登录账号 A、
        // 本次用邮箱 B 登录而会话尚未切换时，把 A 的 id 误当 B 的登录结果
        // （身份错配）。
        final current = _client.auth.currentUser;
        if (current != null &&
            current.email?.toLowerCase() == trimmedEmail.toLowerCase()) {
          userId = current.id;
        }
      }
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
  /// 非空且无空格、域名含点、**排除首尾点与连续点**。
  static final _emailRe = RegExp(
    r'^[^@\s.](?:[^@\s.]|\.(?!\.))*@[^@\s.](?:[^@\s.]|\.(?!\.))*\.[^@\s.]+$',
  );

  bool _looksLikeEmail(String value) => _emailRe.hasMatch(value);
}
