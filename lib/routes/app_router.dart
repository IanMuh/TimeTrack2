import 'package:go_router/go_router.dart';

import '../pages/app_shell.dart';
import '../pages/settings_page.dart';
import '../pages/stats_page.dart';
import '../pages/timeline_page.dart';
import '../pages/timer_page.dart';
import '../pages/today_page.dart';

/// 路由表（阶段 4 批次 1：StatefulShellRoute 5 主页面保活壳）。
///
/// - [StatefulShellRoute.indexedStack]：5 个分支（计时/今日/时间线/统计/设置）
///   各自独立导航栈且保活，页面间切换保持各页状态（契约 §3.1）；
/// - `initialLocation '/timer'`：计时页为默认着陆（契约 §3.1）；
/// - **深链预留**：后续深链（如 `/settings/update`、`/timeline?date=...`）在
///   各 Branch 内嵌 GoRoute 扩展，无需改壳；跨分支深链跳转用
///   `context.go`/`push`，壳的当前分支索引由 shell 的 currentIndex 驱动。
class AppRouter {
  AppRouter._();

  /// 组装 GoRouter。状态与指令通道一律经 Riverpod 容器获取。
  static GoRouter create() {
    return GoRouter(
      initialLocation: '/timer',
      routes: [
        StatefulShellRoute.indexedStack(
          builder: (context, state, navigationShell) {
            return AppShell(navigationShell: navigationShell);
          },
          branches: [
            _branch('/timer', 'timer', (context, state) => TimerPage()),
            _branch('/today', 'today', (context, state) => TodayPage()),
            _branch(
              '/timeline',
              'timeline',
              (context, state) => TimelinePage(),
            ),
            _branch('/stats', 'stats', (context, state) => StatsPage()),
            _branch(
              '/settings',
              'settings',
              (context, state) => SettingsPage(),
            ),
          ],
        ),
      ],
    );
  }

  static StatefulShellBranch _branch(
    String path,
    String name,
    GoRouterWidgetBuilder builder,
  ) {
    return StatefulShellBranch(
      routes: [GoRoute(path: path, name: name, builder: builder)],
    );
  }
}
