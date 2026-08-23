import 'package:flutter_test/flutter_test.dart';
import 'package:timetrack2/viewmodels/profile_settings.dart';
import 'package:timetrack2/viewmodels/tracking_rule.dart';

/// ProfileSettings 批次 4 新增通用偏好字段（schema v3）：
/// 往返序列化 / 默认值 / copyWith 钳制 / 缺键容错（旧互通文件与同步行）。
void main() {
  group('ProfileSettings v3 通用偏好', () {
    test('默认值：浅色主题/周一起始/24 时制/25 分钟/快速提醒开/后台关', () {
      final s = ProfileSettings.defaults();
      expect(s.themeMode, ThemeModeSetting.light);
      expect(s.weekStartDay, 1);
      expect(s.use24HourFormat, isTrue);
      expect(s.defaultRecordMinutes, 25);
      expect(s.quickReminderEnabled, isTrue);
      expect(s.backgroundTrackingEnabled, isFalse);
    });

    test('toMap/fromMap 往返保留全部新字段', () {
      final now = DateTime.utc(2026, 8, 23, 8);
      final s = ProfileSettings(
        themeMode: ThemeModeSetting.system,
        weekStartDay: 7,
        use24HourFormat: false,
        defaultRecordMinutes: 45,
        quickReminderEnabled: false,
        backgroundTrackingEnabled: true,
        timezone: 'CST',
        updatedAt: now,
      );
      final restored = ProfileSettings.fromMap(s.toMap());
      expect(restored.themeMode, ThemeModeSetting.system);
      expect(restored.weekStartDay, 7);
      expect(restored.use24HourFormat, isFalse);
      expect(restored.defaultRecordMinutes, 45);
      expect(restored.quickReminderEnabled, isFalse);
      expect(restored.backgroundTrackingEnabled, isTrue);
    });

    test('fromMap 缺键容错（旧版本互通文件）：布尔默认 true 的字段不丢', () {
      // use_24_hour_format/quick_reminder_enabled 默认 true——readBool 缺键
      // 恒回退 false，缺键必须走显式默认值分支（丢失会静默翻转用户偏好）。
      final now = DateTime.utc(2026, 8, 23, 8).toIso8601String();
      final restored = ProfileSettings.fromMap({
        'timezone': 'CST',
        'updated_at': now,
      });
      expect(restored.use24HourFormat, isTrue);
      expect(restored.quickReminderEnabled, isTrue);
      expect(restored.backgroundTrackingEnabled, isFalse);
      expect(restored.themeMode, ThemeModeSetting.light);
      expect(restored.weekStartDay, 1);
      expect(restored.defaultRecordMinutes, 25);
    });

    test('fromMap 损坏数据钳制：weekStartDay 越界回退合法域', () {
      final now = DateTime.utc(2026, 8, 23, 8).toIso8601String();
      final restored = ProfileSettings.fromMap({
        'week_start_day': 99,
        'default_record_minutes': 0,
        'timezone': 'CST',
        'updated_at': now,
      });
      expect(restored.weekStartDay, 7);
      expect(restored.defaultRecordMinutes, 1);
    });

    test('copyWith 钳制（release 无 assert 兜底）+ 未知主题值回退浅色', () {
      final base = ProfileSettings.defaults();
      expect(base.copyWith(weekStartDay: 0).weekStartDay, 1);
      expect(ThemeModeSetting.fromStorageValue('neon'), ThemeModeSetting.light);
      expect(ThemeModeSetting.fromStorageValue(null), ThemeModeSetting.light);
      expect(ThemeModeSetting.fromStorageValue('dark'), ThemeModeSetting.dark);
    });
  });

  group('TrackingRule.enabled（schema v3）', () {
    test('默认 true + toMap/fromMap 往返 + 缺键回退 true', () {
      final rule = TrackingRule.fromMap(const {
        'id': 'r1',
        'pattern': 'code.exe',
        'match_kind': 'process',
        'activity_id': 'a1',
        'updated_at': '2026-08-23T08:00:00.000Z',
      });
      expect(rule.enabled, isTrue, reason: '缺键（旧互通文件）回退 true');
      final disabled = rule.copyWith(enabled: false);
      expect(disabled.enabled, isFalse);
      final restored = TrackingRule.fromMap(disabled.toMap());
      expect(restored.enabled, isFalse, reason: '显式 false 往返不丢');
      expect(disabled.id, rule.id, reason: '启停是字段级变更不改 id');
    });
  });
}
