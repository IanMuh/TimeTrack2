import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:timetrack2/api/update/update_downloader.dart';
import 'package:timetrack2/api/update/update_verifier.dart';
import 'package:timetrack2/utils/sha256.dart';
import 'package:timetrack2/viewmodels/update/update_manifest.dart';

void main() {
  group('UpdateDownloader', () {
    test('成功：流式写临时文件 + 进度回调 + 边收边算 SHA-256', () async {
      final dir = await Directory.systemTemp.createTemp('dl_success');
      final payload = List<int>.generate(200000, (i) => i % 251);
      final expectedSha = sha256Bytes(payload);
      final progress = <int>[];
      final downloader = UpdateDownloader(
        tempDirectory: dir,
        httpClient: MockClient((request) async {
          // 分块流式响应（模拟网络分块到达）。
          final chunks = <List<int>>[];
          for (var i = 0; i < payload.length; i += 30000) {
            chunks.add(payload.sublist(
              i,
              (i + 30000) < payload.length ? i + 30000 : payload.length,
            ));
          }
          return http.Response.bytes(payload, 200, request: request);
        }),
      );
      try {
        final result = (await downloader.download(
          'https://x.example/app.zip',
          onProgress: (received, total) => progress.add(received),
        ))
            .requireValue();
        final file = File(result.filePath);
        expect(file.existsSync(), isTrue, reason: '临时文件已写入');
        expect(result.totalBytes, payload.length);
        expect(result.sha256, expectedSha,
            reason: '边收边算 SHA-256 与整包一致');
        expect(progress.last, payload.length, reason: '进度到 100%');
        // 实际文件内容一致
        expect(await sha256File(file.path), expectedSha);
      } finally {
        await dir.delete(recursive: true);
      }
    });

    test('网络瞬时失败重试恢复（指数退避）', () async {
      final dir = await Directory.systemTemp.createTemp('dl_retry');
      var calls = 0;
      final downloader = UpdateDownloader(
        tempDirectory: dir,
        httpClient: MockClient((request) async {
          calls += 1;
          if (calls <= 2) {
            throw http.ClientException('connection reset');
          }
          return http.Response('ok', 200, request: request);
        }),
      );
      try {
        final result =
            (await downloader.download('https://x.example/app.zip')).requireValue();
        expect(calls, 3, reason: '2 次失败 + 1 次成功');
        expect(File(result.filePath).readAsStringSync(), 'ok');
      } finally {
        await dir.delete(recursive: true);
      }
    });

    test('持续失败耗尽重试 → 可读失败', () async {
      final dir = await Directory.systemTemp.createTemp('dl_fail');
      final downloader = UpdateDownloader(
        tempDirectory: dir,
        httpClient: MockClient(
          (_) async => throw http.ClientException('reset'),
        ),
      );
      try {
        final result = await downloader.download('https://x.example/app.zip');
        expect(result.isSuccess, isFalse, reason: '重试耗尽失败');
        final msg = result.when(onSuccess: (_) => '', onFailure: (m) => m);
        expect(msg.contains('ClientException'), isFalse,
            reason: '不泄露底层异常类型');
      } finally {
        await dir.delete(recursive: true);
      }
    });
  });

  group('UpdateVerifier', () {
    test('校验通过：返回文件路径（SHA-256 匹配）', () async {
      final dir = await Directory.systemTemp.createTemp('verify_ok');
      final payload = 'payload-bytes';
      final artifact = UpdatePlatformArtifact(
        url: 'https://x.example/app.zip',
        sha256: sha256String(payload),
      );
      try {
        final verifier = UpdateVerifier(
          downloader: UpdateDownloader(
            tempDirectory: dir,
            httpClient: MockClient(
              (request) async => http.Response(payload, 200, request: request),
            ),
          ),
        );
        final result = (await verifier.downloadAndVerify(artifact)).requireValue();
        expect(File(result.filePath).readAsStringSync(), payload);
      } finally {
        await dir.delete(recursive: true);
      }
    });

    test('校验失败：删损坏文件重下，仍失败 → 可读失败', () async {
      final dir = await Directory.systemTemp.createTemp('verify_fail');
      final goodPayload = 'good-payload';
      final artifact = UpdatePlatformArtifact(
        url: 'https://x.example/app.zip',
        sha256: sha256String(goodPayload), // 期望 good
      );
      var calls = 0;
      try {
        final verifier = UpdateVerifier(
          downloader: UpdateDownloader(
            tempDirectory: dir,
            httpClient: MockClient((request) async {
              calls += 1;
              // 每次返回损坏内容（与实际期望不符）。
              return http.Response('corrupted-$calls', 200, request: request);
            }),
          ),
        );
        final result = await verifier.downloadAndVerify(artifact);
        expect(result.isSuccess, isFalse, reason: '校验失败');
        expect(
          result.when(onSuccess: (_) => '', onFailure: (m) => m),
          contains('校验失败'),
        );
        // 重下次数：初始 1 次 + redownloadAfterVerificationFailure(1) = 2 次
        expect(calls, 2, reason: '初始下载 + 1 次重下');
        // 损坏文件已删除（不残留）
        expect(dir.listSync().whereType<File>(), isEmpty,
            reason: '校验失败文件已删');
      } finally {
        await dir.delete(recursive: true);
      }
    });
  });
}
