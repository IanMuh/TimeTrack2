/// 更新清单服务：拉取 `update.json` → 解析校验 → 与本地缓存比较。
///
/// 流程（计划"完整更新系统设计"·管线）：
/// 1. 拉取 [UpdateConfig.defaultManifestUrl]（可被 --dart-define 覆盖）；
/// 2. [UpdateManifest.fromMap] 校验（version/SemVer/sha256/url 快速失败）；
/// 3. 与缓存清单（app_metadata `lastCheckedManifestVersion`）比较：
///    - 远端版本 ≤ 当前应用版本 → 无更新；
///    - 远端版本 ≤ 已忽略版本 → 无更新（"忽略此版本"持久化）；
///    - 否则视为可用更新，缓存远端版本供后续比较。
///
/// 版本比较用 [AppVersion]（SemVer 2.0.0，含 pre-release 规则）。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io' show SocketException, stderr;

import 'package:http/http.dart' as http;

import '../../constants/storage_keys.dart';
import '../../constants/update_config.dart';
import '../../data/database/app_database.dart';
import '../../utils/app_version.dart';
import '../../utils/result.dart';
import '../../viewmodels/update/update_manifest.dart';

/// 检查结果（供阶段 3 编排/UI 使用）。
class UpdateCheckResult {
  const UpdateCheckResult({
    required this.available,
    required this.latestVersion,
    required this.required,
    required this.releaseNotes,
    required this.windows,
    required this.android,
  });

  /// 是否有可用更新。
  final bool available;

  /// 最新可用版本（SemVer 字符串；无更新时为空串）。
  final String latestVersion;

  /// 是否强制更新（不可跳过）。
  final bool required;

  final String releaseNotes;

  /// 各平台产物（无更新/该平台未提供时为 null）。
  final UpdatePlatformArtifact? windows;
  final UpdatePlatformArtifact? android;
}

/// 更新清单服务。
class UpdateManifestService {
  UpdateManifestService({
    required this.database,
    required String currentVersion,
    http.Client? httpClient,
    Uri? manifestUrl,
  }) : _current = AppVersion.parse(
         currentVersion,
       ), // 前置条件：currentVersion 必须合法 SemVer（构造期同步抛 FormatException）
       _http = httpClient ?? http.Client(),
       _ownsHttp = httpClient == null,
       _manifestUrl = manifestUrl ?? UpdateConfig.defaultManifestUrl;

  final AppDatabase database;
  final http.Client _http;

  /// 是否自建 http client（close 时释放；注入对象由调用方负责生命周期）。
  final bool _ownsHttp;
  final Uri _manifestUrl;
  final AppVersion _current;

  /// 是否已 close（close 后 checkForUpdate 返回可读失败，防 StateError 逃逸）。
  bool _closed = false;

  /// 释放自建 http client（注入对象由调用方负责生命周期）。
  void close() {
    if (_closed) return;
    _closed = true;
    if (_ownsHttp) {
      _http.close();
    }
  }

  /// 检查更新；失败返回可读原因（网络/清单损坏/已关闭）。
  Future<AppResult<UpdateCheckResult>> checkForUpdate() async {
    if (_closed) {
      return const AppFailure('更新服务已关闭，请重新创建');
    }
    final http.Response response;
    try {
      response = await _http
          .get(_manifestUrl)
          .timeout(UpdateConfig.checkTimeout);
      // **await 期间可能已被 close（r3）**：资源已释放，不再继续评估——
      // 防"等待期间 close → 成功继续 _evaluate 写库返回成功"违背已关闭语义。
      if (_closed) {
        return const AppFailure('更新服务已关闭，请重新创建');
      }
    } on TimeoutException {
      // 请求期间可能已被 close（自建 client 强关/超时都可能）——先判 _closed
      // 归因"已关闭"（防误导性"网络不可用/超时"）。
      if (_closed) return const AppFailure('更新服务已关闭，请重新创建');
      return const AppFailure('更新检查超时，请稍后重试');
    } on SocketException {
      if (_closed) return const AppFailure('更新服务已关闭，请重新创建');
      return const AppFailure('网络不可用，请稍后重试');
    } on http.ClientException {
      if (_closed) return const AppFailure('更新服务已关闭，请重新创建');
      return const AppFailure('网络不可用，请稍后重试');
    } on StateError catch (e) {
      // **仅当 _closed 或消息匹配时才归因"已关闭"（r14）**：自建 client 在
      // 请求期间被 close 强关时可能抛 StateError('Client is already closed')；
      // 其它 StateError（编程错误）不应被包装成误导性关闭文案——与下载器
      // "Error 不吞"的取舍一致，非关闭 StateError 重新抛出交全局处理。
      if (_closed || e.message.contains('already closed')) {
        return const AppFailure('更新服务已关闭，请重新创建');
      }
      rethrow;
    }
    if (response.statusCode != 200) {
      return AppFailure('更新清单获取失败（${response.statusCode}）');
    }
    final UpdateManifest manifest;
    try {
      manifest = UpdateManifest.fromMap(
        jsonDecode(response.body) as Map<String, Object?>,
      );
    } on FormatException catch (e) {
      return AppFailure('更新清单解析失败：${e.message}');
    } on TypeError {
      // jsonDecode 顶层非对象（数组/标量）。
      return const AppFailure('更新清单结构异常');
    }
    return _evaluate(manifest);
  }

  /// 评估清单：版本比较 + 缓存。**纯逻辑（可单测）**——与网络解耦。
  /// **入口复查 _closed（r9）**：与 checkForUpdate 的关闭语义统一——close 后
  /// 立即失败（防先做一次不必要的 DB 读、到写库前才拒绝）。
  Future<AppResult<UpdateCheckResult>> evaluate(UpdateManifest manifest) async {
    if (_closed) {
      return const AppFailure('更新服务已关闭，请重新创建');
    }
    return _evaluate(manifest);
  }

  Future<AppResult<UpdateCheckResult>> _evaluate(
    UpdateManifest manifest,
  ) async {
    // **版本解析容错**：UpdateManifest.fromMap 的正则只校验格式、不检查数字段
    // 是否超出 Dart int 范围——超大数字段（如 9999999999999999999999.0.0）会
    // 在 AppVersion.parse 抛 FormatException。包一层 catch 返回可读失败，防
    // checkForUpdate 崩溃。
    final AppVersion remote;
    try {
      remote = AppVersion.parse(manifest.version);
    } on FormatException {
      return const AppFailure('更新清单版本号格式非法');
    }
    // 远端版本 ≤ 当前应用版本 → 无更新。
    if (!(_current < remote)) {
      return AppSuccess(_none(manifest));
    }
    // "忽略此版本"：用户选择忽略的版本不再提示（远端 ≤ 已忽略版本即跳过）。
    // **脏数据容错**：本地忽略版本可能被写入非 SemVer（旧数据/手动改库）——
    // 解析失败视为"未忽略"，继续走更新判定（不崩溃）。
    final ignored = await _readString(AppMetadataKeys.ignoredUpdateVersion);
    if (ignored != null) {
      try {
        if (!(AppVersion.parse(ignored) < remote)) {
          return AppSuccess(_none(manifest));
        }
      } on FormatException {
        // 本地脏数据：视为未忽略，继续。
      }
    }
    // 可用更新：缓存远端版本（供"检查过但未装"的后续判断）。
    // **写库前复查（r4）**：_evaluate 的 DB await 期间若被 close，不再落缓存
    //（严格"已关闭语义"——不写入状态）。
    if (_closed) {
      return const AppFailure('更新服务已关闭，请重新创建');
    }
    await _writeString(
      AppMetadataKeys.lastCheckedManifestVersion,
      manifest.version,
    );
    return AppSuccess(
      UpdateCheckResult(
        available: true,
        latestVersion: manifest.version,
        required: manifest.required,
        releaseNotes: manifest.releaseNotes,
        windows: manifest.windows,
        android: manifest.android,
      ),
    );
  }

  UpdateCheckResult _none(UpdateManifest manifest) => UpdateCheckResult(
    available: false,
    latestVersion: '',
    required: false,
    releaseNotes: '',
    windows: null,
    android: null,
  );

  Future<String?> _readString(String key) async {
    try {
      final query = database.select(database.appMetadata)
        ..where((t) => t.key.equals(key));
      final row = await query.getSingleOrNull();
      return row?.value;
    } catch (e) {
      // **DB 异常容错（r14）**：更新检查期间数据库可能被关闭/约束异常——
      // 读失败回退 null（视为"未忽略"继续判定，不崩溃），与"恒返回可读
      // AppResult"契约一致。详细原因写日志。
      stderr.writeln('[update] 读取本地状态失败：$e');
      return null;
    }
  }

  Future<void> _writeString(String key, String value) async {
    try {
      await database
          .into(database.appMetadata)
          .insertOnConflictUpdate(
            AppMetadataCompanion.insert(key: key, value: value),
          );
    } catch (e) {
      // **写失败降级（r14）**：缓存清单版本失败不阻断更新流程——仅本次
      // 不缓存（下次检查仍会重新判断），防 DB 异常使 checkForUpdate 崩溃。
      stderr.writeln('[update] 写入本地状态失败：$e');
    }
  }
}
