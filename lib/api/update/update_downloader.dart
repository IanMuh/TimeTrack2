/// 更新下载器：http **流式**下载到临时目录（进度回调）+ 指数退避重试。
///
/// 流程（计划"完整更新系统设计"·管线）：
/// 1. `GET url` → 流式读响应体，边收边写临时文件（按网络到达的 chunk 写盘，
///    与 [UpdateConfig.downloadStreamTimeout] 结合防挂起）；
/// 2. 每块回调 [onProgress]（已写字节数 / 总字节数；总大小未知时为 null）；
/// 3. 网络瞬时失败指数退避重试 [UpdateConfig.downloadRetryCount] 次；
/// 4. **边收边算 SHA-256**（[sha256Stream] 语义——下载流同时累计哈希，
///    校验环节免二次读盘）；写入完成后调用方自行校验。
///
/// 临时文件放系统临时目录，下载失败/校验失败由调用方删除（防残留）。
library;

import 'dart:async';
import 'dart:io'
    show
        Directory,
        File,
        FileSystemException,
        HttpException,
        SocketException,
        TlsException,
        stderr;

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
  }) : _http = httpClient ?? http.Client(),
       _ownsHttp = httpClient == null,
       _retryCount = retryCount ?? UpdateConfig.downloadRetryCount,
       _retryBaseDelay = retryBaseDelay ?? UpdateConfig.retryBaseDelay,
       _tempDirectory = tempDirectory;

  final http.Client _http;

  /// 是否自建 http client（close 时释放；注入对象由调用方负责生命周期）。
  final bool _ownsHttp;

  /// 重试次数（默认取 [UpdateConfig.downloadRetryCount]；测试注入小值免真实等待）。
  final int _retryCount;

  /// 退避基时（默认取 [UpdateConfig.retryBaseDelay]；测试注入零延迟）。
  final Duration _retryBaseDelay;
  final Directory? _tempDirectory;

  /// 临时文件名自增后缀（防同一微秒并发下载撞名覆盖）。
  int _seq = 0;

  /// 已关闭标记（close 后 download 明确拒绝——防已释放 client 抛异常逃逸）。
  bool _closed = false;

  /// 释放自建 http client（连接池/keep-alive 连接回收；注入对象由调用方负责）。
  void close() {
    if (_closed) return;
    _closed = true;
    if (_ownsHttp) {
      _http.close();
    }
  }

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
    if (_closed) {
      return const AppFailure('下载器已关闭，请重新创建');
    }
    var attempt = 0;
    while (true) {
      // **重试间隙 close() 已触发（r10）**：下次尝试前重新检查——防对已关闭
      // client 发起 send（异常被兜底分支捕获返回误导性文案而非"已关闭"）。
      if (_closed) {
        return const AppFailure('下载器已关闭，请重新创建');
      }
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
      } on HttpException {
        // **瞬态 IO 异常（r9）**：dart:io 流式响应在连接中途被服务端关闭/
        // 协议错误时可能抛 HttpException/TlsException（http 包仅把 send 阶段
        // 与部分流中错误包装为 ClientException，其余透传）——纳入退避重试
        //（保证"总是返回 AppResult"契约 + 不逃逸到全局错误处理）。
        if (!_shouldRetry(attempt)) {
          return const AppFailure('下载失败（网络中断），请稍后重试');
        }
      } on TlsException {
        if (!_shouldRetry(attempt)) {
          return const AppFailure('下载失败（TLS 中断），请稍后重试');
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
      } on Exception catch (e) {
        // **仅兜底 Exception（r10）**：Error（编程错误）不吞、交给全局错误
        // 处理暴露（掩盖真实 bug 会增排障难度）；文案脱敏（不拼 `$e`——可能
        // 含内部 URL/路径细节）。
        // **stderr 写自身保护（r12）**：stderr 已关闭/输出管道断开时 writeln
        // 会抛 FileSystemException——包一层防从兜底分支逃逸（破坏"恒返回
        // AppResult、不逃逸"契约）。
        try {
          stderr.writeln('[update] 下载未知异常：$e');
        } catch (_) {
          // 日志写入失败不影响失败结论。
        }
        return const AppFailure('下载失败，请稍后重试');
      }
      attempt += 1;
      await Future<void>.delayed(_retryDelay(attempt));
    }
  }

  /// 是否继续重试：attempt 从 0 计，重试次数上限 [_retryCount]。
  bool _shouldRetry(int attempt) => attempt < _retryCount;

  /// 指数退避：`base * 2^attempt`（attempt 从 1 计，首次重试等待 base）。
  Duration _retryDelay(int attempt) => _retryBaseDelay * (1 << (attempt - 1));

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
    // **超时边界（r9 注明）**：`Future.timeout` 不取消底层 send——超时后原始
    // 请求仍可能稍后返回 StreamedResponse，本方法已返回失败/进入重试、无法
    // 消费该迟到响应；连接由 http 包 idle 超时兜底回收（已知边界，慢网络 +
    // 重试场景可堆积少量连接，属可接受权衡）。
    final response = await _http
        .send(request)
        .timeout(UpdateConfig.checkTimeout);
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
