import 'package:flutter_test/flutter_test.dart';
import 'package:timetrack2/viewmodels/action_log.dart';

void main() {
  group('ActionLog', () {
    test('严格校验：缺失 updated_at/occurred_at 抛 FormatException', () {
      expect(() => ActionLog.fromMap({'id': 'log1'}), throwsFormatException);
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
      });
      expect(restored.userId, isNull);
      expect(restored.actionType, ActionType.unknown);
      expect(restored.activityId, isNull);
      expect(restored.entryId, isNull);
      expect(restored.message, '');
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
    });
  });
}
