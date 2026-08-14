import 'dart:async';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:timetrack2/data/database/app_database.dart' hide ProfileSettings;
import 'package:timetrack2/data/repositories/activity_repository.dart';
import 'package:timetrack2/data/repositories/category_repository.dart';
import 'package:timetrack2/data/repositories/settings_repository.dart';
import 'package:timetrack2/data/repositories/stats_repository.dart';
import 'package:timetrack2/data/repositories/time_entry_repository.dart';
import 'package:timetrack2/stores/data_revision.dart';
import 'package:timetrack2/stores/stats_store.dart';
import 'package:timetrack2/utils/result.dart';
import 'package:timetrack2/viewmodels/stats/stats_models.dart';

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
    stats = StatsStore(
      repository: StatsRepository(
        activities: activities,
        categories: categories,
        entries: entries,
      ),
      dataRevision: revision,
    );
  }

  late final AppDatabase db;
  late final ActivityRepository activities;
  late final CategoryRepository categories;
  late final SettingsRepository settings;
  late final TimeEntryRepository entries;
  late final DataRevision revision;
  late final StatsStore stats;

  Future<void> close() async {
    stats.dispose();
    revision.dispose();
    await db.close();
  }
}

/// 可挂起的统计仓储：slicesForRange 按调用顺序消费 [gates] 中未放行的
/// Completer 挂起——用于确定性控制并发 compute 的完成顺序（TOCTOU/竞态测试）。
/// [failOnNext] 置真时，下一次放行的调用返回 [failureMessage]（失败分支测试）。
class _GatedStatsRepository extends StatsRepository {
  _GatedStatsRepository({
    required super.activities,
    required super.categories,
    required super.entries,
  });

  /// 每次 slicesForRange 调用消耗一个；队列空 = 不挂起直接执行。
  final gates = <Completer<void>>[];

  /// 置真时下一次放行的调用返回失败（失败分支测试）。
  bool failOnNext = false;
  String failureMessage = '注入失败';

  @override
  Future<AppResult<({List<StatsEntrySlice> slices, bool hasRunningEntry})>>
      slicesForRange({
    required DateTime start,
    required DateTime end,
    DateTime? effectiveNow,
  }) {
    if (gates.isEmpty) {
      return _run(start: start, end: end, effectiveNow: effectiveNow);
    }
    final gate = gates.removeAt(0);
    return gate.future.then((_) => _run(
          start: start,
          end: end,
          effectiveNow: effectiveNow,
        ));
  }

  Future<AppResult<({List<StatsEntrySlice> slices, bool hasRunningEntry})>>
      _run({
    required DateTime start,
    required DateTime end,
    DateTime? effectiveNow,
  }) {
    if (failOnNext) {
      failOnNext = false;
      return Future.value(AppFailure(failureMessage));
    }
    return super.slicesForRange(
      start: start,
      end: end,
      effectiveNow: effectiveNow,
    );
  }
}

void main() {
  group('StatsStore', () {
    late TestHarness h;

    setUp(() => h = TestHarness());
    tearDown(() => h.close());

    test('初始无快照；计算后返回聚合结果', () async {
      expect(h.stats.snapshot, isNull);
      final snapshot = await h.stats.compute(
        start: DateTime(2026, 8, 14, 10),
        end: DateTime(2026, 8, 14, 12),
        dimension: StatsDimension.activity,
      );
      expect(snapshot, isNotNull);
      expect(h.stats.snapshot, same(snapshot)); // 缓存持有同一实例
      expect(h.stats.lastError, isNull);
      expect(snapshot!.rows, isEmpty); // 空库 → 空行
      expect(snapshot.totalDuration, Duration.zero);
    });

    test('同范围同维度：revision 未变则命中缓存（不重算）', () async {
      final a = (await h.activities.createActivity(name: 'A', color: 0))
          .requireValue();
      await h.entries.createManualEntry(
        activityId: a.id,
        startAt: DateTime(2026, 8, 14, 10),
        endAt: DateTime(2026, 8, 14, 11),
        note: '',
      );

      final first = await h.stats.compute(
        start: DateTime(2026, 8, 14, 10),
        end: DateTime(2026, 8, 14, 12),
        dimension: StatsDimension.activity,
      );
      expect(first!.rows.single.totalDuration, const Duration(hours: 1));

      // revision 未变：第二次同参计算命中缓存（同实例）。
      final second = await h.stats.compute(
        start: DateTime(2026, 8, 14, 10),
        end: DateTime(2026, 8, 14, 12),
        dimension: StatsDimension.activity,
      );
      expect(identical(first, second), isTrue);
    });

    test('dataRevision 递增 → 缓存失效，重新计算反映新数据', () async {
      final a = (await h.activities.createActivity(name: 'A', color: 0))
          .requireValue();
      await h.entries.createManualEntry(
        activityId: a.id,
        startAt: DateTime(2026, 8, 14, 10),
        endAt: DateTime(2026, 8, 14, 11),
        note: '',
      );
      final before = await h.stats.compute(
        start: DateTime(2026, 8, 14, 10),
        end: DateTime(2026, 8, 14, 12),
        dimension: StatsDimension.activity,
      );
      expect(before!.rows.single.totalDuration, const Duration(hours: 1));

      // 新增条目（模拟用户操作后的 bump）。
      await h.entries.createManualEntry(
        activityId: a.id,
        startAt: DateTime(2026, 8, 14, 11),
        endAt: DateTime(2026, 8, 14, 11, 30),
        note: '',
      );
      h.revision.bump();

      // 旧缓存被 dataRevision 监听清空。
      expect(h.stats.snapshot, isNull);
      final after = await h.stats.compute(
        start: DateTime(2026, 8, 14, 10),
        end: DateTime(2026, 8, 14, 12),
        dimension: StatsDimension.activity,
      );
      expect(identical(before, after), isFalse); // 重算（新实例）
      expect(after!.rows.single.totalDuration, const Duration(minutes: 90));
    });

    test('范围/维度不同 → 重新计算（同 revision 各维度独立缓存语义）', () async {
      final a = (await h.activities.createActivity(name: 'A', color: 0))
          .requireValue();
      await h.entries.createManualEntry(
        activityId: a.id,
        startAt: DateTime(2026, 8, 14, 10),
        endAt: DateTime(2026, 8, 14, 11),
        note: '',
      );
      final activityView = await h.stats.compute(
        start: DateTime(2026, 8, 14, 10),
        end: DateTime(2026, 8, 14, 12),
        dimension: StatsDimension.activity,
      );
      final categoryView = await h.stats.compute(
        start: DateTime(2026, 8, 14, 10),
        end: DateTime(2026, 8, 14, 12),
        dimension: StatsDimension.primaryCategory,
      );
      expect(identical(activityView, categoryView), isFalse);
      expect(h.stats.snapshot, same(categoryView)); // 最近一次
    });

    test('含运行中条目的快照不命中缓存（时间敏感，每次重算）', () async {
      final a = (await h.activities.createActivity(name: 'A', color: 0))
          .requireValue();
      final running = (await h.entries.switchToActivity(a.id)).requireValue();
      // 范围覆盖运行条目起点（startAt = 真实 now，不可注入）。
      final start = running.startAt.subtract(const Duration(hours: 1));
      final end = running.startAt.add(const Duration(hours: 1));

      final first = await h.stats.compute(
        start: start,
        end: end,
        dimension: StatsDimension.activity,
      );
      expect(first!.containsRunningEntry, isTrue);

      // 同 revision 同参：含运行中条目 → 不命中缓存，返回新实例（重算）。
      final second = await h.stats.compute(
        start: start,
        end: end,
        dimension: StatsDimension.activity,
      );
      expect(identical(first, second), isFalse);
    });

    test('dataRevision 变更 → 清缓存并通知（UI 感知失效）', () async {
      var notified = 0;
      h.stats.addListener(() => notified++);
      h.revision.bump();
      expect(notified, 1);
      expect(h.stats.snapshot, isNull);
    });

    test('TOCTOU：compute 挂起期间 revision 变更 → 结果丢弃（不写脏快照）', () async {
      final a = (await h.activities.createActivity(name: 'A', color: 0))
          .requireValue();
      await h.entries.createManualEntry(
        activityId: a.id,
        startAt: DateTime(2026, 8, 14, 10),
        endAt: DateTime(2026, 8, 14, 11),
        note: '',
      );
      final gated = _GatedStatsRepository(
        activities: h.activities,
        categories: h.categories,
        entries: h.entries,
      );
      final revision = DataRevision();
      final store = StatsStore(repository: gated, dataRevision: revision);
      addTearDown(() {
        store.dispose();
        revision.dispose();
      });

      final gate = Completer<void>();
      gated.gates.add(gate);
      final computeFuture = store.compute(
        start: DateTime(2026, 8, 14, 10),
        end: DateTime(2026, 8, 14, 12),
        dimension: StatsDimension.activity,
      );
      await pumpEventQueue(); // compute 已挂起在 gate 上

      revision.bump(); // 挂起期间数据变更（invalidate 清缓存）
      gate.complete(); // 放行计算
      final result = await computeFuture;

      expect(result, isNull); //      过期结果丢弃（无匹配快照）
      expect(store.snapshot, isNull); // 未写入脏快照
      expect(store.lastError, isNull); // 成功被丢弃不记错误
    });

    test('并发完成序：旧请求晚完成不得覆盖新请求快照', () async {
      final gated = _GatedStatsRepository(
        activities: h.activities,
        categories: h.categories,
        entries: h.entries,
      );
      final revision = DataRevision();
      final store = StatsStore(repository: gated, dataRevision: revision);
      addTearDown(() {
        store.dispose();
        revision.dispose();
      });

      final gateA = Completer<void>();
      final gateB = Completer<void>();
      gated.gates.add(gateA); // 请求 A（先发起）
      gated.gates.add(gateB); // 请求 B（后发起）
      final futureA = store.compute(
        start: DateTime(2026, 8, 14, 10),
        end: DateTime(2026, 8, 14, 11),
        dimension: StatsDimension.activity,
      );
      await pumpEventQueue();
      final futureB = store.compute(
        start: DateTime(2026, 8, 14, 12),
        end: DateTime(2026, 8, 14, 13),
        dimension: StatsDimension.activity,
      );
      await pumpEventQueue();

      gateB.complete(); // 新请求 B 先完成 → 写入快照
      final resultB = await futureB;
      expect(resultB, isNotNull);
      expect(store.snapshot, same(resultB));

      gateA.complete(); // 旧请求 A 晚完成 → 必须被丢弃
      final resultA = await futureA;
      expect(resultA, isNull); //           A 与当前快照参数不同 → null
      expect(store.snapshot, same(resultB)); // 快照仍是 B，未被 A 覆盖
    });

    test('并发同参：旧请求晚完成返回新请求已提交的快照（匹配参数）', () async {
      final gated = _GatedStatsRepository(
        activities: h.activities,
        categories: h.categories,
        entries: h.entries,
      );
      final revision = DataRevision();
      final store = StatsStore(repository: gated, dataRevision: revision);
      addTearDown(() {
        store.dispose();
        revision.dispose();
      });

      final gateA = Completer<void>();
      final gateB = Completer<void>();
      gated.gates.add(gateA);
      gated.gates.add(gateB);
      // A、B 同范围同维度。
      final start = DateTime(2026, 8, 14, 10);
      final end = DateTime(2026, 8, 14, 12);
      final futureA = store.compute(
        start: start,
        end: end,
        dimension: StatsDimension.activity,
      );
      await pumpEventQueue();
      final futureB = store.compute(
        start: start,
        end: end,
        dimension: StatsDimension.activity,
      );
      await pumpEventQueue();

      gateB.complete(); // 新请求 B 先完成 → 写入快照
      final resultB = await futureB;
      expect(resultB, isNotNull);

      gateA.complete(); // 旧请求 A 晚完成 → 返回 B 的快照（参数匹配）
      final resultA = await futureA;
      expect(resultA, same(resultB)); // 复用匹配快照，而非 null
      expect(store.snapshot, same(resultB));
    });

    test('过期失败不触碰 store 状态（不清快照/不覆盖错误/不通知）', () async {
      final gated = _GatedStatsRepository(
        activities: h.activities,
        categories: h.categories,
        entries: h.entries,
      );
      final revision = DataRevision();
      final store = StatsStore(repository: gated, dataRevision: revision);
      addTearDown(() {
        store.dispose();
        revision.dispose();
      });

      // 先成功计算一次，写入快照。
      final ok = await store.compute(
        start: DateTime(2026, 8, 14, 10),
        end: DateTime(2026, 8, 14, 12),
        dimension: StatsDimension.activity,
      );
      expect(ok, isNotNull);

      // 第二次 compute 挂起，期间 bump revision（清缓存），随后失败放行。
      final gate = Completer<void>();
      gated.gates.add(gate);
      gated.failOnNext = true;
      final failingFuture = store.compute(
        start: DateTime(2026, 8, 14, 12),
        end: DateTime(2026, 8, 14, 13),
        dimension: StatsDimension.activity,
      );
      await pumpEventQueue();
      revision.bump();
      gate.complete();
      final result = await failingFuture;

      // 过期失败：不覆盖 store 状态（revision 已变 → 守卫丢弃）。
      expect(result, isNull);
      expect(store.snapshot, isNull); // 快照已被 bump 清空，未被失败覆盖
      expect(store.lastError, isNull); // 错误未被写入
    });

    test('dispose 后不再响应 dataRevision（不再清缓存）', () async {
      final a = (await h.activities.createActivity(name: 'A', color: 0))
          .requireValue();
      await h.entries.createManualEntry(
        activityId: a.id,
        startAt: DateTime(2026, 8, 14, 10),
        endAt: DateTime(2026, 8, 14, 11),
        note: '',
      );
      // 独立实例避免二次 dispose（ChangeNotifier.debugAssertNotDisposed）。
      final revision = DataRevision();
      final store = StatsStore(
        repository: StatsRepository(
          activities: h.activities,
          categories: h.categories,
          entries: h.entries,
        ),
        dataRevision: revision,
      );
      addTearDown(revision.dispose); // 仅清理 revision
      final snapshot = await store.compute(
        start: DateTime(2026, 8, 14, 10),
        end: DateTime(2026, 8, 14, 12),
        dimension: StatsDimension.activity,
      );
      expect(snapshot, isNotNull);

      store.dispose(); // 手动 dispose（避免 addTearDown 二次 dispose）
      revision.bump(); // dispose 后不应清掉已算快照（无监听者）
      expect(store.snapshot, snapshot);
    });
  });
}
