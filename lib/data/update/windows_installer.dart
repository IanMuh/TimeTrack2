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
    int? maxUncompressedEntryBytes,
    int? maxTotalUncompressedBytes,
    int? maxCompressedBytes,
    int? maxEntryCount,
  }) : zipCodec = zipCodec ?? ZipDecoder(),
       assert(
         maxUncompressedEntryBytes == null || maxUncompressedEntryBytes > 0,
       ),
       assert(
         maxTotalUncompressedBytes == null || maxTotalUncompressedBytes > 0,
       ),
       assert(maxCompressedBytes == null || maxCompressedBytes > 0),
       assert(maxEntryCount == null || maxEntryCount > 0),
       maxUncompressedEntryBytes =
           maxUncompressedEntryBytes ?? UpdateConfig.maxUncompressedEntryBytes,
       maxTotalUncompressedBytes =
           maxTotalUncompressedBytes ?? UpdateConfig.maxTotalUncompressedBytes,
       maxCompressedBytes =
           maxCompressedBytes ?? UpdateConfig.maxCompressedBytes,
       maxEntryCount = maxEntryCount ?? UpdateConfig.maxEntryCount;

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

  /// zip bomb 单条目解压后体积上限（可注入小值测试）。
  final int maxUncompressedEntryBytes;

  /// zip bomb 累计解压总体积上限（可注入小值测试）。
  final int maxTotalUncompressedBytes;

  /// zip bomb 压缩后文件大小上限（读入内存前拦截，可注入小值测试）。
  final int maxCompressedBytes;

  /// zip bomb 条目数上限（海量小条目攻击，可注入小值测试）。
  final int maxEntryCount;

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
  /// staging 目录名校验（纯函数，可单测）：返回非法原因，null 表示合法。
  ///
  /// **r16/r17**：除空串/路径分隔符外，`.` 与 `..` 同样危险——`'.'` 解析为
  /// programDir 本身、`'..'` 解析为父目录，下方 staging deleteSync(recursive)
  /// 会递归删除程序目录甚至其父目录（灾难性）。另按 Win32 CreateDirectory 的
  /// **尾部空格/点号裁剪规范化**预先折叠判断：该规范化**同时裁剪尾部空格与
  /// 点号**（可交错出现：`'.. .'`→`'..'`、`'. .'`→`'.'`、`'...'`→`''`）——
  /// 须循环折叠到稳定后再判空/`.`/`..`（仅 trimRight 裁空白会漏尾部点号变体，
  /// 这些名称在 Windows 上仍折叠回 programDir 本身或其父目录）。
  static String? stagingNameError(String name) {
    if (name.isEmpty) return 'staging 目录名配置非法（空）';
    var normalized = name;
    while (normalized.isNotEmpty &&
        (normalized.endsWith(' ') || normalized.endsWith('.'))) {
      // **遇 `.`/`..` 即停（r18）**：Win32 规范化下这两个是特殊目录名、保留
      // 折叠目标（`'.. .'`→`'..'`、`'. .'`→`'.'`），不继续裁成空串——使下方
      // `.`/`..` 分支可达（全点号变体精确停在对应特殊目录名），与折叠语义一致。
      if (normalized == '.' || normalized == '..') break;
      normalized = normalized.substring(0, normalized.length - 1);
    }
    if (normalized.isEmpty) return 'staging 目录名配置非法（裁剪后为空）';
    if (normalized == '.' || normalized == '..') {
      return 'staging 目录名配置非法（裁剪后为 `.`/`..`）';
    }
    if (name.contains('/') || name.contains(r'\')) {
      return 'staging 目录名配置非法（含路径分隔符）';
    }
    return null;
  }

  Future<AppResult<String>> prepareStaging(String zipPath) async {
    // **staging 目录名运行时校验（r15/r16）**：windowsStagingDirName 若被误改
    // 为空串/`.`/`..`/含路径分隔符，`$programDir/$stagingName` 会指向
    // programDir 本身或其父目录——下方 deleteSync(recursive) 会直接递归删除
    // 整个程序目录（灾难性）。防御性校验（常量配置错误早失败）。
    final stagingName = UpdateConfig.windowsStagingDirName;
    final nameError = stagingNameError(stagingName);
    if (nameError != null) {
      return AppFailure(nameError);
    }
    final staging = Directory('$programDir/$stagingName');
    try {
      if (staging.existsSync()) {
        staging.deleteSync(recursive: true);
      }
      staging.createSync(recursive: true);
      // **zip bomb 压缩后大小上限（r13）**：`readAsBytesSync` 会整包读入内存、
      // `decodeBytes` 建全量条目对象——读入前按**压缩后文件大小**与**条目数**
      // 拦截（恶意高压缩比包：压缩后小、解压后巨大——压缩后上限挡包体积，
      // 条目数上限挡海量小条目攻击）。
      if (File(zipPath).lengthSync() > maxCompressedBytes) {
        throw StateError('更新包压缩后体积超上限');
      }
      final bytes = File(zipPath).readAsBytesSync();
      // **zip bomb 防护（r9）**：恶意/异常更新包可用高压缩比条目（zip bomb）
      // 使进程 OOM 或磁盘写满——解压前校验包大小与单条目/累计解压体积上限。
      final archive = zipCodec.decodeBytes(bytes);
      var fileCount = 0;
      var totalUncompressed = 0;
      for (final file in archive.files) {
        // **条目数对全部条目计数（r19）**：只计文件条目会让"几十万条 d0/、
        // d1/… 目录条目"的包在 decodeBytes 阶段即物化海量 ArchiveFile 对象、
        // fileCount 恒为 0——上限形同虚设（OOM 风险）。文件+目录统一计数，
        // 且检查位于任何 content 解压之前（上限检查先于惰性解压）。
        fileCount += 1;
        if (fileCount > maxEntryCount) {
          throw StateError('更新包条目数超上限');
        }
        if (file.isFile) {
          final name = file.name;
          // zip-slip 防护：拒绝路径穿越（`..` 段/绝对路径/盘符路径/尾部空格
          // 规范化绕过/保留设备名）——否则恶意 zip 可把文件写入 staging 之外
          //（如覆盖程序目录/系统路径）。
          if (_isUnsafePath(name)) {
            throw StateError('更新包包含非法路径条目（路径穿越风险）：$name');
          }
          // **zip bomb 双层校验（r11）**：
          // 1) **预检**：中央目录声明的 `file.size` 超单条目上限直接拒绝——
          //    防超限包先被整条惰性解压进内存（archive 4.x 的 content getter
          //    一次性全量解压；声明即超限的包先解压再拒会白耗内存/CPU）；
          // 2) **终检**：元数据可被攻击者伪造（声明小、实际 deflate 流大）——
          //    解压后按真实 `content.length` 再判一次（绕过预检的伪造条目在此
          //    被拦）。
          // **剩余内存风险（如实声明）**：即便双检，恶意条目仍可能在 content
          // 解压完成前分配大内存（预检只挡声明值超限、伪造条目挡在解压后）；
          // 完全消除需流式解压（archive 4.x decodeStream 逐条目流式），本阶段
          // 以预检剪枝 + 终检兜底缓解，流式解压记入后续优化。
          if (file.size > maxUncompressedEntryBytes) {
            throw StateError('更新包条目声明体积超上限：$name');
          }
          final content = file.content as List<int>;
          if (content.length > maxUncompressedEntryBytes) {
            throw StateError('更新包条目实际解压后体积超上限：$name');
          }
          totalUncompressed += content.length;
          // 累计解压体积上限（同样按实际长度）。
          if (totalUncompressed > maxTotalUncompressedBytes) {
            throw StateError('更新包解压总体积超上限');
          }
          final out = File('${staging.path}/$name');
          out.createSync(recursive: true);
          out.writeAsBytesSync(content, flush: true);
        }
      }
      if (fileCount == 0) {
        // **空包判定（r19）**：无任何条目（文件或目录）——防 applyStaging
        // 把程序目录清空成空壳；仅含目录条目的包 fileCount>0 不在此拦截
        //（staging 无文件可写，applyStaging 的"递归含普通文件"守卫会拒绝）。
        throw StateError('更新包为空（无任何条目）');
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
    // **staging 路径防御性校验（r19）**：入参必须严格等于
    // `$programDir/<windowsStagingDirName>`（prepareStaging 的返回值）——若
    // 阶段 3/4 启动逻辑误传 programDir 本身，前置守卫照样通过（其含普通文件），
    // 随后 _clearProgramDir 清空程序目录、staging.listSync 仅剩备份、renameSync
    // 到自身为 no-op、deleteSync(recursive) 连备份一并删除并返回成功——程序
    // 目录被清空且备份销毁、不可恢复。按规范化绝对路径比较（防相对路径/尾斜杠
    // 差异绕过），不符直接失败（未改动程序目录）。
    final expectedStaging = Directory(
      '$programDir/${UpdateConfig.windowsStagingDirName}',
    ).absolute.path;
    if (Directory(stagingPath).absolute.path != expectedStaging) {
      return const AppFailure('安装暂存路径非法（须为程序目录下的 staging 目录），已中止（未改动程序目录）');
    }
    final staging = Directory(stagingPath);
    final backupDir = Directory(
      '$programDir/.backup-${DateTime.now().millisecondsSinceEpoch}',
    );
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
        _copyDirectory(
          Directory(programDir),
          backupDir,
          exclude: const {UpdateConfig.windowsStagingDirName},
        );
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
      // **陈旧备份清理（r19）**：历史上回滚失败/清理失败残留的 `.backup-*`
      // 永不被回收（备份/清空都排除之、本次只删当前 backupDir）——多次失败
      // 长期累积陈旧备份占用磁盘。成功安装后 best-effort 清理其它 `.backup-*`
      //（仅保留最新一个供短窗口内手动回滚，防误删仍在用的最新备份）。
      try {
        final stale =
            Directory(programDir)
                .listSync(followLinks: false)
                .where(
                  (e) =>
                      e is Directory &&
                      e.path.startsWith('$programDir/.backup-'),
                )
                .where((e) => e.path != backupDir.path)
                .toList()
              ..sort(
                (a, b) =>
                    b.uri.pathSegments.last.compareTo(a.uri.pathSegments.last),
              );
        if (stale.isNotEmpty) {
          for (final old in stale.skip(1)) {
            old.deleteSync(recursive: true);
          }
        }
      } on FileSystemException {
        // 清理失败不影响安装成功结论。
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
      return AppFailure('安装更新失败，且回滚未完成（备份保留在 $backupDir，请手动恢复）：$e');
    }
  }

  /// 目录是否**递归含至少一个普通文件**（防仅含空子目录的 staging 通过守卫）。
  /// `followLinks: false`（r19）：目录符号链接/联接不被视为目录递归（防指向
  /// 外部目录的链接被递归扫描/跟随），**Link 条目不算普通文件**（staging 仅含
  /// 链接+空目录时守卫须拒绝——链接不是可安装内容）。
  static bool _containsRegularFile(Directory dir) {
    for (final entry in dir.listSync(followLinks: false)) {
      if (entry is File) return true;
      if (entry is Directory && _containsRegularFile(entry)) return true;
      // Link：跳过（不跟随、不算普通文件）。
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
      // **裁剪后为空恒不安全（r10）**：`' '`/`'...'` 等经 Win32 规范化后会
      // 归一化为空名/`.`——写入抛非法文件名异常或落盘非预期名称，一律拒绝。
      if (trimmed.isEmpty) return true;
      if (trimmed == '.' || trimmed == '..') return true;
      // **保留设备名（r9，r10 修正，r12 补 ADS/CONIN$）**：CON/NUL/PRN/AUX/
      // COM1-9/LPT1-9——防设备访问/挂起（恶意 zip 写入 `nul` 等）。**空格
      // 绕过**：`CON .txt` 因中间空格不匹配 `CON(\..*)?$`，但 Win32 裁剪文件
      // 主名（最后一个点之前部分）尾部空格后解析为 `CON.txt`——按第一个点
      // 拆主名、主名裁剪尾部空格/点号后再匹配。
      final main = trimmed.split('.').first.replaceAll(RegExp(r'[. ]+$'), '');
      // **ADS/冒号形式（r12，r13 修正）**：`CON::$DATA`/`NUL:$DATA` 会解析为
      // 对 CON/NUL 设备的访问（写屏/挂起）；`foo.txt:evil` 会被解析为
      // `foo.txt` 的 NTFS 备用数据流——Windows 常规文件名不允许冒号，**整段**
      // 含 `:` 一律拒绝（盘符路径已在整体级拦截，此处覆盖扩展名段冒号）。
      if (trimmed.contains(':')) return true;
      if (_windowsReservedDevice.hasMatch(main)) return true;
      // **控制台句柄（r12，r13 修正）**：CONIN$/CONOUT$ 不在设备名正则内、
      // Win32 会将其解析为控制台句柄——**大小写不敏感**拒绝（Windows 设备名
      // 解析不区分大小写，精确大写比较会漏 `conin$`/`conout$`）。
      if (main.toLowerCase() == r'conin$' || main.toLowerCase() == r'conout$') {
        return true;
      }
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
  static String _basename(String path) => path.split(RegExp(r'[\\/]')).last;

  void _clearProgramDir() {
    for (final entry in Directory(programDir).listSync(followLinks: false)) {
      final name = _basename(entry.path);
      if (name == UpdateConfig.windowsStagingDirName) continue;
      if (name.startsWith('.backup-')) continue;
      entry.deleteSync(recursive: true);
    }
  }

  void _copyDirectory(
    Directory from,
    Directory to, {
    required Set<String> exclude,
  }) {
    to.createSync(recursive: true);
    for (final entry in from.listSync(followLinks: false)) {
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
      } else if (entry is Link) {
        // **备份链接本身而非指向目标（r19）**：默认跟随会复制链接目标内容
        //（程序目录内指向外部的联接把整个外部目录拷入备份）、循环联接无限
        // 递归；备份链接本身使回滚重建链接（保持原状语义）。
        if (!_isUnsafePath(name)) {
          final fromLink = Link(entry.path);
          final toLink = Link(target.path);
          try {
            final targetPath = fromLink.targetSync();
            toLink.parent.createSync(recursive: true);
            toLink.createSync(targetPath);
          } on FileSystemException {
            // 链接目标读取/创建失败：跳过备份（链接丢失经回滚恢复不了该条目
            // ——与"损坏链接静默跳过"一致，此处显式不中断安装）。
          }
        }
      }
    }
  }
}
