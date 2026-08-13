/// 更新下载器：http **流式**下载到临时目录（进度回调）+ 指数退避重试。
///
/// 流程（计划"完整更新系统设计"·管线）：
/// 1. `GET url` → 流式读响应体，边收边写临时文件（分块 [UpdateConfig.downloadChunkBytes]）；
/// 2. 每块回调 [onProgress]（已写字节数 / 总字节数；总大小未知时为 null）；
/// 3. 网络瞬时失败指数退避重试 [UpdateConfig.downloadRetryCount] 次；
/// 4. **边收边算 SHA-256**（[sha256Stream] 语义——下载流同时累计哈希，
///    校验环节免二次读盘）；写入完成后调用方自行校验。
///
/// 临时文件放系统临时目录，下载失败/校验失败由调用方删除（防残留）。
library;

import 'dart:async';
import 'dart:io' show Directory, File, FileSystemException, SocketException;

import 'package:crypto/crypto.dart' as crypto;
import 'package:http/http.dart' as http;

import '../../constants/update_config.dart';
import '../../utils/result.dart';

/// 下载结果。
class DownloadResult {
  const DownloadResult({
    required this.filePath,
    required this.totalBytes,
    required this.sha256,
  });

  /// 已写入的临时文件路径（含完整内容；校验由调用方负责）。
  final String filePath;

  /// 总字节数（服务端未提供 Content-Length 时为 null）。
  final int? totalBytes;

  /// 下载内容的 SHA-256（hex 小写，边收边算）。
  final String sha256;
}

/// 更新下载器。
class UpdateDownloader {
  UpdateDownloader({
    http.Client? httpClient,
    Directory? tempDirectory,
  })  : _http = httpClient ?? http.Client() {
    _tempDirectory = tempDirectory;
  }

  final http.Client _http;
  late final Directory? _tempDirectory;

  /// 下载 [url] 到临时目录；失败返回可读原因。
  ///
  /// [onProgress] 每块回调（receivedBytes, totalBytes；totalBytes 未知为 null）。
  /// 内部自动重试网络瞬时失败（指数退避 [UpdateConfig.downloadRetryCount] 次）；
  /// **校验失败不重试**（调用方 `UpdateVerifier` 判定后删重下，见配置
  /// `redownloadAfterVerificationFailure`——语义分层，这里只管传输）。
  Future<AppResult<DownloadResult>> download(
    String url, {
    void Function(int receivedBytes, int? totalBytes)? onProgress,
  }) async {
    var attempt = 0;
    while (true) {
      try {
        return AppSuccess(await _attemptDownload(url, onProgress: onProgress));
      } on SocketException {
        // 网络瞬时失败：重试或耗尽后失败。
        if (!_shouldRetry(attempt)) {
          return const AppFailure('下载失败（网络不可用），请稍后重试');
        }
      } on http.ClientException {
        if (!_shouldRetry(attempt)) {
          return const AppFailure('下载失败（网络不可用），请稍后重试');
        }
      } on TimeoutException {
        if (!_shouldRetry(attempt)) {
          return const AppFailure('下载超时，请稍后重试');
        }
      }
      attempt += 1;
      await Future<void>.delayed(_retryDelay(attempt));
    }
  }

  /// 是否继续重试：attempt 从 0 计，重试次数上限 [UpdateConfig.downloadRetryCount]。
  bool _shouldRetry(int attempt) => attempt < UpdateConfig.downloadRetryCount;

  /// 指数退避：`base * 2^attempt`（attempt 从 1 计，首次重试等待 base）。
  Duration _retryDelay(int attempt) =>
      UpdateConfig.retryBaseDelay * (1 << (attempt - 1));

  Future<DownloadResult> _attemptDownload(
    String url, {
    void Function(int receivedBytes, int? totalBytes)? onProgress,
  }) async {
    final file = File(
      '${_tempDirectory?.path ?? Directory.systemTemp.path}/timetrack-download-'
      '${DateTime.now().microsecondsSinceEpoch}',
    );
    final request = http.Request('GET', Uri.parse(url));
    final response = await _http.send(request).timeout(UpdateConfig.checkTimeout);
    if (response.statusCode != 200) {
      throw http.ClientException('HTTP ${response.statusCode}');
    }
    final sink = file.openWrite();
    var received = 0;
    var shaBuilder = _ChunkedSha256();
    try {
      await for (final chunk in response.stream) {
        sink.add(chunk);
        received += chunk.length;
        shaBuilder.add(chunk);
        onProgress?.call(received, response.contentLength);
      }
      await sink.close();
    } catch (_) {
      // 写入失败/流中断：关闭 sink 并删除半成品，重试或失败由外层处理。
      await sink.close();
      try {
        file.deleteSync();
      } on FileSystemException {
        // 删除失败不影响失败结论。
      }
      rethrow;
    }
    return DownloadResult(
      filePath: file.path,
      totalBytes: response.contentLength,
      sha256: shaBuilder.digest(),
    );
  }
}

/// 分块 SHA-256 累积器（复用 crypto 流式 API）。
class _ChunkedSha256 {
  final _collector = _DigestCollector();
  late final _converter =
      crypto.sha256.startChunkedConversion(_collector);

  void add(List<int> chunk) => _converter.add(chunk);

  String digest() {
    _converter.close();
    return _collector.digest!.toString();
  }
}

/// 收集流式哈希的最终 [crypto.Digest]。
class _DigestCollector implements Sink<crypto.Digest> {
  crypto.Digest? digest;

  @override
  void add(crypto.Digest data) {
    digest = data;
  }

  @override
  void close() {}
}
