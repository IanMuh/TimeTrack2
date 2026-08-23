/// LAN 设备互通编排 store（批次 4 设置页设备互通分区）。
///
/// 职责（薄编排——协议/绑定/配对码语义在 api/lan 层）：
/// - **主机**：手动启动/停止（不变式 10：无任何自动开启路径）+ 绑定端口
///   展示 + 配对码生成（单次使用、TTL 见 LanSyncServer）；
/// - **客户端**：配对（health → pair → 自动同步一次）+ 手动同步 + 当前
///   lanClient 对端展示；
/// - 状态字段驱动 UI（运行中/端口/配对码/最近错误/进行中标志）。
///
/// 实例管理：LanSyncServer/LanSyncClient 的 deviceId 为构造期 final 注入，
/// 而设备 id 是惰性生成（app_metadata）——首次操作时以真实 id 重建实例
///（两者均无跨操作可变状态，重建无副作用）。
library;

import 'package:flutter/foundation.dart';
import 'package:uuid/uuid.dart';

import '../api/lan/lan_sync_client.dart';
import '../api/lan/lan_sync_server.dart';
import '../constants/app_constants.dart';
import '../constants/storage_keys.dart' show AppMetadataKeys;
import '../data/database/app_database.dart' hide ProfileSettings;
import '../data/repositories/sync_peer_store.dart';
import '../data/sync/sync_bundle_repository.dart';
import '../utils/result.dart';
import 'data_revision.dart';

class LanStore extends ChangeNotifier {
  LanStore({
    required this.bundleRepository,
    required this.peerStore,
    required this.database,
    required this.dataRevision,
    this.appVersion = '0.1.0',
    this.deviceName = 'TimeTrack',
  });

  final SyncBundleRepository bundleRepository;
  final SyncPeerStore peerStore;
  final AppDatabase database;
  final DataRevision dataRevision;
  final String appVersion;
  final String deviceName;

  LanSyncServer? _server;
  LanSyncClient? _client;
  String? _deviceId;

  String? _pairingCode;
  int? _hostPort;
  bool _hostBusy = false;
  bool _clientBusy = false;
  bool _disposed = false;
  String? _lastError;
  SyncPeer? _clientPeer;

  /// 当前主机实例（null = 从未启动过）。
  LanSyncServer? get server => _server;

  bool get hostRunning => _server?.isRunning ?? false;

  /// 绑定端口（运行中可用）。
  int? get hostPort => _hostPort;

  /// 最近一次生成的配对码（单次使用；主机停止后清空）。
  String? get pairingCode => _pairingCode;

  bool get hostBusy => _hostBusy;

  bool get clientBusy => _clientBusy;

  String? get lastError => _lastError;

  /// 当前已配对的 lanClient 对端（null = 未配对）。
  SyncPeer? get clientPeer => _clientPeer;

  /// 重载客户端对端状态（设置页进入时调用）。
  Future<void> reloadPeer() async {
    if (_disposed) return;
    final result = await peerStore.currentLanClientPeer();
    if (_disposed) return;
    if (result.isSuccess) {
      _clientPeer = result.requireValue();
      notifyListeners();
    }
  }

  /// 读取/生成设备标识（app_metadata.device_id；与 CommandDispatcher 同一
  /// 模式——清除数据保留该键，跨清除稳定）。
  Future<String> _requireDeviceId() async {
    final existing = _deviceId;
    if (existing != null) return existing;
    final query = database.select(database.appMetadata)
      ..where((t) => t.key.equals(AppMetadataKeys.deviceId));
    final row = await query.getSingleOrNull();
    if (row != null) {
      _deviceId = row.value;
      return row.value;
    }
    final id = const Uuid().v4();
    await database.into(database.appMetadata).insertOnConflictUpdate(
          AppMetadataCompanion.insert(key: AppMetadataKeys.deviceId, value: id),
        );
    _deviceId = id;
    return id;
  }

  /// 以真实设备 id 确保主机实例存在（首次启动时重建——构造期无 id 可注入）。
  Future<LanSyncServer> _requireServer() async {
    final deviceId = await _requireDeviceId();
    final existing = _server;
    if (existing != null && existing.sourceDeviceId == deviceId) {
      return existing;
    }
    final created = LanSyncServer(
      bundleRepository: bundleRepository,
      peerStore: peerStore,
      sourceDeviceId: deviceId,
      appVersion: appVersion,
    );
    _server = created;
    return created;
  }

  /// 以真实设备 id 确保客户端实例存在。
  Future<LanSyncClient> _requireClient() async {
    final deviceId = await _requireDeviceId();
    final existing = _client;
    if (existing != null && existing.deviceId == deviceId) {
      return existing;
    }
    final created = LanSyncClient(
      bundleRepository: bundleRepository,
      peerStore: peerStore,
      deviceId: deviceId,
      deviceName: deviceName,
    );
    _client = created;
    return created;
  }

  /// 手动启动主机（不变式 10）。
  Future<void> startHost() async {
    if (_disposed || _hostBusy || hostRunning) return;
    _hostBusy = true;
    _lastError = null;
    notifyListeners();
    try {
      final server = await _requireServer();
      if (_disposed) return;
      final result = await server.start();
      if (_disposed) return;
      if (result case AppFailure<int> failure) {
        _lastError = failure.message;
        notifyListeners();
        return;
      }
      final port = result.requireValue();
      // 配对码与设备身份绑定：本机 id 作为生成入参（冒用防护语义在 server 层）。
      _pairingCode = server.generatePairingCode(deviceId: server.sourceDeviceId);
      _hostPort = port;
      notifyListeners();
    } finally {
      _hostBusy = false;
      if (!_disposed) notifyListeners();
    }
  }

  /// 停止主机（清配对码与端口）。
  Future<void> stopHost() async {
    if (_disposed || _hostBusy) return;
    _hostBusy = true;
    notifyListeners();
    try {
      await _server?.stop();
      if (_disposed) return;
      _pairingCode = null;
      _hostPort = null;
      _lastError = null;
      notifyListeners();
    } finally {
      _hostBusy = false;
      if (!_disposed) notifyListeners();
    }
  }

  /// 客户端配对：`host[:port]` + 6 位配对码 → 健康检查 + 配对 + 自动同步。
  Future<void> pairClient({required String host, required String code}) async {
    if (_disposed || _clientBusy) return;
    _clientBusy = true;
    _lastError = null;
    notifyListeners();
    try {
      final client = await _requireClient();
      if (_disposed) return;
      // host 可带 :port（默认端口见 AppConstants）。
      String hostPart = host.trim();
      var port = AppConstants.lanDefaultPort;
      final colon = hostPart.lastIndexOf(':');
      if (colon > 0 && colon < hostPart.length - 1) {
        final parsed = int.tryParse(hostPart.substring(colon + 1));
        if (parsed != null && parsed > 0 && parsed < 65536) {
          port = parsed;
          hostPart = hostPart.substring(0, colon);
        }
      }
      final result = await client.pair(
        host: hostPart,
        port: port,
        pairingCode: code.trim(),
      );
      if (_disposed) return;
      if (result case AppFailure<SyncPeer> failure) {
        _lastError = failure.message;
        notifyListeners();
        return;
      }
      _clientPeer = result.requireValue();
      dataRevision.bump(); // LAN 同步后数据可能变化
      notifyListeners();
    } finally {
      _clientBusy = false;
      if (!_disposed) notifyListeners();
    }
  }

  /// 客户端手动同步一次。
  Future<void> syncClient() async {
    if (_disposed || _clientBusy) return;
    if (_clientPeer == null) {
      _lastError = '尚未配对 LAN 主机';
      notifyListeners();
      return;
    }
    _clientBusy = true;
    _lastError = null;
    notifyListeners();
    try {
      final client = await _requireClient();
      if (_disposed) return;
      final result = await client.syncNow();
      if (_disposed) return;
      if (result case AppFailure failure) {
        _lastError = failure.message;
        notifyListeners();
        return;
      }
      dataRevision.bump();
      notifyListeners();
    } finally {
      _clientBusy = false;
      if (!_disposed) notifyListeners();
    }
  }

  @override
  void dispose() {
    _disposed = true;
    final running = _server;
    if (running != null && running.isRunning) {
      // fire-and-forget：dispose 不能 async，尽力停止监听。
      running.stop().catchError((Object e) {});
    }
    super.dispose();
  }
}
