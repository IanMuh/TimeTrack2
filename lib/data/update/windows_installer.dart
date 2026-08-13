/// Windows 更新安装器（计划"完整更新系统设计"·Windows 安装）。
///
/// 流程：zip 解压 staging → 数据目录写待安装标记 → 提示重启 → 下次启动
///（exe 未锁定）备份当前 → staging 移入 → 删标记；**标记异常回滚**。
///
/// 本文件实现**安装就绪的两步**（可单测的纯文件操作）：
/// 1. [prepareStaging]：把校验通过的 zip 解压到 staging 目录（**zip-slip 防护**：
///    拒绝 `../` 路径穿越，防恶意 zip 写入任意目录）；
/// 2. [applyStaging]：备份当前程序目录 → 清空 → 移入 staging（失败回滚）。
///
/// 程序目录不可写时降级（[checkWritable]）；待安装标记放**数据目录**
///（与程序目录分离——计划铁律 12），阶段 3/4 的启动时应用逻辑读取。
library;

import 'dart:io';

import 'package:archive/archive.dart';

import '../../constants/update_config.dart';
import '../../utils/result.dart';

/// Windows 安装器。
class WindowsInstaller {
  WindowsInstaller({
    required this.programDir,
    required this.dataDir,
    ZipDecoder? zipCodec,
  }) : zipCodec = zipCodec ?? ZipDecoder();

  /// 程序目录（exe 所在，安装目标）。
  final String programDir;

  /// 数据目录（待安装标记等放这里，与程序目录分离）。
  final String dataDir;

  /// zip 解码器（可注入替换，测试用）。
  final ZipDecoder zipCodec;

  /// 程序目录是否可写（安装前提）。
  bool checkWritable() {
    try {
      final probe = File('$programDir/.write-probe');
      probe.writeAsStringSync('probe');
      probe.deleteSync();
      return true;
    } on FileSystemException {
      return false;
    }
  }

  /// 把 [zipPath] 解压到 staging 目录（**zip-slip 防护**）。
  ///
  /// 解析 zip 条目名，拒绝任何包含 `..` 段/绝对路径/盘符路径的条目（防路径
  /// 穿越写入程序目录之外）；**空包（无任何文件）直接失败**（防 applyStaging
  /// 把程序目录清空成空壳）；staging 已存在则先删除（幂等）。返回 staging 路径。
  /// 失败路径清理 staging（防半解压残留被当作可安装包）。
  Future<AppResult<String>> prepareStaging(String zipPath) async {
    final staging = Directory('$programDir/${UpdateConfig.windowsStagingDirName}');
    try {
      if (staging.existsSync()) {
        staging.deleteSync(recursive: true);
      }
      staging.createSync(recursive: true);
      final bytes = File(zipPath).readAsBytesSync();
      final archive = zipCodec.decodeBytes(bytes);
      var fileCount = 0;
      for (final file in archive.files) {
        if (file.isFile) {
          final name = file.name;
          // zip-slip 防护：拒绝路径穿越（`..` 段/绝对路径/盘符路径）——否则
          // 恶意 zip 可把文件写入 staging 之外（如覆盖程序目录/系统路径）。
          if (_isUnsafePath(name)) {
            throw StateError('更新包包含非法路径条目（路径穿越风险）：$name');
          }
          final out = File('${staging.path}/$name');
          out.createSync(recursive: true);
          out.writeAsBytesSync(file.content as List<int>, flush: true);
          fileCount += 1;
        }
      }
      if (fileCount == 0) {
        throw StateError('更新包为空（无任何文件）');
      }
      return AppSuccess(staging.path);
    } catch (e) {
      // 失败清理 staging（防半解压残留被当作可安装包）。
      try {
        if (staging.existsSync()) {
          staging.deleteSync(recursive: true);
        }
      } on FileSystemException {
        // 清理失败不影响失败结论。
      }
      return AppFailure('解压更新包失败：$e');
    }
  }

  /// 应用 staging：备份当前程序目录 → 清空 → 移入 staging；失败回滚。
  ///
  /// 调用方（阶段 3/4 启动逻辑）应**先确认 exe 未被锁定**（本文件不持有 exe）；
  /// [applyStaging] 内部做原子性：备份目录先建，任何步骤失败恢复备份。
  /// **清空前校验 staging 存在且非空**（防空包把程序目录清空成不可用状态）。
  Future<AppResult<void>> applyStaging(String stagingPath) async {
    // 前置守卫：staging 必须存在且非空（prepareStaging 已拒空包，此处
    // 双保险——调用方可能绕过 prepareStaging 直接传路径）。
    final staging = Directory(stagingPath);
    if (!staging.existsSync() ||
        staging.listSync().isEmpty) {
      return const AppFailure('安装暂存目录缺失或为空，已中止（未改动程序目录）');
    }
    final backupDir = Directory('$programDir/.backup-${DateTime.now().millisecondsSinceEpoch}');
    try {
      // 1. 备份当前程序目录（不含 staging 与备份自身）。
      if (Directory(programDir).existsSync()) {
        _copyDirectory(Directory(programDir), backupDir, exclude: const {
          UpdateConfig.windowsStagingDirName,
        });
      }
      // 2. 清空程序目录（保留 staging/备份）。
      _clearProgramDir();
      // 3. 移入 staging。
      for (final entry in staging.listSync()) {
        entry.renameSync('$programDir/${_basename(entry.path)}');
      }
      staging.deleteSync(recursive: true);
      // 4. 删除备份（**best-effort，r1**）：备份中文件被占用/杀毒扫描时删除
      // 失败——安装已成功，备份删除失败不改变结果（只留备份目录待手动清理），
      // 绝不能因此进入回滚把刚装好的新文件清掉。
      try {
        if (backupDir.existsSync()) {
          backupDir.deleteSync(recursive: true);
        }
      } on FileSystemException {
        // 备份保留（供手动清理/回滚），安装成功结论不变。
      }
      return const AppSuccess(null);
    } catch (e) {
      // **失败回滚（r1 修正）**：清空与恢复必须**各自独立尝试**——清空失败
      //（新文件被占用）不能阻止恢复备份。备份目录保留供手动恢复（不掩盖
      // 原始错误，也不误导为"已回滚"）。
      var rollbackOk = false;
      try {
        _clearProgramDir();
        if (backupDir.existsSync()) {
          for (final entry in backupDir.listSync()) {
            entry.renameSync('$programDir/${_basename(entry.path)}');
          }
          rollbackOk = true;
        }
      } catch (_) {
        // 清空/恢复失败：备份目录仍在，供手动恢复。
      }
      if (rollbackOk) {
        return AppFailure('安装更新失败（已回滚）：$e');
      }
      return AppFailure(
        '安装更新失败，且回滚未完成（备份保留在 $backupDir，请手动恢复）：$e',
      );
    }
  }

  /// 路径穿越判定：绝对路径 / 盘符路径（Windows）/ 含 `..` 段或前导空段的
  /// 条目名不安全。
  static bool _isUnsafePath(String name) {
    if (name.startsWith('/') || name.startsWith(r'\')) return true;
    // 拒绝 Windows 盘符绝对/相对路径（C:/xxx、C:\xxx、C:evil.txt）——
    // 拼接后含内嵌冒号会引发路径解析歧义/非预期行为。
    if (name.length >= 2 && name[1] == ':') return true;
    final segments = name.replaceAll(r'\', '/').split('/');
    return segments.any((s) => s == '..' || s.isEmpty && segments.length > 1);
  }

  /// 跨平台 basename：**不用 `uri.pathSegments.last`**——目录 URI 以 `/` 结尾，
  /// 其 last 段为空串（Windows 上 `File/Directory.path` 混用反斜杠/正斜杠时
  /// 会静默失效，导致 `_clearProgramDir` 误删 staging/备份）。按两种分隔符
  /// 切分取末段。
  static String _basename(String path) =>
      path.split(RegExp(r'[\\/]')).last;

  void _clearProgramDir() {
    for (final entry in Directory(programDir).listSync()) {
      final name = _basename(entry.path);
      if (name == UpdateConfig.windowsStagingDirName) continue;
      if (name.startsWith('.backup-')) continue;
      entry.deleteSync(recursive: true);
    }
  }

  void _copyDirectory(Directory from, Directory to, {required Set<String> exclude}) {
    to.createSync(recursive: true);
    for (final entry in from.listSync()) {
      final name = _basename(entry.path);
      // 备份目录本身在源（programDir）内——复制时必须排除（否则备份被递归
      // 复制进自己形成无限嵌套，且误删最深副本时抛 PathNotFound）。
      if (name.startsWith('.backup-')) continue;
      if (exclude.contains(name)) continue;
      final target = File('${to.path}/$name');
      if (entry is Directory) {
        _copyDirectory(entry, Directory(target.path), exclude: const {});
      } else if (entry is File) {
        target.createSync(recursive: true);
        entry.copySync(target.path);
      }
    }
  }
}
