import 'package:flutter_test/flutter_test.dart';
import 'package:timetrack2/viewmodels/activity.dart';
import 'package:timetrack2/viewmodels/activity_category.dart';
import 'package:timetrack2/viewmodels/profile_settings.dart';
import 'package:timetrack2/viewmodels/time_entry.dart';

void main() {
  group('Activity', () {
    final base = Activity(
      id: 'a1',
      userId: 'u1',
      name: '工作',
      color: 0xff2563eb,
      isFavorite: true,
      updatedAt: DateTime.utc(2026, 8, 10, 4),
    );

    test('缺键容错：非必填字段缺失回退默认值；updated_at 缺失抛 FormatException', () {
      // updated_at 语义必填（LWW 冲突判定关键字段）——缺失即抛错，不伪造当前时刻
      expect(() => Activity.fromMap({'id': 'x'}), throwsFormatException);
    });

    test('缺键容错：非必填字段缺失回退默认值（提供必填 updated_at）', () {
      final restored = Activity.fromMap({
        'id': 'x',
        'updated_at': '2026-08-10T04:00:00Z',
      });
      expect(restored.id, 'x');
      expect(restored.name, '');
      expect(restored.color, Activity.defaultColor);
      expect(restored.isFavorite, isFalse);
      expect(restored.deletedAt, isNull);
      expect(restored.isUnassigned, isFalse);
      expect(restored.isOneOff, isFalse);
    });

    test('非法类型容错：值类型错误时回退默认，不抛异常', () {
      final restored = Activity.fromMap({
        'id': 'x',
        'user_id': 123, // 数字 userId
        'name': 456, // 数字 name
        'color': 'red', // 字符串 color
        'is_favorite': '1', // 字符串布尔
        'updated_at': '2026-08-10T04:00:00Z',
        'deleted_at': '', // 非法软删时间
      });
      expect(restored.userId, isNull);
      expect(restored.name, '');
      expect(restored.color, Activity.defaultColor);
      expect(restored.isFavorite, isFalse);
      expect(restored.deletedAt, isNull);
      expect(restored.updatedAt.isAtSameMomentAs(DateTime.utc(2026, 8, 10, 4)),
          isTrue);
    });

    test('updated_at 缺失/非法 → FormatException（不伪造时间戳）', () {
      expect(() => Activity.fromMap({'id': 'x'}), throwsFormatException);
      expect(
        () => Activity.fromMap({'id': 'x', 'updated_at': 'not-a-date'}),
        throwsFormatException,
      );
      expect(
        () => Activity.fromMap({'id': 'x', 'updated_at': 12345}),
        throwsFormatException,
      );
    });

    test('clearUserId 可将 userId 置空', () {
      expect(base.copyWith(clearUserId: true).userId, isNull);
      expect(base.copyWith(userId: 'u2').userId, 'u2');
      expect(base.copyWith(userId: 'u2').copyWith(clearUserId: true).userId,
          isNull);
    });

    test('round-trip：toMap → fromMap 保真', () {
      final deleted = base.copyWith(
        deletedAt: DateTime.utc(2026, 8, 11, 4),
      );
      final restored = Activity.fromMap(deleted.toMap());
      expect(restored.id, base.id);
      expect(restored.name, base.name);
      expect(restored.color, base.color);
      expect(restored.isFavorite, base.isFavorite);
      // 时刻保真（忽略 UTC/本地表示差异）
      expect(restored.updatedAt.isAtSameMomentAs(base.updatedAt), isTrue);
      expect(restored.deletedAt!.isAtSameMomentAs(deleted.deletedAt!), isTrue);
      expect(restored.updatedAt.toUtc(), base.updatedAt.toUtc());
    });

    test('copyWith：clearDeletedAt 可恢复删除状态', () {
      final deleted = base.copyWith(deletedAt: DateTime.utc(2026, 8, 11));
      expect(deleted.isDeleted, isTrue);
      final restored = deleted.copyWith(clearDeletedAt: true);
      expect(restored.isDeleted, isFalse);
    });

    test('等值比较以 id 为准', () {
      expect(base, Activity.fromMap(base.toMap()));
      // 同一 id 视为同一实体（字段差异不影响相等性）
      expect(base == base.copyWith(name: '改名'), isTrue);
      // 不同 id 视为不同实体
      expect(
        base == Activity(
          id: 'other',
          name: '工作',
          color: 0xff2563eb,
          isFavorite: true,
          updatedAt: DateTime.utc(2026, 8, 10, 4),
        ),
        isFalse,
      );
    });
  });

  group('TimeEntry', () {
    final t1 = DateTime.utc(2026, 8, 10, 4, 0);
    final entry = TimeEntry(
      id: 'e1',
      userId: 'u1',
      activityId: 'a1',
      activityNameSnapshot: '工作',
      activityColorSnapshot: 0xff2563eb,
      startAt: t1,
      endAt: t1.add(const Duration(hours: 2)),
      note: '周会',
      deviceId: 'dev-1',
      updatedAt: t1,
    );

    test('缺键容错：activity_id 缺省为空串，不抛异常', () {
      final restored = TimeEntry.fromMap({
        'id': 'e',
        'start_at': '2026-08-10T04:00:00Z',
        'updated_at': '2026-08-10T04:00:00Z',
      });
      expect(restored.activityId, '');
      expect(restored.activityNameSnapshot, '');
      expect(restored.activityColorSnapshot, isNull);
      expect(restored.note, '');
      expect(restored.deviceId, 'unknown');
      expect(restored.endAt, isNull);
      expect(restored.isRunning, isTrue);
    });

    test('round-trip 保真（含快照与删除状态）', () {
      final withDeleted = entry.copyWith(
        deletedAt: DateTime.utc(2026, 8, 11, 4),
      );
      final restored = TimeEntry.fromMap(withDeleted.toMap());
      expect(restored.activityId, 'a1');
      expect(restored.activityNameSnapshot, '工作');
      expect(restored.activityColorSnapshot, 0xff2563eb);
      expect(restored.startAt.isAtSameMomentAs(t1), isTrue);
      expect(
        restored.endAt!.isAtSameMomentAs(t1.add(const Duration(hours: 2))),
        isTrue,
      );
      expect(restored.note, '周会');
      expect(restored.deviceId, 'dev-1');
      expect(restored.deletedAt!.isAtSameMomentAs(withDeleted.deletedAt!), isTrue);
      expect(restored.isRunning, isFalse);
    });

    test('isRunning / durationUntil / durationInWindow', () {
      final running = entry.copyWith(clearEndAt: true);
      expect(running.isRunning, isTrue);
      final now = t1.add(const Duration(minutes: 30));
      expect(running.durationUntil(now), const Duration(minutes: 30));

      // 窗口裁剪：仅统计窗口内时长
      final windowStart = t1.add(const Duration(minutes: 30));
      final windowEnd = t1.add(const Duration(minutes: 90));
      expect(
        entry.durationInWindow(
          windowStart: windowStart,
          windowEnd: windowEnd,
          now: now,
        ),
        const Duration(minutes: 60),
      );
    });

    test('overlaps 半开区间 + 运行中视为无限', () {
      final other = TimeEntry(
        id: 'e2',
        activityId: 'a2',
        startAt: t1.add(const Duration(minutes: 90)),
        endAt: t1.add(const Duration(hours: 3)),
        deviceId: 'dev-1',
        updatedAt: t1,
      );
      expect(entry.overlaps(other), isTrue);
      expect(other.overlaps(entry), isTrue);

      // 首尾相接（endAt == 另一条 startAt）不重叠
      final adjacent = TimeEntry(
        id: 'e3',
        activityId: 'a2',
        startAt: t1.add(const Duration(hours: 2)),
        endAt: t1.add(const Duration(hours: 3)),
        deviceId: 'dev-1',
        updatedAt: t1,
      );
      expect(entry.overlaps(adjacent), isFalse);

      // 运行中条目与之后任何条目重叠
      final running = entry.copyWith(clearEndAt: true);
      expect(running.overlaps(adjacent), isTrue);
      // 双运行条目互相重叠
      final otherRunning = adjacent.copyWith(clearEndAt: true);
      expect(running.overlaps(otherRunning), isTrue);
      // 反向边界：运行中条目与在其 startAt 之前已结束的历史条目不重叠（+∞ 语义不误读为"与一切重叠"）
      final history = TimeEntry(
        id: 'e4',
        activityId: 'a2',
        startAt: t1.subtract(const Duration(hours: 2)),
        endAt: t1.subtract(const Duration(hours: 1)),
        deviceId: 'dev-1',
        updatedAt: t1,
      );
      expect(running.overlaps(history), isFalse);
      // durationUntil：now 早于 startAt → Duration.zero
      expect(
        running.durationUntil(t1.subtract(const Duration(hours: 1))),
        Duration.zero,
      );
    });

    test('start_at 缺失或非法 → FormatException（不伪造时间戳）', () {
      expect(
        () => TimeEntry.fromMap({'id': 'e', 'activity_id': 'a1'}),
        throwsFormatException,
      );
      expect(
        () => TimeEntry.fromMap({'id': 'e', 'start_at': 'not-a-date'}),
        throwsFormatException,
      );
      expect(
        () => TimeEntry.fromMap({'id': 'e', 'start_at': 12345}),
        throwsFormatException,
      );
    });

    test('非法类型容错：非关键字段类型错误回退默认，不抛异常', () {
      final restored = TimeEntry.fromMap({
        'id': 'e',
        'user_id': 123,
        'activity_id': 456,
        'activity_name': 789,
        'note': 999,
        'start_at': '2026-08-10T04:00:00Z',
        'updated_at': '2026-08-10T04:00:00Z',
        'end_at': '', // 非法结束时间 → null（视为运行中，而非伪造）
      });
      expect(restored.userId, isNull);
      expect(restored.activityId, '');
      expect(restored.activityNameSnapshot, '');
      expect(restored.note, '');
      expect(restored.endAt, isNull);
      expect(restored.isRunning, isTrue);
    });

    test('时间窗边界：运行中裁剪 / now 早于 startAt / 反向窗口 / 窗口全外', () {
      final running = entry.copyWith(clearEndAt: true);
      final now = t1.add(const Duration(hours: 1));

      // 运行中条目：窗口内只统计到 now（t1+1h）为止 → [t1+30m, t1+60m] = 30 分钟
      expect(
        running.durationInWindow(
          windowStart: t1.add(const Duration(minutes: 30)),
          windowEnd: t1.add(const Duration(minutes: 90)),
          now: now,
        ),
        const Duration(minutes: 30),
      );

      // 窗口完全在条目开始之前结束 → 0
      expect(
        entry.durationInWindow(
          windowStart: t1.subtract(const Duration(hours: 2)),
          windowEnd: t1.subtract(const Duration(hours: 1)),
          now: now,
        ),
        Duration.zero,
      );

      // 反向/零长窗口 → 0
      expect(
        entry.durationInWindow(
          windowStart: t1.add(const Duration(hours: 1)),
          windowEnd: t1,
          now: now,
        ),
        Duration.zero,
      );
      expect(
        entry.durationInWindow(
          windowStart: t1,
          windowEnd: t1,
          now: now,
        ),
        Duration.zero,
      );

      // 窗口完全在条目之后 → 0
      expect(
        entry.durationInWindow(
          windowStart: t1.add(const Duration(hours: 5)),
          windowEnd: t1.add(const Duration(hours: 6)),
          now: now,
        ),
        Duration.zero,
      );

      // 窗口完全覆盖条目 → 全时长
      expect(
        entry.durationInWindow(
          windowStart: t1.subtract(const Duration(hours: 1)),
          windowEnd: t1.add(const Duration(hours: 3)),
          now: now,
        ),
        const Duration(hours: 2),
      );
    });

    test('clearUserId 可将 userId 置空', () {
      expect(entry.copyWith(clearUserId: true).userId, isNull);
      expect(entry.copyWith(userId: 'u2').userId, 'u2');
    });
  });

  group('ActivityCategory（层级）', () {
    test('parentId 缺键容错：缺省为 null（顶级）', () {
      final restored = ActivityCategory.fromMap({
        'id': 'c1',
        'updated_at': '2026-08-10T04:00:00Z',
      });
      expect(restored.parentId, isNull);
      expect(restored.name, '');
      expect(restored.deletedAt, isNull);
    });

    test('updated_at 缺失/非法 → FormatException（不伪造时间戳）', () {
      expect(() => ActivityCategory.fromMap({'id': 'c1'}), throwsFormatException);
      expect(
        () => ActivityCategory.fromMap({
          'id': 'c1',
          'updated_at': 'not-a-date',
        }),
        throwsFormatException,
      );
      expect(
        () => ActivityCategory.fromMap({'id': 'c1', 'updated_at': 12345}),
        throwsFormatException,
      );
    });

    test('parentId round-trip 保真', () {
      final category = ActivityCategory(
        id: 'c2',
        userId: 'u1',
        name: '项目A',
        color: 0xff0f766e,
        parentId: 'c1',
        updatedAt: DateTime.utc(2026, 8, 10, 4),
      );
      final restored = ActivityCategory.fromMap(category.toMap());
      expect(restored.parentId, 'c1');
      expect(restored.id, 'c2');
    });

    test('copyWith clearParentId 可升为顶级', () {
      final child = ActivityCategory.fromMap({
        'id': 'c',
        'parent_id': 'p',
        'updated_at': '2026-08-10T04:00:00Z',
      });
      expect(child.copyWith(clearParentId: true).parentId, isNull);
    });

    test('非法类型容错 + clearUserId', () {
      final restored = ActivityCategory.fromMap({
        'id': 'c1',
        'user_id': 123,
        'name': 456,
        'color': 'red',
        'parent_id': 789,
        'updated_at': '2026-08-10T04:00:00Z',
      });
      expect(restored.userId, isNull);
      expect(restored.name, '');
      expect(restored.color, ActivityCategory.defaultColor);
      expect(restored.parentId, isNull);
      expect(restored.copyWith(clearUserId: true).userId, isNull);
      expect(
        restored.copyWith(userId: 'u2').copyWith(clearUserId: true).userId,
        isNull,
      );
    });
  });

  group('ActivityCategoryLink', () {
    test('缺键容错 + isPrimary/sortOrder 默认值', () {
      final restored = ActivityCategoryLink.fromMap({
        'id': 'l1',
        'updated_at': '2026-08-10T04:00:00Z',
      });
      expect(restored.activityId, '');
      expect(restored.categoryId, '');
      expect(restored.isPrimary, isFalse);
      expect(restored.sortOrder, 0);
    });

    test('updated_at 缺失/非法 → FormatException', () {
      expect(
        () => ActivityCategoryLink.fromMap({'id': 'l1'}),
        throwsFormatException,
      );
      expect(
        () => ActivityCategoryLink.fromMap({
          'id': 'l1',
          'updated_at': 'not-a-date',
        }),
        throwsFormatException,
      );
    });

    test('round-trip 保真', () {
      final link = ActivityCategoryLink(
        id: 'l1',
        userId: 'u1',
        activityId: 'a1',
        categoryId: 'c1',
        isPrimary: true,
        sortOrder: 0,
        updatedAt: DateTime.utc(2026, 8, 10, 4),
      );
      final restored = ActivityCategoryLink.fromMap(link.toMap());
      expect(restored.activityId, 'a1');
      expect(restored.categoryId, 'c1');
      expect(restored.isPrimary, isTrue);
      expect(restored.sortOrder, 0);
    });
  });

  group('ProfileSettings', () {
    test('defaults 使用默认提醒参数', () {
      final defaults = ProfileSettings.defaults();
      expect(defaults.reminderMinutes, 45);
      expect(defaults.reminderIntervalMinutes, 10);
      expect(defaults.reminderMethod, ReminderMethod.dialog);
      expect(defaults.reminderTimeOfDayMinutes, 540);
      expect(defaults.mergeNeighborThresholdMinutes, 1);
      expect(defaults.timezone, isNotEmpty);
    });

    test('缺键容错：全部缺失回退默认（提供必填 updated_at）', () {
      final restored = ProfileSettings.fromMap({
        'updated_at': '2026-08-10T04:00:00Z',
      });
      expect(restored.reminderMinutes, 45);
      expect(restored.reminderIntervalMinutes, 10);
      expect(restored.reminderMethod, ReminderMethod.dialog);
      expect(restored.reminderTimeOfDayMinutes, 540);
      expect(restored.mergeNeighborThresholdMinutes, 1);
    });

    test('updated_at 缺失 → FormatException', () {
      expect(() => ProfileSettings.fromMap(const {}), throwsFormatException);
    });

    test('损坏数值容错：钳制到合法范围', () {
      final restored = ProfileSettings.fromMap({
        'updated_at': '2026-08-10T04:00:00Z',
        'reminder_minutes': -5, // 钳制到 1
        'reminder_interval_minutes': 0, // 钳制到 1
        'reminder_time_of_day_minutes': 9999, // 钳制到 23*60+59
        'merge_neighbor_threshold_minutes': -3, // 钳制到 0
      });
      expect(restored.reminderMinutes, 1);
      expect(restored.reminderIntervalMinutes, 1);
      expect(restored.reminderTimeOfDayMinutes, 23 * 60 + 59);
      expect(restored.mergeNeighborThresholdMinutes, 0);
    });

    test('值相等语义：逐字段比较（供变更检测）', () {
      final settings = ProfileSettings(
        reminderMinutes: 30,
        timezone: 'CST',
        updatedAt: DateTime.utc(2026, 8, 10, 4),
      );
      expect(settings, settings.copyWith(reminderMinutes: 30),
          reason: '字段全同视为相等');
      expect(settings == settings.copyWith(reminderMinutes: 60), isFalse,
          reason: '任一字段不同视为不相等');
      expect(settings.hashCode, settings.copyWith(reminderMinutes: 30).hashCode);
    });

    test('clearUserId 可将 userId 置空', () {
      final settings = ProfileSettings(
        userId: 'u1',
        timezone: 'CST',
        updatedAt: DateTime.utc(2026, 8, 10, 4),
      );
      expect(settings.copyWith(clearUserId: true).userId, isNull);
      expect(settings.copyWith(userId: 'u2').userId, 'u2');
      expect(
        settings.copyWith(userId: 'u2').copyWith(clearUserId: true).userId,
        isNull,
      );
    });

    test('round-trip 保真 + ReminderMethod 存储值', () {
      final settings = ProfileSettings(
        userId: 'u1',
        reminderMinutes: 30,
        reminderIntervalMinutes: 15,
        reminderMethod: ReminderMethod.banner,
        reminderTimeOfDayMinutes: 600,
        mergeNeighborThresholdMinutes: 3,
        timezone: 'CST',
        updatedAt: DateTime.utc(2026, 8, 10, 4),
      );
      final map = settings.toMap();
      expect(map['reminder_method'], 'banner');
      final restored = ProfileSettings.fromMap(map);
      expect(restored.reminderMinutes, 30);
      expect(restored.reminderIntervalMinutes, 15);
      expect(restored.reminderMethod, ReminderMethod.banner);
      expect(restored.reminderTimeOfDayMinutes, 600);
      expect(restored.mergeNeighborThresholdMinutes, 3);
      expect(restored.timezone, 'CST');
      // 未知/缺失/空串存储值回退 dialog
      expect(ReminderMethod.fromStorageValue('unknown'), ReminderMethod.dialog);
      expect(ReminderMethod.fromStorageValue(null), ReminderMethod.dialog);
      expect(ReminderMethod.fromStorageValue(''), ReminderMethod.dialog);
      expect(ReminderMethod.fromStorageValue(123), ReminderMethod.dialog,
          reason: '非字符串值也容错回退');
    });
  });
}
