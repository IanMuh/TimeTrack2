/// 云同步后端抽象：阶段 3 编排（SyncStore）与 UI 依赖此接口，不直接触达
/// supabase client。
///
/// 设计（计划模块 2c）：
/// - [SyncBackend]：统一入口（登录态流 / 一次同步 / 登出 / 是否配置）；
/// - [NoopSyncBackend]：未配置 SUPABASE_URL/ANON_KEY 时离线（老项目语义，
///   应用完全本地可用）；测试用 mock backend 可继承本接口替换编排层；
/// - 同步报告 [SyncReport]：拉/推行数、是否全量、目标标识，供 UI/日志展示。
///
/// 登录态流契约：[authStateStream] **必须支持多订阅（broadcast）**，订阅时
/// 立即发出当前用户 id（未登录为 null），之后转发认证事件；多次访问 getter
/// 应返回**同一流实例**（所有订阅者共享同一事件源，防各自新建流丢事件）。
library;

import 'dart:async';

import '../../utils/result.dart';

/// 同步目标标识（status lastTarget 取值）。
abstract final class SyncTarget {
  static const supabase = 'supabase';
  static const lan = 'lan';
}

/// 云同步后端接口。
abstract interface class SyncBackend {
  /// 是否已注入云配置（SUPABASE_URL + ANON_KEY）。
  ///
  /// 注意：**仅表示配置是否注入**，不代表认证会话可用——会话有效性请通过
  /// [authStateStream] / [currentUserId] 判断（登录/登出/过期不影响本值）。
  bool get isConfigured;

  /// 登录态流（用户 id；null = 未登录）。
  ///
  /// 契约：broadcast 流，订阅时立即发出当前用户 id（未登录为 null），
  /// 之后转发认证事件。
  Stream<String?> get authStateStream;

  /// 当前登录用户 id（未登录为 null）。
  String? get currentUserId;

  /// 发起邮箱 OTP 登录（发送魔法链接/验证码到邮箱）。
  Future<AppResult<void>> sendMagicLink(String email);

  /// 校验邮箱 OTP 验证码并登录；成功后返回用户 id。
  Future<AppResult<String>> verifyEmailOtp(String email, String token);

  /// 执行一次完整同步（先拉后推）；失败返回可读原因。
  Future<AppResult<SyncReport>> syncNow();

  /// 登出。
  Future<AppResult<void>> signOut();
}

/// 一次同步的结果报告。
class SyncReport {
  const SyncReport({
    required this.target,
    required this.wasFullSync,
    required this.pulledRows,
    required this.pushedRows,
  });

  /// 同步目标（[SyncTarget]）。
  final String target;

  /// 是否为全量同步（从未同步 → 全量；否则增量）。
  final bool wasFullSync;

  /// 本次拉取并应用的行数（5 张业务表 + 配置）。
  final int pulledRows;

  /// 本次推送的行数。
  final int pushedRows;

  @override
  String toString() =>
      'SyncReport(target: $target, full: $wasFullSync, '
      'pulled: $pulledRows, pushed: $pushedRows)';
}

/// 未配置时的离线后端：一切同步操作返回明确失败，登录态流恒为 null。
///
/// 保证应用在无云配置时完全可用（老项目语义）；同时作为测试的占位实现。
/// 登录态流为**广播流且立即回放 null**（符合接口契约：订阅即收到未登录状态）。
class NoopSyncBackend implements SyncBackend {
  NoopSyncBackend();

  /// 未配置时的统一失败文案（4 处引用同一常量，防漏改导致消息不一致）。
  static const unconfiguredError = '云同步未配置（缺少 SUPABASE_URL/ANON_KEY）';

  @override
  bool get isConfigured => false;

  /// 未配置：状态恒为 null。单例广播流（late final 缓存同一实例，符合
  /// "多次访问返回同一流实例"契约）。
  @override
  late final Stream<String?> authStateStream = Stream<String?>.multi(
    (controller) => controller.add(null),
    isBroadcast: true,
  );

  @override
  String? get currentUserId => null;

  @override
  Future<AppResult<void>> sendMagicLink(String email) async {
    return const AppFailure(unconfiguredError);
  }

  @override
  Future<AppResult<String>> verifyEmailOtp(String email, String token) async {
    return const AppFailure(unconfiguredError);
  }

  @override
  Future<AppResult<SyncReport>> syncNow() async {
    return const AppFailure(unconfiguredError);
  }

  @override
  Future<AppResult<void>> signOut() async {
    // 未配置场景无会话可登出：与其余方法一致返回失败，防调用方误判云端登出
    // 成功而继续执行本地状态清理（本文件契约：失败语义由编排层统一处理）。
    return const AppFailure(unconfiguredError);
  }
}
