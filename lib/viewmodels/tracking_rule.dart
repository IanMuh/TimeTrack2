import '../utils/model_utils.dart';

/// 规则匹配类型（持久化存储值统一为**小写 snake_case**，与 action_log 一致）。
///
/// - `process`：按进程名精确/通配匹配（如 `chrome.exe`、`code.exe`）——主 key，
///   跨会话稳定；
/// - `title`：按窗口标题模式匹配（正则/包含，区分同应用内不同文档/页面）——
///   辅助维度，标题为空或不可信时降级纯进程名匹配。
enum TrackingRuleMatchKind {
  process('process'),
  title('title'),
  /// 未知匹配类型（读取到未来版本/其它设备写入的未知值）——避免反序列化崩溃；
  /// 匹配器对 unknown 规则一律不命中（防未知类型规则意外触发错误映射）。
  unknown('unknown');

  const TrackingRuleMatchKind(this.storageValue);

  final String storageValue;

  static TrackingRuleMatchKind fromStorageValue(Object? value) {
    final text = value is String ? value : null;
    return TrackingRuleMatchKind.values.firstWhere(
      (kind) => kind.storageValue == text,
      orElse: () => TrackingRuleMatchKind.unknown,
    );
  }
}

/// 领域模型：后台自动记录映射规则（进程/窗口标题模式 → 活动）。
///
/// - `syncEnabled`：**per-rule 同步开关**——true 的规则参与云同步（schema.sql
///   tracking_rules 表 + RLS + 引擎行级过滤），false 仅存本地（不进远端、
///   不被远端覆盖）；
/// - `deletedAt` 软删（LWW 删除永远赢），与业务表一致。
class TrackingRule {
  const TrackingRule({
    required this.id,
    this.userId,
    required this.pattern,
    required this.matchKind,
    required this.activityId,
    this.syncEnabled = true,
    required this.updatedAt,
    this.deletedAt,
  });

  final String id;
  final String? userId;
  final String pattern;
  final TrackingRuleMatchKind matchKind;
  final String activityId;
  final bool syncEnabled;
  final DateTime updatedAt;
  final DateTime? deletedAt;

  bool get isDeleted => deletedAt != null;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is TrackingRule && runtimeType == other.runtimeType && id == other.id;

  @override
  int get hashCode => id.hashCode;

  TrackingRule copyWith({
    String? id,
    String? userId,
    bool clearUserId = false,
    String? pattern,
    TrackingRuleMatchKind? matchKind,
    String? activityId,
    bool? syncEnabled,
    DateTime? updatedAt,
    DateTime? deletedAt,
    bool clearDeletedAt = false,
  }) {
    return TrackingRule(
      id: id ?? this.id,
      userId: clearUserId ? null : userId ?? this.userId,
      pattern: pattern ?? this.pattern,
      matchKind: matchKind ?? this.matchKind,
      activityId: activityId ?? this.activityId,
      syncEnabled: syncEnabled ?? this.syncEnabled,
      updatedAt: updatedAt ?? this.updatedAt,
      deletedAt: clearDeletedAt ? null : deletedAt ?? this.deletedAt,
    );
  }

  Map<String, Object?> toMap() {
    return {
      'id': id,
      'user_id': userId,
      'pattern': pattern,
      'match_kind': matchKind.storageValue,
      'activity_id': activityId,
      'sync_enabled': syncEnabled,
      'updated_at': updatedAt.toUtc().toIso8601String(),
      'deleted_at': deletedAt?.toUtc().toIso8601String(),
    };
  }

  static TrackingRule fromMap(Map<String, Object?> map) {
    final id = map['id'];
    if (id is! String || id.isEmpty) {
      throw const FormatException('TrackingRule.fromMap: id 缺失或非法');
    }
    return TrackingRule(
      id: id,
      userId: readNullableString(map['user_id']),
      pattern: readString(map['pattern']),
      matchKind: TrackingRuleMatchKind.fromStorageValue(map['match_kind']),
      activityId: readString(map['activity_id']),
      syncEnabled: readBool(map['sync_enabled']),
      updatedAt: readDateTime(map['updated_at']),
      deletedAt: readNullableDateTime(map['deleted_at']),
    );
  }
}
