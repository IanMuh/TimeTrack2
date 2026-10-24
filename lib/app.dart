import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import 'components/app_theme.dart';
import 'l10n/app_localizations.dart';
import 'providers/engines.dart';
import 'routes/app_router.dart';
import 'viewmodels/profile_settings.dart' show ThemeModeSetting;

/// 应用根。
///
/// - [container] **可空**：null = 纯占位模式（无路由/无壳的最小 home，便于
///   基座测试）；非 null = 经 [UncontrolledProviderScope] 接管，并接入
///   [AppRouter]（StatefulShellRoute 5 页保活壳）；PR5 起 main 先装配容器再
///   runApp，AppStore 已删除。
/// - **主题接线**：唯一事实源为 `ProfileSettings.themeMode`（库），随
///   `settingsChangeProvider` 重建；库未加载时回退浅色（契约 §9.7）。
/// - [locale] 可注入（widget 测试固定中/英文验证 ARB 注入）；
/// - **系统字号钳制**：textScaler 最大 1.3 倍——无障碍放大 1.0-1.3 生效，
///   超出部分钳制（大计时数字/统计树行/活动卡等临界布局按 1.3 上限设计，
///   无钳制时极端放大会全屏溢出）。
class TimeTrack2App extends StatefulWidget {
  const TimeTrack2App({super.key, this.locale, this.container});

  final Locale? locale;

  /// 外部已装配的 Riverpod 容器（main 注入；测试注入预置覆盖的容器）。
  final ProviderContainer? container;

  /// 系统字号放大上限（超出钳制）。
  static const double _maxTextScaleFactor = 1.3;

  /// 主题只构造一次：`buildTimeTrackTheme` 每次调用都会重新计算
  /// ColorScheme——根组件被上层重建会重复昂贵的主题构造；static final 只建
  /// 一次且便于测试复用。
  static final ThemeData _light = buildTimeTrackTheme(Brightness.light);
  static final ThemeData _dark = buildTimeTrackTheme(Brightness.dark);

  @override
  State<TimeTrack2App> createState() => _TimeTrack2AppState();
}

class _TimeTrack2AppState extends State<TimeTrack2App> {
  /// 路由：仅有容器（真实启动/测试装配）时构造。
  GoRouter? _router;

  @override
  void initState() {
    super.initState();
    if (widget.container != null) {
      _router = AppRouter.create();
    }
  }

  @override
  void dispose() {
    _router?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final router = _router;
    final container = widget.container;
    // 占位模式：无容器，恒浅色，无需订阅。
    if (container == null) {
      return _buildApp(router, ThemeMode.light);
    }
    // 真实模式：只订阅设置这一件事（主题/时制等），库变化即重建。
    return UncontrolledProviderScope(
      container: container,
      child: Consumer(
        builder: (context, ref, _) {
          ref.watch(settingsChangeProvider);
          final store = ref.read(settingsStoreProvider);
          return _buildApp(
            router,
            themeModeFromSetting(
              store.current?.themeMode ?? ThemeModeSetting.light,
            ),
          );
        },
      ),
    );
  }

  /// 主题/本地化壳（占位模式与实际路由模式共用）。
  Widget _buildApp(GoRouter? router, ThemeMode themeMode) {
    final theme = TimeTrack2App._light;
    final darkTheme = TimeTrack2App._dark;
    final locale = widget.locale;
    const delegates = [
      AppLocalizations.delegate,
      GlobalMaterialLocalizations.delegate,
      GlobalWidgetsLocalizations.delegate,
      GlobalCupertinoLocalizations.delegate,
    ];
    const supportedLocales = AppLocalizations.supportedLocales;
    // 占位模式（container == null）：最小 home，供基座/主题冒烟测试。
    if (router == null) {
      return MaterialApp(
        title: 'TimeTrack2',
        theme: theme,
        darkTheme: darkTheme,
        themeMode: themeMode,
        localizationsDelegates: delegates,
        supportedLocales: supportedLocales,
        locale: locale,
        builder: _clampTextScaler,
        home: const _ShellPage(),
      );
    }
    // 路由模式：GoRouter 须经 MaterialApp.router 装配。
    return MaterialApp.router(
      title: 'TimeTrack2',
      theme: theme,
      darkTheme: darkTheme,
      themeMode: themeMode,
      localizationsDelegates: delegates,
      supportedLocales: supportedLocales,
      locale: locale,
      builder: _clampTextScaler,
      routerConfig: router,
    );
  }

  /// 系统字号放大钳制（>1.3 的部分截断；缩小方向不干预）。
  static Widget _clampTextScaler(BuildContext context, Widget? child) {
    final mediaQuery = MediaQuery.of(context);
    return MediaQuery(
      data: mediaQuery.copyWith(
        textScaler: mediaQuery.textScaler.clamp(
          minScaleFactor: 0.0,
          maxScaleFactor: TimeTrack2App._maxTextScaleFactor,
        ),
      ),
      child: child ?? const SizedBox.shrink(),
    );
  }
}

/// ThemeModeSetting（viewmodels 纯类型）→ material ThemeMode 映射（UI 层）。
ThemeMode themeModeFromSetting(ThemeModeSetting setting) {
  return switch (setting) {
    ThemeModeSetting.light => ThemeMode.light,
    ThemeModeSetting.dark => ThemeMode.dark,
    ThemeModeSetting.system => ThemeMode.system,
  };
}

/// 占位模式 home（container == null 时使用：验证主题/本地化基座可运行）。
class _ShellPage extends StatelessWidget {
  const _ShellPage();

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return Scaffold(
      appBar: AppBar(title: Text(l10n.appTitle)),
      body: Center(child: Text(l10n.appSubtitle)),
    );
  }
}
