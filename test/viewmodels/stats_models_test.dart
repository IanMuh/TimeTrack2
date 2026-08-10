import 'package:flutter_test/flutter_test.dart';
import 'package:timetrack2/viewmodels/stats/stats_models.dart';

void main() {
  group('StatsEntrySlice', () {
    test('durationBucketLabel 分桶边界（含紧邻阈值两侧）', () {
      expect(_slice(const Duration(minutes: 29)).durationBucketLabel, '<30m');
      expect(_slice(const Duration(minutes: 30)).durationBucketLabel, '30m-1h');
      expect(_slice(const Duration(minutes: 59)).durationBucketLabel, '30m-1h');
      expect(_slice(const Duration(minutes: 60)).durationBucketLabel, '1-3h');
      expect(_slice(const Duration(minutes: 61)).durationBucketLabel, '1-3h');
      expect(_slice(const Duration(minutes: 179)).durationBucketLabel, '1-3h');
      expect(_slice(const Duration(minutes: 180)).durationBucketLabel, '3h+');
      expect(_slice(const Duration(minutes: 181)).durationBucketLabel, '3h+');
    });

    test('durationBucketColor 与桶对应', () {
      expect(
        _slice(const Duration(minutes: 10)).durationBucketColor,
        0xff94a3b8,
      );
      expect(
        _slice(const Duration(minutes: 45)).durationBucketColor,
        0xff0ea5e9,
      );
      expect(
        _slice(const Duration(hours: 2)).durationBucketColor,
        0xff7c3aed,
      );
      expect(
        _slice(const Duration(hours: 5)).durationBucketColor,
        0xffdc2626,
      );
    });

    test('零时长归入 <30m 桶', () {
      expect(_slice(Duration.zero).durationBucketLabel, '<30m');
    });

    test('负时长：debug 下触发断言快速失败（release 下归一化为 0 兜底）', () {
      // 测试运行于 assert 开启的 debug 模式：负时长应触发 AssertionError，
      // 及时暴露数据管道 bug；release 下 assert 移除、构造器归一化兜底。
      expect(
        () => _slice(const Duration(minutes: -5)),
        throwsA(isA<AssertionError>()),
      );
    });
  });

  group('StatsGroupRow', () {
    test('copyWith 保留未变字段', () {
      final row = StatsGroupRow(
        id: 'g1',
        label: '工作 / 项目A',
        totalDuration: const Duration(minutes: 90),
        count: 3,
        color: 0xff2563eb,
        depth: 1,
        ancestorIds: const ['root'],
      );
      final updated = row.copyWith(totalDuration: const Duration(hours: 2));
      expect(updated.id, 'g1');
      expect(updated.label, '工作 / 项目A');
      expect(updated.totalDuration, const Duration(hours: 2));
      expect(updated.count, 3);
      expect(updated.color, 0xff2563eb);
      expect(updated.depth, 1);
      expect(updated.ancestorIds, ['root']);
    });

    test('ancestorIds 不可变视图', () {
      final mutable = <String>['root', 'parent'];
      final row = StatsGroupRow(
        id: 'g1',
        label: 'x',
        totalDuration: Duration.zero,
        count: 0,
        color: 0,
        ancestorIds: mutable,
      );
      mutable.add('被修改');
      expect(row.ancestorIds, ['root', 'parent']);
      expect(() => row.ancestorIds.add('x'), throwsUnsupportedError);
    });

    test('StatsEntrySlice 集合不可变视图', () {
      final linked = <String>{'c1'};
      final ancestors = <String>['root'];
      final slice = StatsEntrySlice(
        activityId: 'a1',
        activityLabel: '工作',
        activityColor: 0xff2563eb,
        primaryCategoryId: null,
        primaryCategoryLabel: null,
        primaryCategoryColor: null,
        linkedCategoryIds: linked,
        categoryAncestorIds: ancestors,
        duration: Duration.zero,
      );
      linked.add('c2');
      ancestors.add('c1');
      expect(slice.linkedCategoryIds, {'c1'});
      expect(slice.categoryAncestorIds, ['root']);
      expect(() => slice.linkedCategoryIds.add('x'),
          throwsUnsupportedError);
      expect(() => slice.categoryAncestorIds.add('x'),
          throwsUnsupportedError);
    });
  });

  group('StatsDimension', () {
    test('包含树聚合维度', () {
      expect(StatsDimension.values, contains(StatsDimension.categoryTree));
    });
  });
}

StatsEntrySlice _slice(Duration duration) {
  return StatsEntrySlice(
    activityId: 'a1',
    activityLabel: '工作',
    activityColor: 0xff2563eb,
    primaryCategoryId: null,
    primaryCategoryLabel: null,
    primaryCategoryColor: null,
    duration: duration,
  );
}
