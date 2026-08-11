/// LAN 同步主机（dart:io HttpServer）。
///
/// 职责（计划模块 2b）：
/// - 端口候选 8787..8797 依次绑定；默认绑定所有接口（`anyIPv4`）供局域网访问；
/// - 6 位数字配对码（TTL 5 分钟，单次使用；生成时清理过期码）；
/// - 每 IP 每分钟限流（`rateLimitPerMinute`，配对/同步端点共用）；
/// - 配对成功 → 存 sync_peers(lanAuthorizedClient)，**id 用客户端 device_id**：
///   同一设备重复配对覆盖同一行、token 轮换，旧 token 立即失效（防泄露 token 复用）；
/// - `POST /sync`：Bearer token 鉴权 → mergeBundle（客户端全量）→ normalize →
///   回传服务器全量 bundle（对等交换，双向收敛）。
///
/// 并发安全：dart 单事件循环 + drift 单连接事务，无需显式锁。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data' show BytesBuilder;

import 'package:uuid/uuid.dart';

import '../../constants/app_constants.dart';
import '../../data/repositories/sync_peer_store.dart';
import '../../data/sync/sync_bundle.dart';
import '../../data/sync/sync_bundle_codec.dart';
import '../../data/sync/sync_bundle_repository.dart';
import '../../utils/result.dart';
import 'lan_sync_protocol.dart';

/// 请求体超过大小上限的内部信号（路由层捕获后转 413）。
class _PayloadTooLarge implements Exception {
  const _PayloadTooLarge();
}

/// LAN 同步主机。
class LanSyncServer {
  LanSyncServer({
    required this.bundleRepository,
    required this.peerStore,
    required this.sourceDeviceId,
    this.appName = 'TimeTrack',
    this.appVersion = '0.1.0',
    InternetAddress? bindAddress,
    this.pairingCodeTtl = AppConstants.lanPairingCodeTtl,
    this.rateLimitPerMinute = AppConstants.lanRateLimitPerMinute,
    this.maxPayloadBytes = AppConstants.lanMaxPayloadBytes,
    DateTime Function()? clock,
    Uuid? uuid,
  })  : _bindAddress = bindAddress ?? InternetAddress.anyIPv4,
        _clock = clock ?? DateTime.now,
        _uuid = uuid ?? const Uuid();

  final SyncBundleRepository bundleRepository;
  final SyncPeerStore peerStore;

  /// 服务器自身设备 id（bundle 导出的 source_device_id）。
  final String sourceDeviceId;
  final String appName;
  final String appVersion;

  final Duration pairingCodeTtl;
  final int rateLimitPerMinute;
  final int maxPayloadBytes;

  final InternetAddress _bindAddress;
  final DateTime Function() _clock;
  final Uuid _uuid;

  /// 请求体读取总时长上限（请求头之后必须在此时间内发完 body）。
  static const _readBodyTimeout = Duration(seconds: 30);

  final SyncBundleCodec _codec = const SyncBundleCodec();

  HttpServer? _server;
  int? _boundPort;

  /// 配对码 → 绑定信息（生成时刻 + 声明的设备身份）。
  ///
  /// 配对码**与设备身份绑定**：配对请求必须携带与生成时一致的 device_id，
  /// 防止冒用他人 device_id 重新配对轮换其 token（无凭据覆盖/DoS）。
  /// 单次使用；生成时清理过期项。
  final Map<String, _PairingCodeInfo> _pairingCodes = {};

  /// 每 IP 请求时刻（滑动窗口 1 分钟；定期清扫防无界增长）。
  final Map<String, List<DateTime>> _requestTimes = {};

  /// 上次清扫时刻（每分钟最多清扫一次，防长期运行内存无界增长）。
  DateTime? _lastSweepAt;

  /// 是否运行中。
  bool get isRunning => _server != null;

  /// 实际绑定端口（绑定后可用；测试传 0 自动分配）。
  int? get boundPort => _boundPort;

  /// 启动：优先绑定 [preferredPort]（传 0 = 系统分配），绑定失败回退依次
  /// 尝试 8787..8797；全部失败返回 AppFailure。
  Future<AppResult<int>> start({int? preferredPort}) async {
    if (_server != null) return const AppFailure('LAN 主机已启动');
    final ports = <int>[
      ?preferredPort,
      for (var port = AppConstants.lanPortRangeStart;
          port <= AppConstants.lanPortRangeEnd;
          port++)
        if (port != preferredPort) port,
    ];
    HttpServer? bound;
    for (final port in ports) {
      try {
        bound = await HttpServer.bind(_bindAddress, port);
        break;
      } on SocketException {
        // 端口占用/无权限：尝试下一个候选。
      }
    }
    if (bound == null) {
      return AppFailure(
        '无法绑定端口（${ports.first}..${ports.last}）：均被占用或不可用',
      );
    }
    _server = bound;
    _boundPort = bound.port;
    bound.listen(
      (request) => unawaited(_dispatch(request)),
      onError: (_) {
        // 订阅层兜底：HttpServer 订阅错误不崩溃 isolate（连接级错误已内联捕获）。
      },
    );
    return AppSuccess(bound.port);
  }

  /// 停止并释放端口（幂等）。
  Future<void> stop() async {
    final server = _server;
    _server = null;
    _boundPort = null;
    _pairingCodes.clear();
    _requestTimes.clear();
    await server?.close(force: true);
  }

  /// 生成新配对码（6 位数字，TTL 内有效；过期码先清理）。
  ///
  /// [deviceId] 为客户端声明的设备身份（**必填**，强制绑定）：配对请求必须
  /// 携带一致值——防冒用他人 device_id 重新配对轮换其 token（无凭据覆盖/DoS）。
  String generatePairingCode({required String deviceId}) {
    _pruneExpiredCodes();
    final random = Random.secure();
    String code;
    do {
      code = '${random.nextInt(1000000)}'.padLeft(
          AppConstants.lanPairingCodeLength, '0');
    } while (_pairingCodes.containsKey(code));
    _pairingCodes[code] =
        _PairingCodeInfo(createdAt: _clock(), deviceId: deviceId.trim());
    return code;
  }

  // ---------------------------------------------------------------------------
  // 请求分发
  // ---------------------------------------------------------------------------

  /// 统一异常兜底：任何未捕获错误 → 500（防 unhandled async error 崩溃进程）。
  Future<void> _dispatch(HttpRequest request) async {
    try {
      await _route(request);
    } catch (e, st) {
      // 统一兜底：不向客户端泄露内部细节（路径/堆栈），只回通用错误。
      // stderr 记录便于排障（平台日志可见）。
      stderr.writeln('[lan-sync] 未捕获异常：$e\n$st');
      await _safeRespond(
        request,
        HttpStatus.internalServerError,
        errorEnvelope(LanSyncErrorCode.serverError, '服务器内部错误'),
      );
    }
  }

  /// 写响应：失败（客户端已断开等）静默吞掉——避免在 catch 内二次抛异常
  /// 逃逸成 unhandled async error 崩溃 isolate。
  Future<void> _safeRespond(
    HttpRequest request,
    int status,
    Map<String, Object?> body,
  ) async {
    try {
      await _respond(request, status, body);
    } on Exception {
      // 客户端已断开/写入失败：响应不可送达，无需上报。
    }
  }

  Future<void> _route(HttpRequest request) async {
    switch (request.uri.path) {
      case LanSyncEndpoints.health:
        return _handleHealth(request);
      case LanSyncEndpoints.pair:
        return _handlePair(request);
      case LanSyncEndpoints.sync:
        return _handleSync(request);
      default:
        return _respond(
          request,
          HttpStatus.notFound,
          errorEnvelope(LanSyncErrorCode.invalidRequest, '未知端点'),
        );
    }
  }

  Future<void> _handleHealth(HttpRequest request) {
    // /health 不参与限流：轻量探测（客户端配对前连通性检查）。
    return _respond(
      request,
      HttpStatus.ok,
      okEnvelope({
        'name': appName,
        'version': appVersion,
        'device_id': sourceDeviceId,
      }),
    );
  }

  Future<void> _handlePair(HttpRequest request) async {
    if (!_allowRequest(request)) {
      await _respond(
        request,
        HttpStatus.tooManyRequests,
        errorEnvelope(
          LanSyncErrorCode.rateLimited,
          '请求过于频繁，请稍后再试',
        ),
      );
      return;
    }
    final bodyResult = await _readBodyGuarded(request);
    if (bodyResult case _BodyReadResult(:final error?)) {
      await _respond(request, error.status, errorEnvelope(error.code, error.message));
      return;
    }
    final body = bodyResult.bytes;

    final decoded = await _decodeJson(request, body);
    if (decoded == null) return;
    final deviceId = decoded['device_id'];
    final deviceName = decoded['device_name'];
    final pairingCode = decoded['pairing_code'];
    if (deviceId is! String ||
        deviceId.trim().isEmpty ||
        deviceName is! String ||
        deviceName.trim().isEmpty ||
        pairingCode is! String ||
        !RegExp(r'^\d{6}$').hasMatch(pairingCode.trim())) {
      await _respond(
        request,
        HttpStatus.badRequest,
        errorEnvelope(LanSyncErrorCode.invalidRequest, '配对请求字段非法'),
      );
      return;
    }

    // 取出即消耗（单次使用）；过期码在查找时才判定 codeExpired（区分 UX）。
    final info = _pairingCodes.remove(pairingCode.trim());
    if (info == null) {
      await _respond(
        request,
        HttpStatus.unauthorized,
        errorEnvelope(LanSyncErrorCode.invalidCode, '配对码无效'),
      );
      return;
    }
    if (_clock().difference(info.createdAt) > pairingCodeTtl) {
      await _respond(
        request,
        HttpStatus.unauthorized,
        errorEnvelope(LanSyncErrorCode.codeExpired, '配对码已过期，请重新生成'),
      );
      return;
    }
    // 配对码与设备身份绑定（生成时强制绑定，防冒用他人 device_id 轮换 token）。
    if (info.deviceId != deviceId.trim()) {
      await _respond(
        request,
        HttpStatus.unauthorized,
        errorEnvelope(LanSyncErrorCode.invalidCode, '配对码与设备身份不匹配'),
      );
      return;
    }

    final token = '${_uuid.v4()}${_uuid.v4()}';
    final saved = await peerStore.upsertPeer(
      // id 用客户端 device_id：重复配对覆盖同一行、token 轮换，旧 token 失效。
      id: deviceId.trim(),
      kind: SyncPeerKind.lanAuthorizedClient,
      displayName: deviceName.trim(),
      token: token,
    );
    if (saved case AppFailure<void> failure) {
      // 内部细节只记日志，不向客户端回显。
      stderr.writeln('[lan-sync] 保存配对对端失败：${failure.message}');
      await _respond(
        request,
        HttpStatus.internalServerError,
        errorEnvelope(LanSyncErrorCode.serverError, '保存配对对端失败'),
      );
      return;
    }
    await _respond(
      request,
      HttpStatus.ok,
      okEnvelope({
        'token': token,
        'server_name': appName,
        'server_device_id': sourceDeviceId,
      }),
    );
  }

  Future<void> _handleSync(HttpRequest request) async {
    if (!_allowRequest(request)) {
      await _respond(
        request,
        HttpStatus.tooManyRequests,
        errorEnvelope(
          LanSyncErrorCode.rateLimited,
          '请求过于频繁，请稍后再试',
        ),
      );
      return;
    }
    final token = _bearerToken(request);
    if (token == null) {
      await _respond(
        request,
        HttpStatus.unauthorized,
        errorEnvelope(LanSyncErrorCode.unauthorized, '缺少 Bearer token'),
      );
      return;
    }
    final authorized = await _authorizedPeerByToken(token);
    if (authorized == null) {
      await _respond(
        request,
        HttpStatus.unauthorized,
        errorEnvelope(LanSyncErrorCode.unauthorized, 'token 无效或已被轮换'),
      );
      return;
    }

    final bodyResult = await _readBodyGuarded(request);
    if (bodyResult case _BodyReadResult(:final error?)) {
      await _respond(request, error.status, errorEnvelope(error.code, error.message));
      return;
    }
    final body = bodyResult.bytes;
    SyncBundle clientBundle;
    try {
      clientBundle = _codec.decode(utf8.decode(body));
    } on FormatException catch (e) {
      await _respond(
        request,
        HttpStatus.badRequest,
        errorEnvelope(LanSyncErrorCode.invalidRequest, '同步包非法：${e.message}'),
      );
      return;
    }
    // 设备身份校验：bundle 的 source_device_id 必须与 token 对应的授权对端一致。
    // 防已配对客户端伪造任意 source_device_id、携带高 updatedAt 记录注入/覆盖
    // 其他设备的数据（LWW 合并按记录 id，不看 source_device_id）。
    if (clientBundle.sourceDeviceId != authorized.id) {
      await _respond(
        request,
        HttpStatus.forbidden,
        errorEnvelope(
          LanSyncErrorCode.invalidRequest,
          '同步包设备身份与 token 不匹配',
        ),
      );
      return;
    }

    final mergeResult = await bundleRepository.mergeBundle(clientBundle);
    if (mergeResult case AppFailure<void> failure) {
      stderr.writeln('[lan-sync] 合并同步包失败：${failure.message}');
      await _respond(
        request,
        HttpStatus.internalServerError,
        errorEnvelope(LanSyncErrorCode.serverError, '合并同步包失败'),
      );
      return;
    }
    final normalizeResult = await bundleRepository.normalizeAfterMerge();
    if (normalizeResult case AppFailure<void> normalizeFailure) {
      // 归一化失败意味着服务器可能处于未归一化/中间状态：此时返回的 bundle
      // 不能作为客户端的收敛依据——返回 5xx，客户端不应用本次响应。
      stderr.writeln('[lan-sync] 合并后归一化失败：${normalizeFailure.message}');
      await _respond(
        request,
        HttpStatus.internalServerError,
        errorEnvelope(LanSyncErrorCode.serverError, '合并后归一化未完成'),
      );
      return;
    }

    final serverBundle = await bundleRepository.exportBundle(
      sourceDeviceId: sourceDeviceId,
    );
    await _respond(
      request,
      HttpStatus.ok,
      okEnvelope({'bundle': serverBundle.toJson()}),
    );
  }

  // ---------------------------------------------------------------------------
  // 内部工具
  // ---------------------------------------------------------------------------

  String? _bearerToken(HttpRequest request) {
    final header = request.headers.value(LanSyncEndpoints.authorizationHeader);
    if (header == null || !header.startsWith(LanSyncEndpoints.bearerPrefix)) {
      return null;
    }
    final token = header.substring(LanSyncEndpoints.bearerPrefix.length).trim();
    return token.isEmpty ? null : token;
  }

  Future<SyncPeer?> _authorizedPeerByToken(String token) async {
    final peersResult = await peerStore.authorizedClients();
    if (peersResult case AppFailure<List<SyncPeer>> failure) {
      stderr.writeln('[lan-sync] 读取已配对客户端失败：${failure.message}');
      return null;
    }
    for (final peer in peersResult.requireValue()) {
      if (peer.token == token) return peer;
    }
    return null;
  }

  /// 每 IP 滑动窗口限流（仅配对/同步端点调用；返回 false = 应拒绝 429）。
  bool _allowRequest(HttpRequest request) {
    _sweepStaleState(); // 定期清扫防无界内存（幂等、廉价：每分钟最多一次）。
    final address = request.connectionInfo?.remoteAddress.address;
    if (address == null) return false;
    final now = _clock();
    final records = _requestTimes.putIfAbsent(address, () => []);
    while (records.isNotEmpty &&
        now.difference(records.first) >= const Duration(minutes: 1)) {
      records.removeAt(0);
    }
    if (records.length >= rateLimitPerMinute) {
      return false;
    }
    records.add(now);
    return true;
  }

  /// 清扫窗口外 IP 记录（每分钟最多一次；幂等）。
  ///
  /// 配对码不在此清扫：单次使用（取出即删）+ 生成时清理过期码，映射天然有界；
  /// 过期判定保留在配对查找时执行（区分 invalidCode / codeExpired 两种 UX）。
  void _sweepStaleState() {
    final now = _clock();
    final last = _lastSweepAt;
    if (last != null && now.difference(last) < const Duration(minutes: 1)) {
      return;
    }
    _lastSweepAt = now;
    _requestTimes.removeWhere(
      (_, records) =>
          records.isEmpty ||
          now.difference(records.last) >= const Duration(minutes: 1),
    );
  }

  void _pruneExpiredCodes() {
    final now = _clock();
    _pairingCodes.removeWhere(
      (_, info) => now.difference(info.createdAt) > pairingCodeTtl,
    );
  }

  /// 读请求体（上限 maxPayloadBytes）；超限返回错误结果。
  ///
  /// 带总时长上限（请求头之后 30s 内必须发完 body，否则 408）：防局域网内
  /// 慢速/挂起连接长期占住连接槽位（HttpServer.idleTimeout 对持续零星数据
  /// 不生效），构成慢速连接资源耗尽面。
  Future<_BodyReadResult> _readBodyGuarded(HttpRequest request) async {
    try {
      final bytes = await _readBody(request, maxPayloadBytes);
      return _BodyReadResult(bytes: bytes);
    } on _PayloadTooLarge {
      return const _BodyReadResult(
        error: _BodyReadFailure(
          status: HttpStatus.requestEntityTooLarge,
          code: LanSyncErrorCode.payloadTooLarge,
          message: '请求体过大',
        ),
      );
    } on TimeoutException {
      return const _BodyReadResult(
        error: _BodyReadFailure(
          status: HttpStatus.requestTimeout,
          code: LanSyncErrorCode.invalidRequest,
          message: '请求体读取超时',
        ),
      );
    }
  }

  Future<List<int>> _readBody(HttpRequest request, int maxBytes) async {
    final builder = BytesBuilder(copy: false);
    var total = 0;
    var tooLarge = false;
    // 双重超时防护（覆盖两种拖死场景）：
    // - Stream.timeout：**空闲超时**——连接静默不发数据时按 idle 触发；
    // - 绝对期限：每 chunk 检查 `_clock()`——慢速零碎发包（每 29s 一字节）逃过
    //   idle 判定时仍会被总时长上限拦下（防慢速连接长期占住连接槽位）。
    final deadline = _clock().add(_readBodyTimeout);
    await for (final chunk in request.timeout(_readBodyTimeout)) {
      if (_clock().isAfter(deadline)) {
        throw TimeoutException('请求体读取超时', _readBodyTimeout);
      }
      total += chunk.length;
      if (total > maxBytes) {
        tooLarge = true;
      }
      if (tooLarge) continue; // 超限后继续排空剩余 body（防客户端写入被 RST）
      builder.add(chunk);
    }
    if (tooLarge) {
      throw const _PayloadTooLarge();
    }
    return builder.takeBytes();
  }

  /// 解码 JSON 对象；失败响应 400 并返回 null（已响应）。
  Future<Map<String, Object?>?> _decodeJson(
    HttpRequest request,
    List<int> body,
  ) async {
    Object? decoded;
    try {
      decoded = jsonDecode(utf8.decode(body));
    } on FormatException {
      await _respond(
        request,
        HttpStatus.badRequest,
        errorEnvelope(LanSyncErrorCode.invalidRequest, '请求体不是合法 JSON'),
      );
      return null;
    }
    if (decoded is! Map<String, Object?>) {
      await _respond(
        request,
        HttpStatus.badRequest,
        errorEnvelope(LanSyncErrorCode.invalidRequest, '请求体应为 JSON 对象'),
      );
      return null;
    }
    return decoded;
  }

  Future<void> _respond(
    HttpRequest request,
    int status,
    Map<String, Object?> body,
  ) async {
    final response = request.response;
    response.statusCode = status;
    response.headers.contentType = ContentType.json;
    response.write(jsonEncode(body));
    await response.close();
  }
}

/// 读体结果：成功携带 bytes，失败携带 error（413 等）。
class _BodyReadResult {
  const _BodyReadResult({this.bytes = const [], this.error});

  final List<int> bytes;
  final _BodyReadFailure? error;
}

/// 读体失败信息（含 413）。
class _BodyReadFailure {
  const _BodyReadFailure({
    required this.status,
    required this.code,
    required this.message,
  });

  final int status;
  final LanSyncErrorCode code;
  final String message;
}

/// 配对码绑定信息：生成时刻 + 声明的设备身份（防冒用轮换 token）。
class _PairingCodeInfo {
  const _PairingCodeInfo({required this.createdAt, this.deviceId});

  final DateTime createdAt;
  final String? deviceId;
}
