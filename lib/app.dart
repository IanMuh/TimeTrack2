import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:go_router/go_router.dart';

import 'components/app_theme.dart';
import 'l10n/app_localizations.dart';
import 'routes/app_router.dart';
import 'stores/app_store.dart';
import 'stores/theme_mode_store.dart';

/// 应用根（阶段 4 批次 1：主题模式接线 + 路由接入）。
///
/// - [appStore] **可空**：null = 纯占位模式（无路由/无壳的最小 home，便于
///   基座测试）；非 null = 接入 [AppRouter]（StatefulShellRoute 5 页保活壳）；
/// - **主题接线**：[ListenableBuilder] 包 [ThemeModeStore] 提供 themeMode
///   （默认浅色，契约 §9.7）；ThemeModeStore 为 UI 状态类——持久化
///   （ProfileSettings 加 theme 列）随设置页批次 4 一起做，本批次仅内存态；
/// - [locale] 可注入（widget 测试固定中/英文验证 ARB 注入）。
class TimeTrack2App extends StatefulWidget {
  const TimeTrack2App({super.key, this.locale, this.appStore});

  final Locale? locale;
  final AppStore? appStore;

  /// 主题只构造一次（r 修复）：`buildTimeTrackTheme` 每次调用都会重新计算
  /// ColorScheme——根组件被上层重建（DI/路由框架接入后）会重复昂贵的主题
  /// 构造；static final 只建一次且便于测试复用。
  static final ThemeData _light = buildTimeTrackTheme(Brightness.light);
  static final ThemeData _dark = buildTimeTrackTheme(Brightness.dark);

  @override
  State<TimeTrack2App> createState() => _TimeTrack2AppState();
}

class _TimeTrack2AppState extends State<TimeTrack2App> {
  /// 主题模式 UI 状态（浅/深/跟随系统；默认浅色）。
  late final ThemeModeStore _themeMode = ThemeModeStore();

  /// 路由：仅 appStore 注入时构造（空壳占位模式不建路由）。
  GoRouter? _router;

  @override
  void initState() {
    super.initState();
    final store = widget.appStore;
    if (store != null) {
      _router = AppRouter.create(store);
    }
  }

  @override
  void dispose() {
    _router?.dispose();
    _themeMode.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final router = _router;
    return ListenableBuilder(
      listenable: _themeMode,
      builder: (context, _) {
        final theme = TimeTrack2App._light;
        final darkTheme = TimeTrack2App._dark;
        final themeMode = _themeMode.mode;
        final locale = widget.locale;
        const delegates = [
          AppLocalizations.delegate,
          GlobalMaterialLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate,
        ];
        const supportedLocales = AppLocalizations.supportedLocales;
        // 占位模式（appStore == null）：最小 home，供基座/主题冒烟测试。
        if (router == null) {
          return MaterialApp(
            title: 'TimeTrack2',
            theme: theme,
            darkTheme: darkTheme,
            themeMode: themeMode,
            localizationsDelegates: delegates,
            supportedLocales: supportedLocales,
            locale: locale,
            home: const _ShellPage(),
          );
        }
        // 路由模式（appStore 注入）：GoRouter 须经 MaterialApp.router 装配
        //（Flutter 3.44：MaterialApp 本体不再接受 routerConfig）。
        return MaterialApp.router(
          title: 'TimeTrack2',
          theme: theme,
          darkTheme: darkTheme,
          themeMode: themeMode,
          localizationsDelegates: delegates,
          supportedLocales: supportedLocales,
          locale: locale,
          routerConfig: router,
        );
      },
    );
  }
}

/// 占位模式 home（appStore == null 时使用：验证主题/本地化基座可运行；
/// 接入 store 后由路由壳取代）。
class _ShellPage extends StatelessWidget {
  const _ShellPage();

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return Scaffold(
      appBar: AppBar(
        title: Text(l10n.appTitle),
      ),
      body: Center(
        child: Text(l10n.appSubtitle),
      ),
    );
  }
}