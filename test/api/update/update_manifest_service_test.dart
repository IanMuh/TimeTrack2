import 'dart:async';
import 'dart:convert';
import 'dart:io' show HttpException, TlsException;

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:timetrack2/api/update/update_manifest_service.dart';
import 'package:timetrack2/constants/storage_keys.dart';
import 'package:timetrack2/data/database/app_database.dart';
import 'package:timetrack2/viewmodels/update/update_manifest.dart';

void main() {
  group('UpdateManifestService evaluate（纯逻辑）', () {
    late AppDatabase db;
    final createdServices = <UpdateManifestService>[];

    setUp(() {
      db = AppDatabase(NativeDatabase.memory());
    });

    tearDown(() {
      // 资源卫生（r9）：service() 未注入 httpClient 会自建默认 client——统一
      // close 释放（防 long-running 测试累积底层连接）。
      for (final s in createdServices) {
        s.close();
      }
      createdServices.clear();
      db.close();
    });

    UpdateManifestService service(String currentVersion) {
      final s = UpdateManifestService(
        database: db,
        currentVersion: currentVersion,
      );
      createdServices.add(s);
      return s;
    }

    UpdateManifest manifest(String version, {bool required = false}) =>
        UpdateManifest(
          version: version,
          required: required,
          releaseNotes: 'notes',
          windows: UpdatePlatformArtifact(
            url: 'https://x.example/app.zip',
            sha256: 'a' * 64,
          ),
        );

    test('远端版本更新 → available + 缓存版本', () async {
      final result = (await service(
        '1.0.0',
      ).evaluate(manifest('1.1.0'))).requireValue();
      expect(result.available, isTrue);
      expect(result.latestVersion, '1.1.0');
      expect(result.required, isFalse);
      expect(result.windows, isNotNull);
      // 缓存供后续判断
      final cached =
          await (db.select(db.appMetadata)..where(
                (t) => t.key.equals(AppMetadataKeys.lastCheckedManifestVersion),
              ))
              .getSingle();
      expect(cached.value, '1.1.0');
    });

    test('远端版本 ≤ 当前版本 → 无更新（含 pre-release 规则）', () async {
      // 1.0.0 == 1.0.0
      expect(
        (await service(
          '1.0.0',
        ).evaluate(manifest('1.0.0'))).requireValue().available,
        isFalse,
      );
      // 0.9.0 < 1.0.0
      expect(
        (await service(
          '1.0.0',
        ).evaluate(manifest('0.9.0'))).requireValue().available,
        isFalse,
      );
      // 1.1.0-pre.1 < 1.1.0（pre-release 不视为更新）
      expect(
        (await service(
          '1.1.0',
        ).evaluate(manifest('1.1.0-pre.1'))).requireValue().available,
        isFalse,
      );
      // 1.1.0-pre.1 > 1.0.0（更高主版本 pre-release 算更新）
      expect(
        (await service(
          '1.0.0',
        ).evaluate(manifest('1.1.0-pre.1'))).requireValue().available,
        isTrue,
      );
      // **pre-release → 正式版升级（r2）**：current=1.1.0-pre.1、remote=1.1.0
      // ——SemVer 规则 pre-release 排序低于正式版，应判为更新（字符串比较会
      // 得出相反结论，此用例锁定防误用字符串比较回归）。
      expect(
        (await service(
          '1.1.0-pre.1',
        ).evaluate(manifest('1.1.0'))).requireValue().available,
        isTrue,
        reason: 'pre-release 用户可升级到同版本正式版',
      );
    });

    test('已忽略版本 → 无更新；忽略版本低于新远端版本 → 仍提示', () async {
      // 忽略 1.1.0
      await db
          .into(db.appMetadata)
          .insertOnConflictUpdate(
            AppMetadataCompanion.insert(
              key: AppMetadataKeys.ignoredUpdateVersion,
              value: '1.1.0',
            ),
          );
      expect(
        (await service(
          '1.0.0',
        ).evaluate(manifest('1.1.0'))).requireValue().available,
        isFalse,
        reason: '已忽略版本不再提示',
      );
      // 忽略版本低于远端新版本 → 仍提示
      expect(
        (await service(
          '1.0.0',
        ).evaluate(manifest('1.2.0'))).requireValue().available,
        isTrue,
      );
    });

    test('远端版本数字段超 int 范围 → 可读失败（不崩溃，r2）', () async {
      // UpdateManifest.fromMap 正则只校验格式不查 int 范围——超大数字段会
      // 在 AppVersion.parse 抛 FormatException，须转 AppFailure。
      final result = await service(
        '1.0.0',
      ).evaluate(manifest('9999999999999999999999.0.0'));
      expect(result.isSuccess, isFalse, reason: '数字段超范围返回失败');
      expect(
        result.when(onSuccess: (_) => '', onFailure: (m) => m),
        contains('版本号'),
      );
    });

    test('忽略版本脏数据（非 SemVer）→ 不崩溃、继续走更新判定（r2）', () async {
      await db
          .into(db.appMetadata)
          .insertOnConflictUpdate(
            AppMetadataCompanion.insert(
              key: AppMetadataKeys.ignoredUpdateVersion,
              value: 'not-semver', // 本地脏数据
            ),
          );
      final result = (await service(
        '1.0.0',
      ).evaluate(manifest('1.1.0'))).requireValue();
      expect(result.available, isTrue, reason: '脏忽略版本视为未忽略，正常提示更新');
    });

    test('远端版本更高但无平台产物（windows/android 为 null，r9）', () async {
      // UpdateManifest 模型注释"缺平台则对应平台不可更新"——_evaluate 当前
      // 直接透传 manifest 不检查平台产物：available=true 且 windows=null。
      // 该行为被显式锁定（防后续为 evaluate 增加平台过滤逻辑时无感知回归）。
      final bare = UpdateManifest(version: '2.0.0'); // 无任何平台产物
      final result = (await service('1.0.0').evaluate(bare)).requireValue();
      expect(result.available, isTrue, reason: '版本更高即视为有更新');
      expect(result.windows, isNull, reason: '无平台产物时 windows 为 null');
      expect(result.android, isNull);
    });

    test('evaluate 入口复查：close 后返回可读失败且不写缓存（r9）', () async {
      final client = service('1.0.0');
      client.close();
      final result = await client.evaluate(manifest('1.1.0'));
      expect(result.isSuccess, isFalse, reason: '已关闭返回失败');
      expect(
        result.when(onSuccess: (_) => '', onFailure: (m) => m),
        contains('已关闭'),
      );
      // 未进入 _evaluate 写库（"不做 DB 写"的保证——防复查被挪到写库后）。
      final cached =
          await (db.select(db.appMetadata)..where(
                (t) => t.key.equals(AppMetadataKeys.lastCheckedManifestVersion),
              ))
              .get();
      expect(cached, isEmpty, reason: 'close 后 evaluate 不写缓存');
    });
  });

  group('UpdateManifestService 网络层（MockClient）', () {
    late AppDatabase db;

    setUp(() {
      db = AppDatabase(NativeDatabase.memory());
    });

    tearDown(() => db.close());

    test('成功拉取 + 解析 + 版本评估', () async {
      final client = UpdateManifestService(
        database: db,
        currentVersion: '1.0.0',
        manifestUrl: Uri.parse('https://x.example/update.json'),
        httpClient: MockClient((request) async {
          expect(request.url.toString(), 'https://x.example/update.json');
          return http.Response(
            jsonEncode({
              'version': '2.0.0',
              'required': 1,
              'release_notes': 'big update',
              'windows': {
                'url': 'https://x.example/app.zip',
                'sha256': 'b' * 64,
              },
            }),
            200,
            headers: {'content-type': 'application/json'},
            request: request,
          );
        }),
      );
      final result = (await client.checkForUpdate()).requireValue();
      expect(result.available, isTrue);
      expect(result.latestVersion, '2.0.0');
      expect(result.required, isTrue);
      expect(result.releaseNotes, 'big update');
    });

    test('清单解析失败（非法 SemVer）→ 可读失败', () async {
      final client = UpdateManifestService(
        database: db,
        currentVersion: '1.0.0',
        manifestUrl: Uri.parse('https://x.example/update.json'),
        httpClient: MockClient(
          (request) async => http.Response(
            jsonEncode({'version': 'not-semver'}),
            200,
            headers: {'content-type': 'application/json'},
            request: request,
          ),
        ),
      );
      final result = await client.checkForUpdate();
      expect(result.isSuccess, isFalse);
      expect(
        result.when(onSuccess: (_) => '', onFailure: (m) => m),
        contains('解析失败'),
        reason: '可读失败消息',
      );
    });

    test('非 200 / 网络异常 → 可读失败（脱敏）', () async {
      final client404 = UpdateManifestService(
        database: db,
        currentVersion: '1.0.0',
        manifestUrl: Uri.parse('https://x.example/update.json'),
        httpClient: MockClient(
          (request) async => http.Response('nf', 404, request: request),
        ),
      );
      expect(
        (await client404.checkForUpdate()).isSuccess,
        isFalse,
        reason: '404 失败',
      );

      final clientNet = UpdateManifestService(
        database: db,
        currentVersion: '1.0.0',
        manifestUrl: Uri.parse('https://x.example/update.json'),
        httpClient: MockClient(
          (_) async => throw http.ClientException('reset'),
        ),
      );
      final result = await clientNet.checkForUpdate();
      expect(result.isSuccess, isFalse);
      final msg = result.when(onSuccess: (_) => '', onFailure: (m) => m);
      expect(
        msg.contains('ClientException') || msg.contains('SocketException'),
        isFalse,
        reason: '不泄露底层异常类型',
      );
    });

    test('非关闭 StateError 重新抛出（不包装成"已关闭"，r14/r16）', () async {
      // 核心语义：仅 `_closed` 或消息匹配（'Client is already closed'）才归因
      // "已关闭"——其它 StateError（编程错误）必须 rethrow，不能吞成误导性
      // 可读失败（掩盖真实缺陷）。
      final client = UpdateManifestService(
        database: db,
        currentVersion: '1.0.0',
        manifestUrl: Uri.parse('https://x.example/update.json'),
        httpClient: MockClient(
          (_) async => throw StateError('programming bug'),
        ),
      );
      // **核心断言**：checkForUpdate **抛出**非关闭 StateError（而非返回
      // AppFailure）——rethrow 语义由 expectLater 锁定。
      await expectLater(
        client.checkForUpdate(),
        throwsA(isA<StateError>()),
        reason: '非关闭 StateError 重新抛出',
      );
    });

    test('StateError 消息匹配（already closed）→ 归因"已关闭"返回可读失败（r14/r19）', () async {
      // r14 精准归因的正向路径：`_closed=false` 但底层客户端抛
      // `StateError('Client is already closed')`（调用方未调 close() 而在外部
      // 关闭了注入的 http.Client）——按消息匹配归因"已关闭"返回 AppFailure，
      // 而非 rethrow。
      final client = UpdateManifestService(
        database: db,
        currentVersion: '1.0.0',
        manifestUrl: Uri.parse('https://x.example/update.json'),
        httpClient: MockClient(
          (_) async => throw StateError('Client is already closed'),
        ),
      );
      final result = await client.checkForUpdate();
      expect(result.isSuccess, isFalse);
      expect(
        result.when(onSuccess: (_) => '', onFailure: (m) => m),
        contains('已关闭'),
        reason: '消息匹配归因已关闭',
      );
    });

    test('HttpException/TlsException → 可读失败（r19 补测）', () async {
      // http 包仅把 send 阶段与部分流中错误包装为 ClientException、其余透传
      // ——dart:io 的 HttpException/TlsException（握手失败/证书校验失败）须被
      // 捕获返回可读失败而非逃逸。
      final clientHttp = UpdateManifestService(
        database: db,
        currentVersion: '1.0.0',
        manifestUrl: Uri.parse('https://x.example/update.json'),
        httpClient: MockClient(
          (_) async => throw HttpException('connection reset by peer'),
        ),
      );
      final resultHttp = await clientHttp.checkForUpdate();
      expect(resultHttp.isSuccess, isFalse, reason: 'HttpException 返回可读失败');
      expect(
        resultHttp.when(onSuccess: (_) => '', onFailure: (m) => m),
        contains('网络不可用'),
      );

      final clientTls = UpdateManifestService(
        database: db,
        currentVersion: '1.0.0',
        manifestUrl: Uri.parse('https://x.example/update.json'),
        httpClient: MockClient(
          (_) async => throw const TlsException('handshake failed'),
        ),
      );
      final resultTls = await clientTls.checkForUpdate();
      expect(resultTls.isSuccess, isFalse, reason: 'TlsException 返回可读失败');
      expect(
        resultTls.when(onSuccess: (_) => '', onFailure: (m) => m),
        contains('网络不可用'),
      );

      // _closed=true 时归因"已关闭"（与其它网络分支一致）。
      final clientTlsClosed = UpdateManifestService(
        database: db,
        currentVersion: '1.0.0',
        manifestUrl: Uri.parse('https://x.example/update.json'),
        httpClient: MockClient(
          (_) async => throw const TlsException('handshake failed'),
        ),
      );
      clientTlsClosed.close();
      final resultClosed = await clientTlsClosed.checkForUpdate();
      expect(resultClosed.isSuccess, isFalse);
      expect(
        resultClosed.when(onSuccess: (_) => '', onFailure: (m) => m),
        contains('已关闭'),
        reason: '已关闭归因关闭而非网络',
      );
    });

    test('强制更新不受忽略版本影响（r19）：required + 已忽略 → 仍提示', () async {
      // r19：required=true 语义为"不可跳过"——用户此前忽略过 ≥ 远端版本时
      // 仍须判为可用更新（防强制/安全更新被静默跳过）。
      await db
          .into(db.appMetadata)
          .insertOnConflictUpdate(
            AppMetadataCompanion.insert(
              key: AppMetadataKeys.ignoredUpdateVersion,
              value: '1.1.0',
            ),
          );
      final client = UpdateManifestService(
        database: db,
        currentVersion: '1.0.0',
        manifestUrl: Uri.parse('https://x.example/update.json'),
        httpClient: MockClient(
          (_) async => http.Response(
            jsonEncode({
              'version': '1.1.0',
              'required': 1,
              'windows': {
                'url': 'https://x.example/app.zip',
                'sha256': 'b' * 64,
              },
            }),
            200,
            headers: {'content-type': 'application/json'},
          ),
        ),
      );
      final result = (await client.checkForUpdate()).requireValue();
      expect(result.available, isTrue, reason: '强制更新不被忽略版本压制');
      expect(result.required, isTrue);
    });

    test('UTF-8 清单无 charset（r19）：中文 releaseNotes 不乱码', () async {
      // response.body 按响应头 charset 解码、未指定默认 latin-1——JSON 规范
      // 要求 UTF-8；显式 utf8.decode(bodyBytes) 后中文应正确解析。
      final client = UpdateManifestService(
        database: db,
        currentVersion: '1.0.0',
        manifestUrl: Uri.parse('https://x.example/update.json'),
        httpClient: MockClient(
          (_) async => http.Response.bytes(
            utf8.encode(
              jsonEncode({
                'version': '2.0.0',
                'release_notes': '更新日志：支持中文',
                'windows': {
                  'url': 'https://x.example/app.zip',
                  'sha256': 'b' * 64,
                },
              }),
            ),
            200,
            // 无 charset=utf-8（只发 application/json）——response.body 会按
            // latin1 解码乱码；显式 utf8.decode(bodyBytes) 必须正确。
            headers: {'content-type': 'application/json'},
          ),
        ),
      );
      final result = (await client.checkForUpdate()).requireValue();
      expect(result.releaseNotes, '更新日志：支持中文', reason: 'UTF-8 显式解码不乱码');
    });

    test('close 后 checkForUpdate 返回可读失败且不发网络请求（r3，网络层归位）', () async {
      var hit = false;
      final client = UpdateManifestService(
        database: db,
        currentVersion: '1.0.0',
        manifestUrl: Uri.parse('https://x.example/update.json'),
        httpClient: MockClient((request) async {
          hit = true;
          return http.Response('{}', 200, request: request);
        }),
      );
      client.close();
      final result = await client.checkForUpdate();
      expect(result.isSuccess, isFalse, reason: '已关闭返回失败');
      expect(
        result.when(onSuccess: (_) => '', onFailure: (m) => m),
        contains('已关闭'),
      );
      expect(hit, isFalse, reason: '已关闭不再发起网络请求');
      // 重复 close 幂等（不抛错）。
      client.close();
    });

    test('请求 await 期间 close → 复查返回"已关闭"且不写库（r4）', () async {
      // 核心竞态：checkForUpdate 已进入 await（网络挂起）后 close 被并发调用——
      // await 后复查 _closed 返回"已关闭"，不进入 _evaluate 写库。
      // **显式等待回调入口（r5）**：`started` Completer 确认 MockClient 回调
      // 已执行并停在 gate.future——不依赖 pumpEventQueue 隐含时序（防重构
      // 改变请求派发后 close 实际发生在请求发出前、退化为 r3 前置路径）。
      final started = Completer<void>();
      final gate = Completer<void>();
      final client = UpdateManifestService(
        database: db,
        currentVersion: '1.0.0',
        manifestUrl: Uri.parse('https://x.example/update.json'),
        httpClient: MockClient((request) async {
          started.complete(); // 请求已进入挂起
          await gate.future; // 挂起响应
          return http.Response(
            jsonEncode({
              'version': '2.0.0',
              'windows': {
                'url': 'https://x.example/app.zip',
                'sha256': 'b' * 64,
              },
            }),
            200,
            headers: {'content-type': 'application/json'},
            request: request,
          );
        }),
      );
      final future = client.checkForUpdate();
      await started.future; // 显式等待请求进入挂起（回调入口）
      client.close();
      gate.complete(); // 释放响应
      final result = await future;
      expect(result.isSuccess, isFalse, reason: 'await 期间关闭返回失败');
      expect(
        result.when(onSuccess: (_) => '', onFailure: (m) => m),
        contains('已关闭'),
      );
      // 未写缓存（不进入 _evaluate）
      final cached =
          await (db.select(db.appMetadata)..where(
                (t) => t.key.equals(AppMetadataKeys.lastCheckedManifestVersion),
              ))
              .get();
      expect(cached, isEmpty, reason: '已关闭不写缓存');
      // **覆盖边界注明（r5）**：本用例触发的是**网络 await 后的 _closed 复查**
      //（返回时未进 _evaluate）；`_evaluate` 内"写库前复查"（DB await 期间
      // close 不落缓存）需可控数据库注入挂起点，现有 drift 架构无此注入——
      // 该分支仅由代码评审 + 本复查逻辑守护，属已知覆盖边界。
    });
  });
}
