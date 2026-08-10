/// 统计聚合类型（纯类型，零 Flutter 依赖）。
library;

/// 负时长归一化：release 下 [StatsEntrySlice] 的 assert 被移除，此处兜底——
/// 任何负时长统一归为 0，避免损坏数据被误归入错误时长桶。可独立测试。
Duration normalizeNonNegativeDuration(Duration duration) {
  return duration < Duration.zero ? Duration.zero : duration;
}

/// 统计聚合维度。
///
/// 老项目 4 维 + 一期新增 `categoryTree`（树聚合：按分类祖先链归并，
/// label 拼接路径，UI 缩进展示，覆盖全部屏宽）。
enum StatsDimension {
  /// 按活动归并。
  activity,

  /// 按主分类归并。
  primaryCategory,

  /// 按时长桶归并（<30m / 30m-1h / 1-3h / 3h+）。
  durationBucket,

  /// 主分类 × 时长桶组合。
  primaryCategoryAndDurationBucket,

  /// 树聚合：按分类祖先链归并，支持层级折叠/展开。
  categoryTree,
}

/// 统计分组行（聚合结果的一行）。
///
/// 值相等：按 [id] 判定（同一分组行视作相同，用于集合去重/变更判定）。
class StatsGroupRow {
  StatsGroupRow({
    required this.id,
    required this.label,
    required this.totalDuration,
    required this.count,
    required this.color,
    this.depth = 0,
    List<String> ancestorIds = const [],
  }) : ancestorIds = List.unmodifiable(ancestorIds);

  final String id;

  /// 展示标签；树聚合时为拼接的路径（如"工作 / 项目A"）。
  final String label;
  final Duration totalDuration;
  final int count;
  final int color;

  /// 树聚合时的缩进层级（0=顶层）。
  final int depth;

  /// 祖先链 id（根 → 父），供树形折叠/展开。不可变视图。
  final List<String> ancestorIds;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is StatsGroupRow && runtimeType == other.runtimeType && id == other.id;

  @override
  int get hashCode => id.hashCode;

  StatsGroupRow copyWith({
    String? id,
    String? label,
    Duration? totalDuration,
    int? count,
    int? color,
    int? depth,
    List<String>? ancestorIds,
  }) {
    return StatsGroupRow(
      id: id ?? this.id,
      label: label ?? this.label,
      totalDuration: totalDuration ?? this.totalDuration,
      count: count ?? this.count,
      color: color ?? this.color,
      depth: depth ?? this.depth,
      ancestorIds: ancestorIds ?? this.ancestorIds,
    );
  }
}

/// 统计计算输入：单条时间条目切出的片段。
///
/// 值相等：按全部字段比较（切片是统计聚合的输入单元，语义上应可判定"同一条"）。
class StatsEntrySlice {
  StatsEntrySlice({
    required this.activityId,
    required this.activityLabel,
    required this.activityColor,
    required this.primaryCategoryId,
    required this.primaryCategoryLabel,
    required this.primaryCategoryColor,
    Set<String> linkedCategoryIds = const {},
    List<String> categoryAncestorIds = const [],
    required Duration duration,
  })  : assert(
          (primaryCategoryId == null &&
                  primaryCategoryLabel == null &&
                  primaryCategoryColor == null) ||
              (primaryCategoryId != null &&
                  primaryCategoryLabel != null &&
                  primaryCategoryColor != null),
          'primaryCategory 的 id/label/color 必须同时存在或同时为 null',
        ),
        assert(duration >= Duration.zero, 'duration 必须非负（debug 快速失败）'),
        linkedCategoryIds = Set.unmodifiable(linkedCategoryIds),
        categoryAncestorIds = List.unmodifiable(categoryAncestorIds),
        // 生产环境防御：负时长一律归一为 0（assert 在 release 被移除，此处兜底）。
        duration = normalizeNonNegativeDuration(duration);

  final String activityId;
  final String activityLabel;
  final int activityColor;
  final String? primaryCategoryId;
  final String? primaryCategoryLabel;
  final int? primaryCategoryColor;
  final Set<String> linkedCategoryIds;

  /// 主分类的祖先链 id（根 → 父），供树聚合归并。
  final List<String> categoryAncestorIds;
  final Duration duration;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is StatsEntrySlice &&
          runtimeType == other.runtimeType &&
          activityId == other.activityId &&
          activityLabel == other.activityLabel &&
          activityColor == other.activityColor &&
          primaryCategoryId == other.primaryCategoryId &&
          primaryCategoryLabel == other.primaryCategoryLabel &&
          primaryCategoryColor == other.primaryCategoryColor &&
          _setEquals(linkedCategoryIds, other.linkedCategoryIds) &&
          _listEquals(categoryAncestorIds, other.categoryAncestorIds) &&
          duration == other.duration;

  @override
  int get hashCode => Object.hash(
        activityId,
        activityLabel,
        activityColor,
        primaryCategoryId,
        primaryCategoryLabel,
        primaryCategoryColor,
        duration,
        Object.hashAll(linkedCategoryIds.toList()..sort()),
        Object.hashAll(categoryAncestorIds),
      );

  static bool _setEquals(Set<String> first, Set<String> second) {
    if (first.length != second.length) return false;
    return first.containsAll(second);
  }

  static bool _listEquals(List<String> first, List<String> second) {
    if (first.length != second.length) return false;
    for (var i = 0; i < first.length; i++) {
      if (first[i] != second[i]) return false;
    }
    return true;
  }

  String get durationBucketLabel {
    if (duration < const Duration(minutes: 30)) return '<30m';
    if (duration < const Duration(hours: 1)) return '30m-1h';
    if (duration < const Duration(hours: 3)) return '1-3h';
    return '3h+';
  }

  int get durationBucketColor {
    return switch (durationBucketLabel) {
      '<30m' => 0xff94a3b8,
      '30m-1h' => 0xff0ea5e9,
      '1-3h' => 0xff7c3aed,
      '3h+' => 0xffdc2626,
      _ => throw StateError('Unexpected bucket label: $durationBucketLabel'),
    };
  }
}
