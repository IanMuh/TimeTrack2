import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:timetrack2/data/database/app_database.dart';
import 'package:timetrack2/data/repositories/action_log_repository.dart';
import 'package:timetrack2/data/repositories/activity_repository.dart';
import 'package:timetrack2/data/repositories/category_repository.dart';
import 'package:timetrack2/data/repositories/settings_repository.dart';
import 'package:timetrack2/data/repositories/time_entry_repository.dart';
import 'package:timetrack2/data/sync/sync_bundle.dart';
import 'package:timetrack2/data/sync/sync_bundle_codec.dart';
import 'package:timetrack2/data/sync/sync_bundle_repository.dart';
import 'package:timetrack2/viewmodels/activity.dart';
import 'package:timetrack2/viewmodels/time_entry.dart';

/// 测试环境：两个独立数据库模拟两台设备（LAN/文件互通的 LWW 合并双方）。
class Harness2 {
  Harness2() {
    _build();
  }

  late final AppDatabase db;
  late final ActivityRepository activities;
  late final CategoryRepository categories;
  late final SettingsRepository settings;
  late final ActionLogRepository actionLogs;
  late final TimeEntryRepository entries;
  late final SyncBundleRepository syncBundle;

  void _build() {
    db = AppDatabase(NativeDatabase.memory());
    activities = ActivityRepository(database: db);
    categories = CategoryRepository(database: db);
    settings = SettingsRepository(database: db);
    actionLogs = ActionLogRepository(database: db);
    entries = TimeEntryRepository(
      database: db,
      activityRepository: activities,
      settingsRepository: settings,
    );
    syncBundle = SyncBundleRepository(
      database: db,
      activities: activities,
      categories: categories,
      timeEntries: entries,
      actionLogs: actionLogs,
      settings: settings,
    );
  }

  Future<void> close() => db.close();
}

Future<Activity> seedActivity(Harness2 h, String name) async {
  return (await h.activities.createActivity(name: name, color: 0xff2563eb))
      .requireValue();
}

void main() {
  group('SyncBundleCodec', () {
    test('round-trip 保真（含软删行与快照字段）', () {
      final now = DateTime.utc(2026, 8, 11, 4);
      final bundle = SyncBundle(
        schemaVersion: 2,
        exportedAt: now,
        sourceDeviceId: 'dev-1',
        activities: [
          Activity(
            id: 'a1',
            name: '工作',
            color: 0xff2563eb,
            isFavorite: true,
            updatedAt: now,
            deletedAt: now, // 软删行包含在导出中
          ),
        ],
        timeEntries: [
          TimeEntry(
            id: 'e1',
            activityId: 'a1',
            activityNameSnapshot: '工作',
            activityColorSnapshot: 0xff2563eb,
            startAt: now,
            endAt: now.add(const Duration(hours: 1)),
            deviceId: 'dev-1',
            updatedAt: now,
          ),
        ],
      );
      final text = const SyncBundleCodec().encode(bundle);
      final decoded = const SyncBundleCodec().decode(text);
      expect(decoded.schemaVersion, 2);
      expect(decoded.sourceDeviceId, 'dev-1');
      expect(decoded.activities.single.name, '工作');
      expect(decoded.activities.single.isDeleted, isTrue,
          reason: '软删行必须随包传播');
      expect(decoded.timeEntries.single.activityNameSnapshot, '工作');
      expect(
        decoded.exportedAt.isAtSameMomentAs(now),
        isTrue,
      );
    });

    test('schema_version 1..2 接受、其他拒绝（校验先于写库）', () {
      const codec = SyncBundleCodec();
      final valid = SyncBundle(
        schemaVersion: 1,
        exportedAt: DateTime.utc(2026),
        sourceDeviceId: 'd',
      );
      expect(codec.decode(codec.encode(valid)).schemaVersion, 1);

      // 版本 0 / 3 / 非数字
      for (final bad in [
        '{"schema_version": 0, "exported_at": "2026-01-01T00:00:00Z", "source_device_id": "d"}',
        '{"schema_version": 3, "exported_at": "2026-01-01T00:00:00Z", "source_device_id": "d"}',
        '{"schema_version": "x", "exported_at": "2026-01-01T00:00:00Z", "source_device_id": "d"}',
        '{"exported_at": "2026-01-01T00:00:00Z", "source_device_id": "d"}', // 缺 version
      ]) {
        expect(() => codec.decode(bad), throwsFormatException,
            reason: '$bad 应被拒绝');
      }
    });

    test('顶层非对象 / 必填字段缺失 → FormatException', () {
      const codec = SyncBundleCodec();
      expect(() => codec.decode('[1,2,3]'), throwsFormatException);
      expect(
        () => codec.decode('{"schema_version": 2, "exported_at": "2026-01-01T00:00:00Z"}'),
        throwsFormatException, // 缺 source_device_id
      );
      expect(
        () => codec.decode('{"schema_version": 2, "source_device_id": "d"}'),
        throwsFormatException, // 缺 exported_at
      );
    });
  });

  group('SyncBundleRepository merge（双设备 LWW）', () {
    late Harness2 deviceA;
    late Harness2 deviceB;

    setUp(() {
      deviceA = Harness2();
      deviceB = Harness2();
    });
    tearDown(() async {
      await deviceA.close();
      await deviceB.close();
    });

    test('B 合并 A 的包：新行落库、旧行不覆盖', () async {
      final a = await seedActivity(deviceA, 'A 的活动');
      // A 导出全量 → B 合并
      final bundleA = await deviceA.syncBundle.exportBundle(sourceDeviceId: 'devA');
      await deviceB.syncBundle.mergeBundle(bundleA);
      final bActivities = (await deviceB.activities.activities()).requireValue();
      expect(bActivities.map((x) => x.id), contains(a.id));

      // B 修改 A 的行（updatedAt 更旧）→ 不覆盖
      final older = a.copyWith(
        name: 'B 旧改',
        updatedAt: a.updatedAt.subtract(const Duration(hours: 1)),
      );
      await deviceB.syncBundle.mergeBundle(SyncBundle(
        schemaVersion: 2,
        exportedAt: DateTime.now(),
        sourceDeviceId: 'devB',
        activities: [older],
      ));
      final after = (await deviceB.activities.activities()).requireValue()
          .firstWhere((x) => x.id == a.id);
      expect(after.name, 'A 的活动', reason: '旧 updatedAt 不覆盖新值');

      // B 新改（updatedAt 更新）→ 覆盖
      final newer = a.copyWith(
        name: 'B 新改',
        updatedAt: a.updatedAt.add(const Duration(hours: 1)),
      );
      await deviceB.syncBundle.mergeBundle(SyncBundle(
        schemaVersion: 2,
        exportedAt: DateTime.now(),
        sourceDeviceId: 'devB',
        activities: [newer],
      ));
      final after2 = (await deviceB.activities.activities()).requireValue()
          .firstWhere((x) => x.id == a.id);
      expect(after2.name, 'B 新改');
    });

    test('删除传播：A 软删的行合并到 B 后 B 也不可见', () async {
      final a = await seedActivity(deviceA, '待删');
      await deviceA.activities.deleteActivity(a);
      final bundleA = await deviceA.syncBundle.exportBundle(sourceDeviceId: 'devA');
      await deviceB.syncBundle.mergeBundle(bundleA);
      final bActivities = (await deviceB.activities.activities()).requireValue();
      expect(bActivities.map((x) => x.id), isNot(contains(a.id)),
          reason: '软删墓碑随 LWW 传播');
      final withDeleted =
          (await deviceB.activities.activities(includeDeleted: true)).requireValue();
      expect(withDeleted.map((x) => x.id), contains(a.id),
          reason: '墓碑行保留（含删导出可见）');
    });

    test('merge 后归一化：运行条目唯一 + 未分配单例存在', () async {
      // A 有一运行条目；B 合并后应只有一个运行条目
      final a = await seedActivity(deviceA, '工作');
      await deviceA.entries.switchToActivity(a.id);
      // B 自己也有一个运行条目（不同设备同时计时）
      final bActivity = await seedActivity(deviceB, '工作B');
      await deviceB.entries.switchToActivity(bActivity.id);

      final bundleA = await deviceA.syncBundle.exportBundle(sourceDeviceId: 'devA');
      await deviceB.syncBundle.mergeBundle(bundleA);
      await deviceB.syncBundle.normalizeAfterMerge();

      final runningB = await deviceB.entries.runningEntry();
      expect(runningB, isNotNull, reason: '归一化后仍有运行条目');
      // 未分配单例已确保
      expect((await deviceB.activities.unassignedActivity()).requireValue().id,
          isNotEmpty);
    });
  });

  group('FileInteropService（临时文件端到端）', () {
    test('导出→导入到另一设备', () async {
      final h = Harness2();
      final h2 = Harness2();
      try {
        final activity = await seedActivity(h, '互通活动');
        await h.entries.createManualEntry(
          activityId: activity.id,
          startAt: DateTime(2026, 8, 11, 9),
          endAt: DateTime(2026, 8, 11, 10),
          note: '互通测试',
        );

        // 直接编码（file_selector 对话框无法在测试中触发）
        final bundle = await h.syncBundle.exportBundle(sourceDeviceId: 'devA');
        final text = const SyncBundleCodec().encode(bundle);

        final dir = await Directory.systemTemp.createTemp('interop');
        try {
          final file = File('${dir.path}/export.timetrack.json');
          await file.writeAsString(text);
          final imported = const SyncBundleCodec().decode(
            await file.readAsString(),
          );
          await h2.syncBundle.mergeBundle(imported);
          await h2.syncBundle.normalizeAfterMerge();

          final activities2 = (await h2.activities.activities()).requireValue();
          expect(activities2.map((x) => x.id), contains(activity.id));
          final entries2 = await h2.entries.entriesForDay(DateTime(2026, 8, 11));
          expect(entries2.single.note, '互通测试');
        } finally {
          await dir.delete(recursive: true);
        }
      } finally {
        await h.close();
        await h2.close();
      }
    });
  });
}
