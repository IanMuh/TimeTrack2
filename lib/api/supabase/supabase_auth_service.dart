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

  /// 底层认证流共享订阅（首个订阅者创建、最后一个取消时释放）。
  /// `Stream.multi` broadcast 会对**每个订阅者**各执行一次 onListen——若在
  /// onListen 内新建底层订阅，先取消的订阅者对应订阅永远不被 cancel（泄漏），
  /// 且同一条认证事件被多次入队。这里改为类级共享单条底层订阅：事件只入队
  /// 一次、广播到所有活跃订阅者，生命周期与监听者解耦。
  StreamSubscription<String?>? _authSub;
  final List<StreamController<String?>> _authControllers = [];

  /// 登录态流（当前用户 id；null = 未登录）。
  ///
  /// - 单例缓存（late final）：getter 多次访问返回**同一流实例**——多组件/
  ///   多订阅者可同时监听（broadcast）；
  /// - **每个新订阅者立即收到当前快照**：onListen 补发当前登录态（未登录为
  ///   null）——broadcast 不重放已发射事件，不补发则晚订阅者一直收不到快照
  ///   直到下一次认证事件；
  /// - **类级共享底层订阅**：首个订阅者创建、最后一个取消时释放，事件广播到
  ///   所有活跃订阅者（防每订阅者新建底层订阅泄漏 + 事件重复入队）；
  /// - **distinct 置于合并流之外**：快照与后续事件一并去重（只对底层流做
  ///   distinct 会漏掉快照与首条同 id 事件的重复下发）；
  /// - onError/onDone 转发：底层认证流错误/关闭时上层可见，不静默丢弃。
  late final Stream<String?> authStateStream = Stream<String?>.multi(
    (controller) {
      // onListen（**每个订阅者**各执行一次）：登记订阅者 + 首个订阅者创建
      // 底层订阅，补发当前登录态快照。
      _authControllers.add(controller);
      _authSub ??= _client.auth.onAuthStateChange
          .map((data) => data.session?.user.id)
          .listen(
        _broadcastAuth,
        onError: _broadcastAuthError,
        onDone: _closeAllAuthControllers,
      );
      // 底层流 onDone 后 controller 已关闭：再 add 会抛 StateError。
      if (!controller.isClosed) {
        controller.add(currentUserId);
      }
      controller.onCancel = () {
        _authControllers.remove(controller);
        if (_authControllers.isEmpty) {
          _authSub?.cancel();
          _authSub = null;
        }
      };
    },
    isBroadcast: true,
  ).distinct();

  void _broadcastAuth(String? value) {
    for (final controller in List.of(_authControllers)) {
      if (!controller.isClosed) controller.add(value);
    }
  }

  void _broadcastAuthError(Object error) {
    for (final controller in List.of(_authControllers)) {
      if (!controller.isClosed) controller.addError(error);
    }
  }

  void _closeAllAuthControllers() {
    // 清空列表 + 置空底层订阅：否则残留的已关闭 controller 使"最后一个取消
    // 时释放"永远无法触发（_authControllers 永不为空 → 内存泄漏），且 _authSub
    // 非 null 时新订阅者无法重建底层订阅（登录态流永久失效）。
    final controllers = List.of(_authControllers);
    _authControllers.clear();
    _authSub = null;
    for (final controller in controllers) {
      if (!controller.isClosed) controller.close();
    }
  }

  /// 释放底层 gotrue 订阅并关闭所有控制器（**登出/reset 生命周期终结用**）。
  ///
  /// **为何需要（r52）**：[_authSub] 对 gotrue `onAuthStateChange` 的订阅在
  /// 最后一个监听者取消前不会被释放——若服务被 reset 弃用（见
  /// SupabaseSyncBackend.reset）而无人取消监听，旧 client 及其底层资源被
  /// 持续引用，每次登录/登出循环都会累积一条旧订阅与一个旧 client（资源
  /// 持续增长）。本方法主动释放，解除"必须等监听者全部取消"的隐式依赖。
  /// 调用后本服务不再可用（流已关闭、底层订阅已取消），调用方须丢弃引用。
  void dispose() {
    final sub = _authSub;
    _authSub = null;
    unawaited(sub?.cancel());
    final controllers = List.of(_authControllers);
    _authControllers.clear();
    for (final controller in controllers) {
      if (!controller.isClosed) controller.close();
    }
  }

  /// 当前登录用户 id（未登录为 null）。
  String? get currentUserId => _client.auth.currentUser?.id;

  /// 发送邮箱 OTP（验证码/魔法链接，由服务端配置决定）。
  ///
  /// **安全说明（r53，用户枚举风险如实声明）**：`shouldCreateUser: false` 下
  /// 服务端对已注册邮箱返回 200、未注册邮箱返回 404 → 失败映射——**成功/失败
  /// 的二元结果本身可被攻击者用于探测邮箱是否已注册**（对候选邮箱逐个调用
  /// 可区分注册状态）。失败文案已泛化（不泄露服务端细节），但二元结果无法
  /// 通过文案隐藏；若产品不希望暴露注册状态，须服务端配合统一响应 + 限流
  ///（当前接受该暴露面，应用仅面向已注册用户登录）。
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
    // 其余非预期异常（编程错误）：重新抛出保留原始堆栈，由上层统一处理——
    // 重抛前记日志（含堆栈，与 lan_sync_server 未捕获异常记录方式一致；
    // 防用户直接触发的 OTP 流程中非预期异常类型导致界面崩溃时无痕可查）。
    // **可达性说明**：gotrue 的 GotrueFetch 会把网络/解析等异常统一
    // 包装成 AuthException（fallthrough 到上方 `on AuthException` 分支），
    // 本 catch 实际仅覆盖 SDK 之外的非预期异常（防御层保留，不专门构造
    // 触发——避免假覆盖测试）。
    // ignore: avoid_catches_without_on_clauses
    catch (e, st) {
      stderr.writeln('[supabase-auth] sendMagicLink 非预期异常：$e\n$st');
      rethrow;
    }
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
      // OTP 一次性凭证已被消费：**response.session.user 才是本次登录建立的
      // 会话的权威用户**——优先取之（防客户端已有旧会话时 response.user 与
      // 新建会话的 session.user 不一致，OTP 已被消费无法重试会锁死用户）。
      // 空安全说明：gotrue 的 Session.user 为非空类型（'user' 缺失时
      // Session.fromJson 解析期即抛 FormatException，落入 on AuthException
      // 分支），取值行 `session?.user.id` 安全；未来 SDK 若将 user 改为可空，
      // 须同步改为 `session?.user?.id ?? response.user?.id`。
      final userId = response.session?.user.id ?? response.user?.id;
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
    // 其余非预期异常（编程错误）：重新抛出保留原始堆栈，由上层统一处理——
    // 重抛前记日志（含堆栈；OTP 一次性凭证已被消费后，非预期异常类型让
    // 上层无从定位，用户又无法重试，日志是唯一排查入口）。
    // ignore: avoid_catches_without_on_clauses
    catch (e, st) {
      stderr.writeln('[supabase-auth] verifyEmailOtp 非预期异常：$e\n$st');
      rethrow;
    }
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
    // 其余非预期异常（编程错误）：重新抛出保留原始堆栈，由上层统一处理——
    // 重抛前记日志（含堆栈）。
    // ignore: avoid_catches_without_on_clauses
    catch (e, st) {
      stderr.writeln('[supabase-auth] signOut 非预期异常：$e\n$st');
      rethrow;
    }
  }

  /// 极简邮箱形态校验（supabase 服务端仍会最终校验）：单个 @、本地部分/域名
  /// 非空且无空格、域名含点、**排除首尾点与连续点**（本地部分不以 `.` 结尾）。
  static final _emailRe = RegExp(
    r'^[^@\s.](?:[^@\s.]|\.(?![.@]))*@[^@\s.](?:[^@\s.]|\.(?!\.))*\.[^@\s.]+$',
  );

  bool _looksLikeEmail(String value) => _emailRe.hasMatch(value);
}
