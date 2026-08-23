import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:timetrack2/constants/storage_keys.dart' show AppMetadataKeys;
import 'package:timetrack2/data/cleanup/data_wipe_service.dart';
import 'package:timetrack2/data/database/app_database.dart' hide ProfileSettings;
import 'package:timetrack2/data/repositories/activity_repository.dart';
import 'package:timetrack2/data/repositories/settings_repository.dart';
import 'package:timetrack2/data/repositories/time_entry_repository.dart';
import 'package:timetrack2/data/repositories/tracking_rule_repository.dart';
import 'package:timetrack2/viewmodels/profile_settings.dart';
import 'package:timetrack2/viewmodels/tracking_rule.dart';

/// DataWipeService（批次 4 设置页危险区）：全清语义——业务表清空、
/// 配置重置、device_id 保留。
void main() {
  late AppDatabase db;
  late DataWipeService wipe;
  late ActivityRepository activities;
  late TimeEntryRepository entries;
  late TrackingRuleRepository rules;
  late SettingsRepository settings;

  setUp(() async {
    db = AppDatabase(NativeDatabase.memory());
    wipe = DataWipeService(database: db);
    activities = ActivityRepository(database: db);
    entries = TimeEntryRepository(
      database: db,
      activityRepository: activities,
      settingsRepository: SettingsRepository(database: db),
    );
    rules = TrackingRuleRepository(database: db);
    settings = SettingsRepository(database: db);

    // 造数据：活动 + 条目 + 规则 + 配置（非默认值）+ device_id + 游标键。
    final activity = (await activities.createActivity(name: '工作', color: 1))
        .requireValue();
    await entries.createManualEntry(
      activityId: activity.id,
      startAt: DateTime(2026, 8, 23, 9),
      endAt: DateTime(2026, 8, 23, 10),
      note: '',
    );
    await rules.saveRule(TrackingRule(
      id: 'r1',
      pattern: 'code.exe',
      matchKind: TrackingRuleMatchKind.process,
      activityId: activity.id,
      updatedAt: DateTime(2026, 8, 23),
    ));
    await settings.save(
        (await settings.settings()).requireValue().copyWith(reminderMinutes: 99));
    await db.into(db.appMetadata).insertOnConflictUpdate(AppMetadataCompanion.insert(
        key: AppMetadataKeys.deviceId, value: 'device-keep'));
    await db.into(db.appMetadata).insertOnConflictUpdate(AppMetadataCompanion.insert(
        key: AppMetadataKeys.lastSyncAt, value: '2026-08-23T00:00:00Z'));
  });

  tearDown(() async {
    await db.close();
  });

  test('wipeAll：业务表清空 + 配置回默认 + device_id 保留 + 游标清除',
      () async {
    final result = await wipe.wipeAll();
    expect(result.isSuccess, isTrue);
    expect(result.requireValue(), greaterThan(0));

    final activityResult = await activities.activities(includeDeleted: true);
    expect(activityResult.requireValue().where((a) => !a.isUnassigned), isEmpty,
        reason: '活动全清（seed 由编排层重建，非 wipe 职责）');
    final entryList = await entries.entriesForRange(DateTime(2020), DateTime(2030));
    expect(entryList, isEmpty);
    final ruleList = await rules.activeRules();
    expect(ruleList.requireValue(), isEmpty);

    // 配置回默认。
    final s = (await settings.settings()).requireValue();
    expect(s.reminderMinutes, ProfileSettings.defaultReminderMinutes,
        reason: '配置重置为默认');

    // app_metadata：device_id 保留，游标清除。
    final meta = await db.select(db.appMetadata).get();
    final keys = meta.map((r) => r.key).toSet();
    expect(keys, contains(AppMetadataKeys.deviceId),
        reason: '设备标识非用户数据，保留防云端"新设备"');
    expect(keys, isNot(contains(AppMetadataKeys.lastSyncAt)),
        reason: '数据已空，旧同步游标清除');

    // 幂等：再次清除不报错。
    final again = await wipe.wipeAll();
    expect(again.isSuccess, isTrue);
  });
}
