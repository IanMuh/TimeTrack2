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
    // **私有字段初始化形参（Dart 3.12 特性）**：`this._x` 命名参数跨库调用名
    // 剥离下划线（调用方写 `copyFileOverride:`）——已用最小程序实证编译运行。
    this._copyFileOverride,
  }) : zipCodec = zipCodec ?? ZipDecoder();
  /// 程序目录（exe 所在，安装目标）。
  final String programDir;

  /// 数据目录（待安装标记等放这里，与程序目录分离——**本文件不直接使用**，
  /// 待安装标记的读写属阶段 3/4 启动逻辑；此处保留为构造契约的声明性占位，
  /// 防调用方遗漏该目录约定）。
  final String dataDir;

  /// zip 解码器（可注入替换，测试用）。
  final ZipDecoder zipCodec;

  /// 文件复制钩子（测试注入失败场景——备份阶段复制抛错时程序目录须原样保留）。
  final void Function(String from, String to)? _copyFileOverride;

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
      // **zip bomb 防护（r9）**：恶意/异常更新包可用高压缩比条目（zip bomb）
      // 使进程 OOM 或磁盘写满——解压前校验包大小与单条目/累计解压体积上限。
      final archive = zipCodec.decodeBytes(bytes);
      var fileCount = 0;
      var totalUncompressed = 0;
      for (final file in archive.files) {
        if (file.isFile) {
          final name = file.name;
          // zip-slip 防护：拒绝路径穿越（`..` 段/绝对路径/盘符路径/尾部空格
          // 规范化绕过/保留设备名）——否则恶意 zip 可把文件写入 staging 之外
          //（如覆盖程序目录/系统路径）。
          if (_isUnsafePath(name)) {
            throw StateError('更新包包含非法路径条目（路径穿越风险）：$name');
          }
          // 单条目解压后大小上限（zip bomb 高压缩比条目）。
          if (file.size > UpdateConfig.maxUncompressedEntryBytes) {
            throw StateError('更新包条目解压后体积超上限：$name');
          }
          totalUncompressed += file.size;
          // 累计解压体积上限。
          if (totalUncompressed > UpdateConfig.maxTotalUncompressedBytes) {
            throw StateError('更新包解压总体积超上限');
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
  /// **两阶段结构（r3 修正）**：
  /// - **备份阶段**（守卫 + 复制 + 完成确认）：任何失败/IO 异常都**直接返回
  ///   失败、绝不进清空路径**——程序目录仍完好，无备份可恢复时清空会造空壳
  ///   （含 staging 不可读的 IO 异常，防从"安全中止"变为"清空程序目录"）；
  /// - **安装阶段**（清空 + 移入 + 删备份）：备份已确认完整后才开始，失败才
  ///   走回滚（清空与恢复各自独立 try）。
  Future<AppResult<void>> applyStaging(String stagingPath) async {
    final staging = Directory(stagingPath);
    final backupDir = Directory('$programDir/.backup-${DateTime.now().millisecondsSinceEpoch}');
    // ---- 备份阶段（失败绝不进清空路径）----
    // 前置守卫：staging 存在且递归含至少一个普通文件（IO 异常显式捕获——
    // 防 listSync 异常进入下方安装/回滚逻辑、在无备份时清空程序目录）。
    bool stagingOk;
    try {
      stagingOk = staging.existsSync() && _containsRegularFile(staging);
    } on FileSystemException {
      stagingOk = false;
    }
    if (!stagingOk) {
      return const AppFailure('安装暂存目录缺失或无文件，已中止（未改动程序目录）');
    }
    try {
      // 备份当前程序目录（不含 staging 与备份自身）。
      if (Directory(programDir).existsSync()) {
        _copyDirectory(Directory(programDir), backupDir, exclude: const {
          UpdateConfig.windowsStagingDirName,
        });
      }
    } catch (e) {
      // 备份阶段失败（文件被占用/只读/IO 异常）：程序目录仍完好，**绝不
      // 清空**（无完整备份可恢复，清空会造空壳）。清理残留备份目录。
      try {
        if (backupDir.existsSync()) {
          backupDir.deleteSync(recursive: true);
        }
      } on FileSystemException {
        // 清理失败不影响失败结论。
      }
      return AppFailure('创建备份失败，已中止（程序目录未改动）：$e');
    }
    // 备份完成确认：必须存在且含内容（防"空备份通过"）。
    bool backupOk;
    try {
      backupOk = backupDir.existsSync() && backupDir.listSync().isNotEmpty;
    } on FileSystemException {
      backupOk = false;
    }
    if (!backupOk) {
      // **清理残留备份（r4）**：备份为空/校验 IO 异常时 partial 备份目录会
      // 残留（后续备份/清空都排除 .backup-*，多次失败会累积占用磁盘）——
      // 与 catch 分支的清理保持一致。
      try {
        if (backupDir.existsSync()) {
          backupDir.deleteSync(recursive: true);
        }
      } on FileSystemException {
        // 清理失败不影响失败结论。
      }
      return const AppFailure('创建备份失败，已中止（程序目录未改动）');
    }

    // ---- 安装阶段（备份已确认完整，失败才走回滚）----
    try {
      _clearProgramDir();
      for (final entry in staging.listSync()) {
        entry.renameSync('$programDir/${_basename(entry.path)}');
      }
      staging.deleteSync(recursive: true);
      // 删除备份（**best-effort**）：备份中文件被占用/杀毒扫描时删除失败
      // ——安装已成功，备份删除失败不改变结果（只留备份目录待手动清理），
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
      // **安装阶段回滚（r2 修正）**：清空与恢复各自独立 try——清空失败
      //（新文件被占用）不能阻止恢复备份。回滚自身失败保留备份目录并明确
      // 告知（不误导为"已回滚"）。
      var rollbackOk = false;
      try {
        _clearProgramDir();
      } catch (_) {
        // 清空失败：继续尝试恢复（备份可能仍有内容可救）。
      }
      try {
        if (backupDir.existsSync()) {
          for (final entry in backupDir.listSync()) {
            entry.renameSync('$programDir/${_basename(entry.path)}');
          }
          rollbackOk = true;
          // **回滚成功后清理（r9）**：备份条目全部移出后 backupDir 成空目录
          // 未删除——多次失败会累积陈旧空备份目录；staging 中未移入的条目
          // 残留原 staging 目录。均 best-effort 清理。
          try {
            backupDir.deleteSync(recursive: true);
            if (staging.existsSync()) {
              staging.deleteSync(recursive: true);
            }
          } on FileSystemException {
            // 清理失败不影响回滚成功结论。
          }
        }
      } catch (_) {
        // 恢复失败：备份目录仍在，供手动恢复。
      }
      if (rollbackOk) {
        return AppFailure('安装更新失败（已回滚）：$e');
      }
      return AppFailure(
        '安装更新失败，且回滚未完成（备份保留在 $backupDir，请手动恢复）：$e',
      );
    }
  }

  /// 目录是否**递归含至少一个普通文件**（防仅含空子目录的 staging 通过守卫）。
  static bool _containsRegularFile(Directory dir) {
    for (final entry in dir.listSync()) {
      if (entry is File) return true;
      if (entry is Directory && _containsRegularFile(entry)) return true;
    }
    return false;
  }

  /// 路径穿越判定：绝对路径 / 盘符路径（Windows）/ 含 `..` 段或前导空段的
  /// 条目名不安全。
  static bool _isUnsafePath(String name) {
    if (name.startsWith('/') || name.startsWith(r'\')) return true;
    // 拒绝 Windows 盘符绝对/相对路径（C:/xxx、C:\xxx、C:evil.txt）——
    // 拼接后含内嵌冒号会引发路径解析歧义/非预期行为。
    if (name.length >= 2 && name[1] == ':') return true;
    final segments = name.replaceAll(r'\', '/').split('/');
    return segments.any((s) {
      // **Windows 路径规范化（r9）**：Win32 打开路径时会去除每个组件**尾部
      // 的空格/点号**——`.. `、`. ` 会被解析为 `..`/`.`，直接判 `s == '..'`
      // 会漏掉 `.. /evil.txt` 这类绕过（写入时解析为 `$staging/../evil.txt`）。
      // 先修剪尾部空格/点号再判。
      final trimmed = s.replaceAll(RegExp(r'[. ]+$'), '');
      if (trimmed.isEmpty) return segments.length > 1;
      if (trimmed == '.' || trimmed == '..') return true;
      // **保留设备名（r9）**：CON/NUL/PRN/AUX/COM1-9/LPT1-9（带扩展名同拒）
      // ——防设备访问/挂起（恶意 zip 写入 `nul` 等）。
      if (_windowsReservedDevice.hasMatch(trimmed)) return true;
      return false;
    });
  }

  /// Windows 保留设备名（不带/带扩展名均拒绝）。
  static final _windowsReservedDevice = RegExp(
    r'^(CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])(\..*)?$',
    caseSensitive: false,
  );

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
        final override = _copyFileOverride;
        if (override != null) {
          override(entry.path, target.path);
        } else {
          entry.copySync(target.path);
        }
      }
    }
  }
}
