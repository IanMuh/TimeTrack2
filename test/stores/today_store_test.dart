import 'dart:async';

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
import 'package:timetrack2/viewmodels/time_entry.dart';

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

  /// 可变的"当前时刻"（跨日/tick 用例重赋值；重赋值后 lint 不再要求 final）。
  DateTime _fixedNow = DateTime(2026, 8, 14, 12);

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

/// 查询 spy：计数 entriesForRange 调用 + 可注入失败（验证 tick 是否真的
/// 触发了 DB 查询、失败路径节流）。
class _SpyEntries extends TimeEntryRepository {
  _SpyEntries({
    required super.database,
    required super.activityRepository,
    required super.settingsRepository,
  });

  int entriesForRangeCalls = 0;
  bool failNext = false;

  @override
  Future<List<TimeEntry>> entriesForRange(DateTime start, DateTime end) {
    entriesForRangeCalls++;
    if (failNext) {
      failNext = false;
      throw Exception('DB 故障');
    }
    return super.entriesForRange(start, end);
  }
}

/// 可挂起查询（并发乱序测试）。
class _GatedEntries extends TimeEntryRepository {
  _GatedEntries({
    required super.database,
    required super.activityRepository,
    required super.settingsRepository,
  });

  final gates = <Completer<void>>[];

  @override
  Future<List<TimeEntry>> entriesForRange(DateTime start, DateTime end) {
    if (gates.isEmpty) return super.entriesForRange(start, end);
    final gate = gates.removeAt(0);
    return gate.future.then((_) => super.entriesForRange(start, end));
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

    test('并发乱序：旧 loadToday 晚完成不覆盖新缓存', () async {
      final a = (await h.activities.createActivity(name: 'A', color: 0))
          .requireValue();
      await h.entries.createManualEntry(
        activityId: a.id,
        startAt: DateTime(2026, 8, 14, 9),
        endAt: DateTime(2026, 8, 14, 10),
        note: '',
      );
      final gated = _GatedEntries(
        database: h.db,
        activityRepository: h.activities,
        settingsRepository: h.settings,
      );
      final revision = DataRevision();
      final clock = ClockStore(autoStart: false);
      final store = TodayStore(
        entries: gated,
        dataRevision: revision,
        clock: clock,
        now: () => h._fixedNow,
      );
      addTearDown(() {
        store.dispose();
        clock.dispose();
        revision.dispose();
      });

      final gate = Completer<void>();
      gated.gates.add(gate);
      final futureA = store.loadToday(); // A 挂起
      await pumpEventQueue();
      await h.entries.createManualEntry(
        activityId: a.id,
        startAt: DateTime(2026, 8, 14, 10),
        endAt: DateTime(2026, 8, 14, 11),
        note: '',
      );
      await store.loadToday(); // B 完成（含 2 条）
      expect(store.today, hasLength(2));
      gate.complete(); // A 晚完成（仅含 1 条旧数据）
      await futureA;
      expect(store.today, hasLength(2)); // 新缓存保持，未被 A 覆盖
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

    test('时钟 tick：无运行条目不查库、有运行条目触发重载（spy 计数）', () async {
      final spy = _SpyEntries(
        database: h.db,
        activityRepository: h.activities,
        settingsRepository: h.settings,
      );
      final revision = DataRevision();
      final clock = ClockStore(autoStart: false);
      final store = TodayStore(
        entries: spy,
        dataRevision: revision,
        clock: clock,
        now: () => h._fixedNow,
      );
      addTearDown(() {
        store.dispose();
        clock.dispose();
        revision.dispose();
      });
      final a = (await h.activities.createActivity(name: 'A', color: 0))
          .requireValue();
      await h.entries.createManualEntry(
        activityId: a.id,
        startAt: DateTime(2026, 8, 14, 9),
        endAt: DateTime(2026, 8, 14, 10),
        note: '',
      );
      await store.loadToday();
      final callsAfterLoad = spy.entriesForRangeCalls;
      expect(callsAfterLoad, greaterThanOrEqualTo(1));

      // 无运行条目：tick 不查库也不通知（计数不变、无监听通知）。
      var notified = 0;
      store.addListener(() => notified++);
      clock.notifyListeners();
      await pumpEventQueue();
      expect(spy.entriesForRangeCalls, callsAfterLoad);
      expect(notified, 0); // 无运行条目 tick 不通知（不重建 UI）

      // 有运行条目：tick 触发重载（计数 +1）。
      await h.entries.switchToActivity(a.id, at: h._fixedNow);
      await store.loadToday(); // 刷新今日缓存含运行条目
      final callsWithRunning = spy.entriesForRangeCalls;
      clock.notifyListeners();
      await pumpEventQueue();
      expect(spy.entriesForRangeCalls, callsWithRunning + 1);
    });

    test('加载失败：loadFailed 置位，同日 tick 不重试（节流）', () async {
      final spy = _SpyEntries(
        database: h.db,
        activityRepository: h.activities,
        settingsRepository: h.settings,
      );
      final revision = DataRevision();
      final clock = ClockStore(autoStart: false);
      final store = TodayStore(
        entries: spy,
        dataRevision: revision,
        clock: clock,
        now: () => h._fixedNow,
      );
      addTearDown(() {
        store.dispose();
        clock.dispose();
        revision.dispose();
      });

      spy.failNext = true;
      await store.loadToday();
      expect(store.loadFailed, isTrue);
      final callsAfterFail = spy.entriesForRangeCalls;

      // 同日无运行条目：tick 不再触发查询（_lastLoadDay 已标记尝试过该日）。
      clock.notifyListeners();
      await pumpEventQueue();
      expect(spy.entriesForRangeCalls, callsAfterFail);

      // 跨日后 tick 触发重载（自动恢复），loadFailed 复位。
      h._fixedNow = DateTime(2026, 8, 15, 0, 1);
      clock.notifyListeners();
      await pumpEventQueue();
      expect(spy.entriesForRangeCalls, greaterThan(callsAfterFail));
      expect(store.loadFailed, isFalse);
    });

    test('跨日 tick：窗口前移强制重载', () async {
      final a = (await h.activities.createActivity(name: 'A', color: 0))
          .requireValue();
      await h.entries.createManualEntry(
        activityId: a.id,
        startAt: DateTime(2026, 8, 14, 23),
        endAt: DateTime(2026, 8, 14, 23, 30),
        note: '',
      );
      await h.store.loadToday();
      expect(h.store.today, hasLength(1));

      // 跨到 8/15：tick 时 dayChanged → 强制重载（无运行条目也查库）。
      h._fixedNow = DateTime(2026, 8, 15, 0, 1);
      h.clock.notifyListeners();
      await pumpEventQueue();
      expect(h.store.today, isEmpty); // 新窗口（8/15）无条目
    });
  });
}
