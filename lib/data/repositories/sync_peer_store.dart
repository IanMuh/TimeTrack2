import 'package:drift/drift.dart';
import 'package:uuid/uuid.dart';

import '../../utils/result.dart';
import '../database/app_database.dart';
import 'repository_mappings.dart';

/// 同步对端类型。
enum SyncPeerKind {
  /// 本机作为 LAN 客户端时，存储的远端主机（有 baseUrl+token）。
  lanClient('lan_client'),

  /// 本机作为 LAN 主机时，存储的已配对客户端（baseUrl 为 null，token 用于 /sync 鉴权）。
  lanAuthorizedClient('lan_authorized_client');

  const SyncPeerKind(this.storageValue);

  final String storageValue;

  static SyncPeerKind fromStorageValue(String value) {
    return SyncPeerKind.values.firstWhere(
      (k) => k.storageValue == value,
      orElse: () => SyncPeerKind.lanClient,
    );
  }
}

/// LAN 同步对端（sync_peers 表读写）。
///
/// 老项目语义迁移：本机作为客户端存"远端主机"；作为主机把配对过的客户端
/// 存为 authorized 供 /sync 鉴权。查询按 kind + updated_at desc 取最新。
class SyncPeerStore with RepositoryMappings {
  SyncPeerStore({
    required this.database,
    Uuid? uuid,
  }) : _uuid = uuid ?? const Uuid();

  final AppDatabase database;
  final Uuid _uuid;

  /// 新增/更新对端。
  Future<AppResult<void>> upsertPeer({
    required String id,
    required SyncPeerKind kind,
    required String displayName,
    String? baseUrl,
    required String token,
  }) async {
    try {
      await database.into(database.syncPeers).insertOnConflictUpdate(
            SyncPeersCompanion.insert(
              id: id,
              kind: kind.storageValue,
              displayName: displayName,
              baseUrl: Value(baseUrl),
              token: token,
              updatedAt: utcString(DateTime.now()),
            ),
          );
      return const AppSuccess(null);
    } catch (e) {
      return AppFailure('保存同步对端失败：$e');
    }
  }

  /// 当前 LAN 客户端对端（kind=lanClient 最新一条）。
  Future<SyncPeer?> currentLanClientPeer() async {
    final query = database.select(database.syncPeers)
      ..where((t) => t.kind.equals(SyncPeerKind.lanClient.storageValue))
      ..orderBy([(t) => OrderingTerm.desc(t.updatedAt)])
      ..limit(1);
    final row = await query.getSingleOrNull();
    return row == null ? null : _peerFromRow(row);
  }

  /// 全部已配对客户端（kind=lanAuthorizedClient，按更新时间倒序）。
  Future<List<SyncPeer>> authorizedClients() async {
    final query = database.select(database.syncPeers)
      ..where((t) => t.kind.equals(SyncPeerKind.lanAuthorizedClient.storageValue))
      ..orderBy([(t) => OrderingTerm.desc(t.updatedAt)]);
    final rows = await query.get();
    return rows.map(_peerFromRow).toList();
  }

  /// 按 id 查对端。
  Future<SyncPeer?> peerById(String id) async {
    final query = database.select(database.syncPeers)
      ..where((t) => t.id.equals(id));
    final row = await query.getSingleOrNull();
    return row == null ? null : _peerFromRow(row);
  }

  /// 删除对端（登出/断开 LAN）。
  Future<AppResult<void>> deletePeer(String id) async {
    try {
      await (database.delete(database.syncPeers)..where((t) => t.id.equals(id)))
          .go();
      return const AppSuccess(null);
    } catch (e) {
      return AppFailure('删除同步对端失败：$e');
    }
  }

  /// 清除所有 lanClient 对端。
  Future<AppResult<void>> clearLanClientPeers() async {
    try {
      await (database.delete(database.syncPeers)
            ..where((t) => t.kind.equals(SyncPeerKind.lanClient.storageValue)))
          .go();
      return const AppSuccess(null);
    } catch (e) {
      return AppFailure('清除 LAN 对端失败：$e');
    }
  }

  /// 生成新对端 id（客户端设备 id 或 lan-client-UUID 由调用方决定）。
  String newPeerId(String prefix) => '$prefix-${_uuid.v4()}';

  SyncPeer _peerFromRow(SyncPeerRow row) {
    return SyncPeer(
      id: row.id,
      kind: SyncPeerKind.fromStorageValue(row.kind),
      displayName: row.displayName,
      baseUrl: row.baseUrl,
      token: row.token,
      updatedAt: readUtc(row.updatedAt),
    );
  }
}

/// LAN 同步对端模型。
class SyncPeer {
  const SyncPeer({
    required this.id,
    required this.kind,
    required this.displayName,
    this.baseUrl,
    required this.token,
    required this.updatedAt,
  });

  final String id;
  final SyncPeerKind kind;
  final String displayName;
  final String? baseUrl;
  final String token;
  final DateTime updatedAt;
}
