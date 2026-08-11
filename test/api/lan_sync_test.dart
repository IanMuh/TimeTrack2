import 'dart:convert';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:timetrack2/api/lan/lan_sync_client.dart';
import 'package:timetrack2/api/lan/lan_sync_server.dart';
import 'package:timetrack2/constants/app_constants.dart';
import 'package:timetrack2/data/database/app_database.dart';
import 'package:timetrack2/data/repositories/action_log_repository.dart';
import 'package:timetrack2/data/repositories/activity_repository.dart';
import 'package:timetrack2/data/repositories/category_repository.dart';
import 'package:timetrack2/data/repositories/settings_repository.dart';
import 'package:timetrack2/data/repositories/sync_peer_store.dart';
import 'package:timetrack2/data/repositories/time_entry_repository.dart';
import 'package:timetrack2/data/sync/sync_bundle_codec.dart';
import 'package:timetrack2/data/sync/sync_bundle_repository.dart';
import 'package:timetrack2/utils/result.dart';

/// 单侧 LAN 测试环境（一个主机 + 一个客户端，各自独立内存库）。
class LanHarness {
  LanHarness._(
    this.db,
    this.activities,
    this.categories,
    this.settings,
    this.actionLogs,
    this.entries,
    this.syncBundle,
    this.peerStore,
  );

  static Future<LanHarness> create() async {
    final db = AppDatabase(NativeDatabase.memory());
    final activities = ActivityRepository(database: db);
    final categories = CategoryRepository(database: db);
    final settings = SettingsRepository(database: db);
    final actionLogs = ActionLogRepository(database: db);
    final entries = TimeEntryRepository(
      database: db,
      activityRepository: activities,
      settingsRepository: settings,
    );
    final syncBundle = SyncBundleRepository(
      database: db,
      activities: activities,
      categories: categories,
      timeEntries: entries,
      actionLogs: actionLogs,
      settings: settings,
    );
    final peerStore = SyncPeerStore(database: db);
    return LanHarness._(
      db,
      activities,
      categories,
      settings,
      actionLogs,
      entries,
      syncBundle,
      peerStore,
    );
  }

  final AppDatabase db;
  final ActivityRepository activities;
  final CategoryRepository categories;
  final SettingsRepository settings;
  final ActionLogRepository actionLogs;
  final TimeEntryRepository entries;
  final SyncBundleRepository syncBundle;
  final SyncPeerStore peerStore;

  Future<void> close() => db.close();
}

/// 组装完整 LAN 环境：主机 harness + 服务器（loopback 随机端口）+ 客户端。
Future<
    ({
      LanHarness host,
      LanHarness clientSide,
      LanSyncServer server,
      LanSyncClient client,
      int port,
    })> _setup({DateTime Function()? clock}) async {
  final host = await LanHarness.create();
  final clientSide = await LanHarness.create();
  final server = LanSyncServer(
    bundleRepository: host.syncBundle,
    peerStore: host.peerStore,
    sourceDeviceId: 'host-dev',
    bindAddress: InternetAddress.loopbackIPv4,
    clock: clock,
  );
  final started = await server.start(preferredPort: 0);
  if (started case AppFailure<int> failure) {
    await host.close();
    await clientSide.close();
    fail('服务器启动失败：${failure.message}');
  }
  final client = LanSyncClient(
    bundleRepository: clientSide.syncBundle,
    peerStore: clientSide.peerStore,
    deviceId: 'client-dev',
    deviceName: '客户端电脑',
  );
  return (
    host: host,
    clientSide: clientSide,
    server: server,
    client: client,
    port: server.boundPort!,
  );
}

/// 原始 HTTP 请求（测试绕过 LanSyncClient 直接验证协议层）。
Future<HttpClientResponse> _rawRequest(
  HttpClient client,
  String method,
  int port,
  String path, {
  String? body,
  String? token,
}) async {
  final request = await client.openUrl(method, Uri.parse('http://127.0.0.1:$port$path'));
  request.headers.contentType = ContentType.json;
  if (token != null) {
    request.headers.set('Authorization', 'Bearer $token');
  }
  if (body != null) request.write(body);
  return request.close();
}

void main() {
  group('LAN 协议与服务器（真 HttpServer）', () {
    test('/health 返回主机信息（含 device_id）', () async {
      final t = await _setup();
      try {
        final health = await t.client.healthCheck(host: '127.0.0.1', port: t.port);
        expect(health.isSuccess, isTrue);

        final raw = HttpClient();
        try {
          final response =
              await _rawRequest(raw, 'GET', t.port, '/health');
          expect(response.statusCode, HttpStatus.ok);
          final body =
              jsonDecode(await response.transform(utf8.decoder).join())
                  as Map<String, Object?>;
          expect(body['ok'], isTrue);
          expect(body['device_id'], 'host-dev');
          expect(body['name'], 'TimeTrack');
        } finally {
          raw.close();
        }
      } finally {
        await t.server.stop();
        await t.host.close();
        await t.clientSide.close();
      }
    });

    test('配对成功：返回 token、双方对端落库（authorized id=客户端 device_id）',
        () async {
      final t = await _setup();
      try {
        final code = t.server.generatePairingCode(deviceId: 'client-dev');
        final paired = await t.client.pair(
          host: '127.0.0.1',
          port: t.port,
          pairingCode: code,
        );
        expect(paired.isSuccess, isTrue, reason: '配对 + 自动同步应成功');
        final peer = paired.requireValue();
        expect(peer.kind, SyncPeerKind.lanClient);
        expect(peer.baseUrl, 'http://127.0.0.1:${t.port}');

        final clientPeer = (await t.clientSide.peerStore.currentLanClientPeer())
            .requireValue();
        expect(clientPeer, isNotNull);
        expect(clientPeer!.token, peer.token);

        final authorized = (await t.host.peerStore.authorizedClients())
            .requireValue();
        expect(authorized, hasLength(1));
        expect(authorized.single.id, 'client-dev',
            reason: 'authorized 对端 id 用客户端 device_id（重复配对可轮换 token）');
        expect(authorized.single.token, peer.token);
      } finally {
        await t.server.stop();
        await t.host.close();
        await t.clientSide.close();
      }
    });

    test('配对码错误 → 失败（invalidCode），对端不落库', () async {
      final t = await _setup();
      try {
        final code = t.server.generatePairingCode(deviceId: 'client-dev');
        final wrong = await t.client.pair(
          host: '127.0.0.1',
          port: t.port,
          pairingCode: code == '123456' ? '654321' : '123456',
        );
        expect(wrong.isSuccess, isFalse);
        expect(
          wrong.when(onSuccess: (_) => '', onFailure: (m) => m),
          contains('配对码无效'),
        );
        expect((await t.host.peerStore.authorizedClients()).requireValue(), isEmpty);
        expect((await t.clientSide.peerStore.currentLanClientPeer()).requireValue(),
            isNull, reason: '配对失败不落客户端对端');
      } finally {
        await t.server.stop();
        await t.host.close();
        await t.clientSide.close();
      }
    });

    test('配对码过期 → 失败（codeExpired）', () async {
      var now = DateTime(2026, 8, 11, 10, 0, 0);
      final t = await _setup(clock: () => now);
      try {
        // 过期时间从常量推导（TTL + 1 分钟缓冲），避免与 lanPairingCodeTtl 耦合；
        // 本用例正确性依赖所有过期判定路径都走注入的 clock（服务器 _handlePair/
        // _pruneExpiredCodes 均用 _clock()，无 DateTime.now() 混用）。
        final code = t.server.generatePairingCode(deviceId: 'client-dev'); // t0 生成
        now = now.add(AppConstants.lanPairingCodeTtl + const Duration(minutes: 1));
        final expired = await t.client.pair(
          host: '127.0.0.1',
          port: t.port,
          pairingCode: code,
        );
        expect(expired.isSuccess, isFalse);
        expect(
          expired.when(onSuccess: (_) => '', onFailure: (m) => m),
          contains('已过期'),
        );
        expect((await t.host.peerStore.authorizedClients()).requireValue(), isEmpty);
      } finally {
        await t.server.stop();
        await t.host.close();
        await t.clientSide.close();
      }
    });

    test('配对码单次使用：同码第二次配对失败', () async {
      final t = await _setup();
      try {
        final code = t.server.generatePairingCode(deviceId: 'client-dev');
        final first = await t.client.pair(
          host: '127.0.0.1',
          port: t.port,
          pairingCode: code,
        );
        expect(first.isSuccess, isTrue);
        final second = await t.client.pair(
          host: '127.0.0.1',
          port: t.port,
          pairingCode: code,
        );
        expect(second.isSuccess, isFalse, reason: '配对码取出即消耗');
        expect(
          second.when(onSuccess: (_) => '', onFailure: (m) => m),
          contains('配对码无效'),
        );
      } finally {
        await t.server.stop();
        await t.host.close();
        await t.clientSide.close();
      }
    });

    test('每 IP 限流：前 N 次放行、第 N+1 次 429（N = 常量阈值）', () async {
      final t = await _setup();
      try {
        final raw = HttpClient();
        try {
          // 阈值从常量读取，避免与实现细节强耦合；限流状态按服务器实例隔离
          //（每个 _setup() 新建独立服务器，后续配对用例不受本次打满配额影响）。
          final limit = AppConstants.lanRateLimitPerMinute;
          final statuses = <int>[];
          for (var i = 0; i < limit + 1; i++) {
            final response =
                await _rawRequest(raw, 'POST', t.port, '/pair', body: '{}');
            statuses.add(response.statusCode);
            await response.drain<void>();
          }
          expect(statuses.sublist(0, limit),
              everyElement(isNot(HttpStatus.tooManyRequests)),
              reason: '前 $limit 次应放行（400 缺字段）而非被限流');
          expect(statuses.last, HttpStatus.tooManyRequests,
              reason: '第 ${limit + 1} 次应被限流');
        } finally {
          raw.close();
        }
      } finally {
        await t.server.stop();
        await t.host.close();
        await t.clientSide.close();
      }
    });

    test('/sync 未授权 → 401（缺 token / token 无效）', () async {
      final t = await _setup();
      try {
        final raw = HttpClient();
        try {
          final missing = await _rawRequest(
              raw, 'POST', t.port, '/sync', body: '{}');
          expect(missing.statusCode, HttpStatus.unauthorized);
          await missing.drain<void>();

          final invalid = await _rawRequest(
              raw, 'POST', t.port, '/sync', body: '{}', token: 'bogus-token');
          expect(invalid.statusCode, HttpStatus.unauthorized);
          await invalid.drain<void>();
        } finally {
          raw.close();
        }
      } finally {
        await t.server.stop();
        await t.host.close();
        await t.clientSide.close();
      }
    });

    test('请求体超限 → 413 且不处理', () async {
      final t = await _setup();
      try {
        // 直接起一个小上限的服务器：放行配对后，超大请求体应被 413 拒绝。
        final oversized = LanSyncServer(
          bundleRepository: t.host.syncBundle,
          peerStore: t.host.peerStore,
          sourceDeviceId: 'host-dev',
          bindAddress: InternetAddress.loopbackIPv4,
          maxPayloadBytes: 1024, // 极小上限
        );
        final started = await oversized.start(preferredPort: 0);
        expect(started.isSuccess, isTrue);
        try {
          final raw = HttpClient();
          try {
            final bigBody = '{"padding":"${'x' * 4096}"}';
            final response = await _rawRequest(
                raw, 'POST', oversized.boundPort!, '/pair',
                body: bigBody);
            expect(response.statusCode, HttpStatus.requestEntityTooLarge,
                reason: '超过 maxPayloadBytes 的请求体应被 413 拒绝');
            final body =
                jsonDecode(await response.transform(utf8.decoder).join())
                    as Map<String, Object?>;
            expect(body['ok'], isFalse);
            expect(
              (body['error'] as Map<String, Object?>)['code'],
              'payload_too_large',
            );
          } finally {
            raw.close();
          }
          expect((await t.host.peerStore.authorizedClients()).requireValue(),
              isEmpty, reason: '413 请求不产生配对副作用');
        } finally {
          await oversized.stop();
        }
      } finally {
        await t.server.stop();
        await t.host.close();
        await t.clientSide.close();
      }
    });

    test('/sync 设备身份校验：bundle source_device_id ≠ token 对端 → 403，不合并', () async {
      final t = await _setup();
      try {
        // 正常配对，拿到授权 token。
        final code = t.server.generatePairingCode(deviceId: 'client-dev');
        final paired = await t.client.pair(
          host: '127.0.0.1',
          port: t.port,
          pairingCode: code,
        );
        expect(paired.isSuccess, isTrue);
        final token = paired.requireValue().token;

        // 用合法 token 但伪造 source_device_id 的 bundle → 403 且服务器不合并。
        final forged = await t.clientSide.syncBundle.exportBundle(
          sourceDeviceId: 'other-device', // 与 token 对端 (client-dev) 不一致
        );
        final beforeIds = (await t.host.activities.activities())
            .requireValue()
            .map((a) => a.id)
            .toSet();
        final raw = HttpClient();
        try {
          final response = await _rawRequest(raw, 'POST', t.port, '/sync',
              body: const SyncBundleCodec().encode(forged),
              token: token);
          expect(response.statusCode, HttpStatus.forbidden,
              reason: '伪造 source_device_id 应被拒绝');
          final body =
              jsonDecode(await response.transform(utf8.decoder).join())
                  as Map<String, Object?>;
          expect(body['ok'], isFalse);
          expect(
            (body['error'] as Map<String, Object?>)['code'],
            'invalid_request',
          );
        } finally {
          raw.close();
        }
        final afterIds = (await t.host.activities.activities())
            .requireValue()
            .map((a) => a.id)
            .toSet();
        expect(afterIds, beforeIds, reason: '被拒请求不写入任何数据');
      } finally {
        await t.server.stop();
        await t.host.close();
        await t.clientSide.close();
      }
    });

    test('重复配对同一设备 → token 轮换且旧 token 立即失效', () async {
      final t = await _setup();
      try {
        final code1 = t.server.generatePairingCode(deviceId: 'client-dev');
        final first = await t.client.pair(
          host: '127.0.0.1',
          port: t.port,
          pairingCode: code1,
        );
        final firstToken = first.requireValue().token;

        final code2 = t.server.generatePairingCode(deviceId: 'client-dev');
        final second = await t.client.pair(
          host: '127.0.0.1',
          port: t.port,
          pairingCode: code2,
        );
        expect(second.isSuccess, isTrue);
        expect(second.requireValue().token, isNot(firstToken),
            reason: '重复配对必须轮换 token');

        final authorized = (await t.host.peerStore.authorizedClients())
            .requireValue();
        expect(authorized, hasLength(1), reason: '同一设备重复配对覆盖同一行');
        expect(authorized.single.token, second.requireValue().token);

        // 客户端侧对端表：currentLanClientPeer 必须持有新 token，且**任何一行**
        // 都不携带已失效旧 token（枚举全部 lanClient 行，防清理失败时旧行残留
        // 被 currentLanClientPeer 的"取最新"掩盖）。
        final clientPeer = (await t.clientSide.peerStore.currentLanClientPeer())
            .requireValue();
        expect(clientPeer, isNotNull);
        expect(clientPeer!.token, second.requireValue().token,
            reason: '重复配对后客户端取到的对端必须是新 token');
        final staleRows = await (t.clientSide.db.select(t.clientSide.db.syncPeers)
              ..where((r) => r.token.equals(firstToken)))
            .get();
        expect(staleRows, isEmpty,
            reason: '客户端侧不存在携带旧 token 的对端行');

        final raw = HttpClient();
        try {
          final stale = await _rawRequest(raw, 'POST', t.port, '/sync',
              body: '{}', token: firstToken);
          expect(stale.statusCode, HttpStatus.unauthorized,
              reason: '轮换后旧 token 立即失效');
          await stale.drain<void>();
        } finally {
          raw.close();
        }
      } finally {
        await t.server.stop();
        await t.host.close();
        await t.clientSide.close();
      }
    });

    test('配对码绑定设备身份：声明不一致 → 拒绝（防冒用轮换 token）', () async {
      final t = await _setup();
      try {
        // 配码生成时绑定目标设备 id；客户端自报 device_id 不匹配 → 拒绝。
        final code = t.server.generatePairingCode(deviceId: 'expected-device');
        final mismatch = await t.client.pair(
          host: '127.0.0.1',
          port: t.port,
          pairingCode: code,
        );
        expect(mismatch.isSuccess, isFalse);
        expect(
          mismatch.when(onSuccess: (_) => '', onFailure: (m) => m),
          contains('不匹配'),
        );
        expect((await t.host.peerStore.authorizedClients()).requireValue(), isEmpty,
            reason: '身份不匹配不落对端、不轮换任何 token');

        // 一致则成功
        final code2 = t.server.generatePairingCode(deviceId: 'client-dev');
        final matched = await t.client.pair(
          host: '127.0.0.1',
          port: t.port,
          pairingCode: code2,
        );
        expect(matched.isSuccess, isTrue, reason: '设备身份一致时配对成功');
      } finally {
        await t.server.stop();
        await t.host.close();
        await t.clientSide.close();
      }
    });
  });

  group('LAN 客户端', () {
    test('未配对 syncNow → 失败提示', () async {
      final t = await _setup();
      try {
        final result = await t.client.syncNow();
        expect(result.isSuccess, isFalse);
        expect(
          result.when(onSuccess: (_) => '', onFailure: (m) => m),
          contains('未配对'),
        );
      } finally {
        await t.server.stop();
        await t.host.close();
        await t.clientSide.close();
      }
    });

    test('拒绝非私网主机（公网 IP / 非 .local 域名）', () async {
      final t = await _setup();
      try {
        final public = await t.client.pair(
          host: '8.8.8.8',
          port: 80,
          pairingCode: '123456',
        );
        expect(public.isSuccess, isFalse);
        expect(
          public.when(onSuccess: (_) => '', onFailure: (m) => m),
          contains('私网'),
        );
        final hostname = await t.client.pair(
          host: 'example.com',
          port: 80,
          pairingCode: '123456',
        );
        expect(hostname.isSuccess, isFalse);
        expect(
            (await t.clientSide.peerStore.currentLanClientPeer()).requireValue(),
            isNull, reason: '白名单拒绝不落对端');
      } finally {
        await t.server.stop();
        await t.host.close();
        await t.clientSide.close();
      }
    });

    test('拒绝非法端口', () async {
      final t = await _setup();
      try {
        final result = await t.client.pair(
          host: '192.168.1.5',
          port: 70000,
          pairingCode: '123456',
        );
        expect(result.isSuccess, isFalse);
        expect(
          result.when(onSuccess: (_) => '', onFailure: (m) => m),
          contains('端口'),
        );
      } finally {
        await t.server.stop();
        await t.host.close();
        await t.clientSide.close();
      }
    });

    test('双向收敛：配对后主机/客户端数据互相到达，重复同步幂等', () async {
      final t = await _setup();
      try {
        // 主机：活动 + 条目；客户端：活动
        final hostActivity = (await t.host.activities.createActivity(
          name: '主机活动',
          color: 0xff2563eb,
        ))
            .requireValue();
        await t.host.entries.createManualEntry(
          activityId: hostActivity.id,
          startAt: DateTime(2026, 8, 11, 9),
          endAt: DateTime(2026, 8, 11, 10),
          note: '主机条目',
        );
        final clientActivity = (await t.clientSide.activities.createActivity(
          name: '客户端活动',
          color: 0xff059669,
        ))
            .requireValue();

        final code = t.server.generatePairingCode(deviceId: 'client-dev');
        final paired = await t.client.pair(
          host: '127.0.0.1',
          port: t.port,
          pairingCode: code,
        );
        expect(paired.isSuccess, isTrue, reason: '配对 + 自动一次同步应成功');

        // 客户端拿到主机活动与条目（拉取）
        final clientActivities =
            (await t.clientSide.activities.activities()).requireValue();
        expect(clientActivities.map((a) => a.id), contains(hostActivity.id));
        final clientEntries =
            await t.clientSide.entries.entriesForDay(DateTime(2026, 8, 11));
        expect(clientEntries.single.note, '主机条目');

        // 主机拿到客户端活动（/sync 合并了客户端 bundle → 推拉双向）
        final hostActivities = (await t.host.activities.activities()).requireValue();
        expect(hostActivities.map((a) => a.id), contains(clientActivity.id));

        // 再次同步幂等：不重复、不丢失（精确集合 + 数量断言，防重复插入漏检；
        // 排除未分配单例——那是合并归一化的不变量行，不参与重复性判定）。
        final again = await t.client.syncNow();
        expect(again.isSuccess, isTrue);
        final hostActivities2 = (await t.host.activities.activities())
            .requireValue();
        final userActivities =
            hostActivities2.where((a) => !a.isUnassigned).toList();
        expect(userActivities.map((a) => a.id).toSet(),
            {hostActivity.id, clientActivity.id},
            reason: '重复同步后活动集合精确不变（无重复行）');
        expect(userActivities, hasLength(2),
            reason: '无额外重复插入的活动行');
        expect(
          await t.host.entries.entriesForDay(DateTime(2026, 8, 11)),
          hasLength(1),
          reason: '条目不因重复同步而叠加',
        );
      } finally {
        await t.server.stop();
        await t.host.close();
        await t.clientSide.close();
      }
    });

    test('LAN 删除传播：客户端软删活动 → 同步后主机不可见', () async {
      final t = await _setup();
      try {
        final activity = (await t.clientSide.activities.createActivity(
          name: '待删',
          color: 0xffd97706,
        ))
            .requireValue();
        final code = t.server.generatePairingCode(deviceId: 'client-dev');
        final paired = await t.client.pair(
          host: '127.0.0.1',
          port: t.port,
          pairingCode: code,
        );
        expect(paired.isSuccess, isTrue);
        expect(
          (await t.host.activities.activities())
              .requireValue()
              .map((a) => a.id),
          contains(activity.id),
          reason: '配对后主机已看到客户端活动',
        );

        await t.clientSide.activities.deleteActivity(activity);
        final synced = await t.client.syncNow();
        expect(synced.isSuccess, isTrue);
        final hostActivities = (await t.host.activities.activities()).requireValue();
        expect(hostActivities.map((a) => a.id), isNot(contains(activity.id)),
            reason: '软删墓碑随 LWW 传播到主机');
      } finally {
        await t.server.stop();
        await t.host.close();
        await t.clientSide.close();
      }
    });
  });
}
