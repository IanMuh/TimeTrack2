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

    test('StateError 消息匹配（already closed）→ 归因"已关闭"（r23）', () async {
      // r22 新增的 `on StateError` 归因分支（与清单服务同款模式）——`_closed`
      // 为 false 但底层 client 被外部强关抛 `StateError('Client is already
      // closed')`：按消息匹配返回可读失败而非 rethrow。
      final dir = await Directory.systemTemp.createTemp('dl_stateerr');
      final downloader = UpdateDownloader(
        tempDirectory: dir,
        httpClient: MockClient(
          (_) async => throw StateError('Client is already closed'),
        ),
      );
      try {
        final result = await downloader.download('https://x.example/app.zip');
        expect(result.isSuccess, isFalse);
        expect(
          result.when(onSuccess: (_) => '', onFailure: (m) => m),
          contains('已关闭'),
          reason: '消息匹配归因已关闭',
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

    test('下载总字节上限（r19/r20）：声明超限前置拒绝 / 分块流超限流式中断且无残留', () async {
      final dir = await Directory.systemTemp.createTemp('dl_cap');
      // **注入小上限（r22/r23）**：maxBytes 可注入——免真实 200MB 写盘/哈希
      // 成本（与 retryCount/tempDirectory 注入模式一致）。**默认配置值不再被
      // 任何用例覆盖**（本文件所有字节上限用例均注入）——默认值本身由
      // update_config.dart 常量注释与代码评审守护。
      const smallCap = 1024 * 1024; // 1 MB
      try {
        // 场景 A：响应头 contentLength 超上限 → send 后立即前置拒绝（不写盘）。
        final declaredOver = _DeclaredOverLimitClient(smallCap);
        final downloaderA = UpdateDownloader(
          tempDirectory: dir,
          retryCount: 3,
          maxBytes: smallCap,
          httpClient: declaredOver,
        );
        final resultA = await downloaderA.download('https://x.example/app.zip');
        expect(resultA.isSuccess, isFalse, reason: '声明超限失败');
        // **精确文案（r20）**：独立异常类型返回"体积超上限"——不复用
        // FormatException 的"下载地址非法"误导。
        expect(
          resultA.when(onSuccess: (_) => '', onFailure: (m) => m),
          contains('体积超上限'),
          reason: '超限文案精确（非"地址非法"）',
        );
        expect(declaredOver.calls, 1, reason: '4xx/超限不重试');
        // 场景 B：分块流实际超限（声明 contentLength 小、实际持续发送）→
        // 流式累计检查中断下载、半成品清理、无残留。
        final downloaderB = UpdateDownloader(
          tempDirectory: dir,
          retryCount: 0,
          maxBytes: smallCap,
          httpClient: _OversizeChunkedHttpClient(smallCap),
        );
        final resultB = await downloaderB.download('https://x.example/app.zip');
        expect(resultB.isSuccess, isFalse, reason: '分块流超限失败');
        // **场景 B 同为 DownloadSizeExceededException 路径（r21）**：流式检查
        // 独立代码路径——文案同样须精确（防回归为 FormatException"地址非法"）。
        expect(
          resultB.when(onSuccess: (_) => '', onFailure: (m) => m),
          contains('体积超上限'),
          reason: '分块流超限文案精确（非"地址非法"）',
        );
        expect(dir.listSync(), isEmpty, reason: '超限中断后半成品已清理（无残留）');
      } finally {
        await dir.delete(recursive: true);
      }
    });

    test('下载总字节上限边界（r22）：恰好等于上限成功（注入小上限）', () async {
      // 上限语义为"严格大于才拒绝"——恰好等于上限的合法包须放行（防未来误把
      // 等值判为超限的回归无感知）。**注入小上限**：免真实 200MB 写盘/哈希。
      const cap = 1024 * 1024; // 1 MB
      final dir = await Directory.systemTemp.createTemp('dl_cap_boundary');
      final downloader = UpdateDownloader(
        tempDirectory: dir,
        maxBytes: cap,
        httpClient: _AtLimitClient(cap),
      );
      try {
        final result = (await downloader.download(
          'https://x.example/app.zip',
        )).requireValue();
        expect(result.totalBytes, cap, reason: '恰好等于上限下载成功');
        final file = File(result.filePath);
        expect(file.lengthSync(), cap);
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

    test('verifier 透传下载阶段失败（r22）：网络异常不重试校验、返回下载器文案', () async {
      // downloadAndVerify 对下载失败（AppFailure）直接透传消息——无校验重下
      //（下载器内部网络重试已耗尽）。
      final dir = await Directory.systemTemp.createTemp('verify_netfail');
      var calls = 0;
      final artifact = UpdatePlatformArtifact(
        url: 'https://x.example/app.zip',
        sha256: 'a' * 64,
      );
      try {
        final verifier = UpdateVerifier(
          downloader: UpdateDownloader(
            tempDirectory: dir,
            retryCount: 2,
            retryBaseDelay: Duration.zero,
            httpClient: MockClient((_) async {
              calls += 1;
              throw http.ClientException('reset');
            }),
          ),
        );
        final result = await verifier.downloadAndVerify(artifact);
        expect(result.isSuccess, isFalse, reason: '下载失败透传');
        // **完整文案等值断言（r23）**：downloadAndVerify 对 AppFailure 原样
        // `AppFailure(failure.message)` 透传——断言完整文案锁住"透传下载器
        // 原文"（contains('网络不可用') 过弱：verifier 自行生成泛化文案也能
        // 通过）。
        expect(
          result.when(onSuccess: (_) => '', onFailure: (m) => m),
          '下载失败（网络不可用），请稍后重试',
          reason: '透传下载器原文',
        );
        expect(calls, 3, reason: '仅下载器内部重试（初始 + 2），无校验重下');
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

/// 分块流总字节数超上限 client（r19/r20/r22）：声明 contentLength 为小值、
/// 实际分块超上限持续发送（模拟无 Content-Length 的分块响应绕过前置检查）。
/// **async* 惰性逐块生成（r20）**：订阅前不缓存全部块（StreamController 在
/// 监听前 add 会全量缓冲）——消费一块产出一块，下载器超限中断（抛
/// DownloadSizeExceededException）取消订阅后生成器随之停止；**上限可注入
/// （r22）**：按注入上限动态推导块数（测试用 1MB 免真实 200MB 写盘/哈希成本，
/// 防常量上调后用例静默失效）。
class _OversizeChunkedHttpClient extends http.BaseClient {
  _OversizeChunkedHttpClient(this.cap);

  final int cap;

  /// 惰性逐块生成：超过 cap 一个额外块（1MB）。
  Stream<List<int>> _oversizeChunks() async* {
    final chunkCount = (cap ~/ (1024 * 1024)) + 2;
    for (var i = 0; i < chunkCount; i++) {
      yield List<int>.filled(1024 * 1024, 7);
    }
  }

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    return http.StreamedResponse(
      _oversizeChunks(),
      200,
      contentLength: 1, // 前置检查按声明（1 字节）通过——实际流超限由流式检查拦。
      headers: {'content-type': 'application/octet-stream'},
      request: request,
    );
  }
}

/// 恰好等于上限 client（r20/r21）：contentLength 与总字节均恰为
/// maxCompressedBytes——上限语义"严格大于才拒绝"，等值必须成功。
/// **惰性逐块生成（r21）**：单次 `List<int>.filled(200M)` 在 64 位 VM 按
/// 8B/int 约 1.6GB、StreamController 订阅前 add 全量缓冲——测试 OOM 风险；
/// 仿照 _OversizeChunkedHttpClient 按 1MB 惰性分块（contentLength 仍填总数）。
class _AtLimitClient extends http.BaseClient {
  _AtLimitClient(this.bytes);

  final int bytes;

  Stream<List<int>> _chunks() async* {
    var remaining = bytes;
    while (remaining > 0) {
      final size = remaining < 1024 * 1024 ? remaining : 1024 * 1024;
      yield List<int>.filled(size, 7);
      remaining -= size;
    }
  }

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    return http.StreamedResponse(
      _chunks(),
      200,
      contentLength: bytes,
      headers: {'content-type': 'application/octet-stream'},
      request: request,
    );
  }
}

/// 响应头 contentLength 超上限 client（r19/r22）：send 后即返回超限声明——
/// 下载器前置检查须在流消费前拒绝（不写盘）。上限可注入（测试用 1MB）。
class _DeclaredOverLimitClient extends http.BaseClient {
  _DeclaredOverLimitClient(this.cap);

  final int cap;
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
      contentLength: cap + 1,
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
