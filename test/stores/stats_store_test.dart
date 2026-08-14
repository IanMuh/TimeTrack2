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
