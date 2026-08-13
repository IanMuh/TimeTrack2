import 'package:flutter_test/flutter_test.dart';
import 'package:timetrack2/viewmodels/tracking_rule.dart';

void main() {
  group('TrackingRule', () {
    final t0 = DateTime.utc(2026, 8, 12, 4, 0);
    final rule = TrackingRule(
      id: 'r1',
      userId: 'u1',
      pattern: 'chrome.exe',
      matchKind: TrackingRuleMatchKind.process,
      activityId: 'a1',
      syncEnabled: true,
      updatedAt: t0,
    );

    test('id 严格校验：缺失/空串/非字符串 → FormatException', () {
      final times = {'updated_at': '2026-08-12T04:00:00Z'};
      expect(() => TrackingRule.fromMap(times), throwsFormatException,
          reason: '缺 id');
      expect(
        () => TrackingRule.fromMap({'id': '', ...times}),
        throwsFormatException,
        reason: '空串 id',
      );
      expect(
        () => TrackingRule.fromMap({'id': 123, ...times}),
        throwsFormatException,
        reason: '非字符串 id',
      );
    });

    test('缺键容错：pattern/activity_id 缺省空串、sync_enabled 回退 false、match_kind 回退 unknown', () {
      final restored = TrackingRule.fromMap({
        'id': 'r',
        'updated_at': '2026-08-12T04:00:00Z',
      });
      expect(restored.pattern, '');
      expect(restored.activityId, '');
      // sync_enabled 缺键 → false（readBool 契约 + 隐私安全）：字段丢失时保守
      // 不进云，防本地偏好被误推上云。注意与**列默认 true** 的区别——列默认
      // 管"新建行"（用户建规则默认进云），缺键回退管"反序列化损坏/外部数据"
      //（丢字段保守不进云），两者语义不同。
      expect(restored.syncEnabled, isFalse, reason: 'sync_enabled 缺键回退 false');
      // match_kind 缺键/未知 → unknown（匹配器不命中，防未知类型规则误触发）
      expect(restored.matchKind, TrackingRuleMatchKind.unknown);
      expect(restored.deletedAt, isNull);
    });

    test('match_kind 存储值解析（process/title/未知）', () {
      for (final (kind, value) in [
        (TrackingRuleMatchKind.process, 'process'),
        (TrackingRuleMatchKind.title, 'title'),
      ]) {
        expect(TrackingRuleMatchKind.fromStorageValue(value), kind,
            reason: '$value → $kind');
      }
      expect(TrackingRuleMatchKind.fromStorageValue('bogus'),
          TrackingRuleMatchKind.unknown);
      expect(TrackingRuleMatchKind.fromStorageValue(null),
          TrackingRuleMatchKind.unknown);
    });

    test('round-trip 保真（含 sync_enabled=false 与删除状态）', () {
      final localOnly = rule.copyWith(
        syncEnabled: false,
        deletedAt: DateTime.utc(2026, 8, 13, 4),
      );
      // **序列化产物断言（r8）**：远端 tracking_rules 表该列默认 true——若
      // toMap 回归为省略 sync_enabled=false 字段，推送载荷会让远端把本地-only
      // 规则误判为可同步（隐私/同步语义错误）；fromMap 对缺键回退 false 会
      // 掩盖该回归，须直接断言序列化产物携带该键。
      final serialized = localOnly.toMap();
      expect(serialized['sync_enabled'], isFalse,
          reason: '序列化产物必须携带 sync_enabled=false（防缺键回退掩盖回归）');
      final restored = TrackingRule.fromMap(serialized);
      expect(restored.id, 'r1');
      expect(restored.userId, 'u1');
      expect(restored.pattern, 'chrome.exe');
      expect(restored.matchKind, TrackingRuleMatchKind.process);
      expect(restored.activityId, 'a1');
      expect(restored.syncEnabled, isFalse, reason: 'sync_enabled=false 保真');
      expect(restored.updatedAt.isAtSameMomentAs(t0), isTrue);
      expect(restored.deletedAt!.isAtSameMomentAs(localOnly.deletedAt!), isTrue);
      expect(restored.isDeleted, isTrue);
    });

    test('等值比较以 id 为准', () {
      final same = TrackingRule(
        id: 'r1',
        pattern: 'other.exe',
        matchKind: TrackingRuleMatchKind.title,
        activityId: 'a2',
        updatedAt: t0,
      );
      expect(same == rule, isTrue, reason: '同 id 视为同一规则');
      expect(same.hashCode, rule.hashCode);
      // 负例边界：不同 id 必须不相等（防比较逻辑退化为恒等或误删 id 之外的
      // 比较）。**注**：hashCode 契约只要求"相等对象 hashCode 相同"，不要求
      // "不同对象 hashCode 不同"（散列碰撞合法）——故不在此断言 hashCode 负例。
      final other = TrackingRule(
        id: 'r2',
        pattern: 'chrome.exe',
        matchKind: TrackingRuleMatchKind.process,
        activityId: 'a1',
        updatedAt: t0,
      );
      expect(other == rule, isFalse, reason: '不同 id 视为不同规则');
    });

    test('updated_at 严格校验：缺失/无时区偏移/非法 → FormatException（不伪造时间戳）', () {
      // readDateTime 契约：updated_at 是 LWW 决胜字段，缺键/无偏移/非法一律
      // 抛错、绝不回退伪造时间戳（防损坏数据在 LWW 冲突中胜出）。
      expect(
        () => TrackingRule.fromMap({'id': 'r'}),
        throwsFormatException,
        reason: 'updated_at 缺失',
      );
      expect(
        () => TrackingRule.fromMap({
          'id': 'r',
          'updated_at': '2026-08-12T04:00:00', // 无时区偏移
        }),
        throwsFormatException,
        reason: 'updated_at 无时区偏移',
      );
      expect(
        () => TrackingRule.fromMap({
          'id': 'r',
          'updated_at': 'not-a-date',
        }),
        throwsFormatException,
        reason: 'updated_at 非法',
      );
    });
  });
}
