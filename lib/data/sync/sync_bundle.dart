import '../../viewmodels/action_log.dart';
import '../../viewmodels/activity.dart';
import '../../viewmodels/activity_category.dart';
import '../../viewmodels/profile_settings.dart';
import '../../viewmodels/time_entry.dart';

/// 同步包（LAN / 文件互通共用同一数据形态）。
///
/// 老项目语义迁移：全量快照 + 行级 LWW 合并；`schema_version` 当前为 2，
/// 解码时 1..2 接受、其他拒绝（校验先于任何写库）。
/// 元素复用 viewmodels 的 `toMap`/`fromMap`（缺键容错）。
class SyncBundle {
  const SyncBundle({
    required this.schemaVersion,
    required this.exportedAt,
    required this.sourceDeviceId,
    this.activities = const [],
    this.categories = const [],
    this.categoryLinks = const [],
    this.timeEntries = const [],
    this.actionLogs = const [],
    this.profileSettings,
  });

  /// 当前支持的 schema 版本。
  static const currentSchemaVersion = 2;

  /// 可接受的版本范围（1..2）。
  static const minSchemaVersion = 1;
  static const maxSchemaVersion = 2;

  final int schemaVersion;
  final DateTime exportedAt;
  final String sourceDeviceId;
  final List<Activity> activities;
  final List<ActivityCategory> categories;
  final List<ActivityCategoryLink> categoryLinks;
  final List<TimeEntry> timeEntries;
  final List<ActionLog> actionLogs;
  final ProfileSettings? profileSettings;

  Map<String, Object?> toJson() {
    return {
      'schema_version': schemaVersion,
      'exported_at': exportedAt.toUtc().toIso8601String(),
      'source_device_id': sourceDeviceId,
      'activities': activities.map((a) => a.toMap()).toList(),
      'categories': categories.map((c) => c.toMap()).toList(),
      'category_links': categoryLinks.map((l) => l.toMap()).toList(),
      'time_entries': timeEntries.map((e) => e.toMap()).toList(),
      'action_logs': actionLogs.map((l) => l.toMap()).toList(),
      'profile_settings': profileSettings?.toMap(),
    };
  }

  static SyncBundle fromJson(Map<String, Object?> json) {
    return SyncBundle(
      schemaVersion: _requiredSchemaVersion(json),
      exportedAt: _requiredDateTime(json, 'exported_at'),
      sourceDeviceId: _requiredString(json, 'source_device_id'),
      activities: List.unmodifiable(
          _parseList(json, 'activities', Activity.fromMap)),
      categories: List.unmodifiable(
          _parseList(json, 'categories', ActivityCategory.fromMap)),
      categoryLinks: List.unmodifiable(
          _parseList(json, 'category_links', ActivityCategoryLink.fromMap)),
      timeEntries: List.unmodifiable(
          _parseList(json, 'time_entries', TimeEntry.fromMap)),
      actionLogs: List.unmodifiable(
          _parseList(json, 'action_logs', ActionLog.fromMap)),
      profileSettings: _parseOptional(
        json['profile_settings'],
        ProfileSettings.fromMap,
      ),
    );
  }

  static List<T> _parseList<T>(
    Map<String, Object?> json,
    String key,
    T Function(Map<String, Object?>) fromMap,
  ) {
    final raw = json[key];
    if (raw == null) return const [];
    if (raw is! List) {
      throw FormatException('bundle 字段 $key 应为数组');
    }
    return [
      for (final item in raw)
        if (item is Map<String, Object?>)
          fromMap(item)
        else
          throw FormatException('bundle 字段 $key 的元素应为对象'),
    ];
  }

  static T? _parseOptional<T>(
    Object? raw,
    T Function(Map<String, Object?>) fromMap,
  ) {
    if (raw == null) return null;
    if (raw is! Map<String, Object?>) {
      throw const FormatException('profile_settings 应为对象');
    }
    return fromMap(raw);
  }

  static DateTime _requiredDateTime(Map<String, Object?> json, String key) {
    final value = json[key];
    if (value is! String) {
      throw FormatException('bundle 必填字段缺失或非法：$key');
    }
    final parsed = DateTime.tryParse(value);
    if (parsed == null) {
      throw FormatException('bundle 必填字段非法：$key');
    }
    return parsed.toLocal();
  }

  static String _requiredString(Map<String, Object?> json, String key) {
    final value = json[key];
    if (value is! String || value.trim().isEmpty) {
      throw FormatException('bundle 必填字段缺失或非法：$key');
    }
    return value.trim();
  }

  /// 严格校验 schema_version：整数且在 [minSchemaVersion, maxSchemaVersion]。
  static int _requiredSchemaVersion(Map<String, Object?> json) {
    final raw = json['schema_version'];
    if (raw is! int) {
      throw const FormatException('bundle 缺少合法的整数 schema_version');
    }
    if (raw < minSchemaVersion || raw > maxSchemaVersion) {
      throw FormatException(
        'bundle schema 版本 $raw 不受支持'
        '（支持 $minSchemaVersion..$maxSchemaVersion）',
      );
    }
    return raw;
  }
}
