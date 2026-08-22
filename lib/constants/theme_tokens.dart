/// 主题令牌色板（纯 int 色值，无 Flutter 依赖）。
///
/// 色值来源：`design/DESIGN_LANG.md`（高保真设计稿统一设计语言）——
/// zinc 中性基底 + indigo-600 品牌主色 + 8 色活动板（Tailwind 500/400 两档，
/// 深色下自动落到 400 保可读）；"未分配"活动固定 zinc-400。
/// 深/浅两套，语义命名（背景/表面/描边/文字）。theme 组装见
/// `components/app_theme.dart`，本文件只存值。
library;

/// 活动色板（8 色 + 未分配灰）。
///
/// 每个颜色给浅/深两档（Tailwind 500 / 400，去色相更亮一档），供活动色点、
/// 浅染卡片底、图表图例等处按主题取用；语义顺序与设计稿一致。
class ActivityPalette {
  ActivityPalette._();

  static const rose = (light: 0xfff43f5e, dark: 0xfffb7185);
  static const orange = (light: 0xfff97316, dark: 0xfffb923c);
  static const amber = (light: 0xfff59e0b, dark: 0xfffbbf24);
  static const emerald = (light: 0xff10b981, dark: 0xff34d399);
  static const teal = (light: 0xff14b8a6, dark: 0xff2dd4bf);
  static const sky = (light: 0xff0ea5e9, dark: 0xff38bdf8);
  static const indigo = (light: 0xff6366f1, dark: 0xff818cf8);
  static const violet = (light: 0xff8b5cf6, dark: 0xffa78bfa);

  /// 设计稿规定的枚举顺序（色板展示、统计图例、新建活动选色器共用）。
  static const all = [rose, orange, amber, emerald, teal, sky, indigo, violet];

  /// "未分配"活动固定灰（zinc-400，深浅两档同值即可）。
  static const unassigned = 0xffa1a1aa;

  /// 取某色在给定明度下的色值（dark = true 取 400 档，否则取 500 档）。
  static int of(({int light, int dark}) color, {required bool dark}) =>
      dark ? color.dark : color.light;
}

/// 浅色主题令牌。
class LightThemeTokens {
  LightThemeTokens._();

  static const background = 0xfffafafa; // zinc-50
  static const surface = 0xffffffff; // white
  static const surfaceMuted = 0xfff4f4f5; // zinc-100
  static const outline = 0xffe4e4e7; // zinc-200
  static const outlineVariant = 0xffd4d4d8; // zinc-300（焦点/选中描边）
  static const text = 0xff18181b; // zinc-900
  static const mutedText = 0xff71717a; // zinc-500
  static const primary = 0xff4f46e5; // indigo-600
  static const accentText = 0xff4f46e5; // indigo-600（强调文字/链接）
  static const secondary = 0xff4f46e5; // 两侧一致（accent 风格，测试契约）
  static const shadow = 0x1a18181b;
}

/// 深色主题令牌。
class DarkThemeTokens {
  DarkThemeTokens._();

  static const background = 0xff09090b; // zinc-950
  static const surface = 0xff18181b; // zinc-900
  static const surfaceMuted = 0xff27272a; // zinc-800
  static const outline = 0xff27272a; // zinc-800
  /// 深色下 `outlineVariant`（zinc-700）比 `outline`（zinc-800）更亮——与浅色
  /// 套同向，用于选中/焦点描边需更高对比；语义"variant=变体"，两侧同向。
  static const outlineVariant = 0xff3f3f46; // zinc-700
  static const text = 0xfffafafa; // zinc-50
  static const mutedText = 0xffa1a1aa; // zinc-400
  static const primary = 0xff4f46e5; // indigo-600（实心按钮两主题一致）
  static const accentText = 0xff818cf8; // indigo-400（深色强调文字更亮）
  static const secondary = 0xff4f46e5; // 两侧一致（accent 风格，测试契约）
  static const shadow = 0x40000000;
}
