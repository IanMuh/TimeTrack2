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
      // 及时暴露数据管道 bug。
      expect(
        () => _slice(const Duration(minutes: -5)),
        throwsA(isA<AssertionError>()),
      );
    });

    test('normalizeNonNegativeDuration：release 兜底逻辑可独立验证', () {
      // 纯函数直接覆盖 release 语义（不依赖 assert 开关）
      expect(normalizeNonNegativeDuration(const Duration(minutes: -5)),
          Duration.zero);
      expect(normalizeNonNegativeDuration(Duration.zero), Duration.zero);
      expect(normalizeNonNegativeDuration(const Duration(minutes: 5)),
          const Duration(minutes: 5));
    });

    test('集合不可变视图：外部集合修改不影响实例', () {
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

  group('StatsGroupRow', () {

    test('primaryCategory 三件套一致性：id/label/color 同时存在或同时为 null', () {
      // id 非空但 label 为 null → 断言失败（debug）
      expect(
        () => StatsEntrySlice(
          activityId: 'a1',
          activityLabel: '工作',
          activityColor: 0,
          primaryCategoryId: 'c1',
          primaryCategoryLabel: null,
          primaryCategoryColor: 0,
          duration: Duration.zero,
        ),
        throwsA(isA<AssertionError>()),
      );
      // 三件齐全 → 正常
      expect(
        () => _slice(Duration.zero, primaryCategoryId: 'c1',
            primaryCategoryLabel: '工作', primaryCategoryColor: 0xff000000),
        returnsNormally,
      );
    });

    test('值相等：同字段切片相等、异字段不等', () {
      final a = StatsEntrySlice(
        activityId: 'a1',
        activityLabel: '工作',
        activityColor: 0xff2563eb,
        primaryCategoryId: 'c1',
        primaryCategoryLabel: '项目A',
        primaryCategoryColor: 0xff0f766e,
        linkedCategoryIds: {'c1'},
        categoryAncestorIds: ['root', 'c1'],
        duration: const Duration(minutes: 30),
      );
      expect(a, StatsEntrySlice(
        activityId: 'a1',
        activityLabel: '工作',
        activityColor: 0xff2563eb,
        primaryCategoryId: 'c1',
        primaryCategoryLabel: '项目A',
        primaryCategoryColor: 0xff0f766e,
        linkedCategoryIds: {'c1'},
        categoryAncestorIds: ['root', 'c1'],
        duration: const Duration(minutes: 30),
      ));
      expect(a.hashCode, StatsEntrySlice(
        activityId: 'a1',
        activityLabel: '工作',
        activityColor: 0xff2563eb,
        primaryCategoryId: 'c1',
        primaryCategoryLabel: '项目A',
        primaryCategoryColor: 0xff0f766e,
        linkedCategoryIds: {'c1'},
        categoryAncestorIds: ['root', 'c1'],
        duration: const Duration(minutes: 30),
      ).hashCode);
      expect(a == StatsEntrySlice(
        activityId: 'a1',
        activityLabel: '工作',
        activityColor: 0xff2563eb,
        primaryCategoryId: 'c1',
        primaryCategoryLabel: '项目A',
        primaryCategoryColor: 0xff0f766e,
        linkedCategoryIds: {'c1'},
        categoryAncestorIds: ['root', 'c1'],
        duration: const Duration(minutes: 31), // 时长不同
      ), isFalse);
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
  });

  group('StatsDimension', () {
    test('包含树聚合维度', () {
      expect(StatsDimension.values, contains(StatsDimension.categoryTree));
    });
  });
}

StatsEntrySlice _slice(
  Duration duration, {
  String? primaryCategoryId,
  String? primaryCategoryLabel,
  int? primaryCategoryColor,
}) {
  return StatsEntrySlice(
    activityId: 'a1',
    activityLabel: '工作',
    activityColor: 0xff2563eb,
    primaryCategoryId: primaryCategoryId,
    primaryCategoryLabel: primaryCategoryLabel,
    primaryCategoryColor: primaryCategoryColor,
    duration: duration,
  );
}
