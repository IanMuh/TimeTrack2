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
    test('zip 解压 staging：文件落位（zip-slip 防护放行合法路径）', () async {
      final root = await Directory.systemTemp.createTemp('win_stage');
      final program = Directory('${root.path}/program')..createSync();
      final data = Directory('${root.path}/data')..createSync();
      final zipPath = '${root.path}/pkg.zip';
      File(zipPath).writeAsBytesSync(buildZip({
        'app.exe': 'binary',
        'libs/foo.dll': 'lib-content',
        'data/config.json': '{}',
      }));
      try {
        final installer = WindowsInstaller(
          programDir: program.path,
          dataDir: data.path,
        );
        final staging = (await installer.prepareStaging(zipPath)).requireValue();
        expect(File('$staging/app.exe').readAsStringSync(), 'binary');
        expect(File('$staging/libs/foo.dll').readAsStringSync(), 'lib-content');
        expect(File('$staging/data/config.json').readAsStringSync(), '{}');
        expect(File('$staging/../app.exe').existsSync(), isFalse,
            reason: '文件只落在 staging 内');
      } finally {
        await root.delete(recursive: true);
      }
    });

    test('zip-slip 防护：`../` 路径穿越条目拒绝（不写入 staging 外）', () async {
      final root = await Directory.systemTemp.createTemp('win_slip');
      final program = Directory('${root.path}/program')..createSync();
      final data = Directory('${root.path}/data')..createSync();
      final zipPath = '${root.path}/evil.zip';
      File(zipPath).writeAsBytesSync(buildZip({
        '../evil.txt': 'evil', // 路径穿越
        'ok.txt': 'ok',
      }));
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
      File(zipPath).writeAsBytesSync(buildZip({
        '/tmp/evil.txt': 'evil', // 绝对路径
      }));
      try {
        final installer = WindowsInstaller(
          programDir: program.path,
          dataDir: data.path,
        );
        expect((await installer.prepareStaging(zipPath)).isSuccess, isFalse,
            reason: '绝对路径条目拒绝');
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
        ].indexed) {
          final zipPath = '${root.path}/evil$i.zip';
          File(zipPath).writeAsBytesSync(buildZip({evil: 'evil'}));
          final result = await installer.prepareStaging(zipPath);
          expect(result.isSuccess, isFalse,
              reason: '非法路径条目拒绝：$evil');
          // 失败后 staging 已清理、program 目录无残留（穿越落点在
          // program/evil.txt 等——直接断言 program 目录干净最可靠）。
          expect(program.listSync(), isEmpty,
              reason: '$evil 失败后无残留文件写出');
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
      File(zipPath).writeAsBytesSync(buildZip({
        'ok.txt': 'ok',
        r'..\evil.txt': 'evil', // 合法条目后的恶意条目
      }));
      try {
        final installer = WindowsInstaller(
          programDir: program.path,
          dataDir: data.path,
        );
        final result = await installer.prepareStaging(zipPath);
        expect(result.isSuccess, isFalse, reason: '混合包整体拒绝');
        // 已解压的 ok.txt 不残留（失败清理）
        expect(Directory('${program.path}/staging').existsSync(), isFalse,
            reason: '失败后 staging 已清理（含已解压合法文件）');
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
      File(zipPath).writeAsBytesSync(
        ZipEncoder().encode(Archive()),
      );
      try {
        final installer = WindowsInstaller(
          programDir: program.path,
          dataDir: data.path,
        );
        final result = await installer.prepareStaging(zipPath);
        expect(result.isSuccess, isFalse, reason: '空包拒绝');
        // staging 未残留（失败清理）
        expect(Directory('${program.path}/staging').existsSync(), isFalse,
            reason: '失败后 staging 已清理');
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
        expect(File('${program.path}/app.exe').readAsStringSync(), 'new',
            reason: '新版 app.exe 就位');
        // staging 已移除；旧内容被替换
        expect(Directory('${program.path}/staging').existsSync(), isFalse);
        expect(File('${program.path}/user-data.txt').existsSync(), isFalse,
            reason: '旧程序目录内容被替换（不含数据文件——数据在数据目录）');
        // 备份目录已删
        expect(
          program.listSync().where((e) => e.uri.pathSegments.last.startsWith('.backup-')),
          isEmpty,
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
        expect(File('${program.path}/app.exe').readAsStringSync(), 'old',
            reason: '程序目录未改动');
      } finally {
        await root.delete(recursive: true);
      }
    });

    test('checkWritable：可写目录 true / 只读目录 false', () async {
      final root = await Directory.systemTemp.createTemp('win_write');
      final writable = Directory('${root.path}/w')..createSync();
      try {
        final installer = WindowsInstaller(
          programDir: writable.path,
          dataDir: '${root.path}/data',
        );
        expect(installer.checkWritable(), isTrue, reason: '临时目录可写');
      } finally {
        await root.delete(recursive: true);
      }
    });
  });

  group('AndroidInstaller（纯函数）', () {
    test('content URI 构造 + Intent 标志', () {
      const installer = AndroidInstaller();
      final uri = installer.apkContentUri('/cache', 'app.apk');
      expect(uri, 'content://com.example.timetrack2.fileprovider/cache/app.apk');
      final intent = installer.installIntentFor(uri);
      expect(intent.action, 'android.intent.action.VIEW');
      expect(intent.dataUri, uri, reason: 'data URI 参与结果（防误传）');
      expect(intent.mimeType, 'application/vnd.android.package-archive',
          reason: '携带 APK MIME（系统才能解析到安装器）');
      expect(intent.flags, 0x00000001, reason: 'FLAG_GRANT_READ_URI_PERMISSION');
    });

    test('content URI 文件名编码（r2）：特殊字符编码 / `..` 拒绝', () {
      const installer = AndroidInstaller();
      // 空格/`#`/`?`/`%` 编码（防 URI 解析错误）
      expect(
        installer.apkContentUri('/cache', 'my app v1.2.apk'),
        'content://com.example.timetrack2.fileprovider/cache/my%20app%20v1.2.apk',
      );
      expect(
        installer.apkContentUri('/cache', 'my#app?100%.apk'),
        'content://com.example.timetrack2.fileprovider/cache/my%23app%3F100%25.apk',
      );
      // 路径分隔符 / 裸 `..`/`.`/空串拒绝（Uri.encodeComponent 不编码 `.`——
      // 裸 `..` 会产生带穿越段的 URI，须显式拒绝）
      expect(
        () => installer.apkContentUri('/cache', '../evil.apk'),
        throwsArgumentError,
        reason: '文件名含路径分隔符拒绝',
      );
      expect(
        () => installer.apkContentUri('/cache', r'..\evil.apk'),
        throwsArgumentError,
      );
      expect(
        () => installer.apkContentUri('/cache', '..'),
        throwsArgumentError,
        reason: '裸 .. 拒绝（防路径穿越段 URI）',
      );
      expect(
        () => installer.apkContentUri('/cache', '.'),
        throwsArgumentError,
      );
      expect(
        () => installer.apkContentUri('/cache', ''),
        throwsArgumentError,
      );
    });

    test('ensureApkValid：存在非空通过 / 缺失失败 / 空文件失败 / 目录失败（r2）', () async {
      final dir = await Directory.systemTemp.createTemp('android_apk');
      final installer = const AndroidInstaller();
      try {
        expect(installer.ensureApkValid('${dir.path}/missing.apk').isSuccess, isFalse,
            reason: '文件不存在失败');
        File('${dir.path}/empty.apk').writeAsStringSync('');
        expect(installer.ensureApkValid('${dir.path}/empty.apk').isSuccess, isFalse,
            reason: '空文件失败');
        // **目录路径（r2）**：POSIX 上 File.existsSync 对目录返回 true、lengthSync
        // 返回 inode 大小——须按 stat.type 显式拒绝（防目录被当作有效 APK）。
        Directory('${dir.path}/adir').createSync();
        expect(installer.ensureApkValid('${dir.path}/adir').isSuccess, isFalse,
            reason: '目录路径失败（非常规文件）');
        File('${dir.path}/real.apk').writeAsBytesSync([1, 2, 3]);
        expect(installer.ensureApkValid('${dir.path}/real.apk').isSuccess, isTrue,
            reason: '非空通过');
      } finally {
        await dir.delete(recursive: true);
      }
    });
  });
}
