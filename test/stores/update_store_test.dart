import 'dart:async';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter/foundation.dart' show debugDefaultTargetPlatformOverride, TargetPlatform;
import 'package:flutter_test/flutter_test.dart';
import 'package:timetrack2/api/update/update_downloader.dart';
import 'package:timetrack2/api/update/update_manifest_service.dart';
import 'package:timetrack2/api/update/update_verifier.dart';
import 'package:timetrack2/data/database/app_database.dart' hide ProfileSettings;
import 'package:timetrack2/data/update/windows_installer.dart';
import 'package:timetrack2/stores/update_store.dart';
import 'package:timetrack2/utils/result.dart';
import 'package:timetrack2/viewmodels/update/update_manifest.dart';

/// fake 清单服务：真构造 + 覆写 checkForUpdate（super 的 http client 从不
/// 触达——子类覆写短路）。
class _FakeManifestService extends UpdateManifestService {
  _FakeManifestService(AppDatabase db)
      : super(database: db, currentVersion: '0.1.0');

  AppResult<UpdateCheckResult> Function()? onCheck;

  @override
  Future<AppResult<UpdateCheckResult>> checkForUpdate() async {
    return onCheck?.call() ?? AppSuccess(_noUpdate());
  }

  static UpdateCheckResult _noUpdate() => const UpdateCheckResult(
        available: false,
        latestVersion: '',
        required: false,
        releaseNotes: '',
        windows: null,
        android: null,
      );
}

class _FakeVerifier extends UpdateVerifier {
  _FakeVerifier() : super(downloader: UpdateDownloader()); // 从不触达网络

  AppResult<UpdateVerifierResult> Function()? onDownload;
  void Function(int, int?)? onProgressCapture;
  Completer<void>? gate; // 非空时挂起（重入/进度测试）

  @override
  Future<AppResult<UpdateVerifierResult>> downloadAndVerify(
    UpdatePlatformArtifact artifact, {
    void Function(int receivedBytes, int? totalBytes)? onProgress,
  }) async {
    onProgressCapture = onProgress;
    final g = gate;
    if (g != null) {
      gate = null;
      await g.future;
    }
    return onDownload?.call() ??
        const AppSuccess(UpdateVerifierResult(filePath: 'x.zip', totalBytes: 100));
  }
}

class _FakeWindowsInstaller extends WindowsInstaller {
  _FakeWindowsInstaller(String programDir, String dataDir)
      : super(programDir: programDir, dataDir: dataDir);

  bool writable = true;
  AppResult<String> Function()? onPrepare;
  AppResult<void> Function()? onApply;

  @override
  bool checkWritable() => writable;

  @override
  Future<AppResult<String>> prepareStaging(String zipPath) async =>
      onPrepare?.call() ?? const AppSuccess('staging');

  @override
  Future<AppResult<void>> applyStaging(String stagingPath) async =>
      onApply?.call() ?? const AppSuccess(null);
}

class _TestHarness {
  _TestHarness() {
    db = AppDatabase(NativeDatabase.memory());
    manifest = _FakeManifestService(db);
    verifier = _FakeVerifier();
    // WindowsInstaller 需要绝对路径 programDir（临时目录）。
    final tmp = Directory.systemTemp.createTempSync('tt2-update-test');
    programDir = tmp.path;
    dataDir = '${tmp.path}${Platform.pathSeparator}data';
    installer = _FakeWindowsInstaller(programDir, dataDir);
    store = UpdateStore(
      manifestService: manifest,
      verifier: verifier,
      windowsInstaller: installer,
      database: db,
    );
  }

  late final AppDatabase db;
  late final _FakeManifestService manifest;
  late final _FakeVerifier verifier;
  late final _FakeWindowsInstaller installer;
  late final String programDir;
  late final String dataDir;
  late final UpdateStore store;

  Future<void> close() async {
    store.dispose();
    await db.close();
    try {
      Directory(programDir).deleteSync(recursive: true);
    } catch (e) {
      // 临时目录清理失败不影响结论，但记录原因便于排查。
      stderr.writeln('[test] 临时目录清理失败：$e');
    }
  }
}

const _availableWindows = UpdateCheckResult(
  available: true,
  latestVersion: '1.2.3',
  required: false,
  releaseNotes: '修复若干问题',
  windows: UpdatePlatformArtifact(url: 'u', sha256: 'abc'),
  android: null,
);

void main() {
  group('UpdateStore 状态机迁移', () {
    late _TestHarness h;

    setUp(() {
      // flutter test 默认 defaultTargetPlatform=android——覆盖为 windows
      // 使 _platformArtifact 返回 windows artifact（测试平台判定）。
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      h = _TestHarness();
    });
    tearDown(() async {
      debugDefaultTargetPlatformOverride = null;
      await h.close(); // async 清理（db.close + 临时目录删除）
    });

    test('check：available（含清单信息）', () async {
      h.manifest.onCheck = () => const AppSuccess(_availableWindows);
      final result = await h.store.check();
      expect(result.isSuccess, isTrue);
      expect(h.store.state, UpdateState.available);
      expect(h.store.status.latestVersion, '1.2.3');
      expect(h.store.status.required, isFalse);
      expect(h.store.status.releaseNotes, '修复若干问题');
    });

    test('check：无更新 → upToDate', () async {
      await h.store.check();
      expect(h.store.state, UpdateState.upToDate);
    });

    test('check：失败 → failed', () async {
      h.manifest.onCheck = () => const AppFailure('网络不可用');
      await h.store.check();
      expect(h.store.state, UpdateState.failed);
      expect(h.store.status.errorMessage, '网络不可用');
    });

    test('非法迁移：idle 直接 download 抛 StateError', () async {
      // download 是 async：StateError 在返回 Future 上异步传递——
      // 用 expectLater 捕获（同步 throws 匹配不到）。
      await expectLater(h.store.download(), throwsStateError);
    });

    test('重入保护：下载中再次 download 返回失败（门控挂起真实并发）', () async {
      h.manifest.onCheck = () => const AppSuccess(_availableWindows);
      await h.store.check();
      final gate = Completer<void>();
      h.verifier.gate = gate;
      final downloadFuture = h.store.download(); // 挂起在 gate（downloading 态）
      await pumpEventQueue();
      expect(h.store.state, UpdateState.downloading);

      final concurrent = await h.store.download(); // 重入
      expect(concurrent, isA<AppFailure<UpdateVerifierResult>>()); // 拦截

      // finally 兜底：断言失败也放行首次下载，防 Future 悬挂/泄漏。
      try {
        gate.complete(); // 放行首次下载
        await downloadFuture;
        expect(h.store.state, UpdateState.verifying);
      } finally {
        if (!gate.isCompleted) gate.complete();
      }
    });

    test('完整流程：check → download → verifying → install → restartRequired', () async {
      h.manifest.onCheck = () => const AppSuccess(_availableWindows);
      await h.store.check();
      expect(h.store.state, UpdateState.available);
      final downloaded = await h.store.download();
      expect(downloaded.isSuccess, isTrue);
      expect(h.store.state, UpdateState.verifying);
      final installed = await h.store.install();
      expect(installed.isSuccess, isTrue);
      expect(h.store.state, UpdateState.restartRequired);
    });

    test('install 但未下载：返回失败（无 verified 产物）', () async {
      h.manifest.onCheck = () => const AppSuccess(_availableWindows);
      await h.store.check();
      final result = await h.store.install(); // 绕过 download
      expect(result.isSuccess, isFalse);
    });

    test('下载失败：进度清零回 failed，可重试下载', () async {
      h.manifest.onCheck = () => const AppSuccess(_availableWindows);
      await h.store.check();
      h.verifier.onDownload = () => const AppFailure('校验失败');
      final result = await h.store.download();
      expect(result.isSuccess, isFalse);
      expect(h.store.state, UpdateState.failed);
      expect(h.store.status.errorMessage, '校验失败');
      // 修复后重试：failed → downloading 合法。
      h.verifier.onDownload = null;
      final retry = await h.store.download();
      expect(retry.isSuccess, isTrue);
      expect(h.store.state, UpdateState.verifying);
    });

    test('进度回调驱动字段更新（不逐条迁移状态）', () async {
      h.manifest.onCheck = () => const AppSuccess(_availableWindows);
      await h.store.check();
      final future = h.store.download();
      h.verifier.onProgressCapture!(50, 100);
      await future;
      expect(h.store.status.receivedBytes, 50); // 进度字段被更新
      expect(h.store.status.totalBytes, 100);
      expect(h.store.state, UpdateState.verifying);
    });

    test('Android 平台：download 用 android artifact，install 返回阶段 4 未支持', () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      final androidAvailable = UpdateCheckResult(
        available: true,
        latestVersion: '1.2.3',
        required: false,
        releaseNotes: '',
        windows: null,
        android: UpdatePlatformArtifact(url: 'apk-url', sha256: 'def'),
      );
      h.manifest.onCheck = () => AppSuccess(androidAvailable);
      await h.store.check();
      expect(h.store.state, UpdateState.available);
      final downloaded = await h.store.download();
      expect(downloaded.isSuccess, isTrue); // android artifact 下载完成
      final installed = await h.store.install();
      expect(installed.isSuccess, isFalse); // 阶段 4 未支持
      expect(h.store.state, UpdateState.failed);
      expect(h.store.status.errorMessage, contains('阶段 4'));
    });

    test('recordLastCheckedVersion：持久化清单版本', () async {
      await h.store.recordLastCheckedVersion('1.2.3');
      final row = await (h.db.select(h.db.appMetadata)
            ..where((t) => t.key.equals('last_checked_manifest_version')))
          .getSingle();
      expect(row.value, '1.2.3');
    });

    test('安装：程序目录不可写 → failed', () async {
      h.manifest.onCheck = () => const AppSuccess(_availableWindows);
      await h.store.check();
      await h.store.download();
      h.installer.writable = false;
      final result = await h.store.install();
      expect(result.isSuccess, isFalse);
      expect(h.store.state, UpdateState.failed);
    });

    test('ignoreCurrentVersion：持久化版本到 app_metadata', () async {
      h.manifest.onCheck = () => const AppSuccess(_availableWindows);
      await h.store.check();
      await h.store.ignoreCurrentVersion();
      final row = await (h.db.select(h.db.appMetadata)
            ..where((t) => t.key.equals('ignored_update_version')))
          .getSingle();
      expect(row.value, '1.2.3');
    });
  });
}
