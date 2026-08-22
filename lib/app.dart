import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';

import 'components/app_theme.dart';
import 'l10n/app_localizations.dart';

/// 应用根（阶段 4 批次 0：接主题组装与本地化）。
///
/// 路由（go_router StatefulShellRoute 5 页保活）与真实壳在批次 1 接入；
/// 当前 home 为最小占位页，用于验证主题/本地化基座可运行。
/// 主题默认浅色（设计稿默认浅色，可切深色/跟随系统的设置项在设置页阶段接入）。
class TimeTrack2App extends StatelessWidget {
  const TimeTrack2App({super.key, this.locale});

  /// 可注入 locale（默认跟随系统；widget 测试用它固定中文/英文验证 ARB 注入）。
  final Locale? locale;

  /// 主题只构造一次（r 修复）：`buildTimeTrackTheme` 每次调用都会重新计算
  /// ColorScheme——根组件被上层重建（DI/路由框架接入后）会重复昂贵的主题
  /// 构造；static final 只建一次且便于测试复用。
  static final ThemeData _light = buildTimeTrackTheme(Brightness.light);
  static final ThemeData _dark = buildTimeTrackTheme(Brightness.dark);

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'TimeTrack2',
      theme: _light,
      darkTheme: _dark,
      themeMode: ThemeMode.light,
      localizationsDelegates: const [
        AppLocalizations.delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      supportedLocales: AppLocalizations.supportedLocales,
      locale: locale,
      home: const _ShellPage(),
    );
  }
}

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
