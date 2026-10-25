import 'package:flutter/widgets.dart' show MediaQuery;
import 'package:go_router/go_router.dart';

import '../constants/layout.dart' show AppBreakpoints;
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
/// - **深链预留**：后续深链（如 `/timeline?date=...`）在各 Branch 内嵌
///   GoRoute 扩展，无需改壳；跨分支深链跳转用 `context.go`/`push`，
///   壳的当前分支索引由 shell 的 currentIndex 驱动；
/// - **设置分支（UI 重建 PR-D）**：`/settings` 父路由 + 十分区子路由
///   `/settings/:section`（路由化主从，`docs/UI重建方案.md` §6）——宽屏
///   redirect 直达 `/settings/general`，窄屏保留分区列表页；子路由挂
///   分支内，深链可用且切分区不丢壳层保活。
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
            StatefulShellBranch(
              routes: [_settingsRoute()],
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

  /// 设置分支路由（路由化主从）：`/settings` = 窄屏分区列表页；宽屏
  /// ≥840 redirect 到 `/settings/general` 主从形态；子路由由分区规格
  /// 一一生成（深链直达，如更新提示 → `/settings/update`）。
  ///
  /// redirect 只在导航时运行、不随窗口尺寸重跑；"窄屏停留列表后拉宽"
  /// 停留在列表页（仍可用，点行即进分区主从）。
  static GoRoute _settingsRoute() {
    return GoRoute(
      path: '/settings',
      name: 'settings',
      builder: (context, state) => const SettingsIndexPage(),
      redirect: (context, state) {
        // matchedLocation 在子路由导航时是父路由自身的匹配段（/settings），
        // 会把 /settings/<section> 深链一并劫持——必须用完整目标 uri 判定。
        if (state.uri.path != '/settings') return null;
        final size = MediaQuery.maybeSizeOf(context);
        if (size == null || size.width < AppBreakpoints.expanded) {
          return null; // 窄屏：列表页本体
        }
        return '/settings/general'; // 宽屏：直达主从默认分区
      },
      routes: [
        for (final spec in kSettingsSections)
          GoRoute(
            path: spec.id,
            name: 'settings-${spec.id}',
            builder: (context, state) =>
                SettingsSectionPage(sectionId: spec.id),
          ),
      ],
    );
  }
}
