import 'package:flutter_test/flutter_test.dart';
import 'package:timetrack2/viewmodels/stats/stats_models.dart';

void main() {
  group('StatsEntrySlice', () {
    test('durationBucketLabel 分桶边界', () {
      // 边界用例
      expect(
        _slice(const Duration(minutes: 29)).durationBucketLabel,
        '<30m',
      );
      expect(
        _slice(const Duration(minutes: 30)).durationBucketLabel,
        '30m-1h',
      );
      expect(
        _slice(const Duration(hours: 1)).durationBucketLabel,
        '1-3h',
      );
      expect(
        _slice(const Duration(hours: 3)).durationBucketLabel,
        '3h+',
      );
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

    test('负时长构造触发非负断言（debug 模式）', () {
      expect(
        () => _slice(const Duration(minutes: -5)),
        throwsA(isA<AssertionError>()),
      );
    });
  });

  group('StatsGroupRow', () {
    test('copyWith 保留未变字段', () {
      const row = StatsGroupRow(
        id: 'g1',
        label: '工作 / 项目A',
        totalDuration: Duration(minutes: 90),
        count: 3,
        color: 0xff2563eb,
        depth: 1,
        ancestorIds: ['root'],
      );
      final updated = row.copyWith(totalDuration: const Duration(hours: 2));
      expect(updated.id, 'g1');
      expect(updated.label, '工作 / 项目A');
      expect(updated.totalDuration, const Duration(hours: 2));
      expect(updated.count, 3);
      expect(updated.depth, 1);
      expect(updated.ancestorIds, ['root']);
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
