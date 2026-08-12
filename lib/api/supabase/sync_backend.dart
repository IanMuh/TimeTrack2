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
  /// LAN 同步目标（**当前未落地，r53 注明**）：模块 2b 的 LAN 后端实现进入
  /// 代码库时随实现一起启用——当前仅作为语义注记保留（避免同步目标标识
  /// 在 LAN 落地时散落为字面量）。
  static const lan = 'lan';
}

/// 云同步后端接口。
abstract interface class SyncBackend {
  /// 未配置（SUPABASE_URL/ANON_KEY 缺失或非法）时的统一失败文案。
  ///
  /// 两个后端（[NoopSyncBackend] 与 Supabase 后端）共用同一常量。
  static const unconfiguredError = '云同步未配置（缺少 SUPABASE_URL/ANON_KEY）';

  /// 未配置失败的结构化错误码（**r52**）：与 [unconfiguredError] 文案解耦——
  /// 调用方（编排层/UI）判定"未配置"用 `failure.code == unconfiguredCode`
  /// 而非 message 字符串相等（文案调整/本地化不影响结构化判定，且有编译期
  /// 类型保障）；未配置失败统一构造为
  /// `AppFailure(unconfiguredError, code: unconfiguredCode)`。
  static const unconfiguredCode = 'unconfigured';

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
  ///
  /// 前置条件：调用方应**先检查 [isConfigured]** 再决定是否调用——未配置场景
  /// 本方法返回 [unconfiguredError] 失败（无会话可登出），防调用方误判云端
  /// 登出成功而继续执行本地状态清理；失败语义由编排层统一处理。
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

  @override
  bool get isConfigured => false;

  /// 未配置：状态恒为 null。单例广播流（late final 缓存同一实例，符合
  /// "多次访问返回同一流实例"契约）。
  /// **机制说明（r53）**：`Stream.multi` 的 onListen 对**每个订阅者各执行
  /// 一次**——每个订阅者收到独立的 null 快照回放，**并非共享同一事件序列**
  ///（当前仅回放常量 null，功能等价）；若未来 Noop 需模拟登录态变化（如作
  /// 测试替身扩展），各订阅者会收到彼此独立的事件序列，须按"每订阅者独立
  /// 回放"语义设计而非"共享事件源"。
  @override
  late final Stream<String?> authStateStream = Stream<String?>.multi(
    (controller) => controller.add(null),
    isBroadcast: true,
  );

  @override
  String? get currentUserId => null;

  @override
  Future<AppResult<void>> sendMagicLink(String email) async {
    return const AppFailure(SyncBackend.unconfiguredError, code: SyncBackend.unconfiguredCode);
  }

  @override
  Future<AppResult<String>> verifyEmailOtp(String email, String token) async {
    return const AppFailure(SyncBackend.unconfiguredError, code: SyncBackend.unconfiguredCode);
  }

  @override
  Future<AppResult<SyncReport>> syncNow() async {
    return const AppFailure(SyncBackend.unconfiguredError, code: SyncBackend.unconfiguredCode);
  }

  @override
  Future<AppResult<void>> signOut() async {
    // 未配置场景无会话可登出：与其余方法一致返回失败，防调用方误判云端登出
    // 成功而继续执行本地状态清理（本文件契约：失败语义由编排层统一处理）。
    return const AppFailure(SyncBackend.unconfiguredError, code: SyncBackend.unconfiguredCode);
  }
}
