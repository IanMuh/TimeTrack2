/// Supabase 邮箱 OTP 认证服务（薄封装 supabase_flutter）。
///
/// - 登录：`sendMagicLink(email)` 发送验证码 → `verifyEmailOtp(email, otp)` 完成登录
///   （supabase_flutter 的 OTP 流程：`signInWithOTP` + `verifyOTP`）；
/// - 登出 / 登录态流（当前用户 id）；
/// - 登录成功后由上层（阶段 3 编排）触发一次同步。
library;

import 'dart:async';
import 'dart:io';

import 'package:http/http.dart' as http;
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
      // GoTrue 默认小写规范化存储邮箱：统一 trim + toLowerCase（防发码/校验
      // 大小写不一致导致 OTP 记录匹配失败）。
      final trimmed = email.trim().toLowerCase();
      if (trimmed.isEmpty || !_looksLikeEmail(trimmed)) {
        return const AppFailure('邮箱地址非法');
      }
      await _client.auth.signInWithOtp(email: trimmed, shouldCreateUser: false);
      return const AppSuccess(null);
    } on AuthException {
      // 远端错误细节不向用户透出（防泄露服务端内部信息）。
      return const AppFailure('发送验证码失败，请稍后重试');
    } on SocketException {
      return const AppFailure('网络不可用，请稍后重试');
    } on TimeoutException {
      return const AppFailure('网络不可用，请稍后重试');
    } on http.ClientException {
      return const AppFailure('网络不可用，请稍后重试');
    }
    // 其余非预期异常（编程错误）：重新抛出保留原始堆栈，由上层统一处理。
  }

  /// 校验邮箱 OTP 验证码并登录；成功返回用户 id。
  Future<AppResult<String>> verifyEmailOtp(String email, String token) async {
    try {
      // 与 sendMagicLink 一致：小写归一（GoTrue 按小写存储邮箱，防大小写
      // 不一致导致 OTP 记录匹配失败）。
      final trimmedEmail = email.trim().toLowerCase();
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
            current.email?.toLowerCase() == trimmedEmail) {
          userId = current.id;
        }
      }
      if (userId == null) {
        // 中性表述（失败结果不应自称"登录成功"）。
        return const AppFailure('无法确认登录用户，请重试');
      }
      return AppSuccess(userId);
    } on AuthException {
      return const AppFailure('验证失败，请检查验证码或稍后重试');
    } on SocketException {
      return const AppFailure('网络不可用，请稍后重试');
    } on TimeoutException {
      return const AppFailure('网络不可用，请稍后重试');
    } on http.ClientException {
      return const AppFailure('网络不可用，请稍后重试');
    }
    // 其余非预期异常（编程错误）：重新抛出保留原始堆栈，由上层统一处理。
  }

  /// 登出。
  Future<AppResult<void>> signOut() async {
    try {
      await _client.auth.signOut();
      return const AppSuccess(null);
    } on AuthException {
      return const AppFailure('登出失败，请稍后重试');
    } on SocketException {
      return const AppFailure('网络不可用，请稍后重试');
    } on TimeoutException {
      return const AppFailure('网络不可用，请稍后重试');
    } on http.ClientException {
      return const AppFailure('网络不可用，请稍后重试');
    }
    // 其余非预期异常（编程错误）：重新抛出保留原始堆栈，由上层统一处理。
  }

  /// 极简邮箱形态校验（supabase 服务端仍会最终校验）：单个 @、本地部分/域名
  /// 非空且无空格、域名含点、**排除首尾点与连续点**。
  static final _emailRe = RegExp(
    r'^[^@\s.](?:[^@\s.]|\.(?!\.))*@[^@\s.](?:[^@\s.]|\.(?!\.))*\.[^@\s.]+$',
  );

  bool _looksLikeEmail(String value) => _emailRe.hasMatch(value);
}
