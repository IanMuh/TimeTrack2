import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import 'components/app_theme.dart';
import 'l10n/app_localizations.dart';
import 'providers/foundation.dart';
import 'providers/infrastructure.dart';
import 'routes/app_router.dart';
import 'stores/app_store.dart';
import 'viewmodels/profile_settings.dart' show ThemeModeSetting;

/// 应用根（阶段 4 批次 1：主题模式接线 + 路由接入）。
///
/// - [appStore] **可空**：null = 纯占位模式（无路由/无壳的最小 home，便于
///   基座测试）；非 null = 接入 [AppRouter]（StatefulShellRoute 5 页保活壳）；
/// - **主题接线**：唯一事实源为 `ProfileSettings.themeMode`（库），随
///   SettingsStore 通知重建；无 store / 库未加载时回退浅色（契约 §9.7）。
///   原 ThemeModeStore 内存双源已删除（R6 漂移风险）——设置页落库即生效；
/// - [locale] 可注入（widget 测试固定中/英文验证 ARB 注入）；
/// - **Riverpod 作用域（迁移期）**：[container] 非 null 时用
///   [UncontrolledProviderScope] 接管（main 先装配容器再 runApp）；为 null
///   时（widget 测试 / 占位模式）内部自建 [ProviderScope]，并把 [appStore]
///   的数据库与 undo 实例桥接进容器——保证页面（ConsumerWidget）在测试里
///   也能拿到同一份撤销状态。B4 删除 AppStore 后此桥接一并移除。
/// - **系统字号钳制**：textScaler 最大 1.3 倍——无障碍放大 1.0-1.3 生效，
///   超出部分钳制（大计时数字/统计树行/活动卡等临界布局按 1.3 上限设计，
///   无钳制时极端放大会全屏溢出）。
class TimeTrack2App extends StatefulWidget {
  const TimeTrack2App({
    super.key,
    this.locale,
    this.appStore,
    this.container,
  });

  final Locale? locale;
  final AppStore? appStore;

  /// 外部已装配的 Riverpod 容器（main 注入；测试可注入预置覆盖的容器）。
  final ProviderContainer? container;

  /// 系统字号放大上限（超出钳制）。
  static const double _maxTextScaleFactor = 1.3;

  /// 主题只构造一次（r 修复）：`buildTimeTrackTheme` 每次调用都会重新计算
  /// ColorScheme——根组件被上层重建（DI/路由框架接入后）会重复昂贵的主题
  /// 构造；static final 只建一次且便于测试复用。
  static final ThemeData _light = buildTimeTrackTheme(Brightness.light);
  static final ThemeData _dark = buildTimeTrackTheme(Brightness.dark);

  @override
  State<TimeTrack2App> createState() => _TimeTrack2AppState();
}

class _TimeTrack2AppState extends State<TimeTrack2App> {
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
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final router = _router;
    final settings = widget.appStore?.settings;
    // 无 store（占位模式）：恒浅色，无需订阅。
    if (settings == null) {
      return _withProviderScope(_buildApp(router, ThemeMode.light));
    }
    // 有 store：只订阅设置这一件事（主题/时制等），库变化即重建。
    return _withProviderScope(
      ListenableBuilder(
        listenable: settings,
        builder: (context, _) => _buildApp(
          router,
          themeModeFromSetting(
            settings.current?.themeMode ?? ThemeModeSetting.light,
          ),
        ),
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
        builder: _clampTextScaler,
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
      builder: _clampTextScaler,
      routerConfig: router,
    );
  }

  /// 迁移期作用域装配：外部容器优先；否则内部建 [ProviderScope] 并桥接
  /// [TimeTrack2App.appStore]（测试/占位模式）。
  ///
  /// 桥接内容：数据库（页面查询 provider 必须命中同一个测试库，否则会
  /// 打开真实 drift 文件）、时钟/修订号/undo 实例（页面 watch 的 provider
  /// 必须与 AppStore 同一份，否则收不到写操作通知）。
  Widget _withProviderScope(Widget child) {
    final container = widget.container;
    if (container != null) {
      return UncontrolledProviderScope(container: container, child: child);
    }
    final store = widget.appStore;
    return ProviderScope(
      overrides: [
        if (store != null) ...[
          appDatabaseProvider.overrideWithValue(store.database),
          // 时钟/修订号/撤销都与 AppStore 同一实例：否则页面 watch 的
          // provider 状态永远收不到 store 写操作的 bump（测试里表现为
          // 页面不刷新），生产走 main 的容器不受此分支影响。
          clockStoreProvider.overrideWithValue(store.clock),
          dataRevisionStoreProvider.overrideWithValue(store.dataRevision),
          undoStoreProvider.overrideWithValue(store.undo),
        ],
      ],
      child: child,
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
