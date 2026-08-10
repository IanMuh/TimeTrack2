import 'package:flutter_test/flutter_test.dart';
import 'package:timetrack2/viewmodels/action_log.dart';

void main() {
  group('ActionLog', () {
    test('严格校验：缺失 updated_at/occurred_at 抛 FormatException', () {
      expect(() => ActionLog.fromMap({'id': 'log1'}), throwsFormatException);
      // 分别缺失单个必填时间字段，定位是哪个字段的校验在生效
      expect(
        () => ActionLog.fromMap({
          'id': 'log1',
          'occurred_at': '2026-08-10T04:00:00Z',
        }),
        throwsFormatException,
        reason: '仅缺 updated_at 也应抛错',
      );
      expect(
        () => ActionLog.fromMap({
          'id': 'log1',
          'updated_at': '2026-08-10T04:00:00Z',
        }),
        throwsFormatException,
        reason: '仅缺 occurred_at 也应抛错',
      );
      // 非法时间字符串
      expect(
        () => ActionLog.fromMap({
          'id': 'log1',
          'updated_at': 'not-a-date',
          'occurred_at': '2026-08-10T04:00:00Z',
        }),
        throwsFormatException,
      );
      expect(
        () => ActionLog.fromMap({
          'id': 'log1',
          'updated_at': '2026-08-10T04:00:00Z',
          'occurred_at': 'not-a-date',
        }),
        throwsFormatException,
      );
      final restored = ActionLog.fromMap({
        'id': 'log1',
        'updated_at': '2026-08-10T04:00:00Z',
        'occurred_at': '2026-08-10T04:00:00Z',
      });
      expect(restored.id, 'log1');
      expect(restored.actionType, ActionType.unknown,
          reason: '缺省 action_type 回退 unknown 而非伪造 switch');
      expect(restored.activityId, isNull);
      expect(restored.entryId, isNull);
      expect(restored.message, '');
      expect(restored.deviceId, 'unknown');
      expect(restored.deletedAt, isNull);
    });

    test('非空 deletedAt 序列化保真 + isDeleted getter', () {
      final log = ActionLog(
        id: 'log1',
        actionType: ActionType.delete,
        occurredAt: DateTime.utc(2026, 8, 10, 4),
        deviceId: 'dev',
        updatedAt: DateTime.utc(2026, 8, 10, 4),
        deletedAt: DateTime.utc(2026, 8, 10, 4, 30),
      );
      expect(log.isDeleted, isTrue);
      final restored = ActionLog.fromMap(log.toMap());
      expect(restored.isDeleted, isTrue);
      expect(
        restored.deletedAt!.isAtSameMomentAs(DateTime.utc(2026, 8, 10, 4, 30)),
        isTrue,
      );
      final cleared = restored.copyWith(clearDeletedAt: true);
      expect(cleared.isDeleted, isFalse);
      expect(cleared.deletedAt, isNull);
    });

    test('非法类型容错：非关键字段类型错误回退默认，不抛异常', () {
      final restored = ActionLog.fromMap({
        'id': 'log1',
        'updated_at': '2026-08-10T04:00:00Z',
        'occurred_at': '2026-08-10T04:00:00Z',
        'user_id': 123,
        'action_type': 456,
        'activity_id': 789,
        'entry_id': 1011,
        'message': 1213,
        'device_id': 1415, // 数字 device_id → 回退 'unknown'
      });
      expect(restored.userId, isNull);
      expect(restored.actionType, ActionType.unknown);
      expect(restored.activityId, isNull);
      expect(restored.entryId, isNull);
      expect(restored.message, '');
      expect(restored.deviceId, 'unknown');
    });

    test('时间字段传 null / 数值 → FormatException（统一异常契约）', () {
      // null（键存在但值 null）
      expect(
        () => ActionLog.fromMap({
          'id': 'log1',
          'updated_at': null,
          'occurred_at': '2026-08-10T04:00:00Z',
        }),
        throwsFormatException,
      );
      expect(
        () => ActionLog.fromMap({
          'id': 'log1',
          'updated_at': '2026-08-10T04:00:00Z',
          'occurred_at': null,
        }),
        throwsFormatException,
      );
      // 数值（非字符串）
      expect(
        () => ActionLog.fromMap({
          'id': 'log1',
          'updated_at': 123,
          'occurred_at': '2026-08-10T04:00:00Z',
        }),
        throwsFormatException,
      );
    });

    test('round-trip 保真：全字段断言', () {
      final log = ActionLog(
        id: 'log1',
        userId: 'u1',
        actionType: ActionType.split,
        activityId: 'a1',
        entryId: 'e1',
        message: '切割时间段',
        occurredAt: DateTime.utc(2026, 8, 10, 4),
        deviceId: 'dev-1',
        updatedAt: DateTime.utc(2026, 8, 10, 4, 30),
      );
      final map = log.toMap();
      expect(map['action_type'], 'split');
      final restored = ActionLog.fromMap(map);
      expect(restored.id, 'log1');
      expect(restored.userId, 'u1');
      expect(restored.actionType, ActionType.split);
      expect(restored.activityId, 'a1');
      expect(restored.entryId, 'e1');
      expect(restored.message, '切割时间段');
      expect(restored.deviceId, 'dev-1');
      expect(restored.occurredAt.isAtSameMomentAs(DateTime.utc(2026, 8, 10, 4)),
          isTrue);
      expect(restored.updatedAt.isAtSameMomentAs(DateTime.utc(2026, 8, 10, 4, 30)),
          isTrue);
      expect(restored.deletedAt, isNull);
    });

    test('本地时间（非 UTC 构造）round-trip 保持绝对时刻', () {
      final local = DateTime(2026, 8, 10, 12, 30); // 本地时区
      final log = ActionLog(
        id: 'log1',
        actionType: ActionType.stop,
        occurredAt: local,
        deviceId: 'dev',
        updatedAt: local,
      );
      final restored = ActionLog.fromMap(log.toMap());
      expect(restored.occurredAt.isAtSameMomentAs(local), isTrue);
      expect(restored.updatedAt.isAtSameMomentAs(local), isTrue);
    });

    test('未知/缺失/非字符串 action_type 回退 unknown', () {
      expect(ActionType.fromStorageValue('nope'), ActionType.unknown);
      expect(ActionType.fromStorageValue(null), ActionType.unknown);
      expect(ActionType.fromStorageValue(''), ActionType.unknown);
      expect(ActionType.fromStorageValue(123), ActionType.unknown);
    });

    test('activityDelete 与 category 系列存储值为小写 snake_case', () {
      const cases = <(ActionType, String)>[
        (ActionType.activityDelete, 'activity_delete'),
        (ActionType.categoryCreate, 'category_create'),
        (ActionType.categoryUpdate, 'category_update'),
        (ActionType.categoryDelete, 'category_delete'),
      ];
      for (final (type, storageValue) in cases) {
        expect(type.storageValue, storageValue);
        // 读取端回环
        expect(ActionType.fromStorageValue(storageValue), type);
      }
      // 旧值兼容：历史数据中的 camelCase 'activityDelete' 必须仍能识别为 activityDelete
      expect(
        ActionType.fromStorageValue('activityDelete'),
        ActionType.activityDelete,
      );
    });

    test('copyWith：普通更新与保持原值分支', () {
      final log = ActionLog(
        id: 'log1',
        userId: 'u1',
        activityId: 'a1',
        entryId: 'e1',
        actionType: ActionType.edit,
        occurredAt: DateTime.utc(2026, 8, 10, 4),
        deviceId: 'dev',
        updatedAt: DateTime.utc(2026, 8, 10, 4),
      );
      // 普通更新
      final updated = log.copyWith(
        userId: 'u2',
        actionType: ActionType.delete,
        message: '新消息',
      );
      expect(updated.userId, 'u2');
      expect(updated.actionType, ActionType.delete);
      expect(updated.message, '新消息');
      // 未传参数保持原值
      expect(updated.id, 'log1');
      expect(updated.activityId, 'a1');
      expect(updated.entryId, 'e1');
      expect(updated.deviceId, 'dev');
    });

    test('copyWith clear 标志可将关联字段置空', () {
      final log = ActionLog(
        id: 'log1',
        userId: 'u1',
        activityId: 'a1',
        entryId: 'e1',
        actionType: ActionType.edit,
        occurredAt: DateTime.utc(2026, 8, 10),
        deviceId: 'dev',
        updatedAt: DateTime.utc(2026, 8, 10),
      );
      final cleared = log.copyWith(
        clearUserId: true,
        clearActivityId: true,
        clearEntryId: true,
      );
      expect(cleared.userId, isNull);
      expect(cleared.activityId, isNull);
      expect(cleared.entryId, isNull);
      expect(cleared.id, 'log1');
      expect(cleared.actionType, ActionType.edit);
      // clear 标志优先于普通赋值（组合语义）
      final combo = log.copyWith(userId: 'u2', clearUserId: true);
      expect(combo.userId, isNull, reason: 'clear 标志无条件优先');
    });
  });
}
