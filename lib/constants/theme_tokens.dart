/// 主题令牌色板（纯 int 色值，无 Flutter 依赖）。
///
/// 迁移自老项目 `ui/theme_tokens.dart` 的色板；新项目 theme 组装（阶段 4）
/// 将 `Color(color)` 包装使用。深/浅两套，语义命名（背景/表面/描边/文字）。
library;

/// 浅色主题令牌。
class LightThemeTokens {
  LightThemeTokens._();

  static const background = 0xfff8fafc;
  static const surface = 0xffffffff;
  static const surfaceMuted = 0xfff1f5f9;
  static const outline = 0xffcbd5e1;
  static const outlineVariant = 0xffe2e8f0;
  static const text = 0xff0f172a;
  static const mutedText = 0xff64748b;
  static const secondary = 0xff14b8a6;
  static const shadow = 0x1a0f172a;
}

/// 深色主题令牌。
class DarkThemeTokens {
  DarkThemeTokens._();

  static const background = 0xff0f172a;
  static const surface = 0xff111827;
  static const surfaceMuted = 0xff1f2937;
  static const outline = 0xff334155;

  /// 注意：深色下 `outlineVariant`（0xff475569）比 `outline`（0xff334155）更亮
  /// —— 这是**有意设计**（与浅色套相反）：深色背景上 variant 用于选中/焦点描边，
  /// 需要更高对比度可见；语义"variant=变体"，不保证两侧方向一致。
  /// 值迁移自老项目 `ui/theme_tokens.dart`，阶段 4 组装 theme 时保持此对比。
  static const outlineVariant = 0xff475569;
  static const text = 0xfff8fafc;
  static const mutedText = 0xffcbd5e1;
  static const secondary = 0xff14b8a6;
  static const shadow = 0x40000000;
}
