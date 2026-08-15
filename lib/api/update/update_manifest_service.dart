/// 更新清单服务：拉取 `update.json` → 解析校验 → 版本判定。
///
/// 流程（计划"完整更新系统设计"·管线）：
/// 1. 拉取 [UpdateConfig.defaultManifestUrl]（可被 --dart-define 覆盖）；
/// 2. [UpdateManifest.fromMap] 校验（version/SemVer/sha256/url 快速失败）；
/// 3. 版本判定（**不依赖"缓存清单比较"**——`lastCheckedManifestVersion` 仅
///    记录最近成功检查版本供阶段 3 编排展示，本服务不读该键）：
///    - 远端版本 ≤ 当前应用版本 → 无更新；
///    - 远端版本 ≤ 已忽略版本 → 无更新（"忽略此版本"持久化；强制更新不受
///      忽略影响）；
///    - 否则视为可用更新，缓存远端版本供后续展示。
///
/// 版本比较用 [AppVersion]（SemVer 2.0.0，含 pre-release 规则）。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io' show HttpException, SocketException, TlsException, stderr;
import 'dart:typed_data' show BytesBuilder;

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

  /// "已关闭"失败文案（r22 抽为类级常量——文件内多分支重复，统一维护）。
  static const _closedMessage = '更新服务已关闭，请重新创建';

  /// 释放自建 http client（注入对象由调用方负责生命周期）。
  void close() {
    if (_closed) return;
    _closed = true;
    if (_ownsHttp) {
      _http.close();
    }
  }

  /// **取消流订阅并吞掉流错误（r24 辅助）**：错误响应体/已关闭后不消费——
  /// 无界消费耗带宽占连接；listen 需 onError 处理器防流错误成为未捕获异步
  /// 异常；cancel 立即停止读取、释放连接。3 处调用点统一（防后续调整漏改）。
  static void _cancelStream(http.StreamedResponse response) {
    response.stream.listen(null, onError: (_) {}).cancel().ignore();
  }

  /// 检查更新；失败返回可读原因（网络/清单损坏/已关闭）。
  Future<AppResult<UpdateCheckResult>> checkForUpdate() async {
    if (_closed) {
      return const AppFailure(_closedMessage);
    }
    final http.StreamedResponse response;
    try {
      response = await _http
          .send(http.Request('GET', _manifestUrl))
          .timeout(UpdateConfig.checkTimeout);
      // **await 期间可能已被 close（r3）**：资源已释放，不再继续评估——
      // 防"等待期间 close → 成功继续 _evaluate 写库返回成功"违背已关闭语义。
      if (_closed) {
        _cancelStream(response);
        return const AppFailure(_closedMessage);
      }
    } on TimeoutException {
      // 请求期间可能已被 close（自建 client 强关/超时都可能）——先判 _closed
      // 归因"已关闭"（防误导性"网络不可用/超时"）。
      if (_closed) return const AppFailure(_closedMessage);
      return const AppFailure('更新检查超时，请稍后重试');
    } on SocketException {
      if (_closed) return const AppFailure(_closedMessage);
      return const AppFailure('网络不可用，请稍后重试');
    } on HttpException {
      // **r19 补充**：http 包仅把 send 阶段与部分流中错误包装为 ClientException、
      // 其余透传——dart:io 的 HttpException/TlsException（含握手失败、证书校验
      // 失败）会直接逃逸（与下载器/supabase_remote_tables 既有处理一致）。
      if (_closed) return const AppFailure(_closedMessage);
      return const AppFailure('网络不可用，请稍后重试');
    } on TlsException {
      // **r22 修正**：SDK 层级为 `HandshakeException extends TlsException`
      //（secure_socket.dart）——`on TlsException` 已捕获握手/证书校验失败的
      // HandshakeException（Android/iOS CERTIFICATE_VERIFY_FAILED 等），无需
      // 单独分支（先前的 `on HandshakeException` 分支是死代码，已移除）。
      if (_closed) return const AppFailure(_closedMessage);
      return const AppFailure('网络不可用，请稍后重试');
    } on http.ClientException {
      if (_closed) return const AppFailure(_closedMessage);
      return const AppFailure('网络不可用，请稍后重试');
    } on StateError catch (e) {
      // **仅当 _closed 或消息匹配时才归因"已关闭"（r14）**：自建 client 在
      // 请求期间被 close 强关时可能抛 StateError('Client is already closed')；
      // 其它 StateError（编程错误）不应被包装成误导性关闭文案——与下载器
      // "Error 不吞"的取舍一致，非关闭 StateError 重新抛出交全局处理。
      if (_closed || e.message.contains('already closed')) {
        return const AppFailure(_closedMessage);
      }
      rethrow;
    }
    if (response.statusCode != 200) {
      // **取消订阅立即中止（r23）**：错误响应体无界消费会耗带宽/占连接——
      // 与下载器非 200 分支一致。
      _cancelStream(response);
      return AppFailure('更新清单获取失败（${response.statusCode}）');
    }
    // **清单响应体大小上限（r23 流式）**：`http.get` 会先把整个响应体缓冲进
    // 内存才返回（对超大清单预检发生在缓冲之后、OOM 未消除）——改用
    // `_http.send` 拿 StreamedResponse 后**逐块消费**：contentLength 前置拦截 +
    // 流式累计超限即中止（与下载器 _maxBytes 同款方案）。防恶意服务器在
    // checkTimeout 内高速推流超大清单耗尽内存。
    // **总时限（r24）**：`stream.timeout` 是相邻事件**空闲**超时——恶意慢速
    // 服务器 1 字节/7.9s 推流可无限挂起（旧 `_http.get` 8s 总时限保证失效）。
    // 记录截止时间、每块复查，超时抛 TimeoutException（与下载器语义对齐：
    // 头超时 + 体超时分离，此处体读取受同一 checkTimeout 总时限约束）。
    final maxManifestBytes = UpdateConfig.maxManifestBytes;
    if (response.contentLength != null &&
        response.contentLength! > maxManifestBytes) {
      _cancelStream(response);
      return const AppFailure('更新清单体积超上限');
    }
    final builder = BytesBuilder(copy: false);
    var received = 0;
    // **总时限用单调时钟（r25）**：DateTime.now() 墙钟受系统时钟调整影响
    //（NTP 校时/手动改时前跳误判超时、后跳放宽时限）——Stopwatch 与
    // stream.timeout 的 Timer 语义一致，保证总时限稳定可信。
    final sw = Stopwatch()..start();
    try {
      await for (final chunk in response.stream.timeout(
        UpdateConfig.checkTimeout,
      )) {
        // **`_closed` 优先（r25 调序）**：close() 后恰逢下一块使 received 超限
        // 时须归因"已关闭"（与各 catch 分支"先判 _closed"的约定一致）。
        if (_closed) {
          return const AppFailure(_closedMessage);
        }
        if (sw.elapsed > UpdateConfig.checkTimeout) {
          throw TimeoutException('更新清单读取超时');
        }
        received += chunk.length;
        if (received > maxManifestBytes) {
          throw const ManifestTooLargeException();
        }
        // **循环内 _closed 复查（r24）**：注入 client 不由本服务关闭、底层流
        // 不被中断——close() 期间循环仍会消费完整响应体；每块后立即返回（
        // await for 退出自动取消订阅、释放连接）。
        if (_closed) {
          return const AppFailure(_closedMessage);
        }
        builder.add(chunk);
      }
      if (_closed) {
        return const AppFailure(_closedMessage);
      }
    } on ManifestTooLargeException {
      return const AppFailure('更新清单体积超上限');
    } on TimeoutException {
      if (_closed) return const AppFailure(_closedMessage);
      return const AppFailure('更新检查超时，请稍后重试');
    } on SocketException {
      if (_closed) return const AppFailure(_closedMessage);
      return const AppFailure('网络不可用，请稍后重试');
    } on HttpException {
      if (_closed) return const AppFailure(_closedMessage);
      return const AppFailure('网络不可用，请稍后重试');
    } on TlsException {
      if (_closed) return const AppFailure(_closedMessage);
      return const AppFailure('网络不可用，请稍后重试');
    } on http.ClientException {
      if (_closed) return const AppFailure(_closedMessage);
      return const AppFailure('网络不可用，请稍后重试');
    } on StateError catch (e) {
      if (_closed || e.message.contains('already closed')) {
        return const AppFailure(_closedMessage);
      }
      rethrow;
    }
    final UpdateManifest manifest;
    try {
      // **显式 UTF-8 解码（r19）**：response.body 按响应头 charset 解码、未
      // 指定时默认 latin-1（JSON 规范要求 UTF-8）——清单服务器只发
      // application/json 无 charset 时中文 releaseNotes 会乱码。按原始字节
      // 显式 utf8 解码。
      manifest = UpdateManifest.fromMap(
        jsonDecode(utf8.decode(builder.takeBytes())) as Map<String, Object?>,
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
      return const AppFailure(_closedMessage);
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
      return AppSuccess(_none());
    }
    // "忽略此版本"：用户选择忽略的版本不再提示（远端 ≤ 已忽略版本即跳过）。
    // **强制更新不受忽略影响（r19）**：required=true 语义为"不可跳过"——强制/
    // 安全更新若被用户此前忽略过会静默跳过，违背设计。required 时不读忽略
    // 版本、直接判为可用更新。
    // **脏数据容错**：本地忽略版本可能被写入非 SemVer（旧数据/手动改库）——
    // 解析失败视为"未忽略"，继续走更新判定（不崩溃）。
    final ignored = manifest.required
        ? null
        : await _readString(AppMetadataKeys.ignoredUpdateVersion);
    // **close 复查（r 修复）**：`_readString` 的 DB await 窗口内 close() 可能
    // 被并发调用——命中"已忽略"分支直接返回"无更新"会违背"close 后立即失败"
    // 语义（调用方拿到"无更新"而非"服务已关闭"）。与写库前复查对齐。
    if (_closed) {
      return const AppFailure(_closedMessage);
    }
    if (ignored != null) {
      try {
        if (!(AppVersion.parse(ignored) < remote)) {
          return AppSuccess(_none());
        }
      } on FormatException {
        // 本地脏数据：视为未忽略，继续。
      }
    }
    // 可用更新：缓存远端版本。
    // **用途澄清（r22）**：`lastCheckedManifestVersion` 为阶段 3 编排预留的
    // "最近一次成功检查的版本"记录（供 UI/更新状态机展示"已检查过"），**本服务
    // 不做该键的读取比较**——是否提示更新仅由"远端 > 当前版本"与"未忽略"决定；
    // 消费方须按此语义使用（勿误以为写库即"检查过不再提示"）。
    // **写库前复查（r4）**：_evaluate 的 DB await 期间若被 close，不再落缓存
    //（严格"已关闭语义"——不写入状态）。
    if (_closed) {
      return const AppFailure(_closedMessage);
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

  UpdateCheckResult _none() => UpdateCheckResult(
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
      // **stderr 写自身保护（r16）**：stderr 已关闭/管道断开时 writeln 再抛
      // 会击穿"读失败回退 null"契约——包一层防从 _readString 逃逸。
      try {
        stderr.writeln('[update] 读取本地状态失败：$e');
      } catch (_) {
        // 日志写入失败不影响回退结论。
      }
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
      // **stderr 写自身保护（r16）**：同上——日志写入失败不影响降级结论。
      try {
        stderr.writeln('[update] 写入本地状态失败：$e');
      } catch (_) {
        // 日志写入失败不影响降级结论。
      }
    }
  }
}

/// 清单响应体超上限（[UpdateConfig.maxManifestBytes]，r23）。
///
/// **独立类型**：流式消费时用于中断——catch 后返回"更新清单体积超上限"。
class ManifestTooLargeException implements Exception {
  const ManifestTooLargeException();
}
