import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../components/global_timer_bar.dart';
import '../l10n/app_localizations.dart';
import '../stores/app_store.dart';
import '../viewmodels/activity.dart';
import '../viewmodels/commands/command_invocation.dart';

/// 应用壳（阶段 4 批次 1，契约 §3）：5 主页面导航 + 全局计时条 + 撤销/重做。
///
/// 布局（design/DESIGN_LANG.md 断点映射，Material 逻辑像素实现）：
/// - **宽屏 ≥ [wideBreakpoint]（840，对应 design min-[840px]）**：左侧固定
///   232px 侧向导航（品牌 TimeTrack + 5 项图标+文字 + 分隔线下的撤销/重做
///   按钮组 + 底部同步状态小字），右侧主内容列底部装配全局计时条；
/// - **< 840（中宽/紧凑）**：底部 NavigationBar 5 项（图标+文字）；计时条
///   叠置在底部导航**上方**（两层叠置，契约 §3.2）。
///
/// 跨页常驻：
/// - **全局计时条数据流**（契约 §3.3）：合并 timer/clock 两 store 监听——
///   timer 管"运行条目变了"，clock 管"秒级推进"；elapsed 用 `now` clamp 计算
///   （运行条目 endAt=null，durationUntil 已含负值归零）；
/// - **"未在记录"判定**：数据层 stop 语义 = 切到"未分配"活动（此后仍存在
///   运行条目），故按运行条目的 activityId 是否未分配活动区分记录中/未记录——
///   异步查一次、按 entry id 校验后缓存（不每帧查库）；
/// - **停止/切换动作**：stop 已接线——经 [CommandDispatcher] 指令通道分发
///   （铁律 7 统一通道），结果由**壳层统一弹 Snackbar**（契约 §2.6/§3.5，
///   各页不自造反馈语义）；switch 按钮禁用 + tooltip 说明（批次 2 提供
///   活动选择器，避免半成品选择器）；
/// - **撤销/重做**（桌面常驻，契约 §3.4）：接 [UndoStore]（canUndo/canRedo/
///   lastUndoLabel/lastRedoLabel），tooltip 用 ARB undoWithLabel/redoWithLabel，
///   禁用时给中性提示（不可用原因语义批次 5 补全——含冲突校验原因与移动端
///   收纳菜单；快捷键 Ctrl+Z/Y 与输入框让位同属批次 5）。
class AppShell extends StatefulWidget {
  const AppShell({
    super.key,
    required this.app,
    required this.navigationShell,
  });

  final AppStore app;
  final StatefulNavigationShell navigationShell;

  /// 宽屏断点：Material 逻辑像素 840（design min-[840px]）。
  static const double wideBreakpoint = 840;

  @override
  State<AppShell> createState() => _AppShellState();
}

class _AppShellState extends State<AppShell> {
  /// 合并 timer（运行条目变化）+ clock（秒级推进）为单一 listenable，
  /// 避免每次 build 重建合并对象反复换订阅（计时条每秒重建）。
  late final Listenable _timerTick =
      Listenable.merge([widget.app.timer, widget.app.clock]);

  /// 未分配活动判定缓存：按运行条目所属 activityId 记录异步查询结果
  /// （防每帧查库）。
  String? _checkedActivityId;
  bool _entryIsUnassigned = false;

  @override
  Widget build(BuildContext context) {
    final shell = widget.navigationShell;
    final isWide = MediaQuery.sizeOf(context).width >= AppShell.wideBreakpoint;
    final content = Expanded(child: shell);
    return Scaffold(
      body: isWide
          ? Row(
              children: [
                _SideNav(
                  app: widget.app,
                  shell: shell,
                  onUndo: () => _dispatch(CommandInvocation(name: 'undo')),
                  onRedo: () => _dispatch(CommandInvocation(name: 'redo')),
                ),
                Expanded(
                  child: Column(
                    children: [content, _buildTimerBar(compact: false)],
                  ),
                ),
              ],
            )
          : Column(
              children: [
                content,
                _buildTimerBar(compact: true),
                _buildBottomNav(shell),
              ],
            ),
    );
  }

  // ---------------------------------------------------------------------------
  // 全局计时条（常驻底部）
  // ---------------------------------------------------------------------------

  Widget _buildTimerBar({required bool compact}) {
    return ListenableBuilder(
      listenable: _timerTick,
      builder: (context, _) {
        final running = widget.app.timer.runningEntry;
        var recording = false;
        String? name;
        Color? color;
        var elapsed = Duration.zero;
        if (running != null) {
          _ensureUnassignedCheckQueued(running.activityId);
          if (!_entryIsUnassigned) {
            recording = true;
            name = running.activityNameSnapshot;
            color = Color(running.activityColorSnapshot ?? Activity.defaultColor);
            elapsed = running.durationUntil(widget.app.clock.now());
          }
        }
        final canStop = recording;
        return GlobalTimerBar(
          isRecording: recording,
          activityName: name,
          activityColor: color,
          elapsed: elapsed,
          compact: compact,
          onStop: canStop
              ? () => _dispatch(CommandInvocation(name: 'stop'))
              : null,
          // 批次 2：活动选择器接入后启用（当前禁用 + tooltip 说明）。
          onSwitch: null,
          onOpenTimer: () => widget.navigationShell.goBranch(0),
        );
      },
    );
  }

  /// 运行条目所属活动变化时排队一次未分配判定（build 期只写字段 + 排微任务，
  /// 不直接 setState；查询完成后按需刷新，期间先按记录中呈现防闪烁）。
  ///
  /// 按 **activityId** 查（activityIdIsUnassigned 按活动表判定；同一活动
  /// 反复 switch 产生多条运行条目，复检同一 activityId 无意义）。
  void _ensureUnassignedCheckQueued(String activityId) {
    if (_checkedActivityId == activityId) return;
    _checkedActivityId = activityId;
    _entryIsUnassigned = false;
    Future.microtask(() async {
      final isUnassigned =
          await widget.app.activities.activityIdIsUnassigned(activityId);
      if (!mounted || _checkedActivityId != activityId) return;
      setState(() => _entryIsUnassigned = isUnassigned);
    });
  }

  // ---------------------------------------------------------------------------
  // 指令分发 + 壳层统一反馈（契约 §2.6/§3.5）
  // ---------------------------------------------------------------------------

  Future<void> _dispatch(CommandInvocation invocation) async {
    final messenger = ScaffoldMessenger.of(context);
    final result = await widget.app.dispatcher.dispatch(invocation);
    if (!mounted) return;
    final l10n = AppLocalizations.of(context)!;
    messenger.hideCurrentSnackBar();
    messenger.showSnackBar(
      SnackBar(
        content: Text(
          result.fold(
            onSuccess: (s) => s.message ?? l10n.commandDone,
            onFailure: (f) => f.reason,
          ),
        ),
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // 底部导航（< 840）
  // ---------------------------------------------------------------------------

  Widget _buildBottomNav(StatefulNavigationShell shell) {
    final l10n = AppLocalizations.of(context)!;
    return NavigationBar(
      selectedIndex: shell.currentIndex,
      onDestinationSelected: (index) => shell.goBranch(
        index,
        initialLocation: index == shell.currentIndex,
      ),
      destinations: [
        for (final spec in _navSpecs(l10n))
          NavigationDestination(
            icon: Icon(spec.icon),
            selectedIcon: Icon(spec.selectedIcon),
            label: spec.label,
          ),
      ],
    );
  }
}

/// 导航项规格（侧导航/底部导航共用；顺序 = 分支顺序）。
typedef _NavSpec = ({
  String path,
  String label,
  IconData icon,
  IconData selectedIcon,
});

List<_NavSpec> _navSpecs(AppLocalizations l10n) {
  return [
    (
      path: '/timer',
      label: l10n.navTimer,
      icon: Icons.timer_outlined,
      selectedIcon: Icons.timer
    ),
    (
      path: '/today',
      label: l10n.navToday,
      icon: Icons.calendar_today_outlined,
      selectedIcon: Icons.calendar_today
    ),
    (
      path: '/timeline',
      label: l10n.navTimeline,
      icon: Icons.view_timeline_outlined,
      selectedIcon: Icons.view_timeline
    ),
    (
      path: '/stats',
      label: l10n.navStats,
      icon: Icons.pie_chart_outline,
      selectedIcon: Icons.pie_chart
    ),
    (
      path: '/settings',
      label: l10n.navSettings,
      icon: Icons.settings_outlined,
      selectedIcon: Icons.settings
    ),
  ];
}

/// 侧向导航（≥ 840，固定 232px；品牌 + 导航 + 撤销/重做 + 同步状态）。
class _SideNav extends StatelessWidget {
  const _SideNav({
    required this.app,
    required this.shell,
    required this.onUndo,
    required this.onRedo,
  });

  final AppStore app;
  final StatefulNavigationShell shell;
  final VoidCallback onUndo;
  final VoidCallback onRedo;

  static const double width = 232; // design：w-[232px]

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l10n = AppLocalizations.of(context)!;
    final scheme = theme.colorScheme;
    final specs = _navSpecs(l10n);

    return Container(
      width: width,
      decoration: BoxDecoration(
        color: scheme.surface,
        border: Border(right: BorderSide(color: scheme.outline)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // 品牌（design：h-16，TimeTrack 字样）。
          SizedBox(
            height: 64,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  l10n.appBrand,
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w600,
                    letterSpacing: -0.3,
                  ),
                ),
              ),
            ),
          ),
          // 5 个导航项。
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Column(
              children: [
                for (var i = 0; i < specs.length; i++)
                  _SideNavItem(
                    spec: specs[i],
                    selected: shell.currentIndex == i,
                    onTap: () => shell.goBranch(
                      i,
                      initialLocation: i == shell.currentIndex,
                    ),
                  ),
              ],
            ),
          ),
          const Spacer(),
          // 撤销/重做组 + 同步状态（分隔线上方）。
          const Divider(),
          _UndoRedoGroup(app: app, onUndo: onUndo, onRedo: onRedo),
          _SyncStatusText(app: app),
          const SizedBox(height: 12),
        ],
      ),
    );
  }
}

class _SideNavItem extends StatelessWidget {
  const _SideNavItem({
    required this.spec,
    required this.selected,
    required this.onTap,
  });

  final _NavSpec spec;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final foreground = selected ? scheme.primary : scheme.onSurfaceVariant;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Material(
        // 选中态：indigo-50 / indigo-500/10（design 高亮）。
        color: selected
            ? scheme.primary.withValues(alpha: 0.10)
            : Colors.transparent,
        borderRadius: BorderRadius.circular(8),
        child: InkWell(
          borderRadius: BorderRadius.circular(8),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
            child: Row(
              children: [
                Icon(
                  selected ? spec.selectedIcon : spec.icon,
                  size: 18,
                  color: foreground,
                ),
                const SizedBox(width: 10),
                Text(
                  spec.label,
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
                    color: foreground,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// 撤销/重做按钮组（桌面常驻，契约 §3.4）：接 UndoStore；点击经指令通道
/// 分发，反馈 Snackbar 由壳层统一弹。
class _UndoRedoGroup extends StatelessWidget {
  const _UndoRedoGroup({
    required this.app,
    required this.onUndo,
    required this.onRedo,
  });

  final AppStore app;
  final VoidCallback onUndo;
  final VoidCallback onRedo;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ListenableBuilder(
      listenable: app.undo,
      builder: (context, _) {
        final l10n = AppLocalizations.of(context)!;
        final undo = app.undo;
        final undoLabel = undo.lastUndoLabel == null
            ? null
            : l10n.undoWithLabel(undo.lastUndoLabel!);
        final redoLabel = undo.lastRedoLabel == null
            ? null
            : l10n.redoWithLabel(undo.lastRedoLabel!);
        return Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
          child: Row(
            children: [
              _UndoRedoButton(
                icon: Icons.undo_rounded,
                tooltip: undoLabel ?? l10n.undoHint,
                onPressed: undo.canUndo ? onUndo : null,
              ),
              const SizedBox(width: 4),
              _UndoRedoButton(
                icon: Icons.redo_rounded,
                tooltip: redoLabel ?? l10n.redoHint,
                onPressed: undo.canRedo ? onRedo : null,
              ),
              const Spacer(),
              // 分组标题（design：侧导航内"撤销 / 重做"小节）。
              Text(
                '${l10n.undo} / ${l10n.redo}',
                style: theme.textTheme.labelSmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

class _UndoRedoButton extends StatelessWidget {
  const _UndoRedoButton({
    required this.icon,
    required this.tooltip,
    required this.onPressed,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    return IconButton(
      icon: Icon(icon, size: 18),
      onPressed: onPressed,
      tooltip: tooltip,
      visualDensity: VisualDensity.compact,
      // 禁用时保留 tooltip（Tooltip 自带手势，不依赖按钮状态；不可用原因
      // 语义批次 5 补全）。
      style: IconButton.styleFrom(
        disabledForegroundColor:
            Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.38),
        minimumSize: const Size(36, 36),
      ),
    );
  }
}

/// 底部同步状态小字（design：cloud 图标 + 状态；离线优先的可感知指示）。
class _SyncStatusText extends StatelessWidget {
  const _SyncStatusText({required this.app});

  final AppStore app;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return ListenableBuilder(
      listenable: app.sync,
      builder: (context, _) {
        final sync = app.sync;
        final l10n = AppLocalizations.of(context)!;
        final String label;
        if (sync.syncing) {
          label = l10n.syncing;
        } else if (sync.lastError != null) {
          label = sync.lastError!;
        } else if (sync.userId != null) {
          label = l10n.syncStatusSynced;
        } else {
          label = l10n.syncStatusLocal;
        }
        final muted = scheme.onSurfaceVariant;
        return Padding(
          padding: const EdgeInsets.fromLTRB(16, 10, 16, 0),
          child: Row(
            children: [
              Icon(Icons.cloud_outlined, size: 13, color: muted),
              const SizedBox(width: 6),
              Flexible(
                child: Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.labelSmall?.copyWith(color: muted),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}