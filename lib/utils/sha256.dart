/// SHA-256 工具：更新系统下载校验（与 update.json 内嵌 sha256 比对）。
library;

import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart' as crypto;

/// 计算字节数组的 SHA-256（hex 小写）。
String sha256Bytes(List<int> bytes) {
  return crypto.sha256.convert(bytes).toString();
}

/// 计算文件流的 SHA-256（hex 小写）；分块读取避免整文件载入内存。
///
/// [onProgress] 可选回调（累计已读字节数 + 文件总字节数，供下载进度计算）；
/// 进入读取前先回调一次 `(0, total)`（空文件时调用方也能初始化进度 UI），
/// 之后每读一块回调一次；文件打开/读取失败抛 [FileSystemException]
/// （converter 在 finally 中关闭）。
Future<String> sha256File(
  String path, {
  void Function(int bytesRead, int totalBytes)? onProgress,
}) async {
  final file = File(path);
  final total = await file.length();
  final collector = _DigestCollector();
  final converter = crypto.sha256.startChunkedConversion(collector);
  var bytesRead = 0;
  try {
    onProgress?.call(0, total);
    await for (final chunk in file.openRead()) {
      converter.add(chunk);
      bytesRead += chunk.length;
      onProgress?.call(bytesRead, total);
    }
  } finally {
    // 无论成功/异常都关闭 converter（回调异常同样走 finally），保证哈希流状态完整。
    converter.close();
  }
  return collector.digest!.toString();
}

/// 计算**任意字节流**的 SHA-256（hex 小写）——供"下载流边收边算"场景
///（下载写临时文件的同时累计哈希，校验环节免二次读盘）。
///
/// 消费完 [stream]（含关闭）后返回；[stream] 中途出错（Error/异常）时
/// 错误向上传播（converter 在 finally 中关闭，哈希状态完整）。
Future<String> sha256Stream(Stream<List<int>> stream) async {
  final collector = _DigestCollector();
  final converter = crypto.sha256.startChunkedConversion(collector);
  try {
    await for (final chunk in stream) {
      converter.add(chunk);
    }
  } finally {
    converter.close();
  }
  return collector.digest!.toString();
}

/// 增量 SHA-256 累积器（**单一事实来源**）：`sha256Stream` 与下载器
///（边写文件边算哈希）共用同一累积逻辑——哈希算法细节集中一处，防漂移。
///
/// 用法：逐块 [add]；全部完成后 [digest]（幂等，重复调用返回同一值）。
class Sha256Sink {
  final _collector = _DigestCollector();
  late final ByteConversionSink _converter;
  bool _closed = false;

  Sha256Sink() {
    _converter = crypto.sha256.startChunkedConversion(_collector);
  }

  /// 累计一块数据。
  void add(List<int> chunk) => _converter.add(chunk);

  /// 结束累积并返回 hex 小写摘要。**幂等（r2）**：显式 `_closed` 标志保证
  /// 只 close 一次——不依赖底层 sink 对重复 close 的处理（Sink.close 契约是
  /// 恰好一次）。
  String digest() {
    if (!_closed) {
      _converter.close();
      _closed = true;
    }
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

/// 计算字符串的 SHA-256（hex 小写），UTF-8 编码。
String sha256String(String text) {
  return sha256Bytes(utf8.encode(text));
}
