import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:timetrack2/api/update/update_downloader.dart';
import 'package:timetrack2/api/update/update_verifier.dart';
import 'package:timetrack2/constants/update_config.dart';
import 'package:timetrack2/utils/sha256.dart';
import 'package:timetrack2/viewmodels/update/update_manifest.dart';

void main() {
  group('UpdateDownloader', () {
    test('成功：流式写临时文件 + 逐块进度回调 + 边收边算 SHA-256', () async {
      final dir = await Directory.systemTemp.createTemp('dl_success');
      final payload = List<int>.generate(200000, (i) => i % 251);
      final expectedSha = sha256Bytes(payload);
      final progress = <int>[];
      // **真分块流式响应（r2）**：MockClient 的 Response.bytes 把整个 body 作为
      // 单块发出——用自定义 BaseClient 返回 StreamedResponse 逐块发射，下载器
      // 才能真正分块消费（逐块进度递增/增量哈希拼接被真实验证）。
      final chunks = <List<int>>[];
      for (var i = 0; i < payload.length; i += 30000) {
        chunks.add(
          payload.sublist(
            i,
            (i + 30000) < payload.length ? i + 30000 : payload.length,
          ),
        );
      }
      final chunkedClient = _ChunkedHttpClient(chunks);
      final downloader = UpdateDownloader(
        tempDirectory: dir,
        httpClient: chunkedClient,
      );
      try {
        final result = (await downloader.download(
          'https://x.example/app.zip',
          onProgress: (received, total) => progress.add(received),
        )).requireValue();
        final file = File(result.filePath);
        expect(file.existsSync(), isTrue, reason: '临时文件已写入');
        expect(result.totalBytes, payload.length);
        expect(result.sha256, expectedSha, reason: '边收边算 SHA-256 与整包一致');
        expect(
          progress.length,
          greaterThan(1),
          reason: '逐块到达应触发多次进度回调（分块流式被真正消费）',
        );
        for (var i = 1; i < progress.length; i++) {
          expect(progress[i] > progress[i - 1], isTrue, reason: '进度单调递增（增量写盘）');
        }
        expect(progress.last, payload.length, reason: '进度到 100%');
        // 实际文件内容一致
        expect(await sha256File(file.path), expectedSha);
      } finally {
        await dir.delete(recursive: true);
      }
    });

    test('网络瞬时失败重试恢复（指数退避；注入零延迟）', () async {
      final dir = await Directory.systemTemp.createTemp('dl_retry');
      var calls = 0;
      final downloader = UpdateDownloader(
        tempDirectory: dir,
        retryBaseDelay: Duration.zero, // 免真实 2s/4s 等待
        httpClient: MockClient((request) async {
          calls += 1;
          if (calls <= 2) {
            throw http.ClientException('connection reset');
          }
          return http.Response('ok', 200, request: request);
        }),
      );
      try {
        final result = (await downloader.download(
          'https://x.example/app.zip',
        )).requireValue();
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
        retryBaseDelay: Duration.zero, // 免 2+4+8s 真实等待
        httpClient: MockClient(
          (_) async => throw http.ClientException('reset'),
        ),
      );
      try {
        final result = await downloader.download('https://x.example/app.zip');
        expect(result.isSuccess, isFalse, reason: '重试耗尽失败');
        final msg = result.when(onSuccess: (_) => '', onFailure: (m) => m);
        expect(msg.contains('ClientException'), isFalse, reason: '不泄露底层异常类型');
      } finally {
        await dir.delete(recursive: true);
      }
    });

    test('4xx 不重试：直接失败带状态码（r2）', () async {
      final dir = await Directory.systemTemp.createTemp('dl_4xx');
      var calls = 0;
      final downloader = UpdateDownloader(
        tempDirectory: dir,
        retryCount: 3,
        retryBaseDelay: Duration.zero,
        httpClient: MockClient((request) async {
          calls += 1;
          return http.Response('nf', 404, request: request);
        }),
      );
      try {
        final result = await downloader.download('https://x.example/app.zip');
        expect(result.isSuccess, isFalse);
        expect(calls, 1, reason: '4xx 不重试（永久性错误）');
        expect(
          result.when(onSuccess: (_) => '', onFailure: (m) => m),
          contains('404'),
          reason: '文案带状态码（区别于瞬态网络）',
        );
      } finally {
        await dir.delete(recursive: true);
      }
    });

    test('5xx 同样不重试且文案带状态码（r9 固化契约）', () async {
      final dir = await Directory.systemTemp.createTemp('dl_5xx');
      var calls = 0;
      final downloader = UpdateDownloader(
        tempDirectory: dir,
        retryCount: 3,
        retryBaseDelay: Duration.zero,
        httpClient: MockClient((request) async {
          calls += 1;
          return http.Response('err', 500, request: request);
        }),
      );
      try {
        final result = await downloader.download('https://x.example/app.zip');
        expect(result.isSuccess, isFalse);
        expect(calls, 1, reason: '非 200 一律不重试');
        expect(
          result.when(onSuccess: (_) => '', onFailure: (m) => m),
          contains('500'),
        );
      } finally {
        await dir.delete(recursive: true);
      }
    });

    test('流中途断连：重试恢复 + 半成品清理（r9）', () async {
      final dir = await Directory.systemTemp.createTemp('dl_midstream');
      final client = _AbortStreamHttpClient();
      final downloader = UpdateDownloader(
        tempDirectory: dir,
        retryCount: 2,
        retryBaseDelay: Duration.zero,
        httpClient: client,
      );
      try {
        final result = (await downloader.download(
          'https://x.example/app.zip',
        )).requireValue();
        expect(client.callCount, 2, reason: '1 次中途断连 + 1 次成功');
        // 最终文件内容正确（第二次成功）。
        expect(
          File(result.filePath).readAsStringSync(),
          _AbortStreamHttpClient.payload,
        );
        // 失败后半成品临时文件已清理（目录仅剩最终成功文件）。
        expect(
          dir.listSync().whereType<File>().length,
          1,
          reason: '断连失败后半成品已删（仅最终成功文件残留）',
        );
      } finally {
        await dir.delete(recursive: true);
      }
    });

    test('下载总字节上限（r19）：声明超限前置拒绝 / 分块流超限流式中断且无残留', () async {
      final dir = await Directory.systemTemp.createTemp('dl_cap');
      try {
        // 场景 A：响应头 contentLength 超 maxCompressedBytes → send 后立即
        // 前置拒绝（不写盘）。
        final declaredOver = _DeclaredOverLimitClient();
        final downloaderA = UpdateDownloader(
          tempDirectory: dir,
          retryCount: 3,
          httpClient: declaredOver,
        );
        final resultA = await downloaderA.download('https://x.example/app.zip');
        expect(resultA.isSuccess, isFalse, reason: '声明超限失败');
        expect(declaredOver.calls, 1, reason: '4xx/超限不重试');
        // 场景 B：分块流实际超限（声明 contentLength 小、实际持续发送）→
        // 流式累计检查中断下载、半成品清理、无残留。
        final downloaderB = UpdateDownloader(
          tempDirectory: dir,
          retryCount: 0,
          httpClient: _OversizeChunkedHttpClient(),
        );
        final resultB = await downloaderB.download('https://x.example/app.zip');
        expect(resultB.isSuccess, isFalse, reason: '分块流超限失败');
        expect(dir.listSync(), isEmpty, reason: '超限中断后半成品已清理（无残留）');
      } finally {
        await dir.delete(recursive: true);
      }
    });

    test('非法 URL（FormatException）→ 可读失败且不触达网络（r9）', () async {
      final dir = await Directory.systemTemp.createTemp('dl_badurl');
      var calls = 0;
      final downloader = UpdateDownloader(
        tempDirectory: dir,
        retryCount: 3,
        httpClient: MockClient((_) async {
          calls += 1;
          return http.Response('x', 200);
        }),
      );
      try {
        // Uri.parse 对 'not a url' 宽松解析为相对 URI（不抛）——用真正畸形
        // 的输入触发 FormatException。
        final result = await downloader.download('https://[bad');
        expect(result.isSuccess, isFalse, reason: '非法 URL 失败');
        expect(
          result.when(onSuccess: (_) => '', onFailure: (m) => m),
          contains('地址非法'),
        );
        // Uri.parse 阶段即抛 FormatException——客户端从未被调用（锁定"不
        // 触达网络"契约）。
        expect(calls, 0, reason: '非法 URL 在解析阶段失败，未发起网络请求');
      } finally {
        await dir.delete(recursive: true);
      }
    });

    test('非 http(s) scheme（file://）→ 可读失败（r15 兜底）', () async {
      final dir = await Directory.systemTemp.createTemp('dl_scheme');
      var calls = 0;
      final downloader = UpdateDownloader(
        tempDirectory: dir,
        httpClient: MockClient((_) async {
          calls += 1;
          return http.Response('x', 200);
        }),
      );
      try {
        // Uri.parse 对 file:// 宽松解析不抛——http.Request 构造/发送时抛
        // ArgumentError（Error）会逃逸；显式 scheme 校验须拦截。
        final result = await downloader.download('file:///tmp/app.zip');
        expect(result.isSuccess, isFalse, reason: '非 http(s) scheme 失败');
        expect(
          result.when(onSuccess: (_) => '', onFailure: (m) => m),
          contains('地址非法'),
        );
        // **时序契约锁定（r16）**：scheme 校验必须在 send 之前拦截——若被
        // 挪到 send 之后，MockClient 对 file:// 会正常返回 200 仅后续校验抛错，
        // 此断言会暴露"实际已触达网络"的回归。
        expect(calls, 0, reason: 'scheme 校验在发送前拦截，未发起网络请求');
      } finally {
        await dir.delete(recursive: true);
      }
    });

    test('scheme-only 无 host（https:// / http:）→ 可读失败（r16 兜底）', () async {
      // Uri.parse('https://')/'http:' 解析成功且 scheme 为 http(s)——旧校验
      //（仅查 scheme）放行，真实 IOClient.openUrl 对空 host 抛 ArgumentError
      //（Error）逃逸破坏"恒返回 AppResult"契约；host 校验须在 send 前拦截。
      final dir = await Directory.systemTemp.createTemp('dl_nohost');
      var calls = 0;
      final downloader = UpdateDownloader(
        tempDirectory: dir,
        httpClient: MockClient((_) async {
          calls += 1;
          return http.Response('x', 200);
        }),
      );
      try {
        for (final url in ['https://', 'http:', 'https://?a=1']) {
          final result = await downloader.download(url);
          expect(result.isSuccess, isFalse, reason: '无 host 的 URL 失败：$url');
          expect(
            result.when(onSuccess: (_) => '', onFailure: (m) => m),
            contains('地址非法'),
          );
        }
        expect(calls, 0, reason: 'host 校验在发送前拦截，未发起网络请求');
      } finally {
        await dir.delete(recursive: true);
      }
    });

    test('重试间隙 close：返回"已关闭"且不再发起下次 send（r11）', () async {
      final dir = await Directory.systemTemp.createTemp('dl_close_retry');
      var calls = 0;
      final gate = Completer<void>();
      final started = Completer<void>();
      final downloader = UpdateDownloader(
        tempDirectory: dir,
        retryCount: 3,
        // 首次 HTTP send 挂起（gate 控制）：close 在请求 in-flight 时被调用，
        // 释放后首次尝试失败并进入退避延迟，循环顶部重查 _closed 返回"已关闭"。
        retryBaseDelay: Duration(milliseconds: 100),
        httpClient: MockClient((request) async {
          calls += 1;
          if (calls == 1) {
            started.complete(); // 首次 send 已发起（回调入口精确标记）
            await gate.future; // 挂起（模拟慢请求）
          }
          throw http.ClientException('reset');
        }),
      );
      try {
        final future = downloader.download('https://x.example/app.zip');
        // **显式等待首次 send 已发起（r13）+ 超时保护（r15）**：started
        // Completer 使同步点确定且自文档化；timeout 防回归导致首次 send 永不
        // 发起时测试挂到全局超时。
        await started.future.timeout(const Duration(seconds: 5));
        downloader.close(); // 重试间隙关闭
        gate.complete(); // 释放首次 send → 抛异常 → 进入重试循环
        final result = await future;
        expect(result.isSuccess, isFalse);
        expect(
          result.when(onSuccess: (_) => '', onFailure: (m) => m),
          contains('已关闭'),
          reason: '重试间隙 close 后返回"已关闭"（非误导性网络错误）',
        );
        expect(calls, 1, reason: 'close 后不再发起下次 send');
      } finally {
        await dir.delete(recursive: true);
      }
    });

    test('Error（编程错误）不吞：StateError 向外传播（r11）', () async {
      final dir = await Directory.systemTemp.createTemp('dl_error');
      final downloader = UpdateDownloader(
        tempDirectory: dir,
        httpClient: MockClient(
          (_) async => throw StateError('programming bug'), // Error 非 Exception
        ),
      );
      try {
        await expectLater(
          downloader.download('https://x.example/app.zip'),
          throwsA(isA<StateError>()),
          reason: 'Error 不吞、向外传播（防掩盖真实 bug）',
        );
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
        final result = (await verifier.downloadAndVerify(
          artifact,
        )).requireValue();
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
        // 重下次数：初始 1 次 + redownloadAfterVerificationFailure 次重下
        // **从配置常量推导（r2）**：防默认值变化时断言静默失效。
        expect(
          calls,
          UpdateConfig.redownloadAfterVerificationFailure + 1,
          reason: '初始下载 + 配置值次重下',
        );
        // 损坏文件已删除（不残留）
        expect(dir.listSync().whereType<File>(), isEmpty, reason: '校验失败文件已删');
      } finally {
        await dir.delete(recursive: true);
      }
    });

    test('校验失败 → 重下成功（恢复路径，r2）', () async {
      final dir = await Directory.systemTemp.createTemp('verify_recover');
      final goodPayload = 'good-payload';
      final artifact = UpdatePlatformArtifact(
        url: 'https://x.example/app.zip',
        sha256: sha256String(goodPayload),
      );
      var calls = 0;
      try {
        final verifier = UpdateVerifier(
          downloader: UpdateDownloader(
            tempDirectory: dir,
            httpClient: MockClient((request) async {
              calls += 1;
              // 首次损坏、重下成功——核心恢复路径。
              if (calls == 1) {
                return http.Response('corrupted', 200, request: request);
              }
              return http.Response(goodPayload, 200, request: request);
            }),
          ),
        );
        final result = (await verifier.downloadAndVerify(
          artifact,
        )).requireValue();
        expect(
          File(result.filePath).readAsStringSync(),
          goodPayload,
          reason: '重下成功的文件内容正确',
        );
        expect(calls, 2, reason: '1 次损坏 + 1 次重下成功');
      } finally {
        await dir.delete(recursive: true);
      }
    });
  });
}

/// 真分块流式响应 client（r2）：`http.Response.bytes` 会把 body 作为单块发出，
/// 下载器无法真实验证逐块消费——用 [http.StreamedResponse] 逐块发射，验证
/// 增量写盘/进度/哈希拼接。
class _ChunkedHttpClient extends http.BaseClient {
  _ChunkedHttpClient(this.chunks);

  final List<List<int>> chunks;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final total = chunks.fold<int>(0, (sum, c) => sum + c.length);
    final controller = StreamController<List<int>>();
    for (final chunk in chunks) {
      controller.add(chunk);
    }
    controller.close();
    return http.StreamedResponse(
      controller.stream,
      200,
      contentLength: total,
      headers: {'content-type': 'application/octet-stream'},
      request: request,
    );
  }
}

/// 分块流总字节数超上限 client（r19）：声明 contentLength 为小值、实际分块
/// 超上限持续发送（模拟无 Content-Length 的分块响应绕过前置检查）。
class _OversizeChunkedHttpClient extends http.BaseClient {
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final controller = StreamController<List<int>>();
    // 分块持续发送至超上限 250MB（> maxCompressedBytes 200MB；downloadStreamTimeout
    // 是相邻块空闲超时——只要持续推块不触顶；流式累计检查须在超限时中断下载、
    // 清理半成品）。逐块消费峰值内存小，写到约 200MB 即中断。
    for (var i = 0; i < 250; i++) {
      controller.add(List<int>.filled(1024 * 1024, 7));
    }
    controller.close();
    return http.StreamedResponse(
      controller.stream,
      200,
      contentLength: 1, // 前置检查按声明（1 字节）通过——实际流超限由流式检查拦。
      headers: {'content-type': 'application/octet-stream'},
      request: request,
    );
  }
}

/// 响应头 contentLength 超上限 client（r19）：send 后即返回超限声明——下载器
/// 前置检查须在流消费前拒绝（不写盘）。
class _DeclaredOverLimitClient extends http.BaseClient {
  int _calls = 0;

  int get calls => _calls;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    _calls += 1;
    final controller = StreamController<List<int>>();
    controller.close();
    return http.StreamedResponse(
      controller.stream,
      200,
      contentLength: UpdateConfig.maxCompressedBytes + 1,
      headers: {'content-type': 'application/octet-stream'},
      request: request,
    );
  }
}

/// 流中途断连 client（r9）：首次 send 发部分块后抛异常（模拟服务端连接
/// 中途关闭）、第二次成功发完整 payload。
class _AbortStreamHttpClient extends http.BaseClient {
  static const payload = 'full-payload-content';
  int _calls = 0;

  /// 已发起的 send 次数（测试断言重试次数用）。
  int get callCount => _calls;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    _calls += 1;
    final controller = StreamController<List<int>>();
    if (_calls == 1) {
      // 发部分块后抛错（流中途断连）。
      controller.add('partial-'.codeUnits);
      controller.addError(const SocketException('connection reset'));
      controller.close();
    } else {
      controller.add(payload.codeUnits);
      controller.close();
    }
    return http.StreamedResponse(
      controller.stream,
      200,
      contentLength: payload.length,
      headers: {'content-type': 'application/octet-stream'},
      request: request,
    );
  }
}
