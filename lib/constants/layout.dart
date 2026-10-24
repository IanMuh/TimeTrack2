/// 自适应布局令牌（UI 重建 PR-A）。
///
/// 页面与壳层统一从这里取断点/内容宽度/间距，避免魔法数散落
/// （旧实现散落 600/840/1024/208/260/320/420/760 等硬编码）。
abstract final class AppBreakpoints {
  /// 紧凑档上界：< 600 单列、紧凑控件密度。
  static const double compact = 600;

  /// 侧栏断点（Material 逻辑像素）：≥ 840 用左侧导航，否则底部导航。
  static const double expanded = 840;

  /// 宽档：≥ 1280 多列列表、图表并排。
  static const double wide = 1280;
}

/// 各页面内容最大宽度（按语义分配，不再全壳统一 1024）。
abstract final class AppContentWidth {
  /// 计时页：活动多列列表 + 焦点区，宽屏可铺开到 1440。
  static const double timer = 1440;

  /// 今日页：头部指标 + 分组列表 + 宽屏右侧时间线预览。
  static const double today = 1120;

  /// 统计页：筛选栏 + 图表/聚合区并排。
  static const double stats = 1440;

  /// 设置页：分区导航 + 分区正文。
  static const double settings = 1280;

  /// 表单/阅读型内容（设置分区正文、编辑器弹层）。
  static const double form = 760;
}

/// 间距令牌（4 的倍数）。
abstract final class AppSpacing {
  static const double xs = 4;
  static const double sm = 8;
  static const double md = 12;
  static const double lg = 16;
  static const double xl = 24;
  static const double xxl = 32;
}
