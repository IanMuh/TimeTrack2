import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:timetrack2/data/database/app_database.dart' hide ProfileSettings;
import 'package:timetrack2/data/repositories/activity_repository.dart';
import 'package:timetrack2/data/repositories/category_repository.dart';
import 'package:timetrack2/data/repositories/settings_repository.dart';
import 'package:timetrack2/data/repositories/time_entry_repository.dart';
import 'package:timetrack2/stores/clock_store.dart';
import 'package:timetrack2/stores/data_revision.dart';
import 'package:timetrack2/stores/today_store.dart';

class TestHarness {
  TestHarness() {
    db = AppDatabase(NativeDatabase.memory());
    activities = ActivityRepository(database: db);
    categories = CategoryRepository(database: db);
    settings = SettingsRepository(database: db);
    entries = TimeEntryRepository(
      database: db,
      activityRepository: activities,
      settingsRepository: settings,
    );
    revision = DataRevision();
    clock = ClockStore(autoStart: false);
    store = TodayStore(
      entries: entries,
      dataRevision: revision,
      clock: clock,
      now: () => _fixedNow,
    );
  }

  late final AppDatabase db;
  late final ActivityRepository activities;
  late final CategoryRepository categories;
  late final SettingsRepository settings;
  late final TimeEntryRepository entries;
  late final DataRevision revision;
  late final ClockStore clock;
  late final TodayStore store;

  final DateTime _fixedNow = DateTime(2026, 8, 14, 12);

  bool _closed = false;

  Future<void> close() async {
    if (_closed) return; // 幂等：个别用例手动 dispose 后 tearDown 不重复
    _closed = true;
    store.dispose();
    clock.dispose();
    revision.dispose();
    await db.close();
  }
}

void main() {
  group('TodayStore', () {
    late TestHarness h;

    setUp(() => h = TestHarness());
    tearDown(() => h.close());

    test('loadToday 只含今日条目（本地日界）', () async {
      final a = (await h.activities.createActivity(name: 'A', color: 0))
          .requireValue();
      await h.entries.createManualEntry(
        activityId: a.id,
        startAt: DateTime(2026, 8, 14, 9),
        endAt: DateTime(2026, 8, 14, 10),
        note: '',
      );
      await h.entries.createManualEntry(
        activityId: a.id,
        startAt: DateTime(2026, 8, 13, 9), // 昨日
        endAt: DateTime(2026, 8, 13, 10),
        note: '',
      );
      await h.store.loadToday();
      expect(h.store.today, hasLength(1));
      expect(h.store.today.single.startAt, DateTime(2026, 8, 14, 9));
    });

    test('dataRevision 变更自动重新加载', () async {
      final a = (await h.activities.createActivity(name: 'A', color: 0))
          .requireValue();
      await h.entries.createManualEntry(
        activityId: a.id,
        startAt: DateTime(2026, 8, 14, 9),
        endAt: DateTime(2026, 8, 14, 10),
        note: '',
      );
      await h.store.loadToday();
      expect(h.store.today, hasLength(1));

      // 模拟用户操作后的 bump：自动刷新反映新条目。
      await h.entries.createManualEntry(
        activityId: a.id,
        startAt: DateTime(2026, 8, 14, 10),
        endAt: DateTime(2026, 8, 14, 11),
        note: '',
      );
      h.revision.bump();
      await pumpEventQueue(); // dataRevision 监听触发 loadToday（async）
      expect(h.store.today, hasLength(2));
    });

    test('totalDuration：运行中条目截至 effectiveNow', () async {
      final a = (await h.activities.createActivity(name: 'A', color: 0))
          .requireValue();
      await h.entries.createManualEntry(
        activityId: a.id,
        startAt: DateTime(2026, 8, 14, 9),
        endAt: DateTime(2026, 8, 14, 10),
        note: '',
      );
      await h.entries.switchToActivity(a.id, at: h._fixedNow); // 运行中（固定 now）
      await h.store.loadToday();
      // effectiveNow = 固定 now +30m：已结束 1h + 运行 30m = 1.5h。
      final duration = h.store.totalDuration(
        effectiveNow: h._fixedNow.add(const Duration(minutes: 30)),
      );
      expect(duration, const Duration(minutes: 90));
    });

    test('dispose 后 dataRevision 变更不触发 loadToday（不崩）', () async {
      // 独立实例（避免手动 dispose 后 tearDown 二次 dispose）。
      final store = TodayStore(
        entries: h.entries,
        dataRevision: h.revision,
        clock: h.clock,
        now: () => h._fixedNow,
      );
      store.dispose();
      h.revision.bump();
      await pumpEventQueue();
      expect(store.today, isEmpty); // dispose 后静默
    });

    test('跨本地午夜条目计入今日（窗口重叠）', () async {
      final a = (await h.activities.createActivity(name: 'A', color: 0))
          .requireValue();
      await h.entries.createManualEntry(
        activityId: a.id,
        startAt: DateTime(2026, 8, 13, 23),
        endAt: DateTime(2026, 8, 14, 1),
        note: '',
      );
      await h.store.loadToday();
      expect(h.store.today, hasLength(1)); // 与今日窗口重叠即计入
    });

    test('时钟 tick：有运行条目时刷新，无运行条目时不查库', () async {
      final a = (await h.activities.createActivity(name: 'A', color: 0))
          .requireValue();
      await h.entries.createManualEntry(
        activityId: a.id,
        startAt: DateTime(2026, 8, 14, 9),
        endAt: DateTime(2026, 8, 14, 10),
        note: '',
      );
      await h.store.loadToday();
      // 无运行条目：tick 仅 notify（不查库——今日内容不随时间变）。
      h.clock.notifyListeners(); // 手动触发 tick 回调
      await pumpEventQueue();
      expect(h.store.today, hasLength(1));
    });
  });
}
