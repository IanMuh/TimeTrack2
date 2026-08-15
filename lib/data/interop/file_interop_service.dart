import 'dart:convert';
import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/services.dart'
    show MissingPluginException, PlatformException;
import 'package:intl/intl.dart';
import 'package:path/path.dart' as p;

import '../../utils/result.dart';
import '../sync/sync_bundle_codec.dart';
import '../sync/sync_bundle_repository.dart';

/// 文件互通：.timetrack.json 导入/导出（与 LAN 共用 SyncBundle 形态）。
///
/// - 导出：file_selector 保存对话框（文件名 `timetrack-<yyyyMMdd-HHmmss>.timetrack.json`），
///   平台不支持对话框时降级选目录/文档目录（老项目语义）
/// - 导入：file_selector 打开 → decode 校验（schema_version 1..2、必填字段，
///   解析校验先于任何写库）→ mergeBundle（单事务行级 LWW）→ 归一化
class FileInteropService {
  FileInteropService({required this.syncBundleRepository});

  final SyncBundleRepository syncBundleRepository;

  static const _extensions = ['json'];

  /// 导入文件大小上限（防深链/AI 通道传入超大/恶意 .timetrack.json 一次性
  /// 读入内存耗尽——`readAsString` 会整文件缓冲）。
  static const maxImportFileBytes = 50 * 1024 * 1024; // 50 MB（正常导出远小于此）

  /// 导出全部数据到用户选择的 .timetrack.json。
  ///
  /// [path]（可选，模块 3d 指令通道）：**显式文件路径**——非空时直接写入
  /// 该路径（跳过 file_selector 对话框，供 AI/深链/自动化指令调用）；null
  /// 时走对话框选择（阶段 4 UI 用）。返回实际写入路径。
  Future<AppResult<String?>> export({
    required String sourceDeviceId,
    String? path,
  }) async {
    try {
      final bundle = await syncBundleRepository.exportBundle(
        sourceDeviceId: sourceDeviceId,
      );
      final text = const SyncBundleCodec().encode(bundle);
      final fileName =
          'timetrack-${DateFormat('yyyyMMdd-HHmmss').format(DateTime.now())}'
          '.timetrack.json';

      final String targetPath;
      if (path != null && path.isNotEmpty) {
        // 指令通道显式路径：防御校验 + 符号链接解析（防深链/AI 误写非 JSON、
        // 覆盖目录、或经符号链接绕过扩展名约束覆盖任意 .json 文件）。
        final resolved = _resolvedExportPath(path);
        if (resolved case AppFailure<String> failure) {
          return AppFailure(failure.message);
        }
        targetPath = resolved.requireValue();
      } else {
        final picked = await _saveTargetPath(fileName);
        if (picked == null) return const AppFailure('未选择保存位置');
        targetPath = picked;
      }
      // **原子写入（r 修复）**：先写同目录临时文件 + flush，成功后再改名覆盖
      // 目标——写入中途崩溃/断电不会留下截断的 .timetrack.json；直接
      // `writeAsString` 到目标会因写入中断产生损坏文件且无法区分新旧。
      // Windows 上 rename 到已存在目标会失败（FileSystemException）——先删
      // 目标再 rename（覆盖语义；删除与 rename 之间的小窗口属可接受边界，
      // 相比"写入中断留下截断文件"已显著改善）。
      final tmpPath = '$targetPath.tmp';
      final tmpFile = File(tmpPath);
      await tmpFile.writeAsString(text, encoding: utf8, flush: true);
      if (await File(targetPath).exists()) {
        await File(targetPath).delete();
      }
      await tmpFile.rename(targetPath);
      return AppSuccess(targetPath);
    } catch (e) {
      return AppFailure('导出失败：$e');
    }
  }

  /// 导入 .timetrack.json（校验 → LWW 合并 → 归一化）。
  ///
  /// [path]（可选，模块 3d 指令通道）：**显式文件路径**——非空时直接读取
  /// 该文件（跳过 file_selector 对话框，供 AI/深链/自动化指令调用）；null
  /// 时走对话框选择（阶段 4 UI 用）。返回包内记录总数。
  Future<AppResult<int>> import({String? path}) async {
    try {
      final File file;
      if (path != null && path.isNotEmpty) {
        // 指令通道显式路径：扩展名 + **符号链接解析 + 常规文件校验**（r 修复）——
        // `exists()` 与读取之间文件可被替换（TOCTOU）、符号链接/目录/FIFO 也能
        // 通过存在性检查——解析符号链接后的最终目标须为常规文件（防深链/AI
        // 经链接读取任意文件）。
        if (!path.endsWith('.json')) {
          return const AppFailure('导入路径必须以 .json 结尾');
        }
        final resolvedPath = _resolvedImportPath(path);
        if (resolvedPath case AppFailure<String> failure) {
          return AppFailure(failure.message);
        }
        file = File(resolvedPath.requireValue());
      } else {
        final picked = await _openFile();
        if (picked == null) return const AppFailure('未选择文件');
        file = File(picked.path);
      }
      // **大小上限（r 修复）**：`readAsString` 会整文件读入内存——深链/AI 通道
      // 可传入超大/恶意 .timetrack.json 导致内存耗尽。读取前按长度预检（
      // 防御：length 与读之间文件被替换时，超限读入仍会被 readAsString 缓冲，
      // 上限为纵深防御而非严格保证）。
      final length = await file.length();
      if (length > maxImportFileBytes) {
        return AppFailure('导入文件过大（> ${maxImportFileBytes ~/ (1024 * 1024)} MB）');
      }
      final text = await file.readAsString(encoding: utf8);
      final bundle = const SyncBundleCodec().decode(text);
      final result = await syncBundleRepository.mergeBundle(bundle);
      if (result case AppFailure<void> failure) {
        return AppFailure('导入合并失败：${failure.message}');
      }
      final normalizeResult = await syncBundleRepository.normalizeAfterMerge();
      if (normalizeResult case AppFailure<void> normalizeFailure) {
        // 数据已合并入库，仅归一化未完成——明确提示避免误导。
        return AppFailure('数据已合并但归一化未完成：${normalizeFailure.message}');
      }
      // 返回包内记录总数（含软删行与 LWW 未覆盖行——语义为"包内记录数"，
      // 供提示展示，不代表实际写入行数）。
      final count = bundle.activities.length +
          bundle.categories.length +
          bundle.categoryLinks.length +
          bundle.timeEntries.length +
          bundle.actionLogs.length;
      return AppSuccess(count);
    } on FormatException catch (e) {
      return AppFailure('导入文件格式非法：${e.message}');
    } catch (e) {
      return AppFailure('导入失败：$e');
    }
  }

  /// 导入路径解析：符号链接解析 + 常规文件校验，返回**最终读取路径**。
  ///
  /// 约束：目标存在且为**常规文件**（解析符号链接后；目录/FIFO/缺失拒绝）。
  /// 读取用解析后路径消除 TOCTOU（校验路径 == 实际读取路径）。
  static AppResult<String> _resolvedImportPath(String path) {
    try {
      if (FileSystemEntity.typeSync(path, followLinks: true) ==
          FileSystemEntityType.notFound) {
        return AppFailure('导入文件不存在：$path');
      }
      final resolved = File(path).resolveSymbolicLinksSync();
      if (FileSystemEntity.typeSync(resolved, followLinks: false) !=
          FileSystemEntityType.file) {
        return AppFailure('导入路径不是常规文件：$path');
      }
      return AppSuccess(resolved);
    } on FileSystemException {
      return AppFailure('导入文件读取失败：$path');
    }
  }

  /// 显式导出路径校验 + 符号链接解析：返回**解析后的最终写入路径**。
  ///
  /// 约束：扩展名 `.json` + 非目录（防误写覆盖任意文件/目录）+ **符号链接
  /// 解析后目标仍满足约束**（防深链/AI 通道经指向其他文件的链接覆盖任意
  /// .json 文件——校验与写入分离会引入 TOCTOU，解析后直接写最终目标消除
  /// 竞态窗口）。目标不存在时原样返回（可新建，合法）。
  static AppResult<String> _resolvedExportPath(String path) {
    if (!path.endsWith('.json')) {
      return const AppFailure('导出路径必须以 .json 结尾');
    }
    try {
      if (FileSystemEntity.typeSync(path, followLinks: true) ==
          FileSystemEntityType.notFound) {
        return AppSuccess(path);
      }
      final resolved = File(path).resolveSymbolicLinksSync();
      if (!resolved.endsWith('.json')) {
        return const AppFailure('导出路径解析后不是 .json 文件');
      }
      if (FileSystemEntity.isDirectorySync(resolved)) {
        return const AppFailure('导出路径指向目录，请指定文件');
      }
      return AppSuccess(resolved);
    } on FileSystemException {
      return AppSuccess(path); // 目标不可解析（如中间链接悬空）：原样返回，写时再报
    }
  }

  /// 保存目标路径（file_selector）；平台不支持保存对话框时降级选目录（老项目语义）。
  Future<String?> _saveTargetPath(String suggestedName) async {
    try {
      final location = await getSaveLocation(
        suggestedName: suggestedName,
        acceptedTypeGroups: const [
          XTypeGroup(
            label: 'TimeTrack JSON',
            extensions: _extensions,
            mimeTypes: ['application/json'],
          ),
        ],
      );
      return location?.path;
    } on UnsupportedError catch (_) {
      return _fallbackDirectoryPath(suggestedName);
    } on MissingPluginException catch (_) {
      // 平台未注册 file_selector 原生实现（method channel 抛此异常）。
      return _fallbackDirectoryPath(suggestedName);
    } on PlatformException catch (_) {
      return _fallbackDirectoryPath(suggestedName);
    }
  }

  /// 降级选目录 + p.join 规范化路径（防双斜杠/UNC 脆弱拼接）。
  Future<String?> _fallbackDirectoryPath(String suggestedName) async {
    final dir = await getDirectoryPath();
    if (dir == null) return null;
    return p.join(dir, suggestedName);
  }

  Future<XFile?> _openFile() {
    return openFile(
      acceptedTypeGroups: const [
        XTypeGroup(
          label: 'TimeTrack JSON',
          extensions: _extensions,
          mimeTypes: ['application/json'],
        ),
      ],
    );
  }
}
