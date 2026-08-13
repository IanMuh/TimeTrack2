import 'dart:async';
import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:timetrack2/api/update/update_manifest_service.dart';
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
          await (db.select(db.appMetadata)
                ..where((t) => t.key.equals('last_checked_manifest_version')))
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
              key: 'ignored_update_version',
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
              key: 'ignored_update_version',
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
      final cached = await (db.select(
        db.appMetadata,
      )..where((t) => t.key.equals('last_checked_manifest_version'))).get();
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
      final cached = await (db.select(
        db.appMetadata,
      )..where((t) => t.key.equals('last_checked_manifest_version'))).get();
      expect(cached, isEmpty, reason: '已关闭不写缓存');
      // **覆盖边界注明（r5）**：本用例触发的是**网络 await 后的 _closed 复查**
      //（返回时未进 _evaluate）；`_evaluate` 内"写库前复查"（DB await 期间
      // close 不落缓存）需可控数据库注入挂起点，现有 drift 架构无此注入——
      // 该分支仅由代码评审 + 本复查逻辑守护，属已知覆盖边界。
    });
  });
}
