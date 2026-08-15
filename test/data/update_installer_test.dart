import 'dart:io';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:timetrack2/data/update/android_installer.dart';
import 'package:timetrack2/data/update/windows_installer.dart';

/// 构造内存 zip 字节（archive 包编码，测试用）。
List<int> buildZip(Map<String, String> files) {
  final archive = Archive();
  for (final entry in files.entries) {
    archive.addFile(ArchiveFile.string(entry.key, entry.value));
  }
  return ZipEncoder().encode(archive);
}

void main() {
  group('WindowsInstaller', () {
    test('programDir 合理性校验（r23/r24）：危险路径构造抛 ArgumentError', () {
      // r23 防御核心：applyStaging/_clearProgramDir 递归清空 programDir——
      // 误配为空/相对/根/含 `..` 段会复制整棵目录树/递归清空根目录（不可恢复
      // 大范围数据丢失）。**构造内 throw（release 构建 assert 被剥离仍生效）**。
      // r24：`C:\\`（连续分隔符，`\1` 字面量替换 bug 修复前会绕过）、`C:\ `
      //（尾部空格折叠）、`C:\foo\..\..`（`..` 段解析为盘根）均须拒绝。
      for (final evil in [
        '',
        'relative/path',
        '/',
        r'\',
        r'C:\',
        r'C:\\', // 连续分隔符（r24：\1/$1 字面量替换 bug 会绕过根判定）
        r'C:\ ', // 尾部空格折叠为 C:\
        r'C:\foo\..\..', // .. 段解析为盘根
        r'C:\..\..\',
        r'C:\foo\..', // r25：`..` 恰为末段——先整体裁尾点会吞掉它（解析为盘根）
        '/foo/..', // r25：同上（POSIX 形态，解析为 /）
        r'C:\foo\.. \.. \Windows', // r25：段内尾部空格变体（解析为 C:\Windows）
        r'C:\foo\.. ', // r26：末段带尾空格（r25 重排序的核心动机用例）
        r'C:\foo\...', // r26：Win32 折叠为 ..（整体裁尾会放行）
        r'C:\foo\.. .', // r26：交错变体（折叠为 ..）
        r'C:\.\', // r26：解析为盘根（rootNorm 循环折叠兜底）
        r'\\?\C:\', // r26：verbatim 命名空间前缀（折叠后 \\? → \? 绕过根判定）
        r'\\.\C:\', // r26：设备命名空间前缀
        '//?/C:\\', // r27：正斜杠 verbatim 形式（Win32 统一规范化为 \）
        '//./C:\\', // r27：正斜杠设备形式
        '///?/C:\\', // r28：多余前导分隔符
        '//?\\C:\\', // r28：混合分隔符
        '\\\\?/C:\\', // r28：混合分隔符（规范化后恰构成 \\?\）
        '\\\\./C:\\', // r28：混合分隔符（规范化后恰构成 \\.\）
      ]) {
        expect(
          () => WindowsInstaller(programDir: evil, dataDir: '/data'),
          throwsArgumentError,
          reason: '危险 programDir 拒绝：$evil',
        );
      }
      // 合法绝对路径放行（构造不抛）。
      for (final ok in [
        r'C:\Program Files\TimeTrack',
        '/opt/timetrack',
        r'C:\app\.\bin', // 含 `.` 段（仅 `..` 段拒绝；`.bin` 非完整段）
        r'C:\foo\bar',
        '//server/share/app', // r28/r29：普通 UNC 不误伤（?/. 后跟非分隔符）
        r'\\server\share\app', // r29：反斜杠 UNC 形式
        '/./foo', // r29：单前导分隔符 + . 段是普通相对段（非命名空间前缀）
        r'\.\foo', // r29：单前导分隔符 + . 段（Windows 当前目录相对）
      ]) {
        expect(
          () => WindowsInstaller(programDir: ok, dataDir: '/data'),
          returnsNormally,
          reason: '合法 programDir 放行：$ok',
        );
      }
    });

    test('staging 目录名校验（r16/r17 纯函数）：空/`.`/`..`/分隔符/尾部空格点号裁剪变体拒绝', () {
      // WindowsInstaller.stagingNameError 纯函数——防 `$programDir/<名>` 解析
      // 到 programDir 本身（`.`/裁剪后 `.`）或其父目录（`..`）时下方
      // deleteSync(recursive) 灾难性递归删除。**r17**：Win32 CreateDirectory
      // 同时裁剪尾部空格与点号（可交错），尾部点号变体同样折叠回 programDir/
      // 其父目录——须循环折叠裁剪（trimRight 只裁空白会漏）；**r18**：折叠
      // 途中遇 `.`/`..` 即停（特殊目录名保留折叠目标，不继续裁成空串）。
      for (final evil in [
        '',
        ' ',
        '.',
        '..',
        '. ',
        '.. ',
        '...', // r18：尾部点号变体（遇 '.'/'..' 停，折叠为 '..'）
        '. .', // → '.'
        '.. .', // → '..'
        '... ', // 点+空格交错 → '..'
        ' . ', // → ''
        '... . ..', // → '..'
        'staging/x',
        r'staging\x',
        'staging ', // 尾部空格（Win32 规范化后目录名失配）
        'staging.', // 尾部点号（同上）
        ' update-staging ', // 前后空格（规范化后名不一致）
      ]) {
        expect(
          WindowsInstaller.stagingNameError(evil),
          isNotNull,
          reason: 'staging 目录名非法（灾难性路径）拒绝：$evil',
        );
      }
      for (final ok in ['staging', '.update-staging']) {
        expect(
          WindowsInstaller.stagingNameError(ok),
          isNull,
          reason: '合法 staging 目录名放行：$ok',
        );
      }
      // **折叠目标精确锁定（r18）**：isNotNull 无法区分「折叠为 '.'/'..' 命中
      // 特殊目录名分支」与「折叠为空串命中空分支」——若 r18 的 break 被移除
      //（回退到 r17 全裁行为）`'...'`/`'... '` 会走空分支而 isNotNull 依然
      // 成立、死代码回归无感知。逐用例锁定错误消息。
      final toDotOrDotDot = {
        '...': '..', // 裁点 → '..'（break）
        '. .': '.', // 裁空格 → '.'（break）
        '.. .': '..', // 裁点 → '.. ' → 裁空格 → '..'（break）
        '... ': '..', // 裁空格 → '...' → '..'（break）
        '. ': '.', // 裁空格 → '.'（break）
        '... . ..': '..', // 连续裁点 → '..'（break）
      };
      for (final entry in toDotOrDotDot.entries) {
        final err = WindowsInstaller.stagingNameError(entry.key);
        expect(err, isNotNull, reason: '${entry.key} 非法');
        expect(
          err,
          contains('裁剪后为 `.`/`..`'),
          reason: '${entry.key} 折叠为 ${entry.value}，须命中特殊目录名分支而非空分支',
        );
      }
      // 纯空白/点号折叠为空串 → 命中「裁剪后为空」分支（另一死代码分支锁定）。
      for (final toEmpty in [' ', ' . ']) {
        final err = WindowsInstaller.stagingNameError(toEmpty);
        expect(err, isNotNull, reason: '$toEmpty 非法');
        expect(err, contains('裁剪后为空'), reason: '$toEmpty 折叠为空串，须命中空分支');
      }
    });

    test('zip 解压 staging：文件落位（zip-slip 防护放行合法路径）', () async {
      final root = await Directory.systemTemp.createTemp('win_stage');
      final program = Directory('${root.path}/program')..createSync();
      final data = Directory('${root.path}/data')..createSync();
      final zipPath = '${root.path}/pkg.zip';
      File(zipPath).writeAsBytesSync(
        buildZip({
          'app.exe': 'binary',
          'libs/foo.dll': 'lib-content',
          'data/config.json': '{}',
        }),
      );
      try {
        final installer = WindowsInstaller(
          programDir: program.path,
          dataDir: data.path,
        );
        final staging = (await installer.prepareStaging(
          zipPath,
        )).requireValue();
        expect(File('$staging/app.exe').readAsStringSync(), 'binary');
        expect(File('$staging/libs/foo.dll').readAsStringSync(), 'lib-content');
        expect(File('$staging/data/config.json').readAsStringSync(), '{}');
        expect(
          File('$staging/../app.exe').existsSync(),
          isFalse,
          reason: '文件只落在 staging 内',
        );
      } finally {
        await root.delete(recursive: true);
      }
    });

    test('zip-slip 防护：`../` 路径穿越条目拒绝（不写入 staging 外）', () async {
      final root = await Directory.systemTemp.createTemp('win_slip');
      final program = Directory('${root.path}/program')..createSync();
      final data = Directory('${root.path}/data')..createSync();
      final zipPath = '${root.path}/evil.zip';
      File(zipPath).writeAsBytesSync(
        buildZip({
          '../evil.txt': 'evil', // 路径穿越
          'ok.txt': 'ok',
        }),
      );
      try {
        final installer = WindowsInstaller(
          programDir: program.path,
          dataDir: data.path,
        );
        final result = await installer.prepareStaging(zipPath);
        expect(result.isSuccess, isFalse, reason: '路径穿越条目拒绝');
        // staging 之外无写入
        expect(File('${root.path}/evil.txt').existsSync(), isFalse);
        expect(File('${root.path}/program/../evil.txt').existsSync(), isFalse);
      } finally {
        await root.delete(recursive: true);
      }
    });

    test('zip-slip 防护：绝对路径条目拒绝', () async {
      final root = await Directory.systemTemp.createTemp('win_abs');
      final program = Directory('${root.path}/program')..createSync();
      final data = Directory('${root.path}/data')..createSync();
      final zipPath = '${root.path}/abs.zip';
      File(zipPath).writeAsBytesSync(
        buildZip({
          '/tmp/evil.txt': 'evil', // 绝对路径
        }),
      );
      try {
        final installer = WindowsInstaller(
          programDir: program.path,
          dataDir: data.path,
        );
        expect(
          (await installer.prepareStaging(zipPath)).isSuccess,
          isFalse,
          reason: '绝对路径条目拒绝',
        );
      } finally {
        await root.delete(recursive: true);
      }
    });

    test('zip-slip 防护：Windows 盘符路径 / 反斜杠穿越条目拒绝（r2）', () async {
      // 反斜杠分隔（Windows 压缩工具常见）与盘符路径是 _isUnsafePath 归一化
      // 的唯一防线——一旦归一化被误删，这些穿越会写出 staging。
      final root = await Directory.systemTemp.createTemp('win_bs');
      final program = Directory('${root.path}/program')..createSync();
      final data = Directory('${root.path}/data')..createSync();
      try {
        final installer = WindowsInstaller(
          programDir: program.path,
          dataDir: data.path,
        );
        for (final (i, evil) in [
          r'..\evil.txt', // 反斜杠穿越
          r'\evil.txt', // 反斜杠绝对路径
          'C:/evil.txt', // 盘符绝对路径
          'C:\\evil.txt',
          'C:evil.txt', // 盘符相对路径
          '../../evil.txt', // 多级穿越
          'a/../../evil.txt', // 嵌套穿越
          '.. /evil.txt', // 尾部空格规范化绕过（Win32 去除组件尾部空格 → `..`）
          '. ./evil.txt', // 尾部空格 → `.`
          'a/.. ./b.txt', // 段内尾部空格（非首段）
          'NUL', // 保留设备名
          'CON.txt',
          'COM1',
          'CON .txt', // 设备名+空格+扩展名绕过（Win32 裁剪主名尾部空格 → CON.txt）
          'CON  .txt',
          'CON::\$DATA', // ADS 冒号形式（r13：解析为 CON 设备访问）
          'NUL:\$DATA',
          'foo.txt:evil', // 扩展名段冒号（NTFS 备用数据流）
          'conin\$', // 控制台句柄（r13：小写变体——大小写不敏感须拒绝）
          'conout\$',
          'CONIN\$',
          'CONOUT\$',
          'nul', // 小写设备名（正则 caseSensitive:false）
          'com1',
        ].indexed) {
          final zipPath = '${root.path}/evil$i.zip';
          File(zipPath).writeAsBytesSync(buildZip({evil: 'evil'}));
          final result = await installer.prepareStaging(zipPath);
          expect(result.isSuccess, isFalse, reason: '非法路径条目拒绝：$evil');
          // 失败后 staging 已清理、program 目录无残留（穿越落点在
          // program/evil.txt 等——直接断言 program 目录干净最可靠）。
          expect(program.listSync(), isEmpty, reason: '$evil 失败后无残留文件写出');
        }
      } finally {
        await root.delete(recursive: true);
      }
    });

    test('混合包：合法条目先解压 + 恶意条目 → 整体失败且已解压文件被清理（r2）', () async {
      final root = await Directory.systemTemp.createTemp('win_mixed');
      final program = Directory('${root.path}/program')..createSync();
      final data = Directory('${root.path}/data')..createSync();
      final zipPath = '${root.path}/mixed.zip';
      File(zipPath).writeAsBytesSync(
        buildZip({
          'ok.txt': 'ok',
          r'..\evil.txt': 'evil', // 合法条目后的恶意条目
        }),
      );
      try {
        final installer = WindowsInstaller(
          programDir: program.path,
          dataDir: data.path,
        );
        final result = await installer.prepareStaging(zipPath);
        expect(result.isSuccess, isFalse, reason: '混合包整体拒绝');
        // 已解压的 ok.txt 不残留（失败清理）
        expect(
          Directory('${program.path}/staging').existsSync(),
          isFalse,
          reason: '失败后 staging 已清理（含已解压合法文件）',
        );
        expect(program.listSync(), isEmpty);
      } finally {
        await root.delete(recursive: true);
      }
    });

    test('空 zip 包拒绝（防 applyStaging 清空程序目录成空壳，r2）', () async {
      final root = await Directory.systemTemp.createTemp('win_empty');
      final program = Directory('${root.path}/program')..createSync();
      final data = Directory('${root.path}/data')..createSync();
      final zipPath = '${root.path}/empty.zip';
      // 空 zip（无任何文件条目）。
      File(zipPath).writeAsBytesSync(ZipEncoder().encode(Archive()));
      try {
        final installer = WindowsInstaller(
          programDir: program.path,
          dataDir: data.path,
        );
        final result = await installer.prepareStaging(zipPath);
        expect(result.isSuccess, isFalse, reason: '空包拒绝');
        // staging 未残留（失败清理）
        expect(
          Directory('${program.path}/staging').existsSync(),
          isFalse,
          reason: '失败后 staging 已清理',
        );
      } finally {
        await root.delete(recursive: true);
      }
    });

    test('zip bomb 防护：声明超限（预检剪枝）+ 伪造声明（终检兜底，r11）', () async {
      final root = await Directory.systemTemp.createTemp('win_bomb');
      final program = Directory('${root.path}/program')..createSync();
      final data = Directory('${root.path}/data')..createSync();
      // 用较小体积（2 KB）覆盖两条上限分支（上限可注入为 1 KB）。
      final bombContent = List<int>.filled(2048, 7);
      try {
        final installer = WindowsInstaller(
          programDir: program.path,
          dataDir: data.path,
          maxUncompressedEntryBytes: 1024, // 注入小上限（1 KB < 2 KB）
          maxTotalUncompressedBytes: 4096,
        );
        // 场景 A：中央目录声明与实际解压均超限——预检剪枝（file.size > 上限）。
        final declaredPath = '${root.path}/declared.zip';
        File(declaredPath).writeAsBytesSync(
          ZipEncoder().encode(
            Archive()..addFile(
              ArchiveFile('bomb.bin', bombContent.length, bombContent),
            ),
          ),
        );
        expect(
          (await installer.prepareStaging(declaredPath)).isSuccess,
          isFalse,
          reason: '声明超限条目拒绝（预检）',
        );
        // 场景 B：**伪造声明**（元数据声明小、实际解压大）——篡改中央目录的
        // size 字段为小值。ZIP 中央目录条目固定区布局：签名(4) + 版本 made
        // by(2) + 版本 needed(2) + 标志(2) + 压缩方法(2) + 时间(2) + 日期(2)
        // + CRC(4) + 压缩后大小(4)，**uncompressed size 偏移 = 4+2+2+2+2+2+2+
        // 4+4 = 24**（r13 修正：原表达式多算一个 2，篡改落到"size 高 2 字节 +
        // 文件名长度"字段，测试走的是无关失败路径）。
        final forgedPath = '${root.path}/forged.zip';
        final forged = List<int>.from(
          ZipEncoder().encode(
            Archive()..addFile(
              ArchiveFile('bomb.bin', bombContent.length, bombContent),
            ),
          ),
        );
        var patched = false;
        for (var i = forged.length - 4; i >= 0 && !patched; i--) {
          if (forged[i] == 0x50 && // 'P'
              forged[i + 1] == 0x4b && // 'K'
              forged[i + 2] == 0x01 && // 中央目录签名
              forged[i + 3] == 0x02) {
            final sizeField = i + 24; // 相对中央目录条目起始 +24 = uncompressed size
            forged[sizeField] = 1; // 声明 1 字节（实际 2048）
            forged[sizeField + 1] = 0;
            forged[sizeField + 2] = 0;
            forged[sizeField + 3] = 0;
            patched = true;
          }
        }
        expect(patched, isTrue, reason: '成功篡改中央目录 size 字段（构造伪造场景）');
        File(forgedPath).writeAsBytesSync(forged);
        final forgedResult = await installer.prepareStaging(forgedPath);
        expect(forgedResult.isSuccess, isFalse, reason: '伪造声明（声明小实际大）经终检拒绝');
        // **失败原因精确断言（r13）**：须命中"实际解压后体积超上限"（终检）——
        // 排除预检（声明超限）或解析失败等无关路径（否则终检兜底缺失时用例
        // 仍通过、回归无感知）。
        final forgedMsg = forgedResult.when(
          onSuccess: (_) => '',
          onFailure: (m) => m,
        );
        expect(
          forgedMsg,
          contains('实际解压后体积超上限'),
          reason: '伪造声明须命中终检（非预检/解析失败）',
        );
        expect(
          Directory('${program.path}/staging').existsSync(),
          isFalse,
          reason: '失败后 staging 已清理',
        );
      } finally {
        await root.delete(recursive: true);
      }
    });

    test('zip bomb 防护：累计超限（多条目各低于单条目上限，r11）', () async {
      final root = await Directory.systemTemp.createTemp('win_bomb_total');
      final program = Directory('${root.path}/program')..createSync();
      final data = Directory('${root.path}/data')..createSync();
      final archive = Archive();
      // 4 个条目各 512 B（低于单条目上限 1 KB），累计 2 KB > 总上限 1 KB。
      for (var i = 0; i < 4; i++) {
        final content = List<int>.filled(512, i + 1);
        archive.addFile(ArchiveFile('f$i.bin', content.length, content));
      }
      final zipPath = '${root.path}/total.zip';
      File(zipPath).writeAsBytesSync(ZipEncoder().encode(archive));
      try {
        final installer = WindowsInstaller(
          programDir: program.path,
          dataDir: data.path,
          maxUncompressedEntryBytes: 1024,
          maxTotalUncompressedBytes: 1024, // 总上限 = 单条目上限（累计超）
        );
        final result = await installer.prepareStaging(zipPath);
        expect(result.isSuccess, isFalse, reason: '累计超限拒绝');
        expect(
          Directory('${program.path}/staging').existsSync(),
          isFalse,
          reason: '失败后 staging 已清理',
        );
      } finally {
        await root.delete(recursive: true);
      }
    });

    test('zip bomb 防护：条目数上限边界（恰好等于上限放行、超限拒绝，r16）', () async {
      // r16 修正：fileCount 曾双重自增导致实际生效上限约为配置值一半、恰好
      // 含 maxEntryCount 个文件的合法包被误拒——现按实际文件数计数。
      final root = await Directory.systemTemp.createTemp('win_count');
      final program = Directory('${root.path}/program')..createSync();
      final data = Directory('${root.path}/data')..createSync();
      try {
        // 恰好 2 个文件 == maxEntryCount(2) → 放行（双重自增时会被误拒为超限）。
        final atLimit = Archive();
        atLimit.addFile(ArchiveFile.string('a.txt', 'a'));
        atLimit.addFile(ArchiveFile.string('b.txt', 'b'));
        final okPath = '${root.path}/ok.zip';
        File(okPath).writeAsBytesSync(ZipEncoder().encode(atLimit));
        expect(
          (await WindowsInstaller(
            programDir: program.path,
            dataDir: data.path,
            maxEntryCount: 2,
          ).prepareStaging(okPath)).requireValue(),
          contains('${program.path}/'),
          reason: '恰好等于条目数上限的合法包放行',
        );
        // 3 个文件 > maxEntryCount(2) → 拒绝。
        final overLimit = Archive();
        for (var i = 0; i < 3; i++) {
          overLimit.addFile(ArchiveFile.string('f$i.txt', '$i'));
        }
        final noPath = '${root.path}/no.zip';
        File(noPath).writeAsBytesSync(ZipEncoder().encode(overLimit));
        expect(
          (await WindowsInstaller(
            programDir: program.path,
            dataDir: data.path,
            maxEntryCount: 2,
          ).prepareStaging(noPath)).isSuccess,
          isFalse,
          reason: '超过条目数上限拒绝',
        );
      } finally {
        await root.delete(recursive: true);
      }
    });

    test('zip bomb 防护：目录条目也计入条目数上限（r19）', () async {
      // r19 修正：只计文件条目会让"海量目录条目"包 fileCount 恒为 0——上限
      // 形同虚设。目录条目统一计数（检查位于任何 content 解压前）。
      // **覆盖边界（r20）**：本用例仅锁定"目录条目计入条目数"的计数语义；
      // decodeBytes 阶段的全量物化防护需流式解码（后续优化），不在本用例范围。
      final root = await Directory.systemTemp.createTemp('win_dircount');
      final program = Directory('${root.path}/program')..createSync();
      final data = Directory('${root.path}/data')..createSync();
      try {
        // 3 个目录条目 + 1 个文件 = 4 条 > maxEntryCount(3) → 拒绝。
        final dirHeavy = Archive();
        for (var i = 0; i < 3; i++) {
          dirHeavy.addFile(ArchiveFile('d$i/', 0, const <int>[])); // 目录条目
        }
        dirHeavy.addFile(ArchiveFile.string('f.txt', 'x'));
        final zipPath = '${root.path}/dirs.zip';
        File(zipPath).writeAsBytesSync(ZipEncoder().encode(dirHeavy));
        final result = await WindowsInstaller(
          programDir: program.path,
          dataDir: data.path,
          maxEntryCount: 3,
        ).prepareStaging(zipPath);
        expect(result.isSuccess, isFalse, reason: '目录条目计入条目数上限');
        // **拒绝原因精确锁定（r20）**：须命中"条目数超上限"而非其它失败
        //（路径校验/空包等无关路径——防实现退化为"不计数目录但仍因别的原因
        // 拒绝"时用例无声通过）。
        expect(
          result.when(onSuccess: (_) => '', onFailure: (m) => m),
          contains('条目数超上限'),
          reason: '目录条目计入条目数上限（拒绝原因精确断言）',
        );
      } finally {
        await root.delete(recursive: true);
      }
    });

    test('applyStaging：误传 programDir 本身 → 拒绝且未改动程序目录（r19）', () async {
      // r19 防御性校验：applyStaging 须严格接收 prepareStaging 返回的 staging
      // 路径。若误传 programDir 本身，旧逻辑会清空程序目录、renameSync 到自身
      // no-op、deleteSync 连备份一并删除并返回成功（不可恢复灾难）——现按
      // 规范化绝对路径校验直接拒绝。
      final root = await Directory.systemTemp.createTemp('win_misuse');
      final program = Directory('${root.path}/program')..createSync();
      final data = Directory('${root.path}/data')..createSync();
      File('${program.path}/app.exe').writeAsStringSync('old');
      final staging = Directory('${program.path}/staging')..createSync();
      File('${staging.path}/app.exe').writeAsStringSync('new');
      try {
        final installer = WindowsInstaller(
          programDir: program.path,
          dataDir: data.path,
        );
        final result = await installer.applyStaging(program.path);
        expect(result.isSuccess, isFalse, reason: '误传程序目录拒绝');
        expect(
          File('${program.path}/app.exe').readAsStringSync(),
          'old',
          reason: '程序目录未改动（未清空/未删除）',
        );
        // 残留 staging 目录在拒绝路径未被动过（仍存在，可正常安装）。
        expect(
          Directory('${program.path}/staging').existsSync(),
          isTrue,
          reason: '拒绝路径不清理 staging（调用方仍可修复后重试）',
        );
      } finally {
        await root.delete(recursive: true);
      }
    });

    test('applyStaging 陈旧备份清理（r21）：仅保留最新备份', () async {
      // r21 回归锁定：备份排序原用 uri.pathSegments.last（Directory URI 尾斜杠
      // 下恒空串、sort 全 0、skip(1) 可能删掉最新备份）——改 _basename 按名称
      // 降序后须只保留时间戳最新的一个。
      final root = await Directory.systemTemp.createTemp('win_stale');
      final program = Directory('${root.path}/program')..createSync();
      final data = Directory('${root.path}/data')..createSync();
      File('${program.path}/app.exe').writeAsStringSync('old');
      final staging = Directory('${program.path}/staging')..createSync();
      File('${staging.path}/app.exe').writeAsStringSync('new');
      // 预置两个陈旧备份（时间戳不同；.backup- 前缀被备份/清空排除）。
      Directory('${program.path}/.backup-1000').createSync();
      File('${program.path}/.backup-1000/stale.bin').writeAsStringSync('s');
      Directory('${program.path}/.backup-2000').createSync();
      File('${program.path}/.backup-2000/stale2.bin').writeAsStringSync('s');
      try {
        final installer = WindowsInstaller(
          programDir: program.path,
          dataDir: data.path,
        );
        final result = await installer.applyStaging(staging.path);
        expect(result.isSuccess, isTrue);
        // 仅最新（.backup-2000）保留，.backup-1000 被清理（r21 排序修正——
        // 旧 bug 会按任意顺序 skip(1) 误删 2000）。
        expect(
          Directory('${program.path}/.backup-2000').existsSync(),
          isTrue,
          reason: '最新备份保留（供短窗口手动回滚）',
        );
        expect(
          Directory('${program.path}/.backup-1000').existsSync(),
          isFalse,
          reason: '陈旧备份清理',
        );
        // 新安装成功不受影响。
        expect(File('${program.path}/app.exe').readAsStringSync(), 'new');
      } finally {
        await root.delete(recursive: true);
      }
    });

    test('applyStaging：备份 → 清空 → 移入 → 删备份（安装成功）', () async {
      final root = await Directory.systemTemp.createTemp('win_apply');
      final program = Directory('${root.path}/program')..createSync();
      final data = Directory('${root.path}/data')..createSync();
      // 旧程序目录（app.exe 旧版）
      File('${program.path}/app.exe').writeAsStringSync('old');
      File('${program.path}/user-data.txt').writeAsStringSync('keep');
      // staging（新版）
      final staging = Directory('${program.path}/staging')..createSync();
      File('${staging.path}/app.exe').writeAsStringSync('new');
      try {
        final installer = WindowsInstaller(
          programDir: program.path,
          dataDir: data.path,
        );
        final result = await installer.applyStaging(staging.path);
        expect(result.isSuccess, isTrue);
        expect(
          File('${program.path}/app.exe').readAsStringSync(),
          'new',
          reason: '新版 app.exe 就位',
        );
        // staging 已移除；旧内容被替换
        expect(Directory('${program.path}/staging').existsSync(), isFalse);
        expect(
          File('${program.path}/user-data.txt').existsSync(),
          isFalse,
          reason: '旧程序目录内容被替换（不含数据文件——数据在数据目录）',
        );
        // 备份目录已删
        // **r22/r23 修正死断言**：`uri.pathSegments.last` 对 Directory 实体（URI
        // 尾斜杠）恒空串——旧断言 where 恒空、isEmpty 无条件通过（残留备份
        // 无法察觉）。按最后路径段前缀判断（与实现侧 `_basename(e.path).startsWith
        // ('.backup-')` 排除语义一致、天然兼容 Windows 反斜杠；整路径 contains
        // 子串过宽会误伤含 `.backup-` 的合法文件名）。
        expect(
          program.listSync().where(
            (e) => e.path.split(RegExp(r'[\\/]')).last.startsWith('.backup-'),
          ),
          isEmpty,
        );
      } finally {
        await root.delete(recursive: true);
      }
    });

    test(
      'applyStaging：数据目录位于程序目录内部（仅大小写不同）→ 拒绝（r 复审）',
      () async {
        // Windows 路径大小写不敏感：dataDir 与 programDir 仅大小写不同仍属
        // "数据目录在程序目录内部"——`_clearProgramDir` 会连带清空数据目录，
        // 大小写敏感比较会漏判放行该危险配置。
        final root = await Directory.systemTemp.createTemp('win_case');
        final program = Directory('${root.path}/Program')..createSync();
        // 仅大小写不同的数据目录（Windows 上指向同一目录）。
        final data = Directory('${root.path}/program/data')..createSync(recursive: true);
        final staging = Directory('${program.path}/staging')..createSync();
        File('${staging.path}/app.exe').writeAsStringSync('new');
        try {
          final installer = WindowsInstaller(
            programDir: program.path,
            dataDir: data.path,
          );
          final result = await installer.applyStaging(staging.path);
          expect(
            result.isSuccess,
            isFalse,
            reason: '数据目录在程序目录内部（大小写不敏感）须拒绝',
          );
          // 程序目录未被改动（无备份残留、staging 未消费）。
          expect(
            program.listSync().where(
              (e) =>
                  e.path.split(RegExp(r'[\\/]')).last.startsWith('.backup-'),
            ),
            isEmpty,
          );
        } finally {
          await root.delete(recursive: true);
        }
      },
      // **平台守卫（r 复审）**：大小写不敏感语义仅 Windows 成立——Linux/
      // 大小写敏感 macOS 卷上 `Program` 与 `program` 是不同目录，无法构造
      // "仅大小写不同的同一目录"，该用例在非 Windows 平台跳过。
      skip: Platform.isWindows ? false : '大小写不敏感语义仅 Windows 成立',
    );

    test(
      'applyStaging 备份为空（backupOk=false，r5）：staging 被 exclude → 失败 + 备份清理',
      () async {
        // 程序目录**仅含 staging 子目录**（备份时 exclude）→ 备份复制后为空 →
        // backupOk=false 分支：返回失败且 `.backup-*` 无残留（r4 新增清理路径）。
        final root = await Directory.systemTemp.createTemp('win_empty_backup');
        final program = Directory('${root.path}/program')..createSync();
        final data = Directory('${root.path}/data')..createSync();
        final staging = Directory('${program.path}/staging')..createSync();
        File('${staging.path}/app.exe').writeAsStringSync('new');
        try {
          final installer = WindowsInstaller(
            programDir: program.path,
            dataDir: data.path,
          );
          final result = await installer.applyStaging(staging.path);
          expect(result.isSuccess, isFalse, reason: '空备份 → 失败');
          expect(
            program
                .listSync()
                .where((e) => e.path.contains('.backup-'))
                .toList(),
            isEmpty,
            reason: 'backupOk=false 分支清理残留备份',
          );
        } finally {
          await root.delete(recursive: true);
        }
      },
    );

    test('applyStaging 备份阶段失败（r4）：复制抛错 → 程序目录原样保留 + 备份清理', () async {
      // r3 核心保证：备份阶段 _copyDirectory 抛错（文件被占用/只读）时程序
      // 目录原样保留、绝不进清空路径（无完整备份可恢复时清空会造空壳）。
      final root = await Directory.systemTemp.createTemp('win_backup_fail');
      final program = Directory('${root.path}/program')..createSync();
      final data = Directory('${root.path}/data')..createSync();
      File('${program.path}/app.exe').writeAsStringSync('old');
      final staging = Directory('${program.path}/staging')..createSync();
      File('${staging.path}/app.exe').writeAsStringSync('new');
      try {
        final installer = WindowsInstaller(
          programDir: program.path,
          dataDir: data.path,
          // 注入复制失败（模拟备份阶段文件被占用）。
          copyFileOverride: (from, to) =>
              throw const FileSystemException('copy blocked'),
        );
        final result = await installer.applyStaging(staging.path);
        expect(result.isSuccess, isFalse, reason: '备份阶段失败返回失败');
        // 程序目录原样保留（未被清空）
        expect(
          File('${program.path}/app.exe').readAsStringSync(),
          'old',
          reason: '备份失败不进入清空路径，程序目录原样保留',
        );
        // 残留备份已清理（.backup-* 不残留）
        expect(
          program.listSync().where((e) => e.path.contains('.backup-')).toList(),
          isEmpty,
          reason: '备份阶段失败后残留备份已清理',
        );
      } finally {
        await root.delete(recursive: true);
      }
    });
    test('applyStaging 备份阶段保护（r3）：staging 仅含空子目录 → 拒绝且程序未动', () async {
      // 防"仅含空子目录的 staging 通过守卫后清空程序目录成空壳"——递归文件
      // 守卫须拒绝；程序目录在备份阶段失败时**绝不进清空路径**（无备份可恢复
      // 时清空会造空壳）。
      final root = await Directory.systemTemp.createTemp('win_guard');
      final program = Directory('${root.path}/program')..createSync();
      final data = Directory('${root.path}/data')..createSync();
      File('${program.path}/app.exe').writeAsStringSync('old');
      final staging = Directory('${program.path}/staging')..createSync();
      // staging 仅含空子目录（无任何普通文件）。
      Directory('${staging.path}/emptydir').createSync();
      try {
        final installer = WindowsInstaller(
          programDir: program.path,
          dataDir: data.path,
        );
        final result = await installer.applyStaging(staging.path);
        expect(result.isSuccess, isFalse, reason: '无文件的 staging 拒绝');
        // 程序目录原样保留（备份阶段失败不进入清空路径）。
        expect(
          File('${program.path}/app.exe').readAsStringSync(),
          'old',
          reason: '程序目录未改动',
        );
      } finally {
        await root.delete(recursive: true);
      }
    });

    test('checkWritable：可写目录 true；只读目录 false（POSIX chmod，r9）', () async {
      final root = await Directory.systemTemp.createTemp('win_write');
      final writable = Directory('${root.path}/w')..createSync();
      final ro = Directory('${root.path}/ro')..createSync();
      try {
        final installer = WindowsInstaller(
          programDir: writable.path,
          dataDir: '${root.path}/data',
        );
        expect(installer.checkWritable(), isTrue, reason: '临时目录可写');
        // **只读分支（r9）**：Windows 目录只读位语义与 Unix 不同（chmod 0555
        // 在 Windows 上几乎无效、以管理员运行也可写）；POSIX root 拥有
        // CAP_DAC_OVERRIDE 同样不受写权限位限制——两平台均跳过。
        if (!Platform.isWindows) {
          final isRoot =
              Process.runSync('id', ['-u']).stdout.toString().trim() == '0';
          if (!isRoot) {
            final chmod = Process.runSync('chmod', ['0555', ro.path]);
            if (chmod.exitCode != 0) {
              // chmod 失败时显式失败（注释所述"掩盖为断言失败"应为显式暴露——
              // 静默跳过会让只读分支回归无感知）。
              fail('chmod 0555 失败：${chmod.stderr}');
            }
            try {
              expect(
                WindowsInstaller(
                  programDir: ro.path,
                  dataDir: '${root.path}/data',
                ).checkWritable(),
                isFalse,
                reason: '只读目录不可写（写探针抛 FileSystemException）',
              );
            } finally {
              Process.runSync('chmod', ['0755', ro.path]);
            }
          }
        }
      } finally {
        await root.delete(recursive: true);
      }
    });
  });

  group('AndroidInstaller（纯函数）', () {
    test('content URI 构造 + Intent 标志', () {
      const installer = AndroidInstaller();
      final uri = installer.apkContentUri('app.apk');
      expect(
        uri,
        'content://com.github.ianmuh.timetrack2.fileprovider/cache/app.apk',
      );
      final intent = installer.installIntentFor(uri);
      expect(intent.action, 'android.intent.action.VIEW');
      expect(intent.dataUri, uri, reason: 'data URI 参与结果（防误传）');
      expect(
        intent.mimeType,
        'application/vnd.android.package-archive',
        reason: '携带 APK MIME（系统才能解析到安装器）',
      );
      expect(
        intent.flags,
        0x00000001,
        reason: 'FLAG_GRANT_READ_URI_PERMISSION',
      );
    });

    test('installIntentFor authority 校验（r9）：非本应用 FileProvider URI 拒绝', () {
      const installer = AndroidInstaller();
      // 误传 file:// 或其它 provider 的 URI——配合 GRANT 标志会向安装器授予
      // 对非预期文件的读取权限，须拒绝。
      expect(
        () => installer.installIntentFor('file:///tmp/app.apk'),
        throwsArgumentError,
      );
      expect(
        () => installer.installIntentFor(
          'content://other.provider/cache/app.apk',
        ),
        throwsArgumentError,
      );
      // **r16：percent-decode 后含 `/` 的段拒绝（r14 修复的死角）**——pathSegments
      // 将 `%2F` 解码为 `/` 但不重新分段：`..%2Ffoo` 成为单段 `../foo`，裸 `..`
      // 检查放行、FileProvider 却 `new File(cacheDir, '../foo')` 逃逸到 cache 根
      // 目录之外。现按解码后段内含分隔符拦截。
      expect(
        () => installer.installIntentFor(
          'content://com.github.ianmuh.timetrack2.fileprovider/cache/..%2Ffoo.apk',
        ),
        throwsArgumentError,
        reason: '`..%2F` 编码穿越段拒绝',
      );
      expect(
        () => installer.installIntentFor(
          'content://com.github.ianmuh.timetrack2.fileprovider/cache/%2E%2E%2Ffoo.apk',
        ),
        throwsArgumentError,
        reason: '`%2E%2E%2F` 编码穿越段拒绝',
      );
      // **r19**：Dart Uri 把 authority 的 host 部分规范化为小写——同一实例产出
      // 的 URI 经自身校验必须通过（往返不断裂）。
      expect(
        installer.installIntentFor(installer.apkContentUri('app.apk')),
        isNotNull,
        reason: '同一实例产出的 URI 通过自身校验',
      );
    });

    test('installValidatedApk 单一安全入口（r19）：校验→URI→Intent 一体', () async {
      // 单一入口：内部依次 ensureApkValid → apkContentUri → installIntentFor，
      // 防调用方绕过校验直接构造 GRANT 意图暴露 cache 根之外的文件。
      final dir = await Directory.systemTemp.createTemp('android_validated');
      const installer = AndroidInstaller();
      try {
        File('${dir.path}/app.apk').writeAsBytesSync([1, 2, 3]);
        final ok = installer.installValidatedApk(
          '${dir.path}/app.apk',
          cacheRoot: dir.path,
        );
        expect(ok.isSuccess, isTrue, reason: '有效 APK 产出安装意图');
        final intent = ok.requireValue();
        expect(intent.action, 'android.intent.action.VIEW');
        // **完整 URI 断言（r20）**：锁定"校验→URI→Intent"一体产出的 URI 与
        // 源文件一致（防 apkFileName 提取/路径段拼接出错暴露错误文件）。
        expect(
          intent.dataUri,
          'content://com.github.ianmuh.timetrack2.fileprovider/cache/app.apk',
        );
        expect(intent.flags, 0x00000001);

        // 缺失文件 → 可读失败（不产出部分结果）
        final missing = installer.installValidatedApk(
          '${dir.path}/nope.apk',
          cacheRoot: dir.path,
        );
        expect(missing.isSuccess, isFalse, reason: '缺失文件失败');

        // **cacheRoot 带尾斜杠（r22 正向用例）**：Directory.absolute.path 保留
        // 尾分隔符——比较前须归一化裁剪，否则根内直子文件被误拒。
        expect(
          installer
              .installValidatedApk(
                '${dir.path}/app.apk',
                cacheRoot: '${dir.path}/',
              )
              .isSuccess,
          isTrue,
          reason: 'cacheRoot 尾斜杠不影响校验（已归一化）',
        );

        // **cache 根外文件拒绝（r20）**：产出的 content URI 指向 FileProvider
        // cache 根——源文件必须在 cache 根内（"校验的文件 == 暴露/安装的文件"）。
        // 用独立目录而非 `..` 相对路径（后者未规范化、前缀匹配会误判为根内）。
        final outside = Directory('${dir.path}.outside')..createSync();
        try {
          File('${outside.path}/app.apk').writeAsBytesSync([1, 2, 3]);
          final outOfRoot = installer.installValidatedApk(
            '${outside.path}/app.apk',
            cacheRoot: dir.path,
          );
          expect(outOfRoot.isSuccess, isFalse, reason: 'cache 根外文件拒绝');
          expect(
            outOfRoot.when(onSuccess: (_) => '', onFailure: (m) => m),
            contains('cache 根目录内'),
            reason: '拒绝原因精确（cache 根约束）',
          );
        } finally {
          await outside.delete(recursive: true);
        }

        // **根内子目录文件拒绝（r21）**：URI 只取单段文件名、FileProvider 解析
        // 为 `$cacheRoot/<名>`——子目录文件会通过前缀校验但 URI 指向根下同名
        // 文件（误装/找不到），破坏核心不变量。父目录须与 cacheRoot 严格相等。
        final sub = Directory('${dir.path}/sub')..createSync();
        try {
          File('${sub.path}/app.apk').writeAsBytesSync([1, 2, 3]);
          final inSub = installer.installValidatedApk(
            '${sub.path}/app.apk',
            cacheRoot: dir.path,
          );
          expect(inSub.isSuccess, isFalse, reason: '根内子目录文件拒绝');
        } finally {
          await sub.delete(recursive: true);
        }

        // **反斜杠文件名拒绝（r23）**：Android 是 POSIX——反斜杠是合法文件名字
        // 符，按 `/` 分割会取到错误基名（URI 指向与校验文件不同的文件）；须
        // 返回 AppFailure（而非 apkContentUri 的 ArgumentError 逃逸）。检查前置
        // 于 ensureApkValid（纯路径形态、与文件是否存在无关），无需真实文件。
        final backslash = installer.installValidatedApk(
          '${dir.path}/foo\\bar.apk',
          cacheRoot: dir.path,
        );
        expect(backslash.isSuccess, isFalse, reason: '反斜杠文件名拒绝');
        expect(
          backslash.when(onSuccess: (_) => '', onFailure: (m) => m),
          contains('含反斜杠'),
          reason: '反斜杠文件名返回可读原因（非 ArgumentError 逃逸）',
        );
      } finally {
        await dir.delete(recursive: true);
      }
    });

    test('tryInstallApk 未实现（r20）：显式 UnsupportedError（防无守卫静默调用）', () {
      // 平台守卫级入口（TOCTOU/父级链接兜底）阶段 4 实现——现不得被当作已加固
      // 入口静默调用。
      const installer = AndroidInstaller();
      expect(
        () => installer.tryInstallApk('/cache/app.apk', cacheRoot: '/cache'),
        throwsUnsupportedError,
      );
    });

    test('content URI 文件名编码（r2）：特殊字符编码 / `..` 拒绝', () {
      const installer = AndroidInstaller();
      // 空格/`#`/`?`/`%` 编码（防 URI 解析错误）
      expect(
        installer.apkContentUri('my app v1.2.apk'),
        'content://com.github.ianmuh.timetrack2.fileprovider/cache/my%20app%20v1.2.apk',
      );
      expect(
        installer.apkContentUri('my#app?100%.apk'),
        'content://com.github.ianmuh.timetrack2.fileprovider/cache/my%23app%3F100%25.apk',
      );
      // 路径分隔符 / 裸 `..`/`.`/空串拒绝（Uri.encodeComponent 不编码 `.`——
      // 裸 `..` 会产生带穿越段的 URI，须显式拒绝）
      expect(
        () => installer.apkContentUri('../evil.apk'),
        throwsArgumentError,
        reason: '文件名含路径分隔符拒绝',
      );
      expect(
        () => installer.apkContentUri(r'..\evil.apk'),
        throwsArgumentError,
      );
      expect(
        () => installer.apkContentUri('..'),
        throwsArgumentError,
        reason: '裸 .. 拒绝（防路径穿越段 URI）',
      );
      expect(() => installer.apkContentUri('.'), throwsArgumentError);
      expect(() => installer.apkContentUri(''), throwsArgumentError);
    });

    test('ensureApkValid：存在非空通过 / 缺失失败 / 空文件失败 / 目录失败（r2）', () async {
      final dir = await Directory.systemTemp.createTemp('android_apk');
      final installer = const AndroidInstaller();
      try {
        expect(
          installer.ensureApkValid('${dir.path}/missing.apk').isSuccess,
          isFalse,
          reason: '文件不存在失败',
        );
        File('${dir.path}/empty.apk').writeAsStringSync('');
        expect(
          installer.ensureApkValid('${dir.path}/empty.apk').isSuccess,
          isFalse,
          reason: '空文件失败',
        );
        // **目录路径（r2）**：POSIX 上 File.existsSync 对目录返回 true、lengthSync
        // 返回 inode 大小——须按 stat.type 显式拒绝（防目录被当作有效 APK）。
        Directory('${dir.path}/adir').createSync();
        expect(
          installer.ensureApkValid('${dir.path}/adir').isSuccess,
          isFalse,
          reason: '目录路径失败（非常规文件）',
        );
        File('${dir.path}/real.apk').writeAsBytesSync([1, 2, 3]);
        expect(
          installer.ensureApkValid('${dir.path}/real.apk').isSuccess,
          isTrue,
          reason: '非空通过',
        );
        // **符号链接拒绝（r10）**：statSync 默认跟随链接、指向常规文件的链接
        // type 仍为 file 会被放行——显式 followLinks:false 检测须拒绝（防外部
        // 文件经链接绕过守卫进入安装流程）。POSIX only；无 symlink 权限的
        // 环境（容器/FAT 挂载）创建会抛 FileSystemException——按"环境不支持
        // 则跳过"处理（与只读目录用例的平台兼容一致）。
        if (!Platform.isWindows) {
          try {
            Link('${dir.path}/link.apk').createSync('${dir.path}/real.apk');
          } on FileSystemException {
            // 环境不支持符号链接：跳过（不误报）。
          }
          if (File('${dir.path}/link.apk').existsSync()) {
            expect(
              installer.ensureApkValid('${dir.path}/link.apk').isSuccess,
              isFalse,
              reason: '符号链接拒绝（防绕过安装守卫）',
            );
          }
        }
      } finally {
        await dir.delete(recursive: true);
      }
    });
  });
}
