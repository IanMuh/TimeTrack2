/// 更新校验器：SHA-256 比对（清单内嵌值与下载文件）。
///
/// 流程（计划"完整更新系统设计"·管线）：下载完成后比对 [UpdatePlatformArtifact.sha256]
/// 与文件实际哈希；**校验失败删除文件并重下**（[UpdateConfig.redownloadAfterVerificationFailure]
/// 次）——防损坏文件被安装。语义分层：`UpdateDownloader` 只管传输重试，
/// 校验失败的重下由本服务编排。
library;

import 'dart:io' show File, FileSystemException, stderr;

import '../../constants/update_config.dart';
import '../../utils/result.dart';
import '../../viewmodels/update/update_manifest.dart';
import 'update_downloader.dart';

/// 更新校验器。
class UpdateVerifier {
  UpdateVerifier({required this.downloader});

  final UpdateDownloader downloader;

  /// 下载并校验产物；校验通过返回 [UpdateVerifierResult]。
  ///
  /// [onProgress] 透传下载进度。校验失败删除文件重下（最多
  /// [UpdateConfig.redownloadAfterVerificationFailure] 次），仍失败返回可读原因。
  /// **进度重置语义（r22 注明）**：校验失败触发重下时，onProgress 在新一轮下载
  /// 中从 0 重新回调（下载器内部网络重试同样如此）——调用方须感知"下载阶段
  /// 重新开始"（进度条会回退，勿误判"已完成"）；如需精确阶段标识由阶段 3
  /// 编排层维护（本层回调仅携带字节数）。
  Future<AppResult<UpdateVerifierResult>> downloadAndVerify(
    UpdatePlatformArtifact artifact, {
    void Function(int receivedBytes, int? totalBytes)? onProgress,
  }) async {
    for (var attempt = 0; ; attempt++) {
      final downloaded = await downloader.download(
        artifact.url,
        onProgress: onProgress,
      );
      if (downloaded case AppFailure<DownloadResult> failure) {
        return AppFailure(failure.message);
      }
      final result = downloaded.requireValue();
      // **复用下载时边收边算的 SHA-256（r1）**：免二次读盘（大更新包双倍
      // I/O）。文件读取类异常在下载器已归为写盘失败；此处只比字符串。
      final actual = result.sha256;
      if (actual == artifact.sha256.toLowerCase()) {
        return AppSuccess(
          UpdateVerifierResult(
            filePath: result.filePath,
            totalBytes: result.totalBytes,
          ),
        );
      }
      // 校验失败：删除损坏文件，重下（防残留）。
      try {
        File(result.filePath).deleteSync();
      } on FileSystemException {
        // 删除失败不阻塞重下；记录残留路径（防多次失败累积损坏文件且无从排查）。
        // **stderr 写自身保护（r14）**：stderr 已关闭/管道断开时 writeln 会再抛
        // ——包一层防从 downloadAndVerify 逃逸（与下载器一致，保"恒返回 AppResult"）。
        try {
          stderr.writeln('[update] 校验失败且删除损坏文件失败（残留）：${result.filePath}');
        } catch (_) {
          // 日志写入失败不影响失败结论。
        }
      }
      if (attempt >= UpdateConfig.redownloadAfterVerificationFailure) {
        return const AppFailure('更新文件校验失败（SHA-256 不匹配），请稍后重试');
      }
    }
  }
}

/// 校验通过的结果。
class UpdateVerifierResult {
  const UpdateVerifierResult({
    required this.filePath,
    required this.totalBytes,
  });

  /// 校验通过的临时文件路径（可安全用于安装）。
  final String filePath;

  final int? totalBytes;
}
