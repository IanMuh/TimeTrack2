import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:timetrack2/data/database/app_database.dart' hide ProfileSettings;
import 'package:timetrack2/data/repositories/activity_repository.dart';
import 'package:timetrack2/data/repositories/category_repository.dart';
import 'package:timetrack2/data/repositories/settings_repository.dart';
import 'package:timetrack2/data/repositories/stats_repository.dart';
import 'package:timetrack2/data/repositories/time_entry_repository.dart';
import 'package:timetrack2/viewmodels/activity.dart';
import 'package:timetrack2/viewmodels/activity_category.dart';
import 'package:timetrack2/viewmodels/stats/stats_models.dart';

/// 内存库测试环境（与 repositories_test 同模式）。
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
    stats = StatsRepository(
      activities: activities,
      categories: categories,
      entries: entries,
    );
  }

  late final AppDatabase db;
  late final ActivityRepository activities;
  late final CategoryRepository categories;
  late final SettingsRepository settings;
  late final TimeEntryRepository entries;
  late final StatsRepository stats;

  Future<void> close() => db.close();
}

Future<Activity> seedActivity(
  TestHarness h, {
  String? name,
  int color = 0xff2563eb,
}) async {
  final result = await h.activities.createActivity(
    name: name ?? '活动${DateTime.now().microsecondsSinceEpoch % 100000}',
    color: color,
    isOneOff: false,
  );
  return result.requireValue();
}

Future<ActivityCategory> seedCategory(
  TestHarness h, {
  required String name,
  int color = 0xff0f766e,
  String? parentId,
}) async {
  final result = await h.categories
      .createCategory(name: name, color: color, parentId: parentId);
  return result.requireValue();
}

Future<void> seedEntry(
  TestHarness h, {
  required String activityId,
  required DateTime startAt,
  required DateTime endAt,
}) async {
  // 与 seedActivity/seedCategory 一致：补记失败（非法时间段/DB 异常）立即暴露
  //（requireValue 抛 StateError），防失败被静默吞掉难以定位。
  (await h.entries.createManualEntry(
    activityId: activityId,
    startAt: startAt,
    endAt: endAt,
    note: '',
  )).requireValue();
}

void main() {
  group('StatsRepository.slicesForRange', () {
    late TestHarness h;

    setUp(() => h = TestHarness());
    tearDown(() => h.close());

    test('范围过滤：只统计 [start, end) 内起点的未删条目', () async {
      final a = await seedActivity(h, name: 'A');
      // 不重叠条目（createManualEntry 的 cutOverlaps 会裁剪重叠数据，
      // 故用例数据须互不重叠）。
      await seedEntry(h, activityId: a.id, startAt: _t(10), endAt: _t(10, 30));
      await seedEntry(h, activityId: a.id, startAt: _t(10, 30), endAt: _t(11));
      await seedEntry(h, activityId: a.id, startAt: _t(11), endAt: _t(12)); // 范围外

      final result = (await h.stats.slicesForRange(
        start: _t(10),
        end: _t(11),
      )).requireValue();
      expect(result.slices, hasLength(2)); // 11:00 起的条目被排除
      final total = result.slices.fold(Duration.zero, (s, x) => s + x.duration);
      expect(total, const Duration(hours: 1));
      expect(result.hasRunningEntry, isFalse); // 全结束条目 → false
    });

    test('裁剪：单条目跨范围边界 → [start, end) 内切片时长', () async {
      final a = await seedActivity(h, name: 'A');
      // 09:30-11:30 一条，范围 10:00-11:00 → 裁左右各 30m，剩 60m。
      await seedEntry(h, activityId: a.id, startAt: _t(9, 30), endAt: _t(11, 30));
      final slices = (await h.stats.slicesForRange(
        start: _t(10),
        end: _t(11),
      )).requireValue().slices;
      expect(slices, hasLength(1));
      expect(slices.single.duration, const Duration(hours: 1));
    });

    test('运行中条目（endAt==null）用 effectiveNow 裁剪', () async {
      final a = await seedActivity(h, name: 'A');
      final running = (await h.entries.switchToActivity(a.id)).requireValue();
      expect(running.endAt, isNull, reason: 'switchToActivity 应返回运行中条目');
      // switchToActivity 的 startAt = DateTime.now()（不可注入）：
      // 用相对真实 now 的窗口保证确定性——range 覆盖运行条目起点，
      // effectiveNow = now+30m 裁剪 → 切片 = 30m。
      final start = running.startAt.subtract(const Duration(hours: 1));
      final end = running.startAt.add(const Duration(hours: 1));

      final result = (await h.stats.slicesForRange(
        start: start,
        end: end,
        effectiveNow: running.startAt.add(const Duration(minutes: 30)),
      )).requireValue();
      expect(result.slices, hasLength(1));
      expect(result.slices.first.duration, const Duration(minutes: 30));
      expect(result.hasRunningEntry, isTrue); // 运行中条目 → true
    });

    test('end <= start 返回空（不崩）', () async {
      final a = await seedActivity(h, name: 'A');
      await seedEntry(h, activityId: a.id, startAt: _t(10), endAt: _t(11));
      final slices = (await h.stats.slicesForRange(
        start: _t(11),
        end: _t(10),
      )).requireValue().slices;
      expect(slices, isEmpty);
    });

    test('活动已删后：条目回退活动快照（名/色）', () async {
      final a = await seedActivity(h, name: 'A', color: 0x112233);
      await seedEntry(h, activityId: a.id, startAt: _t(10), endAt: _t(11));
      await h.activities.deleteActivity(a); // 软删活动

      final slices = (await h.stats.slicesForRange(
        start: _t(10),
        end: _t(12),
      )).requireValue().slices;
      expect(slices.first.activityLabel, 'A'); // 快照名
      expect(slices.first.activityColor, 0x112233); // 快照色
    });

    test('分类已删后：主分类链接失效，primary 回退 null', () async {
      final a = await seedActivity(h, name: 'A');
      final category = await seedCategory(h, name: '工作');
      await h.categories.setActivityCategories(
        activityId: a.id,
        primaryCategoryId: category.id,
      );
      await seedEntry(h, activityId: a.id, startAt: _t(10), endAt: _t(11));

      final before = (await h.stats.slicesForRange(
        start: _t(10),
        end: _t(12),
      )).requireValue().slices;
      expect(before.first.primaryCategoryId, category.id);

      await h.categories.deleteCategory(category); // 软删分类

      final after = (await h.stats.slicesForRange(
        start: _t(10),
        end: _t(12),
      )).requireValue().slices;
      expect(after.first.primaryCategoryId, isNull); // 链接失效，无主分类
      expect(after.first.categoryAncestorIds, isEmpty);
    });

    test('主分类 = isPrimary 链接优先于 sortOrder', () async {
      final a = await seedActivity(h, name: 'A');
      final primary = await seedCategory(h, name: '主');
      final secondary = await seedCategory(h, name: '次');
      await h.categories.setActivityCategories(
        activityId: a.id,
        secondaryCategoryIds: [secondary.id], // 排序次要在前
        primaryCategoryId: primary.id,
      );
      await seedEntry(h, activityId: a.id, startAt: _t(10), endAt: _t(11));

      final slices = (await h.stats.slicesForRange(
        start: _t(10),
        end: _t(12),
      )).requireValue().slices;
      expect(slices.first.primaryCategoryId, primary.id);
      expect(slices.first.primaryCategoryLabel, '主');
      expect(slices.first.categoryAncestorIds, [primary.id]);
    });

    test('无链接：无主分类，ancestorIds 为空', () async {
      final a = await seedActivity(h, name: 'A');
      await seedEntry(h, activityId: a.id, startAt: _t(10), endAt: _t(11));
      final slices = (await h.stats.slicesForRange(
        start: _t(10),
        end: _t(12),
      )).requireValue().slices;
      expect(slices.first.primaryCategoryId, isNull);
      expect(slices.first.categoryAncestorIds, isEmpty);
    });
  });

  group('StatsRepository.aggregate', () {
    late TestHarness h;

    setUp(() => h = TestHarness());
    tearDown(() => h.close());

    test('activity 维度：按活动归并 + 名称兜底', () {
      final rows = h.stats.aggregate([
        _slice('a1', 'A', 0xff0000, duration: const Duration(minutes: 30)),
        _slice('a1', 'A', 0xff0000, duration: const Duration(minutes: 30)),
        _slice('a2', '  ', 0x00ff00, duration: const Duration(minutes: 10)),
      ], StatsDimension.activity);
      expect(rows, hasLength(2));
      final a1 = rows.firstWhere((r) => r.id == 'activity:a1');
      expect(a1.totalDuration, const Duration(hours: 1));
      expect(a1.count, 2);
      final a2 = rows.firstWhere((r) => r.id == 'activity:a2');
      expect(a2.label, unknownActivityLabel); // 空名兜底
    });

    test('primaryCategory 维度：无主分类归并到"未分类"', () {
      final rows = h.stats.aggregate([
        _slice('a1', 'A', 0xff0000, primary: ('c1', '工作', 0x0f766e),
            duration: const Duration(minutes: 20)),
        _slice('a2', 'B', 0x00ff00, duration: const Duration(minutes: 10)),
      ], StatsDimension.primaryCategory);
      expect(rows, hasLength(2));
      final c1 = rows.firstWhere((r) => r.id == 'category:c1');
      expect(c1.label, '工作');
      final none = rows.firstWhere((r) => r.id == 'category:none');
      expect(none.label, unassignedCategoryLabel);
      expect(none.totalDuration, const Duration(minutes: 10));
    });

    test('durationBucket 维度：按桶归并', () {
      final rows = h.stats.aggregate([
        _slice('a1', 'A', 0, duration: const Duration(minutes: 20)),
        _slice('a2', 'B', 0, duration: const Duration(minutes: 40)),
        _slice('a3', 'C', 0, duration: const Duration(minutes: 10)),
      ], StatsDimension.durationBucket);
      expect(rows, hasLength(2));
      final under30 = rows.firstWhere((r) => r.id == 'bucket:<30m');
      expect(under30.count, 2); // 20m + 10m
      final half = rows.firstWhere((r) => r.id == 'bucket:30m-1h');
      expect(half.count, 1);
    });

    test('组合维度：分类 × 桶', () {
      final rows = h.stats.aggregate([
        _slice('a1', 'A', 0, primary: ('c1', '工作', 0), duration: const Duration(minutes: 20)),
        _slice('a2', 'B', 0, primary: ('c1', '工作', 0), duration: const Duration(minutes: 40)),
        _slice('a3', 'C', 0, duration: const Duration(minutes: 10)),
      ], StatsDimension.primaryCategoryAndDurationBucket);
      expect(rows, hasLength(3));
      expect(
        rows.any((r) => r.id == 'category:c1:bucket:<30m' && r.label == '工作 / <30m'),
        isTrue,
      );
    });

    test('categoryTree：按祖先链每个节点归并（父行=自身+子孙）', () {
      final categoryById = <String, ActivityCategory>{
        'root': _cat('root', '工作', parentId: null),
        'c1': _cat('c1', '项目A', parentId: 'root'),
        'c2': _cat('c2', '子项目', parentId: 'c1'),
      };
      final rows = h.stats.aggregate([
        // 子项目分类的活动 → 归并到 root / c1 / c2 三个节点
        _slice('a1', 'A', 0, primary: ('c2', '子项目', 0),
            ancestors: ['root', 'c1', 'c2'], duration: const Duration(minutes: 30)),
        // 顶层分类（root 直接子）的活动 → root / c1
        _slice('a2', 'B', 0, primary: ('c1', '项目A', 0),
            ancestors: ['root', 'c1'], duration: const Duration(minutes: 10)),
      ], StatsDimension.categoryTree, categoryById: categoryById);
      expect(rows, hasLength(3));

      final root = rows.firstWhere((r) => r.id == 'category:root');
      expect(root.label, '工作');
      expect(root.depth, 0);
      expect(root.ancestorIds, isEmpty);
      expect(root.totalDuration, const Duration(minutes: 40)); // 30+10

      final c1 = rows.firstWhere((r) => r.id == 'category:c1');
      expect(c1.label, '工作 / 项目A');
      expect(c1.depth, 1);
      expect(c1.ancestorIds, ['root']);
      expect(c1.totalDuration, const Duration(minutes: 40));

      final c2 = rows.firstWhere((r) => r.id == 'category:c2');
      expect(c2.label, '工作 / 项目A / 子项目');
      expect(c2.depth, 2);
      expect(c2.ancestorIds, ['root', 'c1']);
      expect(c2.totalDuration, const Duration(minutes: 30));
    });

    test('categoryTree：无主分类归并到根节点', () {
      final rows = h.stats.aggregate([
        _slice('a1', 'A', 0, duration: const Duration(minutes: 15)),
      ], StatsDimension.categoryTree);
      expect(rows, hasLength(1));
      expect(rows.single.id, 'category:none');
      expect(rows.single.label, unassignedCategoryLabel);
      expect(rows.single.depth, 0);
      expect(rows.single.totalDuration, const Duration(minutes: 15));
    });

    test('categoryTree：悬空祖先（已删）在断点截断', () {
      final categoryById = <String, ActivityCategory>{
        'c1': _cat('c1', '项目A', parentId: 'missing'), // 父已删
      };
      final rows = h.stats.aggregate([
        _slice('a1', 'A', 0, primary: ('c1', '项目A', 0),
            ancestors: ['c1'], duration: const Duration(minutes: 5)),
      ], StatsDimension.categoryTree, categoryById: categoryById);
      expect(rows, hasLength(1));
      expect(rows.single.id, 'category:c1');
      expect(rows.single.label, '项目A'); // 祖先链在断点处只含自身
    });

    test('categoryTree：链中缺失节点 label 回退"未分类"（不拼原始 id）', () {
      // 切片携带 ancestors=['missingRoot','c1']（模拟切片生成后根分类被删），
      // 聚合侧 map 仅含 c1——缺失节点 label 必须回退可读文案而非原始 id。
      final categoryById = <String, ActivityCategory>{
        'c1': _cat('c1', '项目A', parentId: 'missingRoot'),
      };
      final rows = h.stats.aggregate([
        _slice('a1', 'A', 0, primary: ('c1', '项目A', 0),
            ancestors: ['missingRoot', 'c1'], duration: const Duration(minutes: 5)),
      ], StatsDimension.categoryTree, categoryById: categoryById);
      expect(rows, hasLength(2)); // 两个祖先节点各一行
      final c1 = rows.firstWhere((r) => r.id == 'category:c1');
      expect(c1.label, '$unassignedCategoryLabel / 项目A');
      expect(c1.depth, 1);
    });
  });
}

DateTime _t(int hour, [int minute = 0]) =>
    DateTime(2026, 8, 14, hour, minute);

/// 快速构造切片。
StatsEntrySlice _slice(
  String activityId,
  String activityLabel,
  int activityColor, {
  required Duration duration,
  (String, String, int)? primary, // (id, label, color)
  List<String> ancestors = const [],
}) {
  final primaryId = primary?.$1;
  // StatsEntrySlice 断言：有主分类时 categoryAncestorIds 非空且末尾=主分类自身。
  final effectiveAncestors = primaryId == null
      ? ancestors
      : (ancestors.isEmpty ? [primaryId] : ancestors);
  return StatsEntrySlice(
    activityId: activityId,
    activityLabel: activityLabel,
    activityColor: activityColor,
    primaryCategoryId: primaryId,
    primaryCategoryLabel: primary?.$2,
    primaryCategoryColor: primary?.$3,
    categoryAncestorIds: effectiveAncestors,
    duration: duration,
  );
}

ActivityCategory _cat(String id, String name, {String? parentId}) {
  return ActivityCategory(
    id: id,
    name: name,
    color: 0xff0f766e,
    updatedAt: DateTime(2026, 8, 14),
    parentId: parentId,
  );
}
