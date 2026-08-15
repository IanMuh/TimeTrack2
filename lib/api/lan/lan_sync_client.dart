/// LAN 同步客户端（dart:io HttpClient）。
///
/// 职责（计划模块 2b）：
/// - 手动输入 IP 接入：**私网地址白名单**校验（localhost/.local/私网段，
///   见 `isPrivateNetworkHost`）+ 主机输入归一化（scheme/路径/内嵌端口）；
/// - `pair`：健康检查 → 配对换 token → 存 sync_peers(lanClient) → **自动一次同步**；
/// - `syncNow`：发本机全量 → 收主机全量 → LWW 合并 + 归一化（对等交换）；
/// - 请求超时 8s（连接/响应头/响应体各阶段共用），响应体上限防内存耗尽。
///
/// 网络/协议错误统一收敛为 `AppResult` 失败（不裸抛）。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data' show BytesBuilder;

import '../../constants/app_constants.dart';
import '../../data/repositories/sync_peer_store.dart';
import '../../data/sync/sync_bundle.dart';
import '../../data/sync/sync_bundle_codec.dart';
import '../../data/sync/sync_bundle_repository.dart';
import '../../utils/result.dart';
import 'lan_sync_protocol.dart';

/// LAN 同步客户端。
class LanSyncClient {
  LanSyncClient({
    required this.bundleRepository,
    required this.peerStore,
    required this.deviceId,
    required this.deviceName,
    this.requestTimeout = AppConstants.lanRequestTimeout,
    this.maxPayloadBytes = AppConstants.lanMaxPayloadBytes,
  });

  final SyncBundleRepository bundleRepository;
  final SyncPeerStore peerStore;

  /// 本机设备 id（同步包 source_device_id / 配对时上报给主机）。
  final String deviceId;

  /// 本机显示名（配对时上报，主机以它对端展示）。
  final String deviceName;

  final Duration requestTimeout;
  final int maxPayloadBytes;

  final SyncBundleCodec _codec = const SyncBundleCodec();

  /// 健康检查（配对前连通性验证；UI 也可用于展示主机信息）。
  Future<AppResult<void>> healthCheck({
    required String host,
    int port = AppConstants.lanDefaultPort,
  }) async {
    final base = _resolveBaseUrl(host, port);
    if (base case AppFailure<String> failure) {
      return AppFailure(failure.message);
    }
    final baseUrl = base.requireValue();
    final result =
        await _request('GET', Uri.parse('$baseUrl${LanSyncEndpoints.health}'));
    if (result case AppFailure<Map<String, Object?>> failure) {
      return AppFailure('无法连接 LAN 主机：${failure.message}');
    }
    return const AppSuccess(null);
  }

  /// 配对并自动一次同步：健康检查 → 配对换 token → 存 lanClient 对端 → 同步。
  ///
  /// 返回存好的 [SyncPeer]。配对成功但自动同步失败时返回失败（对端已存，
  /// 可后续用 [syncNow] 重试，消息区分两种失败）。
  Future<AppResult<SyncPeer>> pair({
    required String host,
    required int port,
    required String pairingCode,
  }) async {
    final base = _resolveBaseUrl(host, port);
    if (base case AppFailure<String> failure) {
      return AppFailure(failure.message);
    }
    final baseUrl = base.requireValue();

    final health =
        await _request('GET', Uri.parse('$baseUrl${LanSyncEndpoints.health}'));
    if (health case AppFailure<Map<String, Object?>> failure) {
      return AppFailure('无法连接 LAN 主机：${failure.message}');
    }

    final pairResult = await _request(
      'POST',
      Uri.parse('$baseUrl${LanSyncEndpoints.pair}'),
      body: jsonEncode({
        'device_id': deviceId,
        'device_name': deviceName,
        'pairing_code': pairingCode.trim(),
      }),
    );
    if (pairResult case AppFailure<Map<String, Object?>> failure) {
      return AppFailure('配对失败：${failure.message}');
    }
    final pairedData = pairResult.requireValue();
    final token = pairedData['token'];
    final serverName = pairedData['server_name'];
    if (token is! String || !_isValidToken(token)) {
      return const AppFailure('主机配对响应缺少合法 token');
    }

    // 先存新对端、再清旧对端（顺序防数据丢失）：若 upsert 失败，旧配对仍完好
    // 可用，不因"先清后存"中断而丢失既有配对状态。
    final peer = SyncPeer(
      id: peerStore.newPeerId('lan-client'),
      kind: SyncPeerKind.lanClient,
      displayName:
          serverName is String && serverName.isNotEmpty ? serverName : host,
      baseUrl: baseUrl,
      token: token,
      updatedAt: DateTime.now(),
    );
    final saved = await peerStore.upsertPeer(
      id: peer.id,
      kind: peer.kind,
      displayName: peer.displayName,
      baseUrl: peer.baseUrl,
      token: peer.token,
    );
    if (saved case AppFailure<void> failure) {
      return AppFailure('保存 LAN 对端失败：${failure.message}');
    }
    // 单主机语义（老项目）：清旧 lanClient 对端（保留刚插入的新对端）。
    // **边界如实标注（r 修复）**：这里只删除本地持久化的旧对端行，旧 token
    // 在**服务器端**仍有效（本客户端无吊销通道；服务端按 token 鉴权、重新
    // 配对会轮换新 token 使旧 token 失效）。若旧 token 曾泄露，泄露方在主机
    // 重新配对前仍可调用 /sync——属 LAN 信任模型边界（服务端重新配对即吊销）。
    final cleared = await peerStore.clearLanClientPeersExcept(peer.id);
    if (cleared case AppFailure<void> clearFailure) {
      // 清理失败：旧行残留但新行已存（currentLanClientPeer 按 updatedAt 倒序取
      // 最新，仍会取到新对端）；提示但不中断配对。
      stderr.writeln('[lan-sync] 清除旧 LAN 对端失败：${clearFailure.message}');
    }

    // 配对即自动一次同步（计划语义）。
    final syncResult = await syncNow();
    if (syncResult case AppFailure<SyncBundle> failure) {
      return AppFailure('配对成功，但首次同步失败：${failure.message}');
    }
    return AppSuccess(peer);
  }

  /// 进行中的同步 Future（并发互斥）：pair 末尾的自动同步与手动 syncNow 之间、
  /// 以及两个 syncNow 之间没有串行化时，exportBundle/mergeBundle/normalizeAfterMerge
  /// 跨多个 await 点会交错执行——流程 A 导出本地快照后让出，流程 B 完成
  /// merge+normalize，随后 A 用过期快照再次 merge/normalize，LWW 合并与归一化
  /// 顺序错乱可能导致数据回退或脏状态。并发调用共享同一 in-flight Future
  ///（结果语义一致：都完成同一轮同步）。
  Future<AppResult<SyncBundle>>? _syncInFlight;

  /// 立即同步：发本机全量 bundle → 收主机全量 → LWW 合并 + 归一化。
  ///
  /// 返回**接收到的远端 bundle**（非本地合并后结果——LWW 合并后本地状态可能与
  /// 远端包不一致，调用方若需展示本地最终数据应重新查询，勿用返回值刷新）。
  Future<AppResult<SyncBundle>> syncNow() async {
    final inFlight = _syncInFlight;
    if (inFlight != null) return inFlight;
    final future = _runSyncNow();
    _syncInFlight = future;
    try {
      return await future;
    } finally {
      if (identical(_syncInFlight, future)) {
        _syncInFlight = null;
      }
    }
  }

  Future<AppResult<SyncBundle>> _runSyncNow() async {
    final peerResult = await peerStore.currentLanClientPeer();
    if (peerResult case AppFailure<SyncPeer?> failure) {
      return AppFailure(failure.message);
    }
    final peer = peerResult.requireValue();
    if (peer == null || peer.baseUrl == null) {
      return const AppFailure('尚未配对 LAN 主机');
    }
    final localBundle = await bundleRepository.exportBundle(
      sourceDeviceId: deviceId,
    );
    final result = await _request(
      'POST',
      Uri.parse('${peer.baseUrl}${LanSyncEndpoints.sync}'),
      body: _codec.encode(localBundle),
      token: peer.token,
    );
    if (result case AppFailure<Map<String, Object?>> failure) {
      return AppFailure(failure.message);
    }
    final syncData = result.requireValue();
    final rawBundle = syncData['bundle'];
    if (rawBundle is! Map<String, Object?>) {
      return const AppFailure('主机响应缺少同步包');
    }
    SyncBundle remoteBundle;
    try {
      remoteBundle = SyncBundle.fromJson(rawBundle);
    } catch (e) {
      // 解析链跨多个模型（fromMap/readDateTime 等），远端畸形数据可能触发
      // TypeError/CastError/ArgumentError 等非 FormatException——统一收敛，
      // 不裸抛（类注释约定）。
      return AppFailure('主机同步包非法：$e');
    }
    final merge = await bundleRepository.mergeBundle(remoteBundle);
    if (merge case AppFailure<void> failure) {
      return AppFailure('合并主机数据失败：${failure.message}');
    }
    final normalize = await bundleRepository.normalizeAfterMerge();
    if (normalize case AppFailure<void> failure) {
      return AppFailure('合并后归一化失败：${failure.message}');
    }
    return AppSuccess(remoteBundle);
  }

  // ---------------------------------------------------------------------------
  // 内部
  // ---------------------------------------------------------------------------

  /// 主机输入归一化 + 私网白名单校验，返回 `http://host:port` 基础 URL。
  ///
  /// 安全边界：白名单仅对**主机名字符串**做第一层判定；`.local`/`localhost`
  /// 实际解析后可指向任意地址（DNS 重绑定/mDNS 欺骗），故 [_request] 发起连接
  /// 前会**单次解析**并对解析出的真实 IP 做第二层校验，且直连该校验过的 IP
  /// （消除"校验解析"与"连接解析"之间的 TOCTOU 窗口）。
  AppResult<String> _resolveBaseUrl(String host, int port) {
    final normalized = normalizeLanInput(host);
    if (normalized == null) return const AppFailure('主机地址非法');
    var effectivePort = port;
    final (hostOnly, embeddedPort) = normalized;
    if (embeddedPort != null) effectivePort = embeddedPort;
    if (effectivePort < 1 || effectivePort > 65535) {
      return AppFailure('端口非法：$effectivePort');
    }
    if (!isPrivateNetworkHost(hostOnly)) {
      return const AppFailure('仅支持私网地址（localhost/.local/私网 IP 段）');
    }
    // IPv6 字面量在 URI 中必须加方括号（如 http://[fd00::1]:8000），否则
    // Uri.parse/连接解析会失败或歧义。
    final hostForUrl = hostOnly.contains(':') ? '[$hostOnly]' : hostOnly;
    return AppSuccess('http://$hostForUrl:$effectivePort');
  }

  /// token 合法性：仅可见 ASCII（0x21..0x7E），长度 8..512，不含空白/控制字符。
  /// 防 CR/LF 请求头注入与畸形 token 落库。
  bool _isValidToken(String token) {
    if (token.length < 8 || token.length > 512) return false;
    for (final unit in token.codeUnits) {
      if (unit < 0x21 || unit > 0x7E) return false;
    }
    return true;
  }

  /// 解析主机名并校验**所有**解析结果均为私网/回环/链路本地地址。
  ///
  /// 第二层安全边界：`mypc.local` 可能被 mDNS 欺骗解析到公网 IP，
  /// 此时拒绝连接（绝不携带 token/同步数据发往公网地址）。
  ///
  /// 返回校验通过的地址列表，供 [_request] 经 `connectionFactory` **直连**——
  /// 与后续连接使用同一份解析结果，消除两次解析间的 TOCTOU 窗口。
  Future<AppResult<List<InternetAddress>>> _resolveVerifiedHosts(
    String host,
  ) async {
    final addresses = await InternetAddress.lookup(host);
    if (addresses.isEmpty) {
      return const AppFailure('主机解析无结果');
    }
    final allPrivate = addresses.every(
      (address) => isPrivateNetworkHost(address.address),
    );
    if (!allPrivate) {
      return const AppFailure('主机解析结果包含非私网地址，已拒绝连接');
    }
    return AppSuccess(addresses);
  }

  /// 统一请求：JSON 请求/响应，Bearer 鉴权，超时与响应体上限。
  ///
  /// 响应包络 `ok == true` 才成功；协议错误/HTTP 错误/非法 UTF-8 一律收敛为
  /// AppFailure（不裸抛——类注释约定）。
  Future<AppResult<Map<String, Object?>>> _request(
    String method,
    Uri uri, {
    String? body,
    String? token,
  }) async {
    final client = HttpClient()..connectionTimeout = requestTimeout;
    try {
      // 第二层 DNS 校验：单次解析 + 全部结果为私网才放行；校验通过的地址经
      // connectionFactory 直连（不复解析），消除重绑定/mDNS 欺骗的 TOCTOU 窗口。
      final resolved = await _resolveVerifiedHosts(uri.host);
      if (resolved case AppFailure<List<InternetAddress>> failure) {
        return AppFailure(failure.message);
      }
      final verifiedAddresses = resolved.requireValue();
      client.connectionFactory = (Uri uri, String? _, int? port) async {
        // **多地址按序回退（r 修复）**：主机解析出多个地址（如同时含 A/AAAA
        // 记录）时，首选地址族可能当前不可达（如无 IPv6 路由/端口不通）——
        // 依次尝试全部已验证地址，全部失败抛最后异常（错误收敛到 _request
        // 的 SocketException 分支）。
        Object? lastError;
        for (final address in verifiedAddresses) {
          try {
            return await Socket.startConnect(address, port ?? uri.port);
          } catch (e) {
            lastError = e;
          }
        }
        if (lastError is Object) {
          throw lastError;
        }
        throw const SocketException('无法连接任何已验证地址');
      };
      final request = await client.openUrl(method, uri).timeout(requestTimeout);
      request.headers.contentType = ContentType.json;
      if (token != null) {
        if (!_isValidToken(token)) {
          return const AppFailure('LAN 对端 token 非法');
        }
        request.headers.set(
          LanSyncEndpoints.authorizationHeader,
          '${LanSyncEndpoints.bearerPrefix}$token',
        );
      }
      if (body != null) request.write(body);
      final response = await request.close().timeout(requestTimeout);
      // 响应体上限前置检查：contentLength 已知且超限 → 直接拒绝（防恶意大响应
      // 先撑爆内存再"事后"报错）。
      if (response.contentLength > maxPayloadBytes) {
        return const AppFailure('LAN 主机响应过大');
      }
      // 流式读取并限长 + 全流程超时（8s 覆盖响应体阶段，类注释约定）：字节数
      // 超过上限即停止消费（防无 contentLength 的分块响应耗尽内存）。
      // 注意：`break` 会取消单订阅流，之后不能再对 response 做任何操作（如
      // drain——会抛 StateError 重复 listen）；连接由 finally 的 client.close()
      // 收尾，无需显式排空。
      final bytes = BytesBuilder(copy: false);
      var received = 0;
      var tooLarge = false;
      // **累计超时（r 修复）**：`response.timeout(...)` 只在每个数据事件后重置
      // 定时器，仅保证"相邻 chunk 间隔 ≤ 超时"——慢速/恶意主机可每 7 秒吐 1
      // 字节无限拖长连接（slow-loris）。记录读体起始时刻，每 chunk 检查总
      // 耗时是否超过 [requestTimeout]，超限抛 TimeoutException（走既有超时
      // 分支）。
      final readDeadline = DateTime.now().add(requestTimeout);
      await for (final chunk in response.timeout(requestTimeout)) {
        if (DateTime.now().isAfter(readDeadline)) {
          throw TimeoutException('LAN 主机响应读取超时', requestTimeout);
        }
        received += chunk.length;
        if (received > maxPayloadBytes) {
          tooLarge = true;
          break;
        }
        bytes.add(chunk);
      }
      if (tooLarge) {
        return const AppFailure('LAN 主机响应过大');
      }
      String text;
      try {
        text = utf8.decode(bytes.takeBytes());
      } on FormatException {
        return const AppFailure('LAN 主机响应不是合法 UTF-8');
      }
      Object? decoded;
      try {
        decoded = jsonDecode(text);
      } on FormatException {
        return AppFailure(
          'LAN 主机响应不是合法 JSON（HTTP ${response.statusCode}）',
        );
      }
      try {
        return AppSuccess(parseEnvelope(decoded));
      } on LanSyncException catch (e) {
        return AppFailure(e.message);
      }
    } on TimeoutException {
      return const AppFailure('连接 LAN 主机超时');
    } on SocketException catch (e) {
      return AppFailure('无法连接 LAN 主机：${e.message}');
    } on HttpException catch (e) {
      return AppFailure('LAN 请求失败：${e.message}');
    } on LanSyncException catch (e) {
      return AppFailure(e.message);
    } on Object catch (e) {
      // 兜底：契约要求不裸抛——HandshakeException/ArgumentError/StateError 等
      // 任何未预期异常统一收敛为 AppFailure。
      return AppFailure('LAN 请求异常：$e');
    } finally {
      // **显式断开（r 修复）**：未传 force 的 close() 会等待在途请求自然结束
      //（超时/异常频繁时短暂积压 fd/端口资源）；`force: true` 立即断开连接。
      // 注：dart:io HttpClient.close 返回 void（非 Future），直接调用。
      client.close(force: true);
    }
  }
}
