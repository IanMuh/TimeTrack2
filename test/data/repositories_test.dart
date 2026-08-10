import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:timetrack2/data/database/app_database.dart';
import 'package:timetrack2/data/repositories/activity_repository.dart';
import 'package:timetrack2/data/repositories/action_log_repository.dart';
import 'package:timetrack2/data/repositories/category_repository.dart';
import 'package:timetrack2/data/repositories/settings_repository.dart';
import 'package:timetrack2/data/repositories/time_entry_repository.dart';
import 'package:timetrack2/viewmodels/action_log.dart';
import 'package:timetrack2/viewmodels/activity.dart';

/// 内存库测试环境：隔离的数据库 + 各仓储实例。
class TestHarness {
  TestHarness() {
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
  }

  late final AppDatabase db;
  late final ActivityRepository activities;
  late final CategoryRepository categories;
  late final SettingsRepository settings;
  late final ActionLogRepository actionLogs;
  late final TimeEntryRepository entries;

  Future<void> close() => db.close();
}

/// 便捷：插入活动并返回模型。
Future<Activity> seedActivity(
  TestHarness h, {
  String? name,
  bool isOneOff = false,
}) async {
  final result = await h.activities.createActivity(
    name: name ?? '活动${DateTime.now().microsecondsSinceEpoch % 100000}',
    color: 0xff2563eb,
    isOneOff: isOneOff,
  );
  return result.requireValue();
}

void main() {
  group('Settings 仓储', () {
    late TestHarness h;

    setUp(() => h = TestHarness());
    tearDown(() => h.close());

    test('默认值读取 + 保存后 round-trip', () async {
      final defaults = (await h.settings.settings()).requireValue();
      expect(defaults.mergeNeighborThresholdMinutes, 1);

      final saved = (await h.settings.save(
        defaults.copyWith(
          reminderMinutes: 30,
          mergeNeighborThresholdMinutes: 5,
        ),
      ))
          .requireValue();
      expect(saved.reminderMinutes, 30);

      final reloaded = (await h.settings.settings()).requireValue();
      expect(reloaded.reminderMinutes, 30);
      expect(reloaded.mergeNeighborThresholdMinutes, 5);
      expect(await h.settings.mergeNeighborThresholdMinutes(), 5);
    });
  });

  group('ActionLog 仓储', () {
    late TestHarness h;

    setUp(() => h = TestHarness());
    tearDown(() => h.close());

    test('写入/分页/latestFor 过滤', () async {
      final activity = await seedActivity(h, name: '工作');
      final t = DateTime(2026, 8, 10, 9, 0);
      await h.actionLogs.insert(
        actionType: ActionType.switch_,
        activityId: activity.id,
        entryId: 'e1',
        message: '切换',
        occurredAt: t,
        deviceId: 'dev',
      );
      await h.actionLogs.insert(
        actionType: ActionType.stop,
        activityId: activity.id,
        entryId: 'e2',
        message: '停止',
        occurredAt: t.add(const Duration(minutes: 5)),
        deviceId: 'dev',
      );
      await h.actionLogs.insert(
        actionType: ActionType.manual,
        entryId: 'e3',
        message: '补记',
        occurredAt: t.add(const Duration(minutes: 10)),
        deviceId: 'dev',
      );

      // 分页：时间倒序
      final logs = (await h.actionLogs.logs()).requireValue();
      expect(logs.length, 3);
      expect(logs.first.message, '补记');
      expect(logs.last.message, '切换');
      // 分页边界
      final page = (await h.actionLogs.logs(limit: 2, offset: 1)).requireValue();
      expect(page.length, 2);
      expect(page.first.message, '停止');
      // latestFor 按活动过滤
      final latestForActivity =
          (await h.actionLogs.latestFor(activityId: activity.id)).requireValue();
      expect(latestForActivity!.message, '停止');
      // latestFor 按条目过滤
      final latestForEntry =
          (await h.actionLogs.latestFor(entryId: 'e3')).requireValue();
      expect(latestForEntry!.message, '补记');
    });

    test('同时间戳排序稳定（次级键 id）', () async {
      final t = DateTime(2026, 8, 10, 9, 0);
      for (var i = 0; i < 5; i++) {
        await h.actionLogs.insert(
          actionType: ActionType.manual,
          message: 'log$i',
          occurredAt: t,
          deviceId: 'dev',
        );
      }
      final logs = (await h.actionLogs.logs(limit: 2, offset: 0)).requireValue();
      final secondPage = (await h.actionLogs.logs(limit: 2, offset: 2)).requireValue();
      // 无重复、无遗漏（同时间戳下靠 id 稳定排序）
      final ids = {...logs.map((l) => l.id), ...secondPage.map((l) => l.id)};
      expect(ids.length, 4);
    });
  });

  group('Activity 仓储', () {
    late TestHarness h;

    setUp(() => h = TestHarness());
    tearDown(() => h.close());

    test('创建/查询/软删 + 未分配单例', () async {
      final activity = await seedActivity(h, name: '工作');
      final list = await h.activities.activities();
      expect(list.requireValue().map((a) => a.id), contains(activity.id));

      // 未分配单例：反复获取同一 id
      final unassigned1 = (await h.activities.unassignedActivity()).requireValue();
      final unassigned2 = (await h.activities.unassignedActivity()).requireValue();
      expect(unassigned1.id, unassigned2.id);
      expect(unassigned1.isUnassigned, isTrue);

      // 软删后查询默认不含
      await h.activities.deleteActivity(activity);
      final after = await h.activities.activities();
      expect(after.requireValue().map((a) => a.id), isNot(contains(activity.id)));
      final withDeleted = await h.activities.activities(includeDeleted: true);
      expect(withDeleted.requireValue().map((a) => a.id), contains(activity.id));
    });

    test('one-off 活动用完自动软删；普通活动不受影响', () async {
      final oneOff = await seedActivity(h, name: '一次性', isOneOff: true);
      final normal = await seedActivity(h, name: '普通');
      await h.activities.softDeleteOneOffActivityIfNeeded(
        oneOff.id,
        updatedAt: DateTime.now(),
      );
      await h.activities.softDeleteOneOffActivityIfNeeded(
        normal.id,
        updatedAt: DateTime.now(),
      );
      final oneOffAfter = await h.activities.activities(includeDeleted: true);
      final oneOffRow = oneOffAfter.requireValue().firstWhere((a) => a.id == oneOff.id);
      expect(oneOffRow.isDeleted, isTrue);
      final normalAfter = await h.activities.activities();
      expect(normalAfter.requireValue().map((a) => a.id), contains(normal.id));
    });

    test('LWW：远端更新于本地才替换', () async {
      final activity = await seedActivity(h, name: 'A');
      final older = activity.copyWith(
        name: '远端旧名',
        updatedAt: activity.updatedAt.subtract(const Duration(hours: 1)),
      );
      await h.activities.replaceIfRemoteNewer(older);
      var fresh = (await h.activities.activities()).requireValue().firstWhere((a) => a.id == activity.id);
      expect(fresh.name, 'A', reason: '远端旧于本地不替换');

      final newer = activity.copyWith(
        name: '远端新名',
        updatedAt: activity.updatedAt.add(const Duration(hours: 1)),
      );
      await h.activities.replaceIfRemoteNewer(newer);
      fresh = (await h.activities.activities()).requireValue().firstWhere((a) => a.id == activity.id);
      expect(fresh.name, '远端新名');
    });
  });

  group('Category 仓储（层级）', () {
    late TestHarness h;

    setUp(() => h = TestHarness());
    tearDown(() => h.close());

    test('创建层级分类 + 环检测拒绝挂到子孙下', () async {
      final root = (await h.categories.createCategory(name: '工作', color: 0))
          .requireValue();
      final child = (await h.categories.createCategory(name: '项目A', color: 0, parentId: root.id))
          .requireValue();
      final grandchild =
          (await h.categories.createCategory(name: '子项目', color: 0, parentId: child.id))
              .requireValue();

      // 挂到自身子孙下 → 拒绝
      final cycle = await h.categories.updateCategory(
        category: root,
        parentId: grandchild.id,
      );
      expect(cycle.isSuccess, isFalse);
      expect(cycle.when(onSuccess: (_) => '', onFailure: (m) => m), contains('环'));
      // 挂到不存在的父 → 拒绝
      final noParent = await h.categories.updateCategory(category: child, parentId: 'ghost');
      expect(noParent.isSuccess, isFalse);
    });

    test('删除父分类：递归软删子孙分类 + 各自 links + 自身 links（单事务）', () async {
      final activity = await seedActivity(h, name: '工作');
      final root = (await h.categories.createCategory(name: '根', color: 0)).requireValue();
      final child = (await h.categories.createCategory(name: '子', color: 0, parentId: root.id))
          .requireValue();
      final grandchild =
          (await h.categories.createCategory(name: '孙', color: 0, parentId: child.id))
              .requireValue();
      await h.categories.setActivityCategories(
        activityId: activity.id,
        primaryCategoryId: child.id,
      );

      final deletion = (await h.categories.deleteCategory(root)).requireValue();
      // 被删集合包含自身+子孙分类
      expect(
        deletion.categories.map((c) => c.id).toSet(),
        {root.id, child.id, grandchild.id},
      );
      // 子孙 links 也被删
      final linkDeleted = deletion.links.any((l) => l.activityId == activity.id);
      expect(linkDeleted, isTrue);

      // 库内全部软删（默认查询不含）
      final categories = await h.categories.categories();
      expect(categories.requireValue(), isEmpty);
      final links = await h.categories.linksForActivity(activity.id);
      expect(links.requireValue(), isEmpty);
    });

    test('setActivityCategories：primary + secondary + 移除旧关联', () async {
      final activity = await seedActivity(h, name: '工作');
      final c1 = (await h.categories.createCategory(name: 'c1', color: 0)).requireValue();
      final c2 = (await h.categories.createCategory(name: 'c2', color: 0)).requireValue();
      final c3 = (await h.categories.createCategory(name: 'c3', color: 0)).requireValue();

      final saved = (await h.categories.setActivityCategories(
        activityId: activity.id,
        primaryCategoryId: c1.id,
        secondaryCategoryIds: [c2.id, c3.id],
      ))
          .requireValue();
      expect(saved.map((l) => l.categoryId).toSet(), {c1.id, c2.id, c3.id});
      expect(saved.firstWhere((l) => l.categoryId == c1.id).isPrimary, isTrue);

      // 移除 c3
      final updated = (await h.categories.setActivityCategories(
        activityId: activity.id,
        primaryCategoryId: c1.id,
        secondaryCategoryIds: [c2.id],
      ))
          .requireValue();
      expect(updated.map((l) => l.categoryId).toSet(), {c1.id, c2.id});
      final links = await h.categories.linksForActivity(activity.id);
      expect(links.requireValue().map((l) => l.categoryId).toSet(), {c1.id, c2.id});
      // c3 软删但保留记录
      final all = await h.categories.links(includeDeleted: true);
      expect(all.requireValue().map((l) => l.categoryId), contains(c3.id));
    });
  });

  group('TimeEntry 仓储（核心算法）', () {
    late TestHarness h;

    setUp(() => h = TestHarness());
    tearDown(() => h.close());

    Future<Activity> seedWork() => seedActivity(h, name: '工作');
    Future<Activity> seedStudy() => seedActivity(h, name: '学习');

    test('补记跨天条目自动按本地日切段', () async {
      final activity = await seedWork();
      final start = DateTime(2026, 8, 10, 23, 0);
      final end = start.add(const Duration(hours: 3)); // 跨到 8/11 02:00
      final saved = (await h.entries.createManualEntry(
        activityId: activity.id,
        startAt: start,
        endAt: end,
        note: '熬夜',
      ))
          .requireValue();

      // 首段保留原 id，第二段新 id
      final day1 = await h.entries.entriesForDay(DateTime(2026, 8, 10));
      final day2 = await h.entries.entriesForDay(DateTime(2026, 8, 11));
      expect(day1.length, 1);
      expect(day2.length, 1);
      expect(day1.single.endAt!.isAtSameMomentAs(DateTime(2026, 8, 11, 0, 0)), isTrue);
      expect(day2.single.startAt.isAtSameMomentAs(DateTime(2026, 8, 11, 0, 0)), isTrue);
      expect(day2.single.endAt!.isAtSameMomentAs(end), isTrue);
      expect(saved.id, day1.single.id);
    });

    test('重叠裁剪：补记覆盖旧条目 → 旧条目被切开/软删', () async {
      final activity = await seedWork();
      // 旧条目 10:00-12:00
      await h.entries.createManualEntry(
        activityId: activity.id,
        startAt: DateTime(2026, 8, 10, 10, 0),
        endAt: DateTime(2026, 8, 10, 12, 0),
        note: '旧',
      );
      // 补记 10:30-11:30 覆盖中间 → 旧条目切成两段
      await h.entries.createManualEntry(
        activityId: activity.id,
        startAt: DateTime(2026, 8, 10, 10, 30),
        endAt: DateTime(2026, 8, 10, 11, 30),
        note: '新',
      );
      final day = await h.entries.entriesForDay(DateTime(2026, 8, 10));
      // 三段：旧左 10:00-10:30、新 10:30-11:30、旧右 11:30-12:00
      expect(day.length, 3);
      expect(day[0].startAt.hour, 10);
      expect(day[0].endAt!.minute, 30);
      expect(day[1].startAt.minute, 30);
      expect(day[1].note, '新');
      expect(day[2].startAt.hour, 11);
      expect(day[2].endAt!.hour, 12);
    });

    test('重叠裁剪：完全覆盖 → 旧条目软删', () async {
      final activity = await seedWork();
      await h.entries.createManualEntry(
        activityId: activity.id,
        startAt: DateTime(2026, 8, 10, 10, 0),
        endAt: DateTime(2026, 8, 10, 12, 0),
        note: '旧',
      );
      await h.entries.createManualEntry(
        activityId: activity.id,
        startAt: DateTime(2026, 8, 10, 9, 0),
        endAt: DateTime(2026, 8, 10, 13, 0),
        note: '新',
      );
      final day = await h.entries.entriesForDay(DateTime(2026, 8, 10));
      expect(day.length, 1);
      expect(day.single.note, '新');
    });

    test('switch/stop：切换结束旧条目、运行中跨日滚转', () async {
      final workActivity = await seedWork();
      final studyActivity = await seedStudy();
      final t0 = DateTime(2026, 8, 10, 9, 0);

      final r1 = await h.entries.switchToActivity(workActivity.id, at: t0);
      expect(r1.isSuccess, isTrue);
      final r2 = await h.entries.switchToActivity(studyActivity.id, at: t0.add(const Duration(hours: 1)));
      expect(r2.isSuccess, isTrue);
      expect((await h.entries.runningEntry())!.activityId, studyActivity.id);

      // 切换后旧条目已结束
      final old = (await h.entries.entriesForDay(t0)).singleWhere((e) => e.activityId == workActivity.id);
      expect(old.endAt!.isAtSameMomentAs(t0.add(const Duration(hours: 1))), isTrue);

      // 停止：切到未分配
      final stopped = await h.entries.stopRunning(at: t0.add(const Duration(hours: 2)));
      expect(stopped.isSuccess, isTrue);
      expect((await h.entries.runningEntry())!.activityId,
          (await h.activities.unassignedActivity()).requireValue().id);
    });

    test('跨日滚转：昨天开始的运行条目切成两段', () async {
      final workActivity = await seedWork();
      final start = DateTime(2026, 8, 9, 23, 0); // 昨天 23:00 开始运行
      await h.entries.switchToActivity(workActivity.id, at: start);
      final originalId = (await h.entries.runningEntry())!.id;
      // 今天触发任何命令 → 滚转
      final now = DateTime(2026, 8, 10, 8, 0);
      await h.entries.rolloverRunningEntriesIfNeeded(at: now);

      final day1 = await h.entries.entriesForDay(DateTime(2026, 8, 9));
      final day2 = await h.entries.entriesForDay(DateTime(2026, 8, 10));
      expect(day1.length, 1);
      expect(day1.single.endAt!.isAtSameMomentAs(DateTime(2026, 8, 10, 0, 0)), isTrue);
      expect(day2.length, 1);
      expect(day2.single.isRunning, isTrue, reason: '保留运行段');
      // 运行段必须保留原 id（LWW 按 id 匹配，改 id 会与他端运行段并存产生双运行）
      expect(day2.single.id, originalId, reason: '滚转后运行段保留原 id');
    });

    test('相邻未分配合并：连续未分配条目合成一条（note 换行去重）', () async {
      final unassigned = (await h.activities.unassignedActivity()).requireValue();
      final workActivity = await seedWork();
      // 直接构造两条**相邻**未分配条目（10:00-10:30 与 10:30-11:00，中间无其他条目）
      await h.entries.createManualEntry(
        activityId: unassigned.id,
        startAt: DateTime(2026, 8, 10, 10, 0),
        endAt: DateTime(2026, 8, 10, 10, 30),
        note: '一段',
      );
      await h.entries.createManualEntry(
        activityId: unassigned.id,
        startAt: DateTime(2026, 8, 10, 10, 30),
        endAt: DateTime(2026, 8, 10, 11, 0),
        note: '二段',
      );
      await h.entries.mergeAdjacentUnassignedEntries(unassigned.id);

      final all = await h.entries.entriesForDay(DateTime(2026, 8, 10));
      final unassignedEntries =
          all.where((e) => e.activityId == unassigned.id).toList();
      expect(unassignedEntries.length, 1, reason: '两条相邻未分配应合并为一条');
      expect(
        unassignedEntries.single.startAt.isAtSameMomentAs(DateTime(2026, 8, 10, 10, 0)),
        isTrue,
      );
      expect(
        unassignedEntries.single.endAt!.isAtSameMomentAs(DateTime(2026, 8, 10, 11, 0)),
        isTrue,
      );
      // note 换行去重合并
      expect(unassignedEntries.single.note, '一段\n二段');
      // 相同 note 只保留一条（去重而非简单拼接）
      await h.entries.createManualEntry(
        activityId: unassigned.id,
        startAt: DateTime(2026, 8, 10, 11, 0),
        endAt: DateTime(2026, 8, 10, 11, 30),
        note: '重复',
      );
      await h.entries.createManualEntry(
        activityId: unassigned.id,
        startAt: DateTime(2026, 8, 10, 11, 30),
        endAt: DateTime(2026, 8, 10, 12, 0),
        note: '重复',
      );
      // 相同 note 的两条相邻条目合并时整体去重（_mergedNotes 语义：仅当两条
      // 完整 note 相同才去重，非按行拆分）。
      await h.entries.createManualEntry(
        activityId: unassigned.id,
        startAt: DateTime(2026, 8, 10, 12, 0),
        endAt: DateTime(2026, 8, 10, 12, 30),
        note: '相同备注',
      );
      await h.entries.createManualEntry(
        activityId: unassigned.id,
        startAt: DateTime(2026, 8, 10, 12, 30),
        endAt: DateTime(2026, 8, 10, 13, 0),
        note: '相同备注',
      );
      await h.entries.mergeAdjacentUnassignedEntries(unassigned.id);
      // 独立小场景验证整体 note 去重：两条完整 note 相同的相邻条目合并后
      // 只保留一条（_mergedNotes 按完整 note 字符串去重，非按行拆分）。
      await h.entries.createManualEntry(
        activityId: unassigned.id,
        startAt: DateTime(2026, 8, 10, 14, 0),
        endAt: DateTime(2026, 8, 10, 14, 30),
        note: '完全相同',
      );
      await h.entries.createManualEntry(
        activityId: unassigned.id,
        startAt: DateTime(2026, 8, 10, 14, 30),
        endAt: DateTime(2026, 8, 10, 15, 0),
        note: '完全相同',
      );
      await h.entries.mergeAdjacentUnassignedEntries(unassigned.id);
      final dedupDay = await h.entries.entriesForDay(DateTime(2026, 8, 10));
      final sameNote = dedupDay
          .where((e) => e.activityId == unassigned.id && e.startAt.hour == 14)
          .single;
      expect(sameNote.note, '完全相同',
          reason: '两条完整 note 相同的相邻条目合并后只保留一条');
      // 中间隔其他条目的未分配不合并（工作条目 9:30-10:00 分隔）
      await h.entries.createManualEntry(
        activityId: workActivity.id,
        startAt: DateTime(2026, 8, 10, 9, 30),
        endAt: DateTime(2026, 8, 10, 10, 0),
        note: '工作',
      );
      await h.entries.createManualEntry(
        activityId: unassigned.id,
        startAt: DateTime(2026, 8, 10, 9, 0),
        endAt: DateTime(2026, 8, 10, 9, 30),
        note: '零段',
      );
      await h.entries.mergeAdjacentUnassignedEntries(unassigned.id);
      final after = await h.entries.entriesForDay(DateTime(2026, 8, 10));
      // 被工作条目（9:30-10:00）分隔的 9:00-9:30 与 10:00-11:00 两段不合并——
      // 各自保持独立（加上 14:00 的 dedup 段共 3 条未分配）。
      final separated = after
          .where((e) => e.activityId == unassigned.id)
          .toList();
      expect(separated.length, 3);
      expect(
        separated.any((e) =>
            e.startAt.isAtSameMomentAs(DateTime(2026, 8, 10, 9, 0)) &&
            e.endAt!.isAtSameMomentAs(DateTime(2026, 8, 10, 9, 30))),
        isTrue,
        reason: '9:00-9:30 段保持独立（工作条目分隔，未与 10:00 段合并）',
      );
      expect(
        separated.any((e) =>
            e.startAt.isAtSameMomentAs(DateTime(2026, 8, 10, 10, 0))),
        isTrue,
        reason: '10:00-11:00 段保持独立',
      );
    });

    test('软删不复活 + LWW：远端旧删除不被覆盖', () async {
      final activity = await seedWork();
      final entry = (await h.entries.createManualEntry(
        activityId: activity.id,
        startAt: DateTime(2026, 8, 10, 10, 0),
        endAt: DateTime(2026, 8, 10, 11, 0),
        note: 'x',
      ))
          .requireValue();

      // 本地删除（updatedAt = now）
      await h.entries.deleteEntry(entry);
      // 远端旧版本（updatedAt 更早，未删）→ 不复活
      await h.entries.replaceIfRemoteNewer(
        entry.copyWith(updatedAt: entry.updatedAt.subtract(const Duration(hours: 1))),
      );
      final day = await h.entries.entriesForDay(DateTime(2026, 8, 10));
      expect(day, isEmpty, reason: '删除永远赢：远端旧数据不能复活已删条目');

      // 反向：本地存活条目 + 远端较新删除（updatedAt 更新、deletedAt 非空）→ 覆盖为删除
      final alive = (await h.entries.createManualEntry(
        activityId: activity.id,
        startAt: DateTime(2026, 8, 10, 14, 0),
        endAt: DateTime(2026, 8, 10, 15, 0),
        note: '存活',
      ))
          .requireValue();
      final remoteDelete = alive.copyWith(
        deletedAt: alive.updatedAt.add(const Duration(minutes: 1)),
        updatedAt: alive.updatedAt.add(const Duration(minutes: 1)),
      );
      await h.entries.replaceIfRemoteNewer(remoteDelete);
      final afterRemoteDelete = await h.entries.entriesForDay(DateTime(2026, 8, 10));
      expect(
        afterRemoteDelete.any((e) => e.id == alive.id),
        isFalse,
        reason: '远端较新删除应覆盖本地存活条目',
      );
    });
  });
}
