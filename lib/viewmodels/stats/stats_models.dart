/// 统计聚合类型（纯类型，零 Flutter 依赖）。
library;

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
class StatsGroupRow {
  const StatsGroupRow({
    required this.id,
    required this.label,
    required this.totalDuration,
    required this.count,
    required this.color,
    this.depth = 0,
    this.ancestorIds = const [],
  });

  final String id;

  /// 展示标签；树聚合时为拼接的路径（如"工作 / 项目A"）。
  final String label;
  final Duration totalDuration;
  final int count;
  final int color;

  /// 树聚合时的缩进层级（0=顶层）。
  final int depth;

  /// 祖先链 id（根 → 父），供树形折叠/展开。
  final List<String> ancestorIds;

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
class StatsEntrySlice {
  const StatsEntrySlice({
    required this.activityId,
    required this.activityLabel,
    required this.activityColor,
    required this.primaryCategoryId,
    required this.primaryCategoryLabel,
    required this.primaryCategoryColor,
    this.linkedCategoryIds = const {},
    this.categoryAncestorIds = const [],
    required this.duration,
  }) : assert(duration >= Duration.zero, 'duration 必须非负');

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
