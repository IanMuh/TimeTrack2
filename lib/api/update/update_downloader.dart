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

import 'package:http/http.dart' as http;

import '../../constants/update_config.dart';
import '../../utils/result.dart';
import '../../utils/sha256.dart';

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
    int? retryCount,
    Duration? retryBaseDelay,
  })  : _http = httpClient ?? http.Client(),
        _retryCount = retryCount ?? UpdateConfig.downloadRetryCount,
        _retryBaseDelay = retryBaseDelay ?? UpdateConfig.retryBaseDelay {
    _tempDirectory = tempDirectory;
  }

  final http.Client _http;
  /// 重试次数（默认取 [UpdateConfig.downloadRetryCount]；测试注入小值免真实等待）。
  final int _retryCount;
  /// 退避基时（默认取 [UpdateConfig.retryBaseDelay]；测试注入零延迟）。
  final Duration _retryBaseDelay;
  late final Directory? _tempDirectory;
  /// 临时文件名自增后缀（防同一微秒并发下载撞名覆盖）。
  int _seq = 0;

  /// 下载 [url] 到临时目录；失败返回可读原因。
  ///
  /// [onProgress] 每块回调（receivedBytes, totalBytes；totalBytes 未知为 null）。
  /// 内部自动重试网络瞬时失败（指数退避 [UpdateConfig.downloadRetryCount] 次）；
  /// **校验失败不重试**（调用方 `UpdateVerifier` 判定后删重下，见配置
  /// `redownloadAfterVerificationFailure`——语义分层，这里只管传输）。
  /// **非网络异常（非法 URL/本地写盘失败）直接失败不重试**（重试无意义）。
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
      } on HttpStatusException catch (e) {
        // 服务端明确拒绝（4xx/5xx）：不重试，文案带状态码（区别于瞬态网络）。
        return AppFailure('下载失败（HTTP ${e.statusCode}）');
      } on FileSystemException {
        // 本地写盘失败（目录不可写/磁盘满）：重试无意义，直接失败。
        return const AppFailure('下载写入失败，请检查磁盘空间后重试');
      } on FormatException {
        // 非法 URL。
        return const AppFailure('下载地址非法');
      }
      attempt += 1;
      await Future<void>.delayed(_retryDelay(attempt));
    }
  }

  /// 是否继续重试：attempt 从 0 计，重试次数上限 [_retryCount]。
  bool _shouldRetry(int attempt) => attempt < _retryCount;

  /// 指数退避：`base * 2^attempt`（attempt 从 1 计，首次重试等待 base）。
  Duration _retryDelay(int attempt) =>
      _retryBaseDelay * (1 << (attempt - 1));

  Future<DownloadResult> _attemptDownload(
    String url, {
    void Function(int receivedBytes, int? totalBytes)? onProgress,
  }) async {
    final file = File(
      '${_tempDirectory?.path ?? Directory.systemTemp.path}/timetrack-download-'
      '${DateTime.now().microsecondsSinceEpoch}'
      '-${_seq++}', // 自增后缀防同一微秒并发撞名覆盖
    );
    final request = http.Request('GET', Uri.parse(url));
    final response = await _http.send(request).timeout(UpdateConfig.checkTimeout);
    // **4xx 不重试**（永久性错误）：抛专用异常，download() 直接失败带状态码。
    // 5xx 也先不重试（本模块传输层保守——调用方编排层可整体重试）。
    if (response.statusCode != 200) {
      // **消费/取消响应体（r2，r3 ignore）**：不读取则 dart:io 连接不归还连接池
      // ——反复 4xx/5xx 会堆积占用连接。`.ignore()` 防 drain 过程中流错误成为
      // 未捕获的异步异常（Flutter 全局错误/测试直接失败）；异步进行、不阻塞抛错。
      response.stream.drain<void>().ignore();
      throw HttpStatusException(response.statusCode);
    }
    final sink = file.openWrite();
    var received = 0;
    // 复用共享的增量哈希累积器（Sha256Sink，单一事实来源——与 sha256Stream
    // 同一算法实现，防哈希细节在两侧漂移）。
    final shaBuilder = Sha256Sink();
    var closed = false;
    try {
      // **流读取超时**：响应头已返回但流挂起/断流不报错会无限等待——
      // 给整个流消费过程设独立超时（.timeout 包住 await for 的 future）。
      await response.stream.timeout(UpdateConfig.downloadStreamTimeout).forEach(
            (chunk) {
              sink.add(chunk);
              received += chunk.length;
              shaBuilder.add(chunk);
              onProgress?.call(received, response.contentLength);
            },
          );
      await sink.close();
      closed = true;
    } catch (_) {
      // 写入失败/流中断：sink 只关一次（关闭自身抛错不掩盖原始错误），
      // 删除半成品，重试或失败由外层处理。
      if (!closed) {
        try {
          await sink.close();
        } catch (_) {
          // close 抛错：忽略，原始错误优先。
        }
      }
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

/// 服务端非 200 状态（区别于瞬态网络异常——不重试）。
class HttpStatusException implements Exception {
  const HttpStatusException(this.statusCode);

  final int statusCode;
}

