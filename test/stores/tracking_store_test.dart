import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:timetrack2/data/database/app_database.dart' hide ProfileSettings;
import 'package:timetrack2/data/repositories/activity_repository.dart';
import 'package:timetrack2/data/repositories/category_repository.dart';
import 'package:timetrack2/data/repositories/settings_repository.dart';
import 'package:timetrack2/data/repositories/time_entry_repository.dart';
import 'package:timetrack2/data/repositories/tracking_rule_repository.dart';
import 'package:timetrack2/stores/clock_store.dart';
import 'package:timetrack2/stores/data_revision.dart';
import 'package:timetrack2/stores/timer_store.dart';
import 'package:timetrack2/stores/tracking_store.dart';
import 'package:timetrack2/stores/undo_store.dart';
import 'package:timetrack2/viewmodels/tracking_rule.dart';

class _FakeDetector implements ForegroundDetector {
  // 测试内字段直接赋值（processName/windowTitle 可变）。
  @override
  String? processName;
  @override
  String? windowTitle;
}

class _TestHarness {
  _TestHarness() {
    db = AppDatabase(NativeDatabase.memory());
    activities = ActivityRepository(database: db);
    categories = CategoryRepository(database: db);
    settings = SettingsRepository(database: db);
    entries = TimeEntryRepository(
      database: db,
      activityRepository: activities,
      settingsRepository: settings,
    );
    rules = TrackingRuleRepository(database: db);
    undo = UndoStore();
    revision = DataRevision();
    clock = ClockStore(autoStart: false);
    timer = TimerStore(
      entries: entries,
      undo: undo,
      clock: clock,
      dataRevision: revision,
    );
    detector = _FakeDetector();
    tracking = TrackingStore(
      rules: rules,
      timer: timer,
      dataRevision: revision,
      clock: clock,
      detector: detector,
      pollInterval: const Duration(seconds: 5), // 显式传（防隐式默认耦合）
      now: () => _fixedNow,
    );
  }

  late final AppDatabase db;
  late final ActivityRepository activities;
  late final CategoryRepository categories;
  late final SettingsRepository settings;
  late final TimeEntryRepository entries;
  late final TrackingRuleRepository rules;
  late final UndoStore undo;
  late final DataRevision revision;
  late final ClockStore clock;
  late final TimerStore timer;
  late final _FakeDetector detector;
  late final TrackingStore tracking;

  DateTime _fixedNow = DateTime(2026, 8, 14, 12);

  int _seq = 0;

  Future<TrackingRule> seedRule({
    required String process,
    TrackingRuleMatchKind kind = TrackingRuleMatchKind.process,
    required String activityId,
  }) async {
    final result = await rules.saveRule(TrackingRule(
      id: 'rule-${_seq++}-$process',
      pattern: process,
      matchKind: kind,
      activityId: activityId,
      updatedAt: DateTime(2026, 8, 14).add(Duration(seconds: _seq)),
    ));
    return result.requireValue();
  }

  Future<void> close() async {
    tracking.dispose();
    timer.dispose();
    clock.dispose();
    revision.dispose();
    undo.dispose();
    await db.close();
  }
}

void main() {
  group('TrackingStore 匹配器', () {
    test('进程精确匹配 → 自动切换（isAuto 透传）', () async {
      final h = _TestHarness();
      addTearDown(h.close);
      final a = (await h.activities.createActivity(name: 'A', color: 0))
          .requireValue();
      await h.seedRule(process: 'chrome.exe', activityId: a.id);

      h.detector.processName = 'chrome.exe';
      await h.tracking.poll();
      final running = await h.entries.runningEntry();
      expect(running!.activityId, a.id);
      expect(running.isAuto, isTrue); // 自动记录透传
      expect(h.tracking.lastMatchedActivityId, a.id);
    });

    test('未命中进程：不动作（保持当前）', () async {
      final h = _TestHarness();
      addTearDown(h.close);
      final a = (await h.activities.createActivity(name: 'A', color: 0))
          .requireValue();
      final b = (await h.activities.createActivity(name: 'B', color: 0))
          .requireValue();
      await h.seedRule(process: 'chrome.exe', activityId: a.id);
      await h.timer.switchToActivity(b.id);
      h.detector.processName = 'notepad.exe';
      await h.tracking.poll();
      expect((await h.entries.runningEntry())!.activityId, b.id); // 保持 B
    });

    test('段通配 `code*.exe` 前缀+后缀命中；后缀不符不命中', () async {
      final h = _TestHarness();
      addTearDown(h.close);
      final a = (await h.activities.createActivity(name: 'A', color: 0))
          .requireValue();
      await h.seedRule(process: 'code*.exe', activityId: a.id);
      h.detector.processName = 'code-2.exe';
      await h.tracking.poll();
      expect((await h.entries.runningEntry())!.activityId, a.id);

      // 后缀不符（code-not-exe.txt）：不应命中（防前缀-only 误命中）。
      final b = (await h.activities.createActivity(name: 'B', color: 0))
          .requireValue();
      await h.timer.switchToActivity(b.id);
      h.detector.processName = 'code-not-exe.txt';
      await h.tracking.poll();
      expect((await h.entries.runningEntry())!.activityId, b.id); // 保持 B
    });

    test('title 正则：仅标题匹配即切换（不要求进程命中）', () async {
      final h = _TestHarness();
      addTearDown(h.close);
      final a = (await h.activities.createActivity(name: 'A', color: 0))
          .requireValue();
      await h.seedRule(
        process: r'项目.*文档',
        kind: TrackingRuleMatchKind.title,
        activityId: a.id,
      );
      h.detector.processName = 'any.exe'; // 进程名不参与 title 匹配
      h.detector.windowTitle = '项目A - 文档';
      await h.tracking.poll();
      expect((await h.entries.runningEntry())!.activityId, a.id);
    });

    test('title 不匹配 / 非法正则跳过：有效规则仍命中（跳过并继续）', () async {
      final h = _TestHarness();
      addTearDown(h.close);
      final a = (await h.activities.createActivity(name: 'A', color: 0))
          .requireValue();
      // 非法正则规则排在**可命中的有效规则之前**——若实现遇 FormatException
      // 终止整个循环（而非"跳过继续"），有效规则将无法命中，测试失败。
      await h.seedRule(
        process: r'[', // 非法正则
        kind: TrackingRuleMatchKind.title,
        activityId: a.id,
      );
      await h.seedRule(
        process: r'项目.*文档',
        kind: TrackingRuleMatchKind.title,
        activityId: a.id,
      );
      h.detector.processName = 'any.exe';
      h.detector.windowTitle = '项目A - 文档';
      await h.tracking.poll();
      expect((await h.entries.runningEntry())!.activityId, a.id); // 有效规则命中
    });

    test('同进程多规则取最先', () async {
      final h = _TestHarness();
      addTearDown(h.close);
      final a = (await h.activities.createActivity(name: 'A', color: 0))
          .requireValue();
      final b = (await h.activities.createActivity(name: 'B', color: 0))
          .requireValue();
      await h.seedRule(process: 'work.exe', activityId: a.id);
      await h.seedRule(process: 'work.exe', activityId: b.id);
      h.detector.processName = 'work.exe';
      await h.tracking.poll();
      expect((await h.entries.runningEntry())!.activityId, a.id);
    });
  });

  group('TrackingStore 轮询与去重', () {
    test('已在该活动：poll 不重复切换', () async {
      final h = _TestHarness();
      addTearDown(h.close);
      final a = (await h.activities.createActivity(name: 'A', color: 0))
          .requireValue();
      await h.seedRule(process: 'work.exe', activityId: a.id);
      h.detector.processName = 'work.exe';
      await h.tracking.poll();
      final first = await h.entries.runningEntry();
      await h.tracking.poll(); // 已命中同一活动
      await h.tracking.poll();
      final after = await h.entries.runningEntry();
      expect(after!.id, first!.id); // 同一条目（未重复切换）
    });

    test('tick 限频：间隔未达不轮询，达标才轮询', () async {
      final h = _TestHarness();
      addTearDown(h.close);
      final a = (await h.activities.createActivity(name: 'A', color: 0))
          .requireValue();
      await h.seedRule(process: 'work.exe', activityId: a.id);
      h.detector.processName = 'work.exe';
      // _lastPoll 初始 epoch → 首次 tick 即达标。
      h.clock.notifyListeners();
      await Future<void>.delayed(Duration.zero); // 等异步 poll 完成
      expect((await h.entries.runningEntry())!.activityId, a.id);

      // 5s 间隔内 tick：不轮询（切到 B 后 poll 不动作）。
      final b = (await h.activities.createActivity(name: 'B', color: 0))
          .requireValue();
      await h.timer.switchToActivity(b.id);
      h._fixedNow = h._fixedNow.add(const Duration(seconds: 2));
      h.clock.notifyListeners();
      await Future<void>.delayed(Duration.zero);
      expect((await h.entries.runningEntry())!.activityId, b.id); // 限频未轮询

      // 间隔达标：轮询切回 A。
      h._fixedNow = h._fixedNow.add(const Duration(seconds: 6));
      h.clock.notifyListeners();
      await Future<void>.delayed(Duration.zero);
      expect((await h.entries.runningEntry())!.activityId, a.id);
    });
  });

  group('TrackingStore 规则 CRUD', () {
    test('saveRule/deleteRule：dataRevision bump（经 store 写路径）', () async {
      final h = _TestHarness();
      addTearDown(h.close);
      final a = (await h.activities.createActivity(name: 'A', color: 0))
          .requireValue();
      final before = h.revision.value;
      final rule = TrackingRule(
        id: 'rule-1',
        pattern: 'work.exe',
        matchKind: TrackingRuleMatchKind.process,
        activityId: a.id,
        updatedAt: DateTime(2026, 8, 14),
      );
      final saved = (await h.tracking.saveRule(rule)).requireValue();
      expect(h.revision.value, before + 1); // 规则变更 bump
      await h.tracking.deleteRule(saved);
      expect(h.revision.value, before + 2);
    });
  });
}
