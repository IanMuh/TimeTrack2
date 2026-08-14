import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:timetrack2/data/database/app_database.dart' hide ProfileSettings;
import 'package:timetrack2/data/repositories/activity_repository.dart';
import 'package:timetrack2/data/repositories/category_repository.dart';
import 'package:timetrack2/data/repositories/settings_repository.dart';
import 'package:timetrack2/data/repositories/time_entry_repository.dart';
import 'package:timetrack2/stores/clock_store.dart';
import 'package:timetrack2/stores/data_revision.dart';
import 'package:timetrack2/stores/timer_store.dart';
import 'package:timetrack2/stores/undo_store.dart';
import 'package:timetrack2/utils/result.dart';

/// 内存库 + store 全链路测试环境。
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
    undo = UndoStore();
    clock = ClockStore(autoStart: false);
    revision = DataRevision();
    timer = TimerStore(
      entries: entries,
      undo: undo,
      clock: clock,
      dataRevision: revision,
    );
  }

  late final AppDatabase db;
  late final ActivityRepository activities;
  late final CategoryRepository categories;
  late final SettingsRepository settings;
  late final TimeEntryRepository entries;
  late final UndoStore undo;
  late final ClockStore clock;
  late final DataRevision revision;
  late final TimerStore timer;

  bool _closed = false;

  Future<void> close() async {
    if (_closed) return; // 幂等：个别用例手动 dispose 后 tearDown 不重复
    _closed = true;
    timer.dispose();
    clock.dispose();
    revision.dispose();
    undo.dispose();
    await db.close();
  }
}

void main() {
  group('TimerStore 写路径', () {
    late TestHarness h;

    setUp(() => h = TestHarness());
    tearDown(() => h.close());

    test('switch：创建运行条目并透传 isAuto', () async {
      final a = (await h.activities.createActivity(name: 'A', color: 0))
          .requireValue();
      final switched = (await h.timer.switchToActivity(a.id, isAuto: true))
          .requireValue();
      expect(switched.isAuto, isTrue);
      expect(switched.isRunning, isTrue);
      await h.timer.refresh();
      expect(h.timer.runningEntry?.activityId, a.id);
      expect(h.timer.lastAction?.id, switched.id);
      // 相对采样（防与写路径 bump 次数强耦合）。
      final before = h.revision.value;
      await h.timer.switchToActivity(a.id);
      expect(h.revision.value, before + 1);
    });

    test('stop：结束运行条目并切到未分配', () async {
      final a = (await h.activities.createActivity(name: 'A', color: 0))
          .requireValue();
      await h.timer.switchToActivity(a.id);
      final before = h.revision.value;
      final stopped = (await h.timer.stopRunning()).requireValue();
      expect(stopped.isRunning, isTrue);
      expect(stopped.activityId, isNot(a.id)); // 未分配活动
      expect(h.revision.value, before + 1);
    });

    test('add：补记条目 isAuto 透传 + dataRevision', () async {
      final a = (await h.activities.createActivity(name: 'A', color: 0))
          .requireValue();
      final before = h.revision.value;
      final added = (await h.timer.addEntry(
        activityId: a.id,
        startAt: DateTime(2026, 8, 14, 10),
        endAt: DateTime(2026, 8, 14, 11),
        note: '会议',
        isAuto: true,
      )).requireValue();
      expect(added.isAuto, isTrue);
      expect(added.endAt, DateTime(2026, 8, 14, 11));
      expect(h.revision.value, before + 1);
    });

    test('split：切割为两段', () async {
      final a = (await h.activities.createActivity(name: 'A', color: 0))
          .requireValue();
      final added = (await h.timer.addEntry(
        activityId: a.id,
        startAt: DateTime(2026, 8, 14, 10),
        endAt: DateTime(2026, 8, 14, 11),
        note: '',
      )).requireValue();
      final parts = (await h.timer.splitEntry(
        entryId: added.id,
        splitAt: DateTime(2026, 8, 14, 10, 30),
      )).requireValue();
      expect(parts, hasLength(2));
      expect(parts[0].endAt, DateTime(2026, 8, 14, 10, 30));
      expect(parts[1].startAt, DateTime(2026, 8, 14, 10, 30));
    });

    test('merge：合并相邻同活动条目', () async {
      final a = (await h.activities.createActivity(name: 'A', color: 0))
          .requireValue();
      final first = (await h.timer.addEntry(
        activityId: a.id,
        startAt: DateTime(2026, 8, 14, 10),
        endAt: DateTime(2026, 8, 14, 11),
        note: '',
      )).requireValue();
      await h.timer.addEntry(
        activityId: a.id,
        startAt: DateTime(2026, 8, 14, 11),
        endAt: DateTime(2026, 8, 14, 12),
        note: '',
      );
      final merged = (await h.timer.mergeWithNeighbor(
        entryId: first.id,
        mergePrevious: false, // 合并右侧
      )).requireValue();
      expect(merged, isNotNull);
      expect(merged!.startAt, DateTime(2026, 8, 14, 10));
      expect(merged.endAt, DateTime(2026, 8, 14, 12));
    });

    test('delete：软删条目', () async {
      final a = (await h.activities.createActivity(name: 'A', color: 0))
          .requireValue();
      final added = (await h.timer.addEntry(
        activityId: a.id,
        startAt: DateTime(2026, 8, 14, 10),
        endAt: DateTime(2026, 8, 14, 11),
        note: '',
      )).requireValue();
      await h.timer.deleteEntry(added.id);
      final current = await h.entries.entryByIdIncludingDeleted(added.id);
      expect(current, isNotNull);
      expect(current!.isDeleted, isTrue);
      expect(h.timer.lastAction, isNull); // 删除后 lastAction 置空（契约）
    });

    test('边界：运行中条目 split/merge 拒绝；add 非法时间段拒绝；删除运行中', () async {
      final a = (await h.activities.createActivity(name: 'A', color: 0))
          .requireValue();
      final running = (await h.timer.switchToActivity(a.id)).requireValue();

      // 运行中条目 split → 仓储拒绝（AppFailure）。
      final splitResult = await h.timer.splitEntry(
        entryId: running.id,
        splitAt: running.startAt.add(const Duration(minutes: 30)),
      );
      expect(splitResult.isSuccess, isFalse);
      // 运行中条目 merge → 拒绝（AppFailure）。
      final mergeResult = await h.timer.mergeWithNeighbor(
        entryId: running.id,
        mergePrevious: false,
      );
      expect(mergeResult.isSuccess, isFalse);
      // add 非法时间段（startAt >= endAt）→ AppFailure 且不记 undo。
      final beforeUndo = h.undo.undoDepth;
      final addResult = await h.timer.addEntry(
        activityId: a.id,
        startAt: DateTime(2026, 8, 14, 11),
        endAt: DateTime(2026, 8, 14, 10),
        note: '',
      );
      expect(addResult.isSuccess, isFalse);
      expect(h.undo.undoDepth, beforeUndo); // 失败不记 undo
      // 删除运行中条目：无守卫，删除后运行态缓存须刷新（不再有运行条目）。
      await h.timer.deleteEntry(running.id);
      await h.timer.refresh();
      expect(h.timer.runningEntry, isNull);
    });

    test('merge 向左合并（mergePrevious=true）', () async {
      final a = (await h.activities.createActivity(name: 'A', color: 0))
          .requireValue();
      final first = (await h.timer.addEntry(
        activityId: a.id,
        startAt: DateTime(2026, 8, 14, 10),
        endAt: DateTime(2026, 8, 14, 11),
        note: '',
      )).requireValue();
      final second = (await h.timer.addEntry(
        activityId: a.id,
        startAt: DateTime(2026, 8, 14, 11),
        endAt: DateTime(2026, 8, 14, 12),
        note: '',
      )).requireValue();
      final merged = (await h.timer.mergeWithNeighbor(
        entryId: second.id,
        mergePrevious: true, // 向左合并 first
      )).requireValue();
      expect(merged, isNotNull);
      expect(merged!.startAt, DateTime(2026, 8, 14, 10));
      expect(merged.endAt, DateTime(2026, 8, 14, 12));
      // 中间态：邻居 first 软删 + 活动 A 仅剩一条非删行（合并行=second）。
      expect((await h.entries.entryByIdIncludingDeleted(first.id))!.isDeleted,
          isTrue);
      final surviving = (await h.entries.allEntries())
          .where((e) => !e.isDeleted && e.activityId == a.id)
          .toList();
      expect(surviving, hasLength(1));
      expect(surviving.single.id, second.id);
      expect(surviving.single.startAt, DateTime(2026, 8, 14, 10));
      expect(surviving.single.endAt, DateTime(2026, 8, 14, 12));
      // undo：恢复 first 与 second。
      await h.undo.undo();
      expect(
          (await h.entries.entryByIdIncludingDeleted(first.id))!.isDeleted,
          isFalse);
      expect(
          (await h.entries.entryByIdIncludingDeleted(second.id))!.isDeleted,
          isFalse);
    });

    test('无运行条目时 stop：开始未分配，无 undo 记录', () async {
      final before = h.undo.undoDepth;
      final stopped = (await h.timer.stopRunning()).requireValue();
      expect(stopped.isRunning, isTrue);
      expect(stopped.activityId, isNotNull); // 未分配活动
      // beforeRunning == null → _recordSwitchOrStop 直接返回（无 undo 记录）。
      expect(h.undo.undoDepth, before);
      expect(h.undo.canUndo, isFalse);
    });

    test('运行计时中合并已结束条目：运行态缓存保留', () async {
      final a = (await h.activities.createActivity(name: 'A', color: 0))
          .requireValue();
      final b = (await h.activities.createActivity(name: 'B', color: 0))
          .requireValue();
      // 先开始 B 计时。
      final running = (await h.timer.switchToActivity(b.id)).requireValue();
      expect(h.timer.runningEntry?.id, running.id);
      // 再补记一条 A 的已结束条目并合并（合并不涉及运行条目）。
      final first = (await h.timer.addEntry(
        activityId: a.id,
        startAt: DateTime(2026, 8, 14, 10),
        endAt: DateTime(2026, 8, 14, 11),
        note: '',
      )).requireValue();
      final second = (await h.timer.addEntry(
        activityId: a.id,
        startAt: DateTime(2026, 8, 14, 11),
        endAt: DateTime(2026, 8, 14, 12),
        note: '',
      )).requireValue();
      // 捕获合并结果并断言非空——防邻居判定/阈值回归导致静默返回 null
      // 使用例"空过"（运行条目同样不会被清空，无法证明合并路径执行）。
      final merged = (await h.timer.mergeWithNeighbor(
        entryId: first.id,
        mergePrevious: false, // 合并右侧 second：current=first 保留为 merged，邻居 second 软删
      )).requireValue();
      expect(merged, isNotNull); // 合并确实执行
      final firstAfter = await h.entries.entryByIdIncludingDeleted(first.id);
      expect(firstAfter, isNotNull); // 可空解包前先断言（失败可诊断）
      expect(firstAfter!.isDeleted, isFalse); // first 保留（= merged）
      expect(firstAfter.endAt, DateTime(2026, 8, 14, 12));
      //（Dart 流程分析：`!` 断言使用后同一 final 局部变量被提升——本行
      // 无需 `!`；实证：带 `!` 版本触发 unnecessary_non_null_assertion，
      // 无 `!` 版本触发 unchecked_use_of_nullable_value，仅当前组合
      //（前置 `!` + 后续无 `!`）analyze 0——以实证为准，勿按直觉调整。）
      final secondAfter = await h.entries.entryByIdIncludingDeleted(second.id);
      expect(secondAfter, isNotNull);
      expect(secondAfter!.isDeleted, isTrue); // 邻居 second 已软删
      // 运行态缓存必须保留（未被合并清空）。
      expect(h.timer.runningEntry?.id, running.id);
      expect(h.timer.runningEntry?.isRunning, isTrue);
    });

    test('合并间隔超阈值：返回 null 且不产生 undo 记录（两侧均不受影响）', () async {
      final a = (await h.activities.createActivity(name: 'A', color: 0))
          .requireValue();
      // 默认阈值 1 分钟：间隔 30 分钟 > 阈值 → 不可合并。
      final first = (await h.timer.addEntry(
        activityId: a.id,
        startAt: DateTime(2026, 8, 14, 10),
        endAt: DateTime(2026, 8, 14, 11),
        note: '',
      )).requireValue();
      final second = (await h.timer.addEntry(
        activityId: a.id,
        startAt: DateTime(2026, 8, 14, 11, 30),
        endAt: DateTime(2026, 8, 14, 12),
        note: '',
      )).requireValue();
      final before = h.undo.undoDepth;
      final merged = (await h.timer.mergeWithNeighbor(
        entryId: second.id,
        mergePrevious: true, // 与 first 间隔 30m > 阈值 1m
      )).requireValue();
      expect(merged, isNull); // 无合并对象（阈值超限归为业务 null）
      expect(h.undo.undoDepth, before); // 无 undo 记录
      final secondAfter = await h.entries.entryByIdIncludingDeleted(second.id);
      expect(secondAfter, isNotNull);
      expect(secondAfter!.isDeleted, isFalse); // 未被软删
      final firstAfter = await h.entries.entryByIdIncludingDeleted(first.id);
      expect(firstAfter, isNotNull);
      expect(firstAfter!.isDeleted, isFalse); // 邻居也未受影响
    });

    test('undo 恢复写库后 dataRevision 递增（恢复作为新修改参与同步）', () async {
      final a = (await h.activities.createActivity(name: 'A', color: 0))
          .requireValue();
      await h.timer.addEntry(
        activityId: a.id,
        startAt: DateTime(2026, 8, 14, 10),
        endAt: DateTime(2026, 8, 14, 11),
        note: '',
      );
      final afterAdd = h.revision.value; // 1
      await h.undo.undo(); // 软删新条目（恢复写库）
      expect(h.revision.value, afterAdd + 1); // undo 恢复 bump
      await h.undo.redo(); // 恢复新条目（恢复写库）
      expect(h.revision.value, afterAdd + 2); // redo 恢复 bump
    });

    test('dispose 后 undo 恢复链完成：仍 bump dataRevision（不 notify 不崩）', () async {
      final a = (await h.activities.createActivity(name: 'A', color: 0))
          .requireValue();
      // 独立 TimerStore 实例（避免手动 dispose 后 tearDown 二次 dispose）。
      final store = TimerStore(
        entries: h.entries,
        undo: h.undo,
        clock: h.clock,
        dataRevision: h.revision,
      );
      await store.addEntry(
        activityId: a.id,
        startAt: DateTime(2026, 8, 14, 10),
        endAt: DateTime(2026, 8, 14, 11),
        note: '',
      );
      final afterAdd = h.revision.value;

      // 发起 undo（不 await）后立即 dispose store——恢复写库链可能在
      // dispose 后才完成（onApplied 的 _disposed 分支：仅 bump、跳过
      // notify/refresh）。
      final undoFuture = h.undo.undo();
      store.dispose();
      final result = await undoFuture;
      expect(result, isA<AppSuccess<void>>()); // 恢复完成
      expect(h.revision.value, afterAdd + 1); // dispose 后仍 bump
    });
  });

  group('TimerStore undo/redo 往返', () {
    late TestHarness h;

    setUp(() => h = TestHarness());
    tearDown(() => h.close());

    test('add undo：软删新条目；redo：恢复', () async {
      final a = (await h.activities.createActivity(name: 'A', color: 0))
          .requireValue();
      final added = (await h.timer.addEntry(
        activityId: a.id,
        startAt: DateTime(2026, 8, 14, 10),
        endAt: DateTime(2026, 8, 14, 11),
        note: '',
      )).requireValue();

      await h.undo.undo();
      expect((await h.entries.entryByIdIncludingDeleted(added.id))!.isDeleted,
          isTrue);

      await h.undo.redo();
      final restored = await h.entries.entryByIdIncludingDeleted(added.id);
      expect(restored, isNotNull);
      expect(restored!.isDeleted, isFalse);
      expect(restored.endAt, DateTime(2026, 8, 14, 11));
    });

    test('delete undo：恢复；redo：软删', () async {
      final a = (await h.activities.createActivity(name: 'A', color: 0))
          .requireValue();
      final added = (await h.timer.addEntry(
        activityId: a.id,
        startAt: DateTime(2026, 8, 14, 10),
        endAt: DateTime(2026, 8, 14, 11),
        note: '',
      )).requireValue();
      await h.timer.deleteEntry(added.id);

      await h.undo.undo();
      expect((await h.entries.entryByIdIncludingDeleted(added.id))!.isDeleted,
          isFalse);

      await h.undo.redo();
      expect((await h.entries.entryByIdIncludingDeleted(added.id))!.isDeleted,
          isTrue);
    });

    test('switch undo：旧运行恢复未结束态；redo 恢复切换后状态', () async {
      final a = (await h.activities.createActivity(name: 'A', color: 0))
          .requireValue();
      final b = (await h.activities.createActivity(name: 'B', color: 0))
          .requireValue();
      await h.timer.switchToActivity(a.id);
      await h.timer.switchToActivity(b.id);
      expect((await h.entries.runningEntry())!.activityId, b.id);

      await h.undo.undo(); // 恢复 A 未结束态
      final restored = await h.entries.runningEntry();
      expect(restored!.activityId, a.id);
      expect(restored.isRunning, isTrue);

      await h.undo.redo(); // redo 恢复切换后状态：B 重新运行、A 结束
      final afterRedo = await h.entries.runningEntry();
      expect(afterRedo!.activityId, b.id);
      expect(afterRedo.isRunning, isTrue);
    });

    test('split undo：恢复原条目完整时段；redo 保持切分后状态', () async {
      final a = (await h.activities.createActivity(name: 'A', color: 0))
          .requireValue();
      final added = (await h.timer.addEntry(
        activityId: a.id,
        startAt: DateTime(2026, 8, 14, 10),
        endAt: DateTime(2026, 8, 14, 11),
        note: '',
      )).requireValue();
      await h.timer.splitEntry(
        entryId: added.id,
        splitAt: DateTime(2026, 8, 14, 10, 30),
      );

      await h.undo.undo(); // 恢复原条目完整时段（覆盖两段）
      final restored = await h.entries.entryByIdIncludingDeleted(added.id);
      expect(restored!.isDeleted, isFalse);
      expect(restored.startAt, DateTime(2026, 8, 14, 10));
      expect(restored.endAt, DateTime(2026, 8, 14, 11));
      // 切分第二段（新 id）必须被软删——残留会与恢复的完整条目重叠。
      final all = await h.entries.allEntries();
      final surviving = all
          .where((e) => !e.isDeleted && e.activityId == a.id)
          .toList();
      expect(surviving, hasLength(1)); // 仅恢复的原条目，无残留段
      expect(surviving.single.id, added.id);

      await h.undo.redo(); // redo 恢复切分后状态：原条目切分态 + 第二段
      final afterRedo = await h.entries.entryByIdIncludingDeleted(added.id);
      expect(afterRedo!.isDeleted, isFalse);
      expect(afterRedo.endAt, DateTime(2026, 8, 14, 10, 30)); // 首段切分态
      final secondSegments = (await h.entries.allEntries())
          .where((e) => !e.isDeleted && e.activityId == a.id && e.id != added.id)
          .toList();
      expect(secondSegments, hasLength(1)); // 第二段恢复存活
      expect(secondSegments.single.startAt, DateTime(2026, 8, 14, 10, 30));
    });

    test('merge undo：恢复原条目与邻居；redo 保持合并后状态', () async {
      final a = (await h.activities.createActivity(name: 'A', color: 0))
          .requireValue();
      final first = (await h.timer.addEntry(
        activityId: a.id,
        startAt: DateTime(2026, 8, 14, 10),
        endAt: DateTime(2026, 8, 14, 11),
        note: '',
      )).requireValue();
      final second = (await h.timer.addEntry(
        activityId: a.id,
        startAt: DateTime(2026, 8, 14, 11),
        endAt: DateTime(2026, 8, 14, 12),
        note: '',
      )).requireValue();
      await h.timer.mergeWithNeighbor(
        entryId: first.id,
        mergePrevious: false,
      );

      await h.undo.undo(); // 恢复 first 与 second
      final firstBack = await h.entries.entryByIdIncludingDeleted(first.id);
      final secondBack = await h.entries.entryByIdIncludingDeleted(second.id);
      expect(firstBack!.isDeleted, isFalse);
      expect(firstBack.endAt, DateTime(2026, 8, 14, 11));
      expect(secondBack!.isDeleted, isFalse);

      await h.undo.redo(); // redo 恢复合并后状态：first 合并态 + 邻居软删
      final firstAfter = await h.entries.entryByIdIncludingDeleted(first.id);
      expect(firstAfter!.isDeleted, isFalse);
      expect(firstAfter.endAt, DateTime(2026, 8, 14, 12)); // 合并后 endAt
      final secondAfter = await h.entries.entryByIdIncludingDeleted(second.id);
      expect(secondAfter!.isDeleted, isTrue); // 邻居软删
    });

    test('undo 冲突校验：目标行已删时 redo 拒绝', () async {
      final a = (await h.activities.createActivity(name: 'A', color: 0))
          .requireValue();
      final added = (await h.timer.addEntry(
        activityId: a.id,
        startAt: DateTime(2026, 8, 14, 10),
        endAt: DateTime(2026, 8, 14, 11),
        note: '',
      )).requireValue();
      await h.undo.undo(); // 软删新条目
      // 模拟并发：redo 前目标行被物理移除（redo 恢复分支校验"行存在"）。
      await (h.db.delete(h.db.timeEntries)
            ..where((t) => t.id.equals(added.id)))
          .go();
      final redoResult = await h.undo.redo();
      // 目标行缺失 → validate 拒绝，redo 返回失败（栈不动、可重试）。
      expect(redoResult, isA<AppFailure<void>>());
      expect(h.undo.canRedo, isTrue);
    });
  });
}
