import 'dart:async';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:timetrack2/data/database/app_database.dart' hide ProfileSettings;
import 'package:timetrack2/data/repositories/activity_repository.dart';
import 'package:timetrack2/data/repositories/category_repository.dart';
import 'package:timetrack2/data/repositories/settings_repository.dart';
import 'package:timetrack2/data/repositories/time_entry_repository.dart';
import 'package:timetrack2/stores/data_revision.dart';
import 'package:timetrack2/stores/timeline_store.dart';
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
    store = TimelineStore(
      entries: entries,
      dataRevision: revision,
    );
  }

  late final AppDatabase db;
  late final ActivityRepository activities;
  late final CategoryRepository categories;
  late final SettingsRepository settings;
  late final TimeEntryRepository entries;
  late final DataRevision revision;
  late final TimelineStore store;

  Future<void> close() async {
    store.dispose();
    revision.dispose();
    await db.close();
  }
}

/// 查询抛异常（加载失败路径）。
class _ThrowingEntries extends TimeEntryRepository {
  _ThrowingEntries({
    required super.database,
    required super.activityRepository,
    required super.settingsRepository,
  });

  @override
  Future<List<TimeEntry>> entriesForRange(DateTime start, DateTime end) {
    throw Exception('DB 故障');
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
  group('TimelineStore', () {
    late TestHarness h;

    setUp(() => h = TestHarness());
    tearDown(() => h.close());

    test('loadRange：只含范围内条目（含跨日裁剪语义由仓储保证）', () async {
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
        startAt: DateTime(2026, 8, 13, 9),
        endAt: DateTime(2026, 8, 13, 10),
        note: '',
      );
      await h.store.loadRange(
        DateTime(2026, 8, 14),
        DateTime(2026, 8, 15),
      );
      expect(h.store.loadedRange, (DateTime(2026, 8, 14), DateTime(2026, 8, 15)));
      expect(h.store.entriesForRange, hasLength(1));
      expect(h.store.entriesForRange.single.startAt, DateTime(2026, 8, 14, 9));
    });

    test('dataRevision 变更自动重新加载当前范围', () async {
      final a = (await h.activities.createActivity(name: 'A', color: 0))
          .requireValue();
      await h.entries.createManualEntry(
        activityId: a.id,
        startAt: DateTime(2026, 8, 14, 9),
        endAt: DateTime(2026, 8, 14, 10),
        note: '',
      );
      await h.store.loadRange(
        DateTime(2026, 8, 14),
        DateTime(2026, 8, 15),
      );
      expect(h.store.entriesForRange, hasLength(1));

      await h.entries.createManualEntry(
        activityId: a.id,
        startAt: DateTime(2026, 8, 14, 10),
        endAt: DateTime(2026, 8, 14, 11),
        note: '',
      );
      h.revision.bump();
      await pumpEventQueue();
      expect(h.store.entriesForRange, hasLength(2));
    });

    test('未加载范围时 dataRevision 变更不崩', () async {
      h.revision.bump();
      await pumpEventQueue();
      expect(h.store.loadedRange, isNull);
    });

    test('窗口重叠/边界条目计入范围', () async {
      final a = (await h.activities.createActivity(name: 'A', color: 0))
          .requireValue();
      // 跨窗口条目（23:00→次日 01:00，窗口 8/14 整天）。
      await h.entries.createManualEntry(
        activityId: a.id,
        startAt: DateTime(2026, 8, 14, 23),
        endAt: DateTime(2026, 8, 15, 1),
        note: '',
      );
      // 恰在窗口起点的条目。
      await h.entries.createManualEntry(
        activityId: a.id,
        startAt: DateTime(2026, 8, 14),
        endAt: DateTime(2026, 8, 14, 0, 30),
        note: '',
      );
      // 窗口外（8/15 起）的条目。
      await h.entries.createManualEntry(
        activityId: a.id,
        startAt: DateTime(2026, 8, 15, 1),
        endAt: DateTime(2026, 8, 15, 2),
        note: '',
      );
      await h.store.loadRange(
        DateTime(2026, 8, 14),
        DateTime(2026, 8, 15),
      );
      // 跨窗口与起点条目计入（与窗口重叠即返回整行）；窗口外不含。
      expect(h.store.entriesForRange, hasLength(2));
      expect(
        h.store.entriesForRange.every(
          (e) => e.startAt.isBefore(DateTime(2026, 8, 15)),
        ),
        isTrue,
      );
    });

    test('加载异常：loadFailed 置位且不抛未处理异常', () async {
      final throwing = _ThrowingEntries(
        database: h.db,
        activityRepository: h.activities,
        settingsRepository: h.settings,
      );
      final revision = DataRevision();
      final store = TimelineStore(entries: throwing, dataRevision: revision);
      addTearDown(() {
        store.dispose();
        revision.dispose();
      });
      await store.loadRange(
        DateTime(2026, 8, 14),
        DateTime(2026, 8, 15),
      );
      expect(store.loadFailed, isTrue);
      expect(store.entriesForRange, isEmpty);
    });

    test('并发乱序：旧请求晚完成不覆盖新缓存', () async {
      final a = (await h.activities.createActivity(name: 'A', color: 0))
          .requireValue();
      await h.entries.createManualEntry(
        activityId: a.id,
        startAt: DateTime(2026, 8, 14, 10),
        endAt: DateTime(2026, 8, 14, 11),
        note: '',
      );
      await h.entries.createManualEntry(
        activityId: a.id,
        startAt: DateTime(2026, 8, 15, 10),
        endAt: DateTime(2026, 8, 15, 11),
        note: '',
      );
      final gated = _GatedEntries(
        database: h.db,
        activityRepository: h.activities,
        settingsRepository: h.settings,
      );
      final revision = DataRevision();
      final store = TimelineStore(entries: gated, dataRevision: revision);
      addTearDown(() {
        store.dispose();
        revision.dispose();
      });

      final gateA = Completer<void>();
      gated.gates.add(gateA);
      final futureA = store.loadRange(
        DateTime(2026, 8, 14), // A 挂起（8/14 窗口）
        DateTime(2026, 8, 15),
      );
      await pumpEventQueue();
      await store.loadRange( // B 立即完成（8/15 窗口）
        DateTime(2026, 8, 15),
        DateTime(2026, 8, 16),
      );
      gateA.complete(); // A 晚完成
      await futureA;

      // 新请求 B 保持：A 的结果被序号守卫丢弃。
      expect(store.loadedRange, (DateTime(2026, 8, 15), DateTime(2026, 8, 16)));
      expect(store.entriesForRange, hasLength(1));
      expect(store.entriesForRange.single.startAt, DateTime(2026, 8, 15, 10));
    });
  });
}
