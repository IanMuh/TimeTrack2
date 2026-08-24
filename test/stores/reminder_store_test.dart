import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:timetrack2/data/database/app_database.dart' hide ProfileSettings;
import 'package:timetrack2/data/repositories/activity_repository.dart';
import 'package:timetrack2/data/repositories/settings_repository.dart';
import 'package:timetrack2/data/repositories/time_entry_repository.dart';
import 'package:timetrack2/stores/clock_store.dart';
import 'package:timetrack2/stores/data_revision.dart';
import 'package:timetrack2/stores/reminder_store.dart';
import 'package:timetrack2/stores/settings_store.dart';
import 'package:timetrack2/stores/timer_store.dart';
import 'package:timetrack2/stores/undo_store.dart';
import 'package:timetrack2/viewmodels/profile_settings.dart';

/// ReminderStore 确定性测试：ClockStore 不启动，测试直接改注入时刻后
/// 调 [ReminderStore.handleTick]（tick 逻辑与 ClockStore 解耦）。
///
/// 注意：TimerStore 写路径用真实 DateTime.now()——运行条目起点必须经
/// `switchToActivity(at:)` 对齐注入时刻，否则 elapsed/阈值断言漂移。
class _Harness {
  _Harness() {
    db = AppDatabase(NativeDatabase.memory());
    activities = ActivityRepository(database: db);
    settingsRepo = SettingsRepository(database: db);
    entries = TimeEntryRepository(
      database: db,
      activityRepository: activities,
      settingsRepository: settingsRepo,
    );
    undo = UndoStore();
    revision = DataRevision();
    clock = ClockStore(autoStart: false);
    timer = TimerStore(
      entries: entries,
      undo: undo,
      clock: clock,
      dataRevision: revision,
    );
    settings = SettingsStore(
      settings: settingsRepo,
      undo: undo,
      dataRevision: revision,
    );
    reminder = ReminderStore(
      clock: clock,
      settings: settings,
      timer: timer,
      isUnassignedActivity: activities.activityIdIsUnassigned,
      now: () => fixedNow,
    );
  }

  late final AppDatabase db;
  late final ActivityRepository activities;
  late final SettingsRepository settingsRepo;
  late final TimeEntryRepository entries;
  late final UndoStore undo;
  late final DataRevision revision;
  late final ClockStore clock;
  late final TimerStore timer;
  late final SettingsStore settings;
  late final ReminderStore reminder;

  DateTime fixedNow = DateTime(2026, 8, 23, 8, 0);

  Future<void> configure({
    int reminderMinutes = 30,
    int reminderIntervalMinutes = 10,
    ReminderMethod method = ReminderMethod.dialog,
    bool quickReminderEnabled = true,
    int reminderTimeOfDayMinutes = 540,
  }) async {
    await settings.reload();
    final current = settings.current!;
    await settings.save(current.copyWith(
      reminderMinutes: reminderMinutes,
      reminderIntervalMinutes: reminderIntervalMinutes,
      reminderMethod: method,
      quickReminderEnabled: quickReminderEnabled,
      reminderTimeOfDayMinutes: reminderTimeOfDayMinutes,
    ));
  }

  Future<void> close() async {
    reminder.dispose();
    settings.dispose();
    timer.dispose();
    clock.dispose();
    revision.dispose();
    undo.dispose();
    await db.close();
  }
}

void main() {
  group('ReminderStore 运行阈值提醒「仍在进行？」', () {
    test('达到阈值触发（dialog 载体）；顺延间隔后重复触发', () async {
      final h = _Harness();
      addTearDown(h.close);
      await h.configure(reminderMinutes: 1, reminderIntervalMinutes: 1);
      final a =
          (await h.activities.createActivity(name: '写代码', color: 1))
              .requireValue();

      // 会话起点对齐注入时刻（switch --at）。
      await h.timer.switchToActivity(a.id, at: h.fixedNow);

      // +59s：未达 1 分钟阈值。
      h.fixedNow = h.fixedNow.add(const Duration(seconds: 59));
      await h.reminder.handleTick();
      expect(h.reminder.active, isNull);

      // +61s：触发「仍在进行？」。
      h.fixedNow = h.fixedNow.add(const Duration(seconds: 2));
      await h.reminder.handleTick();
      final active = h.reminder.active;
      expect(active, isA<OngoingReminder>());
      final ongoing = active! as OngoingReminder;
      expect(ongoing.entryId, (await h.entries.runningEntry())!.id);
      expect(ongoing.activityName, '写代码');
      expect(ongoing.method, ReminderMethod.dialog);
      expect(ongoing.elapsed.inSeconds, 61);

      // 待处置期间不叠加触发。
      h.fixedNow = h.fixedNow.add(const Duration(minutes: 5));
      await h.reminder.handleTick();
      expect(identical(h.reminder.active, ongoing), isTrue);

      // 继续/稍后 → 清除；再过一个间隔后重复触发。
      h.reminder.acknowledgeOngoing();
      expect(h.reminder.active, isNull);
      h.fixedNow = h.fixedNow.add(const Duration(seconds: 30));
      await h.reminder.handleTick();
      expect(h.reminder.active, isNull, reason: '间隔未到');
      h.fixedNow = h.fixedNow.add(const Duration(seconds: 31));
      await h.reminder.handleTick();
      expect(h.reminder.active, isA<OngoingReminder>());
    });

    test('停止动作经 TimerStore 落库（切到未分配）并清状态', () async {
      final h = _Harness();
      addTearDown(h.close);
      await h.configure(reminderMinutes: 1);
      final a =
          (await h.activities.createActivity(name: '写代码', color: 1))
              .requireValue();
      await h.timer.switchToActivity(a.id, at: h.fixedNow);
      h.fixedNow = h.fixedNow.add(const Duration(seconds: 61));
      await h.reminder.handleTick();
      expect(h.reminder.active, isA<OngoingReminder>());

      await h.reminder.stopOngoing();
      expect(h.reminder.active, isNull);
      final running = await h.entries.runningEntry();
      expect(
        await h.activities.activityIdIsUnassigned(running!.activityId),
        isTrue,
        reason: '停止 = 切到未分配（未记录态）',
      );
    });

    test('silent 方式不产生任何待处置提醒', () async {
      final h = _Harness();
      addTearDown(h.close);
      await h.configure(reminderMinutes: 1, method: ReminderMethod.silent);
      final a =
          (await h.activities.createActivity(name: '写代码', color: 1))
              .requireValue();
      await h.timer.switchToActivity(a.id, at: h.fixedNow);
      h.fixedNow = h.fixedNow.add(const Duration(minutes: 10));
      await h.reminder.handleTick();
      expect(h.reminder.active, isNull);
    });
  });

  group('ReminderStore 触发时刻提醒（快速提醒）', () {
    test('到点且未记录时触发一次；当日不重复；次日重置', () async {
      final h = _Harness();
      addTearDown(h.close);
      await h.configure(reminderTimeOfDayMinutes: 540); // 09:00

      // 08:59：未到点。
      h.fixedNow = DateTime(2026, 8, 23, 8, 59);
      await h.reminder.handleTick();
      expect(h.reminder.active, isNull);

      // 09:01：触发。
      h.fixedNow = DateTime(2026, 8, 23, 9, 1);
      await h.reminder.handleTick();
      expect(h.reminder.active, isA<QuickStartReminder>());

      // 处置后当日不再重复。
      h.reminder.dismissQuick();
      expect(h.reminder.active, isNull);
      h.fixedNow = DateTime(2026, 8, 23, 15, 0);
      await h.reminder.handleTick();
      expect(h.reminder.active, isNull);

      // 次日到点可再次触发。
      h.fixedNow = DateTime(2026, 8, 24, 9, 1);
      await h.reminder.handleTick();
      expect(h.reminder.active, isA<QuickStartReminder>());
    });

    test('记录中不触发快速提醒（运行阈值优先）', () async {
      final h = _Harness();
      addTearDown(h.close);
      await h.configure(reminderMinutes: 60, reminderTimeOfDayMinutes: 540);
      final a =
          (await h.activities.createActivity(name: '写代码', color: 1))
              .requireValue();
      await h.timer.switchToActivity(a.id, at: DateTime(2026, 8, 23, 9, 0));
      h.fixedNow = DateTime(2026, 8, 23, 9, 30);
      await h.reminder.handleTick();
      expect(h.reminder.active, isNull, reason: '记录中不提醒开始记录');
    });

    test('开关关闭时不触发', () async {
      final h = _Harness();
      addTearDown(h.close);
      await h.configure(quickReminderEnabled: false);
      h.fixedNow = DateTime(2026, 8, 23, 10, 0);
      await h.reminder.handleTick();
      expect(h.reminder.active, isNull);
    });
  });
}
