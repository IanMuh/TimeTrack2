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
