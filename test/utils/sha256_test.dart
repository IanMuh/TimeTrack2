import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:timetrack2/utils/sha256.dart';

void main() {
  // 已知向量（RFC 6234 / 常见校验值）。
  group('sha256Bytes / sha256String', () {
    test('空字符串', () {
      expect(
        sha256String(''),
        'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855',
      );
    });

    test('abc', () {
      expect(
        sha256String('abc'),
        'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad',
      );
    });

    test('中文 UTF-8', () {
      expect(
        sha256String('你好'),
        '670d9743542cae3ea7ebe36af56bd53648b0a1126162e78d81a32934a711302e',
      );
    });
  });

  group('sha256File', () {
    Future<String> hashTempFile(List<int> data) async {
      final dir = await Directory.systemTemp.createTemp('sha256_test');
      try {
        final file = File('${dir.path}/sample.bin');
        await file.writeAsBytes(data);
        // 必须 await：finally 删除目录要在哈希完成后执行。
        return await sha256File(file.path);
      } finally {
        await dir.delete(recursive: true);
      }
    }

    test('文件内容哈希与字节哈希一致（分块读取）', () async {
      expect(await hashTempFile('abc'.codeUnits), sha256String('abc'));
    });

    test('空文件：零 chunk 也能正确最终化', () async {
      expect(await hashTempFile(const []), sha256Bytes(const []));
    });

    test('缓冲区边界：64KB ± 1（openRead 默认块大小）', () async {
      final size = 64 * 1024;
      for (final n in [size - 1, size, size + 1]) {
        final data = List<int>.generate(n, (i) => i % 251);
        expect(await hashTempFile(data), sha256Bytes(data),
            reason: '$n 字节应与一次性哈希一致');
      }
    });

    test('大文件多块读取正确（1.5 MiB 随机数据）', () async {
      final data = List<int>.generate(1572864, (i) => i % 251); // 1.5 MiB
      expect(await hashTempFile(data), sha256Bytes(data));
    });

    test('onProgress：累计字节数单调递增且最终值等于文件总长', () async {
      final dir = await Directory.systemTemp.createTemp('sha256_progress');
      try {
        final file = File('${dir.path}/p.txt');
        await file.writeAsString('progress data');
        final total = await file.length();
        final seen = <int>[];
        await sha256File(file.path, onProgress: (bytes, totalBytes) {
          seen.add(bytes);
          expect(totalBytes, total);
        });
        expect(seen, isNotEmpty);
        // 单调递增
        for (var i = 1; i < seen.length; i++) {
          expect(seen[i] >= seen[i - 1], isTrue);
        }
        expect(seen.last, total, reason: '最终回调应等于文件总长');
      } finally {
        await dir.delete(recursive: true);
      }
    });

    test('文件不存在 → 抛 FileSystemException', () async {
      final dir = await Directory.systemTemp.createTemp('sha256_missing');
      try {
        final missing = '${dir.path}/nope.bin';
        await expectLater(
          sha256File(missing),
          throwsA(isA<FileSystemException>()),
        );
      } finally {
        await dir.delete(recursive: true);
      }
    });
  });
}
