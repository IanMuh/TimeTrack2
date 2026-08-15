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
        HttpClient,
        HttpException,
        SocketException,
        TlsException,
        stderr;
import 'dart:math';

import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';

import '../../constants/update_config.dart';
import '../../utils/result.dart';
import '../../utils/sha256.dart';

/// 下载总字节数超上限（[UpdateConfig.maxCompressedBytes]，r19）。
///
/// **独立类型（r20）**：不复用 FormatException——`download()` 的
/// `on FormatException` 分支会把它固定映射为"下载地址非法"（误导排障）；
/// 单独捕获返回"更新包体积超上限"。永久性错误（不重试——重试同一 URL 结果
/// 不变）。
class DownloadSizeExceededException implements Exception {
  const DownloadSizeExceededException();
}

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
  /// "已关闭"失败文案（r23 类级常量——文件内 3 处复用，单点维护）。
  static const downloadClosedMessage = '下载器已关闭，请重新创建';

  UpdateDownloader({
    http.Client? httpClient,
    this._tempDirectory,
    int? retryCount,
    Duration? retryBaseDelay,
    int? maxBytes,
  }) : _http = httpClient ?? _defaultClient(),
       _ownsHttp = httpClient == null,
       _retryCount = retryCount ?? UpdateConfig.downloadRetryCount,
       _retryBaseDelay = retryBaseDelay ?? UpdateConfig.retryBaseDelay,
       // **下载总字节上限（r22 可注入）**：默认取配置常量；测试注入小值即可
       // 覆盖同一检查逻辑（免真实 200MB 写盘/哈希成本，与 retryCount/tempDirectory
       // 的注入模式一致）。
       _maxBytes = maxBytes ?? UpdateConfig.maxCompressedBytes;

  /// 默认底层 client（r20）：显式 `autoUncompress = false`——`Accept-Encoding:
  /// identity` 只是告知服务器、不保证禁用 dart:io 的自动解压（解压与否取决于
  /// 响应 `Content-Encoding` 头）。产物（zip/apk）本已压缩、二次压缩无意义；
  /// 禁用自动解压使流内字节 = 文件实际字节 = contentLength 口径一致（进度回调
  /// 不超 100%、DownloadResult.totalBytes 与清单 SHA-256 口径一致）。
  static http.Client _defaultClient() =>
      IOClient(HttpClient()..autoUncompress = false);

  final http.Client _http;

  /// 是否自建 http client（close 时释放；注入对象由调用方负责生命周期）。
  final bool _ownsHttp;

  /// 重试次数（默认取 [UpdateConfig.downloadRetryCount]；测试注入小值免真实等待）。
  final int _retryCount;

  /// 退避基时（默认取 [UpdateConfig.retryBaseDelay]；测试注入零延迟）。
  final Duration _retryBaseDelay;
  final Directory? _tempDirectory;

  /// 下载总字节上限（默认取 [UpdateConfig.maxCompressedBytes]；测试注入小值）。
  final int _maxBytes;

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
      return const AppFailure(downloadClosedMessage);
    }
    var attempt = 0;
    while (true) {
      // **重试间隙 close() 已触发（r10）**：下次尝试前重新检查——防对已关闭
      // client 发起 send（异常被兜底分支捕获返回误导性文案而非"已关闭"）。
      if (_closed) {
        return const AppFailure(downloadClosedMessage);
      }
      try {
        return AppSuccess(await _attemptDownload(url, onProgress: onProgress));
      } on SocketException {
        if (_closed) return const AppFailure(downloadClosedMessage);
        // 网络瞬时失败：重试或耗尽后失败。
        if (!_shouldRetry(attempt)) {
          return const AppFailure('下载失败（网络不可用），请稍后重试');
        }
      } on http.ClientException {
        if (_closed) return const AppFailure(downloadClosedMessage);
        if (!_shouldRetry(attempt)) {
          return const AppFailure('下载失败（网络不可用），请稍后重试');
        }
      } on TimeoutException {
        if (_closed) return const AppFailure(downloadClosedMessage);
        if (!_shouldRetry(attempt)) {
          return const AppFailure('下载超时，请稍后重试');
        }
      } on HttpException {
        if (_closed) return const AppFailure(downloadClosedMessage);
        // **瞬态 IO 异常（r9）**：dart:io 流式响应在连接中途被服务端关闭/
        // 协议错误时可能抛 HttpException/TlsException（http 包仅把 send 阶段
        // 与部分流中错误包装为 ClientException，其余透传）——纳入退避重试
        //（保证"总是返回 AppResult"契约 + 不逃逸到全局错误处理）。
        if (!_shouldRetry(attempt)) {
          return const AppFailure('下载失败（网络中断），请稍后重试');
        }
      } on TlsException {
        if (_closed) return const AppFailure(downloadClosedMessage);
        if (!_shouldRetry(attempt)) {
          return const AppFailure('下载失败（TLS 中断），请稍后重试');
        }
      } on StateError catch (e) {
        // **底层 client 强关归因（r22）**：close() 生命周期只覆盖重试间隙——
        // 若 close() 在 send/流传输中被调用，底层 client 强关可能抛
        // `StateError('Client is already closed')`（Error 非 Exception，会从
        // download() 逃逸破坏"恒返回 AppResult"契约）。与清单服务一致：仅
        // `_closed` 或消息匹配才归因"已关闭"；其它 StateError（编程错误）
        // rethrow（Error 不吞）。
        if (_closed || e.message.contains('already closed')) {
          return const AppFailure(downloadClosedMessage);
        }
        rethrow;
      } on HttpStatusException catch (e) {
        // 服务端明确拒绝（4xx/5xx）：不重试，文案带状态码（区别于瞬态网络）。
        return AppFailure('下载失败（HTTP ${e.statusCode}）');
      } on DownloadSizeExceededException {
        // 下载总字节数超上限（r19/r20）：永久性错误，不重试——文案精确（不复用
        // FormatException 的"地址非法"误导）。
        return const AppFailure('更新包体积超上限');
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

  /// 随机 hex 后缀（r14 防路径可预测——共享系统临时目录 TOCTOU 符号链接）。
  static final _random = Random.secure();
  static String _randomHex(int bytes) {
    final buffer = StringBuffer();
    for (var i = 0; i < bytes; i++) {
      buffer.write(_random.nextInt(256).toRadixString(16).padLeft(2, '0'));
    }
    return buffer.toString();
  }

  Future<DownloadResult> _attemptDownload(
    String url, {
    void Function(int receivedBytes, int? totalBytes)? onProgress,
  }) async {
    final file = File(
      '${_tempDirectory?.path ?? Directory.systemTemp.path}/timetrack-download-'
      '${DateTime.now().microsecondsSinceEpoch}'
      '-${_seq++}' // 自增后缀防同一微秒并发撞名覆盖
      '-${_randomHex(8)}', // **随机后缀（r14）**：防路径可预测（共享系统临时
      // 目录下恶意预创建同名符号链接的 TOCTOU 攻击）
    );
    final uri = Uri.parse(url);
    // **scheme/host 显式校验（r14/r16）**：Uri.parse 对非 http(s)（file:///ftp:///
    // 相对）宽松解析不抛——http.Request 构造或真实 IOClient 发送时抛
    // ArgumentError（Error 非 Exception，会逃逸破坏"恒返回 AppResult"契约）。
    // 另须校验 host：`Uri.parse('https://')`/`http:`（scheme-only）仍解析成功、
    // 但 dart:io HttpClient.openUrl 对空 host 抛 ArgumentError 同样逃逸——与
    // UpdateConfig.resolveManifestUrl 的既有校验保持一致（该函数已注明
    // `https://` 等无 host 需额外校验）。此处显式拦截。
    if ((uri.scheme != 'http' && uri.scheme != 'https') ||
        !uri.isAbsolute ||
        !uri.hasAuthority ||
        uri.host.isEmpty) {
      throw const FormatException('仅支持 http/https');
    }
    final request = http.Request('GET', uri);
    // **显式请求 identity 编码（r19）**：dart:io HttpClient 默认
    // autoUncompress=true——若服务器对产物加 `Content-Encoding: gzip`，流内
    // 是解压后字节（与清单 SHA-256 口径一致）而 contentLength 是压缩后大小，
    // 进度回调出现 received > totalBytes、DownloadResult.totalBytes 与真实文件
    // 字节数不一致。zip/apk 产物本已压缩、二次压缩无意义——显式 Accept-Encoding:
    // identity 使 dart:io 不自动解压（该头被显式提供时 HttpClient 尊重客户端）。
    request.headers['accept-encoding'] = 'identity';
    // **下载超时边界（r11/r19）**：`Future.timeout` 不取消底层 send——超时后
    // 原始请求仍可能稍后返回 StreamedResponse，本方法已返回失败/进入重试、
    // 无法消费该迟到响应；连接由 http 包 idle 超时兜底回收（已知边界，慢网络
    // + 重试场景可堆积少量连接，属可接受权衡）。**独立超时常量（r19）**：响应
    // 头等待超时用 downloadHeaderTimeout 而非 checkTimeout（后者面向清单检查
    // 场景、8s 偏紧——大更新包服务器生成响应可能更慢）。
    final response = await _http
        .send(request)
        .timeout(UpdateConfig.downloadHeaderTimeout);
    // **4xx 不重试**（永久性错误）：抛专用异常，download() 直接失败带状态码。
    // 5xx 也先不重试（本模块传输层保守——调用方编排层可整体重试）。
    if (response.statusCode != 200) {
      // **立即取消订阅而非 drain（r22）**：drain() 会在后台把整个 4xx/5xx
      // body 读尽——无大小上限/超时（downloadStreamTimeout 仅作用于 200 路径），
      // 恶意/故障服务器超大或持续流式错误体时无限消耗带宽、长期占用连接且
      // future 无法中止（与 200 路径的体积/超时防护不对称）。listen 需 onError
      // 处理器防流错误成为未捕获异步异常；cancel 立即停止读取、释放连接。
      response.stream.listen(null, onError: (_) {}).cancel().ignore();
      throw HttpStatusException(response.statusCode);
    }
    // **下载总字节上限（r19）**：`downloadStreamTimeout` 只是相邻 chunk 间的
    // 空闲超时——恶意/被入侵服务器可持续以不触顶超时的速率流式发送，写满
    // 系统临时目录造成磁盘耗尽。**响应头前置检查**：contentLength 已知即先拒
    //（超限直接失败，不等流消费）；流式消费中累计 received 超过上限即中断
    //（覆盖无 Content-Length 的分块响应）。上限复用
    // [UpdateConfig.maxCompressedBytes]（与安装器"压缩后大小上限"同口径——
    // 传输层先于解压层拦截）。
    final declaredTotal = response.contentLength;
    if (declaredTotal != null && declaredTotal > _maxBytes) {
      // **取消订阅立即中止（r20）**：drain() 会把整个超限响应体下载完（本功能
      // 恰要防御恶意大响应——浪费带宽/占用连接）；listen(null).cancel() 立即
      // 停止消费、释放连接。
      response.stream.listen(null).cancel().ignore();
      throw const DownloadSizeExceededException();
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
      // **用 await for 而非 forEach（r19）**：forEach 回调内 throw 不进入返回
      // 的 future（逃逸为未捕获异步异常）——上限检查须在循环体（await for
      // 的异常正常传播）执行。
      await for (final chunk in response.stream.timeout(
        UpdateConfig.downloadStreamTimeout,
      )) {
        sink.add(chunk);
        received += chunk.length;
        shaBuilder.add(chunk);
        // **总字节上限流式检查（r19/r20）**：超出即中断下载（防分块响应无
        // Content-Length 时绕过前置检查写满磁盘）。**抛 DownloadSizeExceededException
        //（与前置检查同类型）而非 StateError（r19）**：StateError 是 Error 非
        // Exception——catch(_) rethrow 后 download() 的 `on Exception` 分类
        // 分支不匹配、直接从 download() 逃逸破坏"恒返回 AppResult"契约。
        if (received > _maxBytes) {
          throw const DownloadSizeExceededException();
        }
        // **onProgress 异常隔离（r14/r16）**：UI 层回调抛错不应归因下载失败/
        // 触发重试——只记录不中断；stderr 写自身保护（已关闭/管道断开时
        // writeln 再抛——包一层防逃逸，保"恒返回 AppResult"）。
        try {
          onProgress?.call(received, declaredTotal);
        } catch (e) {
          try {
            stderr.writeln('[update] 进度回调异常（忽略）：$e');
          } catch (_) {
            // 日志写入失败不影响下载。
          }
        }
      }
      await sink.close();
      closed = true;
      // **实收字节校验（r 修复）**：Content-Length 声明与实收不符时流结束可能
      // 不抛错（连接过早 EOF 未被 dart:io 判异常、或自定义 client 实现差异）——
      // 静默返回截断文件会让调用方拿到错误 totalBytes 与 SHA-256。声明值与实收
      // 不一致即抛 HttpException（走既有清理/重试路径）；-1（自定义 client 未知
      // 大小）跳过校验。
      if (declaredTotal != null &&
          declaredTotal >= 0 &&
          received != declaredTotal) {
        throw HttpException(
          'Content-Length（$declaredTotal）与实际接收字节（$received）不一致',
        );
      }
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
