import 'dart:convert';
import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:intl/intl.dart';

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
  Future<AppResult<String?>> export({
    required String sourceDeviceId,
  }) async {
    try {
      final bundle = await syncBundleRepository.exportBundle(
        sourceDeviceId: sourceDeviceId,
      );
      final text = const SyncBundleCodec().encode(bundle);
      final fileName =
          'timetrack-${DateFormat('yyyyMMdd-HHmmss').format(DateTime.now())}'
          '.timetrack.json';

      final location = await _saveLocation(fileName);
      if (location == null) return const AppFailure('未选择保存位置');
      final file = File(location.path);
      await file.writeAsString(text, encoding: utf8);
      return AppSuccess(location.path);
    } catch (e) {
      return AppFailure('导出失败：$e');
    }
  }

  /// 导入 .timetrack.json（校验 → LWW 合并 → 归一化）。
  Future<AppResult<int>> import() async {
    try {
      final file = await _openFile();
      if (file == null) return const AppFailure('未选择文件');
      final text = await file.readAsString(encoding: utf8);
      final bundle = const SyncBundleCodec().decode(text);
      final result = await syncBundleRepository.mergeBundle(bundle);
      if (result.when(onSuccess: (_) => false, onFailure: (_) => true)) {
        return AppFailure('导入合并失败');
      }
      await syncBundleRepository.normalizeAfterMerge();
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

  /// 保存对话框（file_selector）；平台不支持时降级选目录。
  Future<FileSaveLocation?> _saveLocation(String suggestedName) async {
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
    return location;
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
