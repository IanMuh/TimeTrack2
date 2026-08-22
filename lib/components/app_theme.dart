import 'package:flutter/material.dart';

import '../constants/theme_tokens.dart';

/// 组装全局主题（阶段 4 批次 0，按 design/DESIGN_LANG.md）。
///
/// - 字体栈：Inter → Segoe UI / PingFang SC / Microsoft YaHei（桌面优先
///   Inter，中文回退系统字体）；
/// - 圆角：卡片/对话框 16dp（rounded-2xl）、按钮/输入 8dp（rounded-lg）；
/// - 品牌主色 indigo-600（实心按钮两主题一致），深色强调字色 indigo-400；
/// - 无重阴影（shadow-sm 气质），卡片靠 1px 描边分层。
ThemeData buildTimeTrackTheme(Brightness brightness) {
  final dark = brightness == Brightness.dark;
  final background =
      Color(dark ? DarkThemeTokens.background : LightThemeTokens.background);
  final surface =
      Color(dark ? DarkThemeTokens.surface : LightThemeTokens.surface);
  final surfaceMuted = Color(
      dark ? DarkThemeTokens.surfaceMuted : LightThemeTokens.surfaceMuted);
  final outline =
      Color(dark ? DarkThemeTokens.outline : LightThemeTokens.outline);
  final outlineVariant = Color(
      dark ? DarkThemeTokens.outlineVariant : LightThemeTokens.outlineVariant);
  final text = Color(dark ? DarkThemeTokens.text : LightThemeTokens.text);
  final mutedText =
      Color(dark ? DarkThemeTokens.mutedText : LightThemeTokens.mutedText);
  final primary =
      Color(dark ? DarkThemeTokens.primary : LightThemeTokens.primary);
  final accentText = Color(
      dark ? DarkThemeTokens.accentText : LightThemeTokens.accentText);

  final colorScheme = ColorScheme.fromSeed(
    seedColor: primary,
    brightness: brightness,
  ).copyWith(
    primary: primary,
    onPrimary: Colors.white,
    secondary: primary,
    onSecondary: Colors.white,
    surface: surface,
    surfaceContainer: surface,
    surfaceContainerHighest: surfaceMuted,
    outline: outline,
    outlineVariant: outlineVariant,
    onSurface: text,
    onSurfaceVariant: mutedText,
    error: const Color(0xffdc2626), // red-600 语义一致
  );

  final base = ThemeData(
    useMaterial3: true,
    colorScheme: colorScheme,
    scaffoldBackgroundColor: background,
    visualDensity: VisualDensity.standard,
    fontFamily: 'Inter',
    fontFamilyFallback: const ['Segoe UI', 'PingFang SC', 'Microsoft YaHei'],
  );

  // 浅色阴影像 zinc 投影；深色更透明。
  final cardShape = RoundedRectangleBorder(
    borderRadius: BorderRadius.circular(16),
    side: BorderSide(color: outline),
  );

  final selectedIndicator = Color.lerp(
    surfaceMuted,
    accentText,
    dark ? 0.34 : 0.18,
  )!;

  return base.copyWith(
    textTheme: base.textTheme.apply(
      bodyColor: text,
      displayColor: text,
    ),
    cardTheme: CardThemeData(
      color: surface,
      elevation: 0,
      shadowColor: Colors.transparent,
      surfaceTintColor: Colors.transparent,
      margin: EdgeInsets.zero,
      shape: cardShape,
    ),
    navigationRailTheme: NavigationRailThemeData(
      backgroundColor: surface,
      indicatorColor: selectedIndicator.withValues(alpha: dark ? 0.42 : 0.68),
      selectedIconTheme: IconThemeData(color: accentText),
      selectedLabelTextStyle: TextStyle(
        color: accentText,
        fontWeight: FontWeight.w600,
        fontSize: 12,
      ),
      unselectedIconTheme: IconThemeData(color: mutedText),
      unselectedLabelTextStyle: TextStyle(color: mutedText, fontSize: 12),
    ),
    navigationBarTheme: NavigationBarThemeData(
      backgroundColor: surface,
      indicatorColor: selectedIndicator.withValues(alpha: dark ? 0.42 : 0.78),
      labelTextStyle: WidgetStateProperty.resolveWith((states) {
        final selected = states.contains(WidgetState.selected);
        return TextStyle(
          color: selected ? accentText : mutedText,
          fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
          fontSize: 11,
        );
      }),
      iconTheme: WidgetStateProperty.resolveWith((states) {
        final selected = states.contains(WidgetState.selected);
        return IconThemeData(color: selected ? accentText : mutedText);
      }),
    ),
    listTileTheme: ListTileThemeData(
      iconColor: mutedText,
      selectedColor: accentText,
      selectedTileColor: selectedIndicator.withValues(alpha: dark ? 0.30 : 0.54),
      contentPadding: const EdgeInsets.symmetric(horizontal: 12),
      minLeadingWidth: 24,
      horizontalTitleGap: 12,
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: surface,
      contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(8),
        borderSide: BorderSide(color: outline),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(8),
        borderSide: BorderSide(color: outline),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(8),
        borderSide: BorderSide(color: accentText, width: 1.5),
      ),
      errorBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(8),
        borderSide: BorderSide(color: colorScheme.error),
      ),
      hintStyle: TextStyle(color: mutedText),
    ),
    dialogTheme: DialogThemeData(
      backgroundColor: surface,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      titleTextStyle: TextStyle(
        color: text,
        fontSize: 16,
        fontWeight: FontWeight.w600,
      ),
    ),
    snackBarTheme: SnackBarThemeData(
      backgroundColor: const Color(0xff18181b),
      contentTextStyle: const TextStyle(color: Colors.white, fontSize: 14),
      behavior: SnackBarBehavior.floating,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
    ),
    chipTheme: ChipThemeData(
      backgroundColor: surfaceMuted,
      selectedColor: selectedIndicator,
      side: BorderSide(color: outline),
      labelStyle: TextStyle(color: text, fontSize: 13, fontWeight: FontWeight.w500),
      secondaryLabelStyle:
          TextStyle(color: accentText, fontSize: 13, fontWeight: FontWeight.w600),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(999)),
    ),
    tooltipTheme: TooltipThemeData(
      decoration: BoxDecoration(
        color: const Color(0xff18181b),
        borderRadius: BorderRadius.circular(8),
      ),
      textStyle: const TextStyle(color: Colors.white, fontSize: 12),
    ),
    dividerTheme: DividerThemeData(color: outline, thickness: 1, space: 1),
    elevatedButtonTheme: ElevatedButtonThemeData(
      style: ElevatedButton.styleFrom(
        backgroundColor: primary,
        foregroundColor: Colors.white,
        elevation: 0,
        shadowColor: Colors.transparent,
        textStyle: const TextStyle(fontSize: 14, fontWeight: FontWeight.w500),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        foregroundColor: text,
        side: BorderSide(color: outlineVariant),
        textStyle: const TextStyle(fontSize: 14, fontWeight: FontWeight.w500),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(
        foregroundColor: accentText,
        textStyle: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
      ),
    ),
    sliderTheme: SliderThemeData(
      activeTrackColor: primary,
      inactiveTrackColor: outlineVariant.withValues(alpha: 0.5),
      thumbColor: Colors.white,
      thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 8),
      overlayColor: primary.withValues(alpha: 0.12),
      valueIndicatorColor: const Color(0xff18181b),
      valueIndicatorTextStyle: const TextStyle(color: Colors.white, fontSize: 12),
    ),
    switchTheme: SwitchThemeData(
      trackColor: WidgetStateProperty.resolveWith(
        (states) => states.contains(WidgetState.selected)
            ? primary
            : outlineVariant.withValues(alpha: 0.6),
      ),
      thumbColor: const WidgetStatePropertyAll(Colors.white),
      trackOutlineColor: const WidgetStatePropertyAll(Colors.transparent),
    ),
    progressIndicatorTheme: ProgressIndicatorThemeData(color: primary),
    // 组件统一阴影档位（shadow-sm）
    splashFactory: InkSparkle.splashFactory,
  );
}
