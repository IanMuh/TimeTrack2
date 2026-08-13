import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:timetrack2/utils/sha256.dart';

/// 'abc' 的 SHA-256 已知向量（RFC 6234）——多处用例共享，防向量调整漏改。
const _sha256Abc =
    'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad';

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
      expect(sha256String('abc'), _sha256Abc);
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
        expect(
          await hashTempFile(data),
          sha256Bytes(data),
          reason: '$n 字节应与一次性哈希一致',
        );
      }
    });

    test('大文件多块读取正确（1.5 MiB 随机数据）', () async {
      final data = List<int>.generate(1572864, (i) => i % 251); // 1.5 MiB
      expect(await hashTempFile(data), sha256Bytes(data));
    });

    test('onProgress：累计字节数单调递增且最终值等于文件总长（多块）', () async {
      final dir = await Directory.systemTemp.createTemp('sha256_progress');
      try {
        // 200KB > openRead 默认 64KB 块，确保至少触发多次回调
        final file = File('${dir.path}/p.bin');
        await file.writeAsBytes(List<int>.generate(200 * 1024, (i) => i % 251));
        final total = await file.length();
        final seen = <int>[];
        await sha256File(
          file.path,
          onProgress: (bytes, totalBytes) {
            seen.add(bytes);
            expect(totalBytes, total);
          },
        );
        expect(seen.length, greaterThan(1), reason: '多块应触发多次回调');
        // 首回调为 0（初始化），之后单调递增
        expect(seen.first, 0);
        for (var i = 1; i < seen.length; i++) {
          expect(seen[i] > seen[i - 1], isTrue);
        }
        expect(seen.last, total, reason: '最终回调应等于文件总长');
      } finally {
        await dir.delete(recursive: true);
      }
    });

    test('onProgress：空文件先回调 (0, 0) 初始化进度', () async {
      final dir = await Directory.systemTemp.createTemp(
        'sha256_empty_progress',
      );
      try {
        final file = File('${dir.path}/empty.bin');
        await file.writeAsBytes(const []);
        final seen = <(int, int)>[];
        await sha256File(
          file.path,
          onProgress: (bytes, totalBytes) {
            seen.add((bytes, totalBytes));
          },
        );
        expect(seen, [(0, 0)], reason: '空文件仅回调一次 (0, 0)');
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

  group('sha256Stream', () {
    test('与 sha256Bytes 一致（分块累积，含空流）', () async {
      final payload = List<int>.generate(100000, (i) => i % 251);
      expect(
        await sha256Stream(Stream.value(payload)),
        sha256Bytes(payload),
        reason: '单块流与字节数组哈希一致',
      );
      // 分块累积（模拟下载流逐块到达）。
      final chunks = <List<int>>[];
      for (var i = 0; i < payload.length; i += 7000) {
        chunks.add(
          payload.sublist(
            i,
            (i + 7000) < payload.length ? i + 7000 : payload.length,
          ),
        );
      }
      expect(
        await sha256Stream(Stream.fromIterable(chunks)),
        sha256Bytes(payload),
        reason: '分块流与整块哈希一致（分块不影响结果）',
      );
      expect(
        await sha256Stream(const Stream.empty()),
        sha256Bytes(const []),
        reason: '空流哈希',
      );
    });

    test('已知向量（abc）', () async {
      expect(await sha256Stream(Stream.value('abc'.codeUnits)), _sha256Abc);
    });

    test('Sha256Sink digest 幂等（r3）：重复调用不抛错且返回同一摘要', () {
      final sink = Sha256Sink()..add('abc'.codeUnits);
      final first = sink.digest();
      // 第二次调用不抛 StateError（显式 _closed 标志只 close 一次）、值一致。
      final second = sink.digest();
      expect(second, first);
      expect(first, _sha256Abc);
    });

    test('流中途出错：异常向上传播（下载流中断关键路径，r2）', () async {
      // 文档承诺"流中途出错时错误向上传播、converter 在 finally 中关闭"——
      // 下载流中断/网络异常时哈希状态完整、不泄漏。
      final controller = StreamController<List<int>>();
      controller
        ..add([1, 2, 3])
        ..addError(StateError('stream interrupted'))
        ..close();
      await expectLater(
        sha256Stream(controller.stream),
        throwsA(isA<StateError>()),
        reason: '中途错误向上传播',
      );
      // 错误后仍可用（converter 关闭不泄漏）：新流哈希与已知向量精确一致。
      expect(
        await sha256Stream(Stream.value('abc'.codeUnits)),
        _sha256Abc,
        reason: '错误后新流哈希仍与已知向量一致',
      );
    });

    test('零长度块与首块前出错（下载流强相关边界，r15）', () async {
      // HTTP chunked 传输可能产出空块——`sink.add([])` 不影响累积结果。
      expect(
        await sha256Stream(
          Stream.fromIterable(['ab'.codeUnits, const <int>[], 'c'.codeUnits]),
        ),
        _sha256Abc,
        reason: '零长度块不影响哈希',
      );
      // 首块数据前即出错（连接立即失败）——异常路径在空哈希状态也能正确关闭。
      final earlyFail = StreamController<List<int>>();
      earlyFail
        ..addError(const SocketException('connection refused'))
        ..close(); // 级联 close（r16）：错误 + 完成语义明确，控制器资源不泄漏。
      await expectLater(
        sha256Stream(earlyFail.stream),
        throwsA(isA<SocketException>()),
        reason: '首块前出错向上传播',
      );
    });
  });
}
