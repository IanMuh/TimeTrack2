import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:timetrack2/api/supabase/supabase_auth_service.dart';

/// SupabaseAuthService 单测：用 MockClient（http/testing）注入真 SDK 网络层，
/// 覆盖共享订阅状态机（多订阅/取消/重建/快照补发/底层事件广播）与
/// verifyOTP 取值优先级——这两类时序最易回归，且不依赖真实 Supabase 服务。
///
/// 构造用 `flowType: implicit` + `autoRefreshToken: false`：免 PKCE 存储、
/// 免自动刷新定时器。signOut 细节：默认 local scope **无会话时**不发网络
/// 请求（本地清会话）；**有会话时** gotrue 会带 access token 发 POST
/// /logout（见对应用例）。
///
/// **SDK 升级核验清单（r40 收敛）**：本文件多处耦合 gotrue 2.27.1 内部行为
///（已逐处对照 pub 缓存源码核验）——① local scope 有会话时 signOut 发 POST
/// /logout（gotrue_client.dart `_signOut`）；② `AuthResponse.fromJson` 解析规则
///（session.user 取顶层 'user'、response.user 取顶层 'id'）；③ verifyOTP →
/// notifyAllSubscribers 事件时序。`pub upgrade` 升级 supabase_flutter（caret
/// 约束 ^2.17.1）引入新 gotrue 时，须逐一核验上述行为并同步调整 mock/断言；
/// 任何一项变化若未被核验，用例会以误导性方式失败（易误判为服务层回归）。
void main() {
  // 统一在 main 首行初始化（与项目其他测试文件保持一致——防维护者误以为
  // setUp 依赖 binding 或存在初始化顺序约定）。
  TestWidgetsFlutterBinding.ensureInitialized();
  // SupabaseClient 构造时 GoTrueClient 会异步恢复持久化会话（平台存储），
  // 且 MockClient 需在测试的 zone 中运行——隔离策略（r23 固化）：flutter_test
  // 提供**内存**平台存储；会话持久化（verifyEmailOtp 成功路径）理论上可跨
  // 用例恢复——用 setUp 重置 SharedPreferences mock 存储，将"用例顺序无关"
  // 从隐式行为变为显式保证（防未来 SDK/存储实现变化导致 CI 偶发 flaky）。
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  /// 造一个**按请求路径分发**的处理器（handler 按 URL path 返回 JSON 对象）：
  /// - `/auth/v1/verify` → onVerify（登录会话响应）；
  /// - `/auth/v1/otp` → onOtp（发码，空对象即可）；
  /// - 未匹配路径 → 404 **大声失败**（若 SDK 新增/调整请求路径，此处抛错
  ///   暴露而非静默应答，提升状态机用例的缺陷捕获能力）。
  /// **onAnyRequest**：任意请求（含 404 兜底）计数回调——"不发网络
  /// 请求"类断言须用它（仅 onVerify/onOtp 置位会漏掉未注册路径的请求）。
  MockClient mockAuthClient({
    Map<String, dynamic> Function(http.Request request)? onVerify,
    Map<String, dynamic> Function(http.Request request)? onOtp,
    void Function(http.Request request)? onAnyRequest,
  }) =>
      MockClient((request) async {
        onAnyRequest?.call(request);
        Map<String, dynamic>? result;
        if (request.url.path == '/auth/v1/verify' && onVerify != null) {
          result = onVerify(request);
        } else if (request.url.path == '/auth/v1/otp' && onOtp != null) {
          result = onOtp(request);
        } else {
          return http.Response('Not found', 404, request: request);
        }
        return http.Response(
          jsonEncode(result),
          200,
          headers: {'content-type': 'application/json'},
          request: request,
        );
      });

  /// 构造被测服务：`implicit` + `autoRefreshToken: false`（免 PKCE 存储、
  /// 免自动刷新定时器——聚焦服务层自身契约）。
  /// **覆盖缺口（已记录）**：生产路径（SupabaseSyncBackend._lazyClient）
  /// 用默认配置（PKCE + 自动刷新）——本文件对 PKCE 码交换、token 自动刷新/
  /// 401 刷新失败恢复等认证路径**无覆盖**（implicit 免 PKCE 存储，刷新定时器
  /// 关闭）；这些路径回归（如刷新循环清会话、PKCE 状态校验缺失）现有断言
  /// 无法发现，**归阶段 3 编排集成测试落点**（届时用默认 authOptions 构造 +
  /// 内存网关补 PKCE 冒烟用例；本文件头注释已列 SDK 升级核验清单）。
  SupabaseAuthService buildService(MockClient client) {
    final supabase = SupabaseClient(
      'https://example.supabase.co',
      'test-anon-key',
      httpClient: client,
      authOptions: const AuthClientOptions(
        autoRefreshToken: false,
        authFlowType: AuthFlowType.implicit,
      ),
    );
    return SupabaseAuthService(client: supabase);
  }

  /// 登录会话 JSON payload（**单一事实来源**——verifyOTP 成功响应在状态机组/
  /// signOut 等 6+ 处复用；改会话字段（token 键/expires_at 等）只需改此处）。
  Map<String, dynamic> mockSessionPayload({String id = 'session-user-id'}) => {
        'access_token': 'access-token',
        'token_type': 'bearer',
        'expires_in': 3600,
        'refresh_token': 'refresh-token',
        'user': {
          'id': id,
          'email': 'a@b.com',
          'aud': 'authenticated',
          'created_at': '2026-08-11T00:00:00Z',
        },
      };

  group('authStateStream 共享订阅状态机', () {
    test('getter 多次访问返回同一流实例（单例契约）', () {
      // **单例锁定（r47 #7）**：生产代码中不同组件跨调用订阅同一状态源——若
      // getter 每次新建 Stream.multi，各组件拿到独立数据流、事件互相丢失；
      // 实现为 late final 单例缓存，本断言防重构回归（各用例先缓存再 listen
      // 的模式无法捕获该回归）。
      final service = buildService(mockAuthClient());
      expect(service.authStateStream, same(service.authStateStream),
          reason: 'authStateStream getter 必须返回同一流实例（单例契约）');
    });

    test('多订阅者各收到一次快照，且只收到一次（不重复补发）', () async {
      final service = buildService(mockAuthClient());
      final stream = service.authStateStream;

      final firstEvents = <String?>[];
      final firstSub = stream.listen(firstEvents.add);
      addTearDown(firstSub.cancel); // 防断言失败时订阅泄漏（含底层共享订阅）
      await pumpEventQueue();
      expect(firstEvents, [null], reason: '首个订阅者立即收到快照 null');

      // 新订阅者加入：各自收到一次快照；**已存在订阅者不重复收到**（broadcast
      // 不重放，Stream.multi 仅对新订阅者执行 onListen 补发）。
      final secondEvents = <String?>[];
      final secondSub = stream.listen(secondEvents.add);
      addTearDown(secondSub.cancel);
      await pumpEventQueue();
      expect(secondEvents, [null], reason: '新订阅者收到快照');
      expect(firstEvents, [null],
          reason: '新订阅者加入不得向已存在订阅者重复补发快照');
    });

    test('全部取消后重新订阅：底层订阅可重建，快照再次补发', () async {
      final service = buildService(mockAuthClient());
      final stream = service.authStateStream;

      final sub1 = stream.listen((_) {});
      await pumpEventQueue();
      await sub1.cancel(); // 最后取消 → 底层订阅释放

      // 重新订阅：onListen 再次执行，快照重新补发。
      // **守护范围（r38 如实声明）**：本用例只能发现"过早释放"方向（取消后
      // 重建无法收到快照/事件）；"**永不释放** _authSub"（泄漏导致重复 gotrue
      // 监听器/重复事件回调）方向无法被观测——需 @visibleForTesting 的订阅
      // 计数钩子才能直接断言，属已知覆盖边界。
      final events = <String?>[];
      final sub2 = stream.listen(events.add);
      addTearDown(sub2.cancel);
      await pumpEventQueue();
      expect(events, [null], reason: '重建后订阅者仍立即收到快照');
    });

    test('部分取消后其余订阅者仍收到底层事件（引用计数不被误释放）', () async {
      // 多个订阅者中取消其中一个：_authControllers 未清空 → 底层订阅不得
      // 释放；其余订阅者仍能收到后续广播事件。
      final service = buildService(mockAuthClient(onVerify: (request) {
        return mockSessionPayload();
      }));
      final stream = service.authStateStream;
      final kept = <String?>[];
      final subKeep = stream.listen(kept.add);
      final subDrop = stream.listen((_) {});
      addTearDown(subKeep.cancel);
      addTearDown(subDrop.cancel);
      await pumpEventQueue();
      expect(kept, [null], reason: '初始快照');

      // **waiter 在取消前订阅（r46）**：若"任一订阅取消即提前释放 _authSub"
      // 的缺陷存在，取消后订阅会触发 onListen 立即重建底层订阅、kept 仍收到
      // 广播而掩盖缺陷——提前订阅使取消与事件触发之间无新 onListen，缺陷
      // 导致 Completer 超时真实暴露。
      final completer = Completer<void>();
      final waiter = stream.listen((value) {
        if (value == 'session-user-id' && !completer.isCompleted) {
          completer.complete();
        }
      });
      addTearDown(waiter.cancel);
      await subDrop.cancel(); // 取消其中一个（非最后一个）
      await pumpEventQueue();
      await service.verifyEmailOtp('a@b.com', '123456');
      await completer.future.timeout(
        const Duration(seconds: 5),
        onTimeout: () => throw TestFailure('等待 session-user-id 广播事件超时'),
      );
      expect(kept, [null, 'session-user-id'],
          reason: '部分取消后其余订阅者仍收到广播事件（底层订阅未误释放）');
    });

    test('全取消重建后的新订阅者收到后续广播事件（事件通路真正恢复）', () async {
      final service = buildService(mockAuthClient(onVerify: (request) {
        return mockSessionPayload();
      }));
      final stream = service.authStateStream;
      final sub1 = stream.listen((_) {});
      await pumpEventQueue();
      await sub1.cancel(); // 全取消 → 底层订阅释放（_authSub 置空）

      // 重建订阅（新订阅者）：仅补发快照不足以证明通路恢复——需后续
      // verifyOTP 事件能广播到新订阅者（验证 _authSub 重建后事件转发恢复）。
      final events = <String?>[];
      final sub2 = stream.listen(events.add);
      addTearDown(sub2.cancel);
      await pumpEventQueue();
      expect(events, [null], reason: '重建后快照补发');

      // waiter 在触发前订阅（真实等待广播，非快照补发）。
      final completer = Completer<void>();
      final waiter = stream.listen((value) {
        if (value == 'session-user-id' && !completer.isCompleted) {
          completer.complete();
        }
      });
      addTearDown(waiter.cancel);
      await service.verifyEmailOtp('a@b.com', '123456');
      await completer.future.timeout(
        const Duration(seconds: 5),
        onTimeout: () => throw TestFailure('等待重建后广播事件超时'),
      );
      expect(events, [null, 'session-user-id'],
          reason: '重建后新订阅者收到后续广播事件（底层订阅重建成功）');
    });

    test('底层 auth 事件广播到所有活跃订阅者（事件通路恢复且至少投递一次）', () async {
      // 驱动方式：verifyOTP 成功时 SDK 保存会话并 notifyAllSubscribers
      //（signedIn 事件）→ 类级共享底层订阅收到 → _broadcastAuth 广播到
      // 所有活跃订阅者。锁定"事件只入队一次、广播到每个订阅者恰好一次"
      // 的核心状态机（此前仅覆盖快照补发路径）。
      // **依赖说明（已知）**：本用例通过 verifyOTP 成功驱动底层流，间接依赖
      // gotrue 的 verifyOTP→notifyAllSubscribers 内部行为——若该行为变化，
      // 用例会失败提示（而非静默通过），仍具回归价值；不依赖固定延时。
      final service = buildService(mockAuthClient(onVerify: (request) {
        return mockSessionPayload();
      }));
      final stream = service.authStateStream;
      final firstEvents = <String?>[];
      final secondEvents = <String?>[];
      final subA = stream.listen(firstEvents.add);
      final subB = stream.listen(secondEvents.add);
      addTearDown(subA.cancel);
      addTearDown(subB.cancel);
      await pumpEventQueue();
      expect(firstEvents, [null], reason: '订阅者 A 先收到快照');
      expect(secondEvents, [null], reason: '订阅者 B 也收到快照');

      // 显式等待目标事件到达（不依赖 pumpEventQueue 冲刷时序）：两个订阅者
      // 都必须收到 'session-user-id'——waiter 在**触发前**订阅（真实等待广播
      // 而非快照补发），Completer + onTimeout 诊断（超时抛 TestFailure 带
      // 上下文，而非裸 TimeoutException）。
      // **守护范围（r38 如实声明）**：authStateStream 以 `.distinct()` 收尾——
      // 单次 verifyOTP 驱动下，**同值事件重复广播**（_broadcastAuth 对同一
      // controller 连续入队两次）会被 distinct 折叠，本用例**无法区分"恰好
      // 广播一次"与"重复但被去重"**；实际守护的是"事件通路恢复 + 至少一次
      // 投递到所有活跃订阅者"。要锁定"单条底层事件恰好入队一次"需在 distinct
      // 之前观测（暴露未去重流或内部 controller 计数），属已知覆盖边界。
      final waiters = <StreamSubscription<String?>>[];
      // **await 取消**：StreamSubscription.cancel 返回 Future——与
      // 本文件其他 addTearDown(cancel) 一致，await 保证取消完成时机受控。
      addTearDown(() async {
        for (final w in waiters) {
          await w.cancel();
        }
      });
      final completerA = Completer<void>();
      final completerB = Completer<void>();
      waiters.add(stream.listen((value) {
        if (value == 'session-user-id' && !completerA.isCompleted) {
          completerA.complete();
        }
      }));
      waiters.add(stream.listen((value) {
        if (value == 'session-user-id' && !completerB.isCompleted) {
          completerB.complete();
        }
      }));
      await service.verifyEmailOtp('a@b.com', '123456'); // 单次触发
      await Future.wait([
        completerA.future.timeout(
          const Duration(seconds: 5),
          onTimeout: () => throw TestFailure('等待订阅者 A 广播事件超时'),
        ),
        completerB.future.timeout(
          const Duration(seconds: 5),
          onTimeout: () => throw TestFailure('等待订阅者 B 广播事件超时'),
        ),
      ]);
      // 事件广播恰好一次（每个订阅者的事件序列：[null, 'session-user-id']）
      expect(firstEvents, [null, 'session-user-id'],
          reason: '底层事件广播到订阅者 A（恰好一次）');
      expect(secondEvents, [null, 'session-user-id'],
          reason: '底层事件广播到订阅者 B（恰好一次）');
    });
  });

  group('verifyEmailOtp 取值优先级', () {
    // 用例判别力依赖 gotrue AuthResponse.fromJson 的解析细节（session.user
    // 从顶层 'user' 解析、response.user 从顶层 'id' 解析）——这两条用例锁定
    // 的是**我们服务层**的取值顺序（session 优先），SDK 解析规则变化会使
    // mock 构造失准（用例失败提示），而非静默掩盖。
    // **判别力核验**：已对照 gotrue 2.27.1 auth_response.dart——
    // `user = User.fromJson(json) ?? Session.fromJson(json)?.user`，即顶层
    // 'user' 对象与顶层 'id' 同时存在时，session.user.id 与 response.user.id
    // 来自不同键、可真实构造不同值；"user 存在则取 user 不回退顶层 id"的
    // 实现不存在——本用例的优先级判别有效。
    test('response.session.user 为权威取值（优先于 response.user，两者真实不同）', () async {
      // **payload 单一事实来源（r46）**：从 mockSessionPayload 派生并覆盖差异
      // 字段（access_token/user/id）——会话结构变更只改 mockSessionPayload；
      // 下方判别力自校验与 handler 共用同一 payload 局部变量（防两处内联漂移）。
      http.Request? verifyRequest;
      final discriminatorPayload = <String, dynamic>{
        ...mockSessionPayload(),
        'access_token': 'new-access-token',
        'refresh_token': 'new-refresh-token',
        'user': {
          'id': 'session-user-id',
          'email': 'new@example.com',
          'aud': 'authenticated',
          'created_at': '2026-08-11T00:00:00Z',
        },
        'id': 'top-level-user-id', // 顶层用户对象（旧会话/残留，非本次登录）
      };
      final service = buildService(mockAuthClient(onVerify: (request) {
        verifyRequest = request;
        // **机制说明**：本 handler 内无断言——对未注册路径"大声失败"的是
        // mockAuthClient 的 404 兜底分支（SDK 收到 404 后包成 AuthException，
        // 最终由 `requireValue()` 抛 StateError），而非 handler 内 expect。
        // SDK 的 AuthResponse.fromJson：session.user 从顶层 'user' 对象解析，
        // response.user 从**顶层 'id'** 解析——两者构造为不同值，才能真实
        // 锁定"优先 session.user"（本次 OTP 登录建立的会话的权威用户），
        // 否则两者相同、用例无法区分优先级。
        return discriminatorPayload;
      }));

      // **判别力自校验**：本用例依赖 gotrue 解析细节（session.user 取顶层
      // 'user'、response.user 取顶层 'id'）——若 SDK 未来统一解析使两个候选
      // 值相同，优先级回归会静默失判；先对 payload 过 AuthResponse.fromJson
      // 断言两侧非 null 且确实不同，判别力失效时大声失败而非静默通过。
      final parsed = AuthResponse.fromJson(discriminatorPayload);
      // **判别力前置（先断言两侧均非 null，再断言不同）**：任一侧为 null
      // 时 `isNot` 恒真、判别力静默丢失——非 null 断言使判别力失效大声失败。
      expect(parsed.session?.user.id, isNotNull,
          reason: '判别力前置：session.user 必须解析出用户');
      expect(parsed.user?.id, isNotNull,
          reason: '判别力前置：response.user 必须解析出用户');
      expect(parsed.session?.user.id, isNot(parsed.user?.id),
          reason: '判别力前置：session.user 与 response.user 必须解析为不同值'
              '（否则本用例无法锁定优先级）');

      final result =
          await service.verifyEmailOtp('New@Example.COM', '123456');
      expect(result.requireValue(), 'session-user-id',
          reason: '优先 session.user（本次登录建立的会话的权威用户），'
              '不得取顶层残留用户');

      // **verify 请求体断言（r47 #6）**：OTP 是一次性凭证，参数回归代价最高
      //（email/token 颠倒、去小写归一、type 错配会让状态机组与优先级组用例
      // 全部假阴性通过）——锁定 SDK 侧请求体的 email 小写/token/type 语义。
      // **判别力（r48）**：入参用混合大小写 'New@Example.COM'——若服务层删除
      // verifyEmailOtp 侧的 toLowerCase 归一化，断言 `== 'new@example.com'`
      // 会失败（用全小写入参则归一化删除后断言仍通过、判别力丢失；sendMagicLink
      // 用例只守护自己那侧，无法覆盖本路径）。
      expect(verifyRequest, isNotNull, reason: 'verifyEmailOtp 必须发出 /verify 请求');
      final verifyBody =
          jsonDecode(verifyRequest!.body) as Map<String, dynamic>;
      expect(verifyBody['email'], 'new@example.com',
          reason: 'verify 请求体 email 已小写归一化');
      expect(verifyBody['token'], '123456', reason: 'verify 请求体携带原样 token');
      expect(verifyBody['type'], 'email', reason: 'verify 请求体 type=email');
    });

    test('session 缺失时回退 response.user（响应即用户对象）', () async {
      final service = buildService(mockAuthClient(onVerify: (request) {
        // 无 access_token → Session.fromJson 返回 null；SDK 的 User.fromJson
        // 从**顶层** id 字段解析用户对象——响应本身是用户对象时才走该回退
        //（对应两步验证中间响应/无 session 的登录响应形态）。
        return {
          'id': 'plain-user-id',
          'email': 'plain@example.com',
          'aud': 'authenticated',
          'created_at': '2026-08-11T00:00:00Z',
        };
      }));

      final result = await service.verifyEmailOtp('plain@example.com', '654321');
      expect(result.requireValue(), 'plain-user-id',
          reason: 'session 缺失时回退 response.user（顶层用户对象）');
    });

    test('两者皆缺失 → 显式失败（OTP 已消费不可重试，不得假装成功）', () async {
      // `const {}` 空响应：AuthResponse.fromJson 解析为 session=null/user=null
      //（SDK 行为——已实测确认），verifyEmailOtp 返回"无法确认登录用户"失败。
      final service = buildService(mockAuthClient(onVerify: (request) => const {}));
      final result = await service.verifyEmailOtp('a@b.com', '123456');
      expect(result.isSuccess, isFalse,
          reason: '无法确认用户时显式失败（防拿错误 userId 去同步数据）');
    });

    test('空邮箱 / 空 token 早退分支：显式失败不触达网络（OTP 已消费不可重试场景防回归）', () async {
      // 服务层早退分支（邮箱非法/空、token 空）返回失败即止——尤其 OTP
      // 为一次性凭证，若该路径回归（误触达网络/返回错误 userId）用户会被
      // 锁死或同步到错误账号。
      // **onAnyRequest 计数**：仅 onVerify 会漏掉"回归为对 /auth/v1/otp
      // 发请求"的路径（未设 onOtp → 404 兜底 + gotrue 包成 AuthException →
      // 两个断言仍通过，假阴性）——onAnyRequest 覆盖任意路径。
      var hitNetwork = false;
      final service = buildService(mockAuthClient(onAnyRequest: (request) {
        hitNetwork = true;
      }));

      // 空/空白邮箱
      for (final email in ['', '   ']) {
        final result = await service.verifyEmailOtp(email, '123456');
        expect(result.isSuccess, isFalse, reason: '空邮箱拒绝：$email');
      }
      // 空/空白 token（r33：空白 token 覆盖——实现依赖 trim 后 isEmpty；
      // 若未来移除某处 trim 仅保留 isEmpty，空白 token 会通过检查触达网络，
      // 且 token 无邮箱正则的第二道防线，hitNetwork 断言须能捕获）。
      for (final token in ['', '   ']) {
        expect(
          (await service.verifyEmailOtp('a@b.com', token)).isSuccess,
          isFalse,
          reason: '空 token 拒绝：$token',
        );
      }
      // **非法格式邮箱走 OTP 路径（r46）**：命中 `_looksLikeEmail` 正则分支
      //（与 sendMagicLink 用例的 'a..b@c.com' 断言对齐，补齐正则分支覆盖——
      // 若未来移除 OTP 路径邮箱校验，非法邮箱会触达网络并可能消耗一次性 OTP）。
      for (final email in ['a..b@c.com', 'a b@c.com']) {
        expect(
          (await service.verifyEmailOtp(email, '123456')).isSuccess,
          isFalse,
          reason: '非法邮箱 OTP 拒绝：$email',
        );
      }
      // 空/空白邮箱发码
      for (final email in ['', '   ']) {
        expect((await service.sendMagicLink(email)).isSuccess, isFalse,
            reason: '空邮箱发码拒绝：$email');
      }
      expect(hitNetwork, isFalse,
          reason: '早退分支不得触达网络（防误消耗一次性凭证）');
    });
  });

  group('sendMagicLink / signOut', () {
    test('sendMagicLink 发码成功（校验请求路径/方法/邮箱小写）；非法邮箱拒绝', () async {
      http.Request? captured;
      var hitNetwork = false;
      final service = buildService(mockAuthClient(onOtp: (request) {
        captured = request;
        hitNetwork = true;
        return const {};
      }));

      final ok = await service.sendMagicLink('User@Example.COM');
      expect(ok.isSuccess, isTrue);
      expect(hitNetwork, isTrue, reason: '合法邮箱应发码');
      expect(captured, isNotNull);
      final request = captured!; // 解包结果存入局部变量，后续访问不触碰 nullable 的 captured
      expect(request.url.path, '/auth/v1/otp', reason: '发码走 OTP 端点');
      expect(request.method, 'POST', reason: '发码为 POST');
      // 邮箱小写归一化由服务层完成（SDK 按小写存储邮箱）——请求体必须携带
      // 小写邮箱（防大小写不一致导致 OTP 记录匹配失败）。
      final body = jsonDecode(request.body) as Map<String, dynamic>;
      expect(body['email'], 'user@example.com', reason: '邮箱已小写归一化');
      // **create_user 语义（r47 #6）**：锁定 shouldCreateUser: false——防误
      // 创建用户（应用只允许已存在账号登录，注册流程另有通道）。
      expect(body['create_user'], false,
          reason: '发码请求体必须携带 create_user=false（防误创建用户）');

      // 非法邮箱不发码（不触达网络；captured 保持上次值，仅用 hitNetwork 判定）。
      hitNetwork = false;
      final bad = await service.sendMagicLink('a..b@c.com');
      expect(bad.isSuccess, isFalse, reason: '连续点邮箱拒绝');
      expect(hitNetwork, isFalse, reason: '非法邮箱不得触达网络');
    });

    test('signOut：无会话本地清除即成功（不发网络请求）', () async {
      var hitNetwork = false;
      // 用 onAnyRequest（含 404 兜底分支都计数）——防 gotrue 无会话时仍向
      // 未注册路径（如 /logout）发请求且 SDK 吞错时"不发网络请求"断言
      // 假阳性（仅 onVerify/onOtp 置位会漏掉任意未预期路径）。
      final service = buildService(mockAuthClient(onAnyRequest: (request) {
        hitNetwork = true;
      }));
      final result = await service.signOut();
      expect(result.isSuccess, isTrue);
      expect(hitNetwork, isFalse,
          reason: '无会话时 signOut 仅本地清会话（默认 local scope）');
    });

    test('signOut：有会话时走 POST /logout 并广播 signedOut 事件', () async {
      // 依赖说明：本用例将测试耦合到 gotrue SDK 的 signOut 内部网络行为——
      // 服务层 signOut() 只是调用 _client.auth.signOut()（默认 local scope），
      // SDK 在有会话时会发起 /logout 登出请求；若 SDK 行为变化（如不再发
      // 请求/路径变更），断言失败提示而非静默掩盖。会话建立与登出后的
      // signedOut 事件广播是本用例锁定的服务层契约。
      // **核验依据**：已对照 gotrue 2.27.1 源码（gotrue_client.dart 的
      // _signOut：scope != others 时 `await admin.signOut(accessToken, ...)`
      // 发起网络请求）——有会话时 local scope 的 signOut 确实发送 /logout；
      // 该断言作为锁定契约，SDK 升级时如行为变化须同步核验。
      // 先通过 verifyOTP 建立会话（服务端轮换后 signOut 携带 access token
      // 调 /logout；SDK signOut 默认 local scope，但会带上 token 请求登出）。
      final logoutRequests = <http.Request>[];
      // 未匹配路径需"大声失败"（404 暴露额外请求），故直接构造 MockClient
      //（mockAuthClient 的 handler 签名只支持 JSON 对象响应）。
      final client = MockClient((request) async {
        if (request.url.path == '/auth/v1/verify') {
          return http.Response(
            jsonEncode(mockSessionPayload()),
            200,
            headers: {'content-type': 'application/json'},
            request: request,
          );
        }
        if (request.url.path == '/auth/v1/logout') {
          logoutRequests.add(request);
          return http.Response('{}', 200,
              headers: {'content-type': 'application/json'},
              request: request);
        }
        // 未匹配路径：大声失败（404）——若 SDK 在 /verify、/logout 之外新增
        // 请求（会话刷新、userinfo 等），此处会抛错暴露而非静默吞掉。
        return http.Response('Not found', 404, request: request);
      });
      final service = buildService(client);
      final stream = service.authStateStream;
      final events = <String?>[];
      final sub = stream.listen(events.add);
      addTearDown(sub.cancel);
      await pumpEventQueue();
      expect(events, [null], reason: '未登录快照');

      // **Completer 显式等待（r34）**：认证状态广播可能跨多个微任务/存储
      // 通道轮次，pumpEventQueue（默认 20 轮零时长延迟）无法严格保证事件
      // 已到达——与文件内既有 waiter 模式保持一致，防慢速 CI 间歇失败。
      final loginSeen = Completer<void>();
      final loginWaiter = stream.listen((value) {
        if (value == 'session-user-id' && !loginSeen.isCompleted) {
          loginSeen.complete();
        }
      });
      addTearDown(loginWaiter.cancel);
      expect((await service.verifyEmailOtp('a@b.com', '123456')).isSuccess, isTrue);
      await loginSeen.future.timeout(
        const Duration(seconds: 5),
        onTimeout: () => throw TestFailure('等待登录广播事件超时'),
      );
      expect(events.last, 'session-user-id', reason: '登录后 userId 广播');

      final logoutSeen = Completer<void>();
      // **非空快照断言（r38）**：已登录（currentUserId='session-user-id'）时
      // 订阅，晚订阅者**立即收到当前 userId 快照**——显式断言首个事件
      //（防服务层非空态快照补发回归：误补 null/不补发时被只等 null 事件的
      // 条件掩盖）。
      final logoutSnapshot = <String?>[];
      final logoutWaiter = stream.listen((value) {
        if (logoutSnapshot.length < 2) logoutSnapshot.add(value);
        if (value == null && !logoutSeen.isCompleted) {
          logoutSeen.complete();
        }
      });
      addTearDown(logoutWaiter.cancel);
      await pumpEventQueue();
      expect(logoutSnapshot, isNotEmpty,
          reason: '晚订阅者立即收到快照');
      expect(logoutSnapshot.first, 'session-user-id',
          reason: '登录态下晚订阅者快照为当前 userId（非 null）');
      expect((await service.signOut()).isSuccess, isTrue);
      expect(logoutRequests, hasLength(1),
          reason: '有会话时 signOut 必须请求 /logout 端点');
      expect(logoutRequests.single.method, 'POST', reason: '登出为 POST');
      // **Authorization 头锁定（r48）**：注释声称"signOut 携带 access token
      // 调 /logout"，测试须锁定——若 SDK/服务层回归导致登出请求丢失 token/
      // 带错 token，服务端可能拒绝登出或产生不一致会话状态。gotrue 用当前
      // 会话 access_token 附加 Bearer 头（键名可能为小写 'authorization'）。
      final authHeader = logoutRequests.single.headers.entries
          .firstWhere(
            (e) => e.key.toLowerCase() == 'authorization',
            orElse: () => MapEntry('authorization', ''),
          )
          .value;
      expect(authHeader, contains('Bearer access-token'),
          reason: '登出请求必须携带当前会话 access token（Bearer 认证头）');
      await logoutSeen.future.timeout(
        const Duration(seconds: 5),
        onTimeout: () => throw TestFailure('等待登出广播事件超时'),
      );
      expect(events.last, isNull, reason: '登出后广播 null（signedOut 事件）');
    });

    test('服务端 4xx 错误映射：OTP 过期/无效邮箱 → 可读失败（不锁死用户）', () async {
      // gotrue 对 HTTP 4xx/5xx 抛带 statusCode 的 AuthException，服务层映射
      // 为可读失败。OTP 为一次性凭证——若该映射回归（误吞异常/返回错误
      // userId），用户会被锁死或同步到错误账号；显式覆盖三条失败映射。
      // 401 = OTP 无效/过期（verifyEmailOtp）；404 = 邮箱未注册（发码）。
      // **范围说明**：5xx 同样走 AuthException→可读失败分支（与 4xx 同路径，
      // 状态码不参与服务层判定——不单独构造 5xx mock）；本用例聚焦用户
      // 可感知的 4xx 认证语义。
      final client = MockClient((request) async {
        if (request.url.path == '/auth/v1/verify') {
          return http.Response(
            jsonEncode({'message': 'Token has expired or is invalid', 'code': '401'}),
            401,
            headers: {'content-type': 'application/json'},
            request: request,
          );
        }
        if (request.url.path == '/auth/v1/otp') {
          return http.Response(
            jsonEncode({'message': 'User not found', 'code': '404'}),
            404,
            headers: {'content-type': 'application/json'},
            request: request,
          );
        }
        return http.Response('Not found', 404, request: request);
      });
      final service = buildService(client);

      // verifyEmailOtp 401：验证失败（可读，不锁死用户）
      final verify = await service.verifyEmailOtp('a@b.com', '123456');
      expect(verify.isSuccess, isFalse, reason: 'OTP 无效 → 验证失败');
      final verifyMsg = verify.when(onSuccess: (_) => '', onFailure: (m) => m);
      expect(verifyMsg, isNotEmpty, reason: '验证失败携带可读消息');
      // **4xx 不泄露底层异常（r49）**：服务端 4xx 走 AuthException（带
      // statusCode）分支——若该分支回归为 `e.toString()` 透传，isNotEmpty
      // 仍通过、消息泄露 SDK 内部细节；与"网络异常映射"用例一致补类型串
      // 黑名单（不绑定具体文案，防文案润色误失败；异常透出必然命中类型串）。
      expect(
        verifyMsg.contains('AuthException') ||
            verifyMsg.contains('SocketException') ||
            verifyMsg.contains('ClientException') ||
            verifyMsg.contains('TimeoutException'),
        isFalse,
        reason: '验证失败消息不得含底层异常类型串（不泄露内部实现）：$verifyMsg',
      );

      // sendMagicLink 404：发码失败（邮箱未注册等）
      final magic = await service.sendMagicLink('nouser@b.com');
      expect(magic.isSuccess, isFalse, reason: '服务端拒绝发码 → 失败');
      final magicMsg = magic.when(onSuccess: (_) => '', onFailure: (m) => m);
      expect(magicMsg, isNotEmpty, reason: '发码失败携带可读消息');
      expect(
        magicMsg.contains('AuthException') ||
            magicMsg.contains('SocketException') ||
            magicMsg.contains('ClientException') ||
            magicMsg.contains('TimeoutException'),
        isFalse,
        reason: '发码失败消息不得含底层异常类型串（不泄露内部实现）：$magicMsg',
      );
    });

    test('网络异常映射：SocketException/ClientException/Timeout → 可读失败', () async {
      // 覆盖发码/验证两方法统一异常映射（AuthException 之外的真实网络层异常）。
      // 注：signOut 无会话时默认 local scope 不发网络请求（另有用例覆盖），
      // 网络异常路径只针对 sendMagicLink/verifyEmailOtp。
      final socketService = buildService(MockClient(
        (_) async => throw const SocketException('connection refused'),
      ));
      final clientErrorService = buildService(MockClient(
        (_) async => throw http.ClientException('connection closed'),
      ));
      final timeoutService = buildService(MockClient(
        (_) async => throw TimeoutException('timed out'),
      ));

      for (final service in [socketService, clientErrorService, timeoutService]) {
        final magic = await service.sendMagicLink('a@b.com');
        expect(magic.isSuccess, isFalse, reason: '发码网络异常转失败');
        final verify = await service.verifyEmailOtp('a@b.com', '123456');
        expect(verify.isSuccess, isFalse, reason: '验证网络异常转失败');
        // 网络异常统一转为失败：注意 gotrue 会把部分网络错误包装成
        // AuthException（statusCode 为 0 等），落到发码/验证失败分支——
        // 只断言"失败 + 不泄露异常类型"，不绑定具体文案（防 SDK 行为变化脆断）。
        for (final r in [magic, verify]) {
          final message = r.when(onSuccess: (_) => '', onFailure: (m) => m);
          expect(message, isNotEmpty, reason: '失败必须携带可读消息');
          // **防泄露目标独立覆盖（r43 简化）**：不绑定"失败/网络/稍后重试"
          // 关键词（可读文案合理换措辞会误失败）——异常透出必然命中类型串，
          // "非空 + 不含异常类型串"双重约束已覆盖防泄露目标。
          expect(
            message.contains('SocketException') ||
                message.contains('ClientException') ||
                message.contains('TimeoutException') ||
                message.contains('AuthException'),
            isFalse,
            reason: '消息不得含底层异常类型串（不泄露内部实现）：$message',
          );
        }
      }
    });

    test('signOut 有会话时网络异常 → 可读失败（不崩溃/不上抛）', () async {
      // 覆盖 signOut 有会话场景的网络异常路径：先经 verifyOTP 建立会话，
      // 再让 /logout 抛 SocketException——断言失败且消息可读（防该路径
      // 异常处理回归为直接上抛）。
      final service = buildService(MockClient((request) async {
        if (request.url.path == '/auth/v1/verify') {
          return http.Response(
            jsonEncode(mockSessionPayload()),
            200,
            headers: {'content-type': 'application/json'},
            request: request,
          );
        }
        // /logout：网络层失败（gotrue 会包成 AuthException，落到服务层
        // 可读失败分支）。
        throw const SocketException('connection reset');
      }));

      // **广播行为锁定（r47 #8，r49 修正初始快照陷阱）**：SDK 先
      // `_removeSession()` 再发 /logout——网络失败时本地会话已被清除，认证流
      // 实际广播 null（signedOut），而调用方收到的是"登出失败"。无论约定为
      // 广播 null 还是保持原值，均须显式锁定（防后续误改导致 UI 呈现不一致
      // 状态）。用 Completer 显式等待，与文件内既有 waiter 模式一致（防慢速
      // CI 间歇失败）。
      // **初始快照陷阱（r49）**：订阅发生在登录之前——onListen 会对新订阅者
      // 立即补发当前快照（未登录为 null）。若无守卫，首个 `value == null`
      // 来自初始快照、Completer 在登录前就被提前满足，后续断言无条件通过
      //（登出失败路径不再广播 null 也测不出）。须等**登录事件之后**再出现的
      // null 才算登出广播。
      final stream = service.authStateStream;
      final broadcastSeen = Completer<void>();
      var loggedIn = false;
      final sub = stream.listen((value) {
        if (value == 'session-user-id') loggedIn = true;
        if (value == null && loggedIn && !broadcastSeen.isCompleted) {
          broadcastSeen.complete();
        }
      });
      addTearDown(sub.cancel);

      expect((await service.verifyEmailOtp('a@b.com', '123456')).isSuccess, isTrue);
      final result = await service.signOut();
      expect(result.isSuccess, isFalse, reason: '有会话登出遇网络异常转失败');
      final message = result.when(onSuccess: (_) => '', onFailure: (m) => m);
      // 与"网络异常映射"用例策略一致：不绑定具体文案关键词，仅约束
      // "非空 + 不含底层异常类型串"（防文案润色/国际化误失败；异常透出
      // 必然命中类型串）。
      expect(message, isNotEmpty, reason: '失败必须携带可读消息');
      expect(
        message.contains('SocketException') ||
            message.contains('ClientException') ||
            message.contains('TimeoutException') ||
            message.contains('AuthException'),
        isFalse,
        reason: '消息不得含底层异常类型串（不泄露内部实现）：$message',
      );
      // **广播断言**：登出失败后认证流广播 null（SDK 先清本地会话再发请求，
      // 失败不撤销清除）——显式锁定该语义（当前实现行为；若未来 SDK 改变
      // 顺序导致广播保持原值，须同步更新本断言而非静默通过）。
      await broadcastSeen.future.timeout(
        const Duration(seconds: 5),
        onTimeout: () => throw TestFailure('登出失败后未广播 null（signedOut 事件）'),
      );
      // **会话语义说明**：gotrue SDK 的 signOut 先 `_removeSession()` 再发起
      // /logout 网络请求——失败后**本地会话已被 SDK 清除**（服务层无法改变
      // 该顺序）；本用例锁定服务层契约：失败转可读 AppResult 不抛错、不误报
      // 成功。会话清除语义由 SDK 行为决定，不在服务层范围。
    });
  });
}
