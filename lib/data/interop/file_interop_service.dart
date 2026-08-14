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
        // 指令通道显式路径：防御校验（防深链/AI 误写非 JSON/覆盖目录）。
        final pathError = _validateExportPath(path);
        if (pathError != null) return AppFailure(pathError);
        targetPath = path;
      } else {
        final picked = await _saveTargetPath(fileName);
        if (picked == null) return const AppFailure('未选择保存位置');
        targetPath = picked;
      }
      final file = File(targetPath);
      await file.writeAsString(text, encoding: utf8);
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
        // 指令通道显式路径：存在性 + .json 扩展名校验（防深链/AI 读任意文件）。
        if (!path.endsWith('.json')) return const AppFailure('导入路径必须以 .json 结尾');
        final target = File(path);
        if (!await target.exists()) return AppFailure('导入文件不存在：$path');
        file = target;
      } else {
        final picked = await _openFile();
        if (picked == null) return const AppFailure('未选择文件');
        file = File(picked.path);
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

  /// 导出显式路径校验：扩展名 `.json`/`.timetrack.json` + 非目录（防误写
  /// 覆盖任意文件/目录）。
  static String? _validateExportPath(String path) {
    if (!path.endsWith('.json')) return '导出路径必须以 .json 结尾';
    try {
      if (FileSystemEntity.isDirectorySync(path)) {
        return '导出路径指向目录，请指定文件';
      }
    } on FileSystemException {
      return null; // 目标不存在：可新建，合法
    }
    return null;
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
