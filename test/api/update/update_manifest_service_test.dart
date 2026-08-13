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

    setUp(() {
      db = AppDatabase(NativeDatabase.memory());
    });

    tearDown(() => db.close());

    UpdateManifestService service(String currentVersion) =>
        UpdateManifestService(database: db, currentVersion: currentVersion);

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
      final result =
          (await service('1.0.0').evaluate(manifest('1.1.0'))).requireValue();
      expect(result.available, isTrue);
      expect(result.latestVersion, '1.1.0');
      expect(result.required, isFalse);
      expect(result.windows, isNotNull);
      // 缓存供后续判断
      final cached = await (db.select(db.appMetadata)
            ..where((t) => t.key.equals('last_checked_manifest_version')))
          .getSingle();
      expect(cached.value, '1.1.0');
    });

    test('远端版本 ≤ 当前版本 → 无更新（含 pre-release 规则）', () async {
      // 1.0.0 == 1.0.0
      expect((await service('1.0.0').evaluate(manifest('1.0.0'))).requireValue().available, isFalse);
      // 0.9.0 < 1.0.0
      expect((await service('1.0.0').evaluate(manifest('0.9.0'))).requireValue().available, isFalse);
      // 1.1.0-pre.1 < 1.1.0（pre-release 不视为更新）
      expect((await service('1.1.0').evaluate(manifest('1.1.0-pre.1'))).requireValue().available, isFalse);
      // 1.1.0-pre.1 > 1.0.0（更高主版本 pre-release 算更新）
      expect((await service('1.0.0').evaluate(manifest('1.1.0-pre.1'))).requireValue().available, isTrue);
    });

    test('已忽略版本 → 无更新；忽略的更新版本低于当前 → 无更新', () async {
      // 忽略 1.1.0
      await db.into(db.appMetadata).insertOnConflictUpdate(
            AppMetadataCompanion.insert(
              key: 'ignored_update_version',
              value: '1.1.0',
            ),
          );
      expect((await service('1.0.0').evaluate(manifest('1.1.0'))).requireValue().available, isFalse,
          reason: '已忽略版本不再提示');
      // 忽略版本低于远端新版本 → 仍提示
      expect((await service('1.0.0').evaluate(manifest('1.2.0'))).requireValue().available, isTrue);
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
        httpClient: MockClient((request) async => http.Response(
              jsonEncode({'version': 'not-semver'}),
              200,
              headers: {'content-type': 'application/json'},
              request: request,
            )),
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
      expect((await client404.checkForUpdate()).isSuccess, isFalse,
          reason: '404 失败');

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
  });
}
