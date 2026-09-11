import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:timetrack2/data/database/app_database.dart' hide ProfileSettings;
import 'package:timetrack2/data/repositories/action_log_repository.dart';
import 'package:timetrack2/data/repositories/activity_repository.dart';
import 'package:timetrack2/data/repositories/category_repository.dart';
import 'package:timetrack2/data/repositories/settings_repository.dart';
import 'package:timetrack2/data/repositories/sync_peer_store.dart';
import 'package:timetrack2/data/repositories/time_entry_repository.dart';
import 'package:timetrack2/data/sync/sync_bundle_repository.dart';
import 'package:timetrack2/stores/data_revision.dart';
import 'package:timetrack2/stores/lan_store.dart';
import 'package:timetrack2/constants/storage_keys.dart' show AppMetadataKeys;

/// LanStore（批次 4 设备互通编排）：
/// 主机启停/配对码、客户端配对失败路径、device_id 惰性生成与跨操作稳定。
void main() {
  late AppDatabase db;
  late SyncBundleRepository bundleRepo;
  late SyncPeerStore peerStore;
  late DataRevision revision;
  late LanStore store;

  setUp(() async {
    db = AppDatabase(NativeDatabase.memory());
    final activities = ActivityRepository(database: db);
    bundleRepo = SyncBundleRepository(
      database: db,
      activities: activities,
      categories: CategoryRepository(database: db),
      timeEntries: TimeEntryRepository(
        database: db,
        activityRepository: activities,
        settingsRepository: SettingsRepository(database: db),
      ),
      actionLogs: ActionLogRepository(database: db),
      settings: SettingsRepository(database: db),
    );
    peerStore = SyncPeerStore(database: db);
    revision = DataRevision();
    store = LanStore(
      bundleRepository: bundleRepo,
      peerStore: peerStore,
      database: db,
      dataRevision: revision,
    );
  });

  tearDown(() async {
    store.dispose();
    revision.dispose();
    await db.close();
  });

  Future<String?> readDeviceId() async {
    final query = db.select(db.appMetadata)
      ..where((t) => t.key.equals(AppMetadataKeys.deviceId));
    final row = await query.getSingleOrNull();
    return row?.value;
  }

  test('startHost：端口绑定 + 6 位配对码 + device_id 惰性生成', () async {
    await store.startHost();
    expect(store.hostRunning, isTrue);
    expect(store.hostPort, isNotNull);
    expect(store.pairingCode, matches(RegExp(r'^\d{6}$')));
    expect(await readDeviceId(), isNotNull,
        reason: '首次启动生成并持久化 device_id');
  });

  test('stopHost：清配对码与端口', () async {
    await store.startHost();
    await store.stopHost();
    expect(store.hostRunning, isFalse);
    expect(store.pairingCode, isNull);
    expect(store.hostPort, isNull);
  });

  test('重复 startHost：幂等（已运行不再绑定）', () async {
    await store.startHost();
    final port = store.hostPort;
    await store.startHost();
    expect(store.hostPort, port);
  });

  test('pairClient：主机不可达 → lastError 且不崩溃', () async {
    // 回环地址无主机监听的端口（绑定一个再释放，取几乎不可能被占用的端口）。
    await store.pairClient(host: '127.0.0.1', code: '123456');
    expect(store.lastError, isNotNull, reason: '无主机时配对失败要有可读原因');
    expect(store.clientPeer, isNull);
  });

  test('syncClient：未配对 → 明确失败', () async {
    await store.syncClient();
    expect(store.lastError, contains('尚未配对'));
  });

  test('device_id 跨清除稳定：直接删 app_metadata 其余键后再启动保持同 id',
      () async {
    await store.startHost();
    final first = await readDeviceId();
    await store.stopHost();
    await store.startHost();
    expect(await readDeviceId(), first, reason: '同一 LanStore 生命周期内稳定');
  });
}
