import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:timetrack2/api/supabase/cloud_sync_engine.dart';
import 'package:timetrack2/api/supabase/supabase_sync_backend.dart';
import 'package:timetrack2/api/supabase/sync_backend.dart';
import 'package:timetrack2/api/supabase/sync_status_store.dart';
import 'package:timetrack2/constants/build_config.dart';
import 'package:timetrack2/data/database/app_database.dart';
import 'package:timetrack2/data/repositories/action_log_repository.dart';
import 'package:timetrack2/data/repositories/activity_repository.dart';
import 'package:timetrack2/data/repositories/category_repository.dart';
import 'package:timetrack2/data/repositories/settings_repository.dart';
import 'package:timetrack2/data/repositories/tracking_rule_repository.dart';
import 'package:timetrack2/data/repositories/time_entry_repository.dart';

import 'memory_remote.dart';

/// SupabaseSyncBackend 纯逻辑单元测试：URL 合法性判定（根路径约束）——
/// 工厂降级与 double-check 共用的同一判定，配置错误须在前置阶段拦截
///（防错误 URL 延迟到运行时请求才暴露）。
void main() {
  group('isValidSupabaseUrl（根路径约束）', () {
    test('合法：http/https + 根路径（空 path / "/" / 尾斜杠 / 带端口 / 前导空白）', () {
      // 注：http（非 TLS）被判定合法——本地自托管/内网场景需要；公网使用
      // http 时 anon key 会明文传输（中间人可嗅探），安全职责在配置侧
      //（生产应配 https），判定层保持 http 放行（与 supabase 官方 SDK
      // 行为一致）。
      for (final url in [
        'https://example.supabase.co',
        'https://example.supabase.co/',
        'http://example.supabase.co',
        'https://example.supabase.co:8443', // 自托管经反代/直连的非默认端口
        'https://example.supabase.co    ', // 尾随空白容忍（trim）
        '  https://example.supabase.co', // 前导空白容忍（trim）
        'HTTPS://EXAMPLE.SUPABASE.CO', // scheme/host 大小写（Uri 归一化）
        'https://[::1]', // IPv6 字面量
      ]) {
        expect(SupabaseSyncBackend.isValidSupabaseUrl(url), isTrue,
            reason: '应判定合法：$url');
      }
    });

    test('非法：非 http(s) scheme / 相对地址 / 无主机', () {
      for (final url in [
        'ftp://example.supabase.co',
        'not-a-url',
        'https://',
        'example.supabase.co', // 相对（无 scheme）
        '  ', // 空白
        '',
      ]) {
        expect(SupabaseSyncBackend.isValidSupabaseUrl(url), isFalse,
            reason: '应判定非法：$url');
      }
    });

    test('非法：非根路径 / query / fragment / userInfo / 组合边界（拼接端点会生成错误 URL）', () {
      for (final url in [
        'https://example.supabase.co/supabase', // 非根路径
        'https://example.supabase.co?x=1', // query
        'https://example.supabase.co#frag', // fragment
        'https://user:pass@example.supabase.co', // 凭据
        'https://host:8443/api', // 端口 + 子路径（子路径非法）
        'https://host:8443?a=1#f', // query + fragment 组合
        'https://host:0', // 端口 0 无法建连（Uri.port 显式 :0 返回 0）
        // **Uri 解析本身失败**：非法端口/未闭合 IPv6 括号——tryParse
        // 返回 null，判定 false（fail-safe；防未来误改 Uri.parse 抛错）。
        'https://host:abc',
        'https://[::1',
      ]) {
        expect(SupabaseSyncBackend.isValidSupabaseUrl(url), isFalse,
            reason: '应判定非法（基址无法正确拼接端点）：$url');
      }
    });
  });

  group('sessionExpiredMessage 判定矩阵（真实 GoTrue 消息样本）', () {
    test('会话失效消息判为过期（重登提示）', () {
      for (final message in [
        'Refresh Token not found',
        'refresh_token already used',
        'Invalid Refresh Token: Refresh Token Not Found',
        'JWT expired',
        'jwt expired',
        'session expired',
        'user not found',
        'bad jwt',
        'session_not_found',
        // **\t 分隔符变体**：归一化后命中 refresh_token_not_found。
        'Refresh Token\tnot found',
      ]) {
        expect(SupabaseSyncBackend.sessionExpiredMessage(message), isTrue,
            reason: '应判会话失效：$message');
      }
    });

    test('非会话失效消息不误判（不收窄误伤）', () {
      for (final message in [
        // "本设备会话已被登出"：明确非过期（消息不含失效关键词），走
        // "登录状态异常"分支仍提示重新登录——语义合理，不误判为"过期"。
        'Session from this device has been signed out',
        'password reset token has expired', // 密码重置令牌过期，非会话失效
        'Email link is invalid or has expired', // 邮件链接过期
        'Token has expired or is invalid', // 含 token+expired 但无 session/refresh 语境
        // **网络故障消息（收窄）**：含 refresh token 字样但非会话失效——
        // 归一化后命中的是裸 refresh_token 子串，须判非会话失效（防网络
        // 抖动被误判为会话失效强制重登、锁死体验）。
        'Failed to refresh token: Network is unreachable',
        'Cannot refresh token due to connection error',
        // 边界输入：空串/纯空白必须稳定返回 false（AuthException 可能携带
        // 空 message——依赖 replaceAll/lowercase 不崩溃是巧合，须锁定）。
        '',
        '   ',
        '\t',
        // **分隔符变体**：\n 等非空格分隔符——归一化依赖
        // `[^a-z0-9]+` 覆盖所有非字母数字；若未来收窄为仅空格会漏命中。
        'Failed to refresh token:\nNetwork is unreachable', // 多行网络故障不命中
      ]) {
        expect(SupabaseSyncBackend.sessionExpiredMessage(message), isFalse,
            reason: '不应误判会话失效：$message');
      }
    });

    test('大小写混排 + 分隔符混合仍正确判定（归一化稳健）', () {
      // 分隔符（空格/连字符）混合 + 大小写混排：归一化后仍命中白名单。
      expect(
        SupabaseSyncBackend.sessionExpiredMessage('Refresh Token NOT FOUND'),
        isTrue,
        reason: '大小写 + 空格分隔命中 refresh_token',
      );
      expect(
        SupabaseSyncBackend.sessionExpiredMessage('Invalid-Grant: bad grant'),
        isTrue,
        reason: '连字符分隔命中 invalid_grant',
      );
      expect(
        SupabaseSyncBackend.sessionExpiredMessage('Session-Expired'),
        isTrue,
        reason: '连字符 + expired 命中 session 上下文',
      );
    });
  });

  group('isSessionExpiredCode 判定矩阵（与 message 矩阵对称）', () {
    test('命中白名单的 code 判会话失效', () {
      for (final code in [
        'refresh_token_not_found',
        'invalid_grant',
        'session_not_found',
        'user_not_found',
        'bad_jwt',
        'token_expired',
        'refresh_token_already_used',
        'invalid_refresh_token',
      ]) {
        expect(SupabaseSyncBackend.isSessionExpiredCode(code), isTrue,
            reason: '应判会话失效：$code');
      }
    });

    test('未命中白名单的 code 不误判（收窄——不含宽泛 token/invalid 子串）', () {
      for (final code in [
        'rate_limit_exceeded',
        'over_request_rate_limit', // 含 rate 但非失效
        'invalid_signup_data', // 含 invalid 子串但非会话失效
        'network_error',
        'unknown_code',
        // **收窄**：裸 refresh_token 子串不再命中——网络故障类错误码
        //（非失效语境）不得误判为会话失效强制重登。
        'refresh_token_network_error',
        'refresh_token_fetch_failed',
        'refresh_token',
      ]) {
        expect(SupabaseSyncBackend.isSessionExpiredCode(code), isFalse,
            reason: '不应误判会话失效：$code');
      }
    });
  });

  group('createSupabaseSyncBackend 工厂', () {
    /// 最小 CloudSyncEngine（不执行查询，仅满足工厂签名——未配置路径不触达
    /// engine，见下）。
    CloudSyncEngine dummyEngine(AppDatabase db) {
      final activities = ActivityRepository(database: db);
      final categories = CategoryRepository(database: db);
      final settings = SettingsRepository(database: db);
      final actionLogs = ActionLogRepository(database: db);
      final entries = TimeEntryRepository(
        database: db,
        activityRepository: activities,
        settingsRepository: settings,
      );
      return CloudSyncEngine(
        database: db,
        gateway: MemoryRemote(),
        statusStore: SyncStatusStore(database: db),
        activities: activities,
        categories: categories,
        timeEntries: entries,
        actionLogs: actionLogs,
        settings: settings,
        trackingRules: TrackingRuleRepository(database: db),
      );
    }

    test('NoopSyncBackend 行为契约（确定性构造，不依赖 dart-define）', () async {
      // Noop 的"一切同步操作返回 unconfiguredError"契约抽成确定性用例——
      // 直接构造 NoopSyncBackend()（不依赖工厂/环境，CI 注入配置时仍执行，
      // 防关键契约随环境漂移而失去守护）。**覆盖全部接口方法**：
      // sendMagicLink / verifyEmailOtp / syncNow / signOut 均须精确返回
      // unconfiguredError；authStateStream 回放 null。
      final backend = NoopSyncBackend();
      expect(backend.isConfigured, isFalse);
      // 四个操作方法统一精确断言失败消息 = 共享常量 + 结构化错误码
      for (final result in [
        await backend.sendMagicLink('a@b.com'),
        await backend.verifyEmailOtp('a@b.com', '123456'),
        await backend.syncNow(),
        await backend.signOut(),
      ]) {
        expect(result.isSuccess, isFalse, reason: '未配置操作失败');
        expect(
          result.when(onSuccess: (_) => '', onFailure: (m) => m),
          SyncBackend.unconfiguredError,
          reason: '失败消息精确等于共享未配置常量（不绑定文案子串）',
        );
        // **结构化错误码（r52）**：判定"未配置"用 code（文案调整/本地化不
        // 影响结构化判定）——锁定 unconfiguredCode 契约。
        expect(
          result.fold(
            onSuccess: (_) => null,
            onFailure: (f) => f.code,
          ),
          SyncBackend.unconfiguredCode,
          reason: '未配置失败必须携带 unconfiguredCode（结构化区分）',
        );
      }
      // authStateStream：订阅即回放 null（未登录）。
      final events = <String?>[];
      final sub = backend.authStateStream.listen(events.add);
      addTearDown(sub.cancel);
      await pumpEventQueue();
      expect(events, [null], reason: '未配置登录态流回放 null');
      // currentUserId：未配置恒 null（不触达懒加载认证——覆盖接口契约
      // 全字段，防 future 构造路径扩展时遗漏）。
      expect(backend.currentUserId, isNull,
          reason: '未配置 → currentUserId 为 null（无登录会话）');
    });

    test('NoopSyncBackend：新订阅者加入不向已有订阅者重复补发快照（负向契约）', () async {
      // **归属说明（r47 #5 迁移）**：本用例原在 sync_status_store_test.dart——
      // 它是 Noop 后端的**流契约**测试，与 SyncStatusStore 的 app_metadata
      // 读写职责无关；Noop 后端行为测试全部集中在本文件，迁来相邻维护。
      final backend = NoopSyncBackend();
      final stream = backend.authStateStream;
      final firstEvents = <String?>[];
      final sub1 = stream.listen(firstEvents.add);
      addTearDown(sub1.cancel); // 防断言失败时订阅泄漏
      await pumpEventQueue(); // 等事件队列排空（Stream.multi 微任务投递）
      expect(firstEvents, [null], reason: '首个订阅者立即收到快照 null');

      // 新订阅者加入：各自收到一次快照；**已存在订阅者不重复收到**（broadcast
      // 不重放，Stream.multi 仅对新订阅者执行 onListen 补发）——该契约是
      // 后续云实现替换时状态初始化关键路径，防重复补发导致 UI 重复初始化。
      final secondEvents = <String?>[];
      final sub2 = stream.listen(secondEvents.add);
      addTearDown(sub2.cancel);
      await pumpEventQueue();
      expect(secondEvents, [null], reason: '新订阅者收到快照');
      expect(firstEvents, [null],
          reason: '新订阅者加入不得向已存在订阅者重复补发快照');
      // 订阅清理统一由 addTearDown 兜底（含断言失败路径），无需末尾重复 cancel。
    });

    test('未配置（测试环境无 dart-define）→ 工厂返回 NoopSyncBackend', () async {
      // **环境前提**：本用例依赖测试进程**未注入** SUPABASE_URL/
      // SUPABASE_ANON_KEY 两个 dart-define（AppBuildConfig 经
      // String.fromEnvironment 读取，编译期常量无法运行时 mock）——一旦
      // CI/本地注入合法配置，工厂走配置路径，本用例跳过（Noop 行为契约
      // 已由上方确定性用例独立守护，环境分支仅验证工厂编排）。
      // 注：markTestSkipped 抛 SkipException 终止测试，其后代码不执行
      //（无需 return）。
      if (AppBuildConfig.isSupabaseConfigured()) {
        markTestSkipped(
          '测试进程注入了 SUPABASE 配置，本用例验证"未配置降级"路径，跳过',
        );
      }
      final db = AppDatabase(NativeDatabase.memory());
      try {
        final backend = createSupabaseSyncBackend(
          engine: dummyEngine(db),
          syncTimeout: const Duration(milliseconds: 1),
        );
        expect(backend, isA<NoopSyncBackend>(),
            reason: '未配置 → Noop（应用完全本地可用）');
        expect(backend.isConfigured, isFalse);
      } finally {
        await db.close();
      }
    });

    test('syncTimeout 默认值 = 2 分钟（注入路径由编译期签名锁定）', () {
      expect(SupabaseSyncBackend.defaultSyncTimeout, const Duration(minutes: 2),
          reason: '默认网络段超时 2 分钟');
      // 工厂签名接受 syncTimeout 并透传私有构造——注入路径由编译期签名锁定
      //（配置环境下运行时透传属网络路径，测试环境未配置不触达；语义由
      // 代码评审 + 本文件工厂降级用例覆盖）。
      //
      // **覆盖说明（已知边界）**：reset 保留在途引用的 epoch 丢弃语义、
      // token 刷新/engine 同步超时分支、isSessionExpiredCode/
      // sessionExpiredMessage 判定——这些逻辑依赖**已配置 + 已登录 + 真
      // 会话**的环境（工厂在测试环境未配置时降级 Noop，无法触达）；当前以
      // 代码评审 + 单元级纯函数测试（URL 判定、message 归一化回归）覆盖，
      // 完整路径测试归阶段 3 编排集成测试。
    });

    test('buildBackend 决策（可注入配置值，不依赖 dart-define）：配置分支可单测', () async {
      // 核心决策已抽取为可注入静态方法——URL 合法 → 真后端 + syncTimeout
      // 透传、URL 非法 → Noop 降级、syncTimeout 非法 → 回退默认，均在
      // 普通 flutter test 下确定性构造（不再依赖 String.fromEnvironment）。
      final db = AppDatabase(NativeDatabase.memory());
      try {
        final engine = dummyEngine(db);
        // 1) 未配置 → Noop
        final unconfigured = SupabaseSyncBackend.buildBackend(
          isConfigured: false,
          url: 'https://example.supabase.co',
          engine: engine,
        );
        expect(unconfigured, isA<NoopSyncBackend>(),
            reason: '未配置 → Noop');

        // 2) 已配置 + URL 非法 → Noop 降级
        final invalidUrl = SupabaseSyncBackend.buildBackend(
          isConfigured: true,
          url: 'https://example.supabase.co/api', // 非根路径
          engine: engine,
        );
        expect(invalidUrl, isA<NoopSyncBackend>(),
            reason: 'URL 非法 → Noop 降级');

        // 2b) 含凭据 URL（user:pass@host 同时违反 userInfo 与根路径约束）
        // → Noop 降级，且降级日志脱敏（sanitizedUrlForLog 只输出 scheme://host
        // ——用户/密码绝不入日志；此处直接锁定脱敏函数输出）。
        final credentialUrl = SupabaseSyncBackend.buildBackend(
          isConfigured: true,
          url: 'https://user:password@example.supabase.co',
          engine: engine,
        );
        expect(credentialUrl, isA<NoopSyncBackend>(),
            reason: '含凭据 URL → Noop 降级');
        expect(
          SupabaseSyncBackend.sanitizedUrlForLog(
            'https://user:password@example.supabase.co',
          ),
          'https://example.supabase.co',
          reason: '脱敏只输出 scheme://host（凭据不泄露）',
        );

        // 3) 已配置 + URL 合法 → 真后端（syncTimeout 透传）
        final valid = SupabaseSyncBackend.buildBackend(
          isConfigured: true,
          url: 'https://example.supabase.co',
          engine: engine,
          syncTimeout: const Duration(seconds: 30),
        );
        expect(valid, isA<SupabaseSyncBackend>(),
            reason: 'URL 合法 → 真后端');
        expect(valid.isConfigured, isTrue);
        // 实际生效值断言（非仅"不抛异常"弱契约）：注入值必须透传到实例。
        expect(
          (valid as SupabaseSyncBackend).syncTimeout,
          const Duration(seconds: 30),
          reason: 'syncTimeout 注入值应透传',
        );

        // 3b) **省略 syncTimeout 默认路径**：签名默认绑定
        // defaultSyncTimeout——防未来误改为其他时长时配置静默漂移。
        final defaulted = SupabaseSyncBackend.buildBackend(
          isConfigured: true,
          url: 'https://example.supabase.co',
          engine: engine,
        );
        expect(
          (defaulted as SupabaseSyncBackend).syncTimeout,
          SupabaseSyncBackend.defaultSyncTimeout,
          reason: '省略 syncTimeout 时使用默认值',
        );

        // 4) 非法 syncTimeout（零/负）→ 回退默认（不抛异常，契约保持）
        // **零与负值都覆盖**（实现以 `<= Duration.zero` 判定——防后续改成
        // `== Duration.zero` 之类判定时负值分支回归漏测）。
        for (final bad in [Duration.zero, const Duration(milliseconds: -1)]) {
          final badTimeout = SupabaseSyncBackend.buildBackend(
            isConfigured: true,
            url: 'https://example.supabase.co',
            engine: engine,
            syncTimeout: bad,
          );
          expect(badTimeout, isA<SupabaseSyncBackend>(),
              reason: '非法 syncTimeout($bad) 回退默认而非抛错');
          // 回退后的实际生效值 = 默认（防回退逻辑出错时测试仍通过）。
          expect(
            (badTimeout as SupabaseSyncBackend).syncTimeout,
            SupabaseSyncBackend.defaultSyncTimeout,
            reason: '非法 syncTimeout($bad) 回退为默认值',
          );
        }

        // 5) sanitizedUrlForLog 边界（防脱敏回归引入凭据泄露/误导日志）：
        // 带端口（userInfo/query/fragment 剥离；**非默认端口保留**——排障
        // 可诊断性，端口不含凭据）、畸形 URL（无 scheme → unparseable）。
        expect(
          SupabaseSyncBackend.sanitizedUrlForLog(
            'https://user:pass@host:8443/api?x=1#f',
          ),
          'https://host:8443',
          reason: 'userInfo/query/fragment 剥离、非默认端口保留',
        );
        expect(
          SupabaseSyncBackend.sanitizedUrlForLog(
            'https://user:pass@example.supabase.co',
          ),
          'https://example.supabase.co',
          reason: '默认端口（443）不显式输出',
        );
        // IPv6 字面量：方括号重包装 + 非默认端口保留（Uri.host 返回裸 ::1）。
        expect(
          SupabaseSyncBackend.sanitizedUrlForLog(
            'https://user:pass@[::1]:8443',
          ),
          'https://[::1]:8443',
          reason: 'IPv6 host 补方括号 + 非默认端口保留',
        );
        expect(
          SupabaseSyncBackend.sanitizedUrlForLog('https://[::1]'),
          'https://[::1]',
          reason: 'IPv6 默认端口不显式输出',
        );
        expect(
          SupabaseSyncBackend.sanitizedUrlForLog('//host/path'),
          '<unparseable>',
          reason: '无 scheme → unparseable（防误导性 ://host）',
        );
        expect(
          SupabaseSyncBackend.sanitizedUrlForLog('not a url'),
          '<unparseable>',
        );
        // **畸形输入边界**：空串/纯空白/仅 scheme（无 host）均回退
        // unparseable——防未来改动兜底分支（如直接输出 scheme://）产生
        // 误导性日志而测试无法捕获。
        for (final malformed in ['', '   ', 'https:', 'https://']) {
          expect(
            SupabaseSyncBackend.sanitizedUrlForLog(malformed),
            '<unparseable>',
            reason: '畸形输入回退 unparseable：$malformed',
          );
        }
      } finally {
        await db.close();
      }
    });
  });
}
