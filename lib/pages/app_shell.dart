import 'dart:async';

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../api/platform/android_tracking.dart' show AndroidTrackingBridge;
import '../components/global_timer_bar.dart';
import '../constants/storage_keys.dart';
import '../l10n/app_localizations.dart';
import '../stores/app_store.dart';
import '../stores/reminder_store.dart';
import '../stores/update_store.dart' show UpdateState;
import '../viewmodels/activity.dart';
import '../viewmodels/commands/command_invocation.dart';
import '../viewmodels/profile_settings.dart' show ReminderMethod;

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

  /// 主内容最大宽度：design max-w-5xl（1024）居中。
  static const double _contentMaxWidth = 1024;

  @override
  State<AppShell> createState() => _AppShellState();
}

class _AppShellState extends State<AppShell>
    with WidgetsBindingObserver {
  /// 合并 timer（运行条目变化）+ clock（秒级推进）为单一 listenable，
  /// 避免每次 build 重建合并对象反复换订阅（计时条每秒重建）。
  late final Listenable _timerTick =
      Listenable.merge([widget.app.timer, widget.app.clock]);

  /// 未分配活动判定缓存：按运行条目所属 activityId 记录异步查询结果
  /// （防每帧查库）。
  String? _checkedActivityId;
  bool _entryIsUnassigned = false;

  // ---------------------------------------------------------------------------
  // 批次 5c：弹窗体系（可疑条目 / 提醒 / 更新提示）
  // ---------------------------------------------------------------------------

  /// 本次会话启动时刻（clock 注入源）：运行条目起点早于它 = 跨上次会话
  /// 的可疑条目（§5.2 场景 3）。**必须在 initState 立即赋值**——若声明成
  /// 惰性 `= clock.now()`，首次访问发生在 timer 触发检查时，彼时本会话内
  /// 新切换的运行条目已存在，会被误判为"早于会话启动"而误弹对话框。
  late final DateTime _sessionStart;
  bool _suspiciousChecked = false;

  /// 已弹过对话框的提醒请求 id（对话框模态，防重复弹）。
  String? _shownReminderDialogId;

  /// 已提示过的"更新可用"版本（每会话每版本一次；忽略走持久化接口）。
  final Set<String> _updateSnackbarShownVersions = {};
  bool _forcedUpdateDialogShown = false;

  // ---- Windows 托盘（批次 6）----

  /// 关窗模式（`ask`/`minimize`/`exit`；启动异步加载，未加载前按 ask 兜底）。
  String _trayCloseMode = TrayCloseMode.ask;
  bool _closeDialogShownThisSession = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _sessionStart = widget.app.clock.now();
    widget.app.reminder.addListener(_onReminderChanged);
    widget.app.update.addListener(_onUpdateChanged);
    _wireTray();
    _wireAndroidTracking();
    // 可疑条目启动检测：AppStore.init 已 await timer.refresh()，postFrame
    // 时 runningEntry 缓存可用；timer 监听兜底晚到场景（幂等，标志位去重）。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _checkSuspiciousEntry();
      unawaited(_syncAndroidService());
    });
    widget.app.timer.addListener(_onTimerForSuspicious);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    widget.app.reminder.removeListener(_onReminderChanged);
    widget.app.update.removeListener(_onUpdateChanged);
    widget.app.timer.removeListener(_onTimerForSuspicious);
    widget.app.settings.removeListener(_syncAndroidService);
    // 托盘回调指向本 State：dispose 后必须摘除（服务随 AppStore 存活）。
    widget.app.tray.onCommand = null;
    widget.app.tray.onCloseToTray = null;
    widget.app.androidTracking.onPauseRequested = null;
    super.dispose();
  }

  /// Android 前台服务接线（批次 6b）：通知「暂停」动作 → 会话暂停翻转；
  /// 总开关/授权/命中活动变化 → 服务启停与常驻通知文案同步。
  void _wireAndroidTracking() {
    if (!AndroidTrackingBridge.isSupported) return;
    final bridge = widget.app.androidTracking;
    bridge.onPauseRequested = () {
      final tracking = widget.app.tracking;
      tracking.setSessionPaused(!tracking.sessionPaused);
      setState(() {});
      unawaited(_syncAndroidService());
    };
    widget.app.settings.addListener(_syncAndroidService);
  }

  /// 依据 总开关+使用情况授权 决定前台服务启停，并同步通知文案
  /// （内容=最近命中的规则活动名；无命中由 native 显示「检测中…」）。
  Future<void> _syncAndroidService() async {
    if (!AndroidTrackingBridge.isSupported || !mounted) return;
    final app = widget.app;
    final enabled = app.settings.current?.backgroundTrackingEnabled ?? false;
    final granted = await app.androidTracking.isUsageGranted();
    if (!mounted) return;
    if (!(enabled && granted)) {
      await app.androidTracking.stopTrackingService();
      return;
    }
    String content = '';
    final matchedId = app.tracking.lastMatchedActivityId;
    if (matchedId != null) {
      final activity = await app.activities.activityById(matchedId);
      if (!mounted) return;
      content = activity?.name ?? '';
    }
    await app.androidTracking.startTrackingService(
      paused: app.tracking.sessionPaused,
      content: content,
    );
  }

  /// 托盘事件接线（批次 6）：命令路由 + 关窗模式加载。
  void _wireTray() {
    final tray = widget.app.tray;
    tray.onCommand = (command) {
      switch (command) {
        case 'togglePause':
          final tracking = widget.app.tracking;
          tracking.setSessionPaused(!tracking.sessionPaused);
          setState(() {}); // 计时条重建 → 推送新暂停态给托盘菜单/tooltip
        case 'show':
          // 唤起窗口由 native 完成；Dart 侧无需动作（保留分支防未来扩展）。
          break;
      }
    };
    tray.onCloseToTray = _onClosedToTray;
    unawaited(_loadTrayCloseMode());
  }

  Future<void> _loadTrayCloseMode() async {
    final mode = await widget.app.settings.trayCloseMode();
    if (!mounted) return;
    setState(() => _trayCloseMode = mode);
    // 加载完成后立即推送一次托盘配置（非 Windows no-op）。
    _pushTrayStatus();
  }

  /// 关窗被拦截并隐藏到托盘后：ask 模式且本次会话未询问过 → 弹选择对话框
  /// （契约 §6.4"首次关窗弹选择对话框，可记住选择"）。
  Future<void> _onClosedToTray() async {
    if (_trayCloseMode != TrayCloseMode.ask || _closeDialogShownThisSession) {
      return;
    }
    if (!mounted) return;
    _closeDialogShownThisSession = true;
    await _showClosePreferenceDialog();
  }

  void _onTimerForSuspicious() {
    _checkSuspiciousEntry();
    // 命中活动变化（自动切换/手动切换）→ 常驻通知文案同步（批次 6b）。
    unawaited(_syncAndroidService());
  }

  /// 应用生命周期（批次 6b Android）：从后台/系统设置回到前台时——
  /// - 补问通知权限（引导页跳系统设置期间弹窗无法展示，回前台补问）；
  /// - 刷新前台服务启停与通知文案（授权态可能已变）。
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) return;
    final bridge = widget.app.androidTracking;
    if (!AndroidTrackingBridge.isSupported) return;
    final enabled =
        widget.app.settings.current?.backgroundTrackingEnabled ?? false;
    if (!bridge.notificationPermissionAsked && enabled) {
      unawaited(bridge.requestNotificationPermission());
    }
    unawaited(_syncAndroidService());
  }

  /// 首次关窗选择对话框：最小化到托盘（默认）/ 直接退出 + 记住选择。
  Future<void> _showClosePreferenceDialog() async {
    if (!mounted) return;
    final l10n = AppLocalizations.of(context)!;
    var selected = TrayCloseMode.minimize; // 契约：默认最小化到托盘
    var remember = true;
    await showDialog<void>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (dialogContext, setDialogState) => AlertDialog(
          backgroundColor: Theme.of(dialogContext).colorScheme.surface,
          shape:
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          title: Text(l10n.closeAppTitle, style: const TextStyle(fontSize: 15)),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(l10n.closeAppContent),
              // RadioGroup（3.32+ 新 API）：组值/回调收敛到祖先，单钮只声明 value。
              RadioGroup<String>(
                groupValue: selected,
                onChanged: (v) =>
                    setDialogState(() => selected = v ?? selected),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    RadioListTile<String>(
                      value: TrayCloseMode.minimize,
                      title: Text(l10n.minimizeToTray),
                      contentPadding: EdgeInsets.zero,
                      dense: true,
                    ),
                    RadioListTile<String>(
                      value: TrayCloseMode.exit,
                      title: Text(l10n.exitApp),
                      contentPadding: EdgeInsets.zero,
                      dense: true,
                    ),
                  ],
                ),
              ),
              CheckboxListTile(
                value: remember,
                onChanged: (v) => setDialogState(() => remember = v ?? true),
                title: Text(l10n.trayCloseRemember),
                contentPadding: EdgeInsets.zero,
                controlAffinity: ListTileControlAffinity.leading,
                dense: true,
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(),
              child: Text(l10n.ok),
            ),
            FilledButton(
              onPressed: () async {
                Navigator.of(dialogContext).pop();
                if (remember) {
                  await widget.app.settings.setTrayCloseMode(selected);
                }
                if (!mounted) return;
                setState(() => _trayCloseMode = selected);
                _pushTrayStatus();
              },
              child: Text(l10n.ok),
            ),
          ],
        ),
      ),
    );
  }

  /// 推送托盘状态（模式 + 记录态 + 暂停态；服务内去重）。在计时条构建器
  /// 中每秒调用——重复推送被 TrayService 拦截，无通道流量。
  void _pushTrayStatus() {
    final running = widget.app.timer.runningEntry;
    final recording =
        running != null && !_entryIsUnassigned;
    final activity = recording ? running.activityNameSnapshot : '';
    unawaited(widget.app.tray.configure(
      mode: _trayCloseMode,
      recording: recording,
      paused: widget.app.tracking.sessionPaused,
      activity: activity,
    ));
  }

  void _onReminderChanged() {
    if (!mounted) return;
    setState(() {}); // 横幅随 active 增删重建
    final active = widget.app.reminder.active;
    if (active == null || active.method != ReminderMethod.dialog) return;
    if (_shownReminderDialogId == active.id) return;
    _shownReminderDialogId = active.id;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _showReminderDialog(active);
    });
  }

  void _onUpdateChanged() {
    if (!mounted) return;
    final update = widget.app.update;
    if (update.state != UpdateState.available) return;
    if (update.status.required) {
      // 强制更新：不可跳过对话框（唯一操作"立即更新"，无关闭）——每会话一次。
      if (_forcedUpdateDialogShown) return;
      _forcedUpdateDialogShown = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _showForcedUpdateDialog();
      });
      return;
    }
    final version = update.status.latestVersion;
    if (_updateSnackbarShownVersions.add(version)) {
      _showUpdateAvailableSnackBar(version);
    }
  }

  /// §5.2 场景 3：可疑条目（启动时发现跨会话的遗留运行条目）——须决策
  /// 对话框「保留当前 / 结束到现在」。
  void _checkSuspiciousEntry() {
    if (_suspiciousChecked || !mounted) return;
    final running = widget.app.timer.runningEntry;
    if (running == null) return; // 无运行条目：无需检测
    if (!running.startAt.isBefore(_sessionStart)) return; // 本会话内开始
    _suspiciousChecked = true;
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) {
        final l10n = AppLocalizations.of(dialogContext)!;
        return AlertDialog(
          backgroundColor: Theme.of(dialogContext).colorScheme.surface,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          title: Row(children: [
            CircleAvatar(
              radius: 18,
              backgroundColor: const Color(0x14f59e0b),
              child: const Icon(Icons.error_outline,
                  size: 20, color: Color(0xffd97706)),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(l10n.suspiciousTitle,
                      style: const TextStyle(fontSize: 15)),
                  Text(l10n.suspiciousSubtitle,
                      style: TextStyle(
                          fontSize: 12,
                          color: Theme.of(dialogContext)
                              .colorScheme
                              .onSurfaceVariant)),
                ],
              ),
            ),
          ]),
          content: Text(l10n.suspiciousEntryContent(_hm(running.startAt))),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(),
              child: Text(l10n.keepCurrent),
            ),
            FilledButton(
              onPressed: () {
                Navigator.of(dialogContext).pop();
                unawaited(_dispatch(CommandInvocation(
                  name: 'entry_update',
                  args: [running.id],
                  options: {'end': _hm(DateTime.now())},
                )));
              },
              child: Text(l10n.endToNow),
            ),
          ],
        );
      },
    );
  }

  static String _hm(DateTime t) =>
      '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';

  String _formatElapsed(Duration d) {
    final h = d.inHours;
    final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return h > 0 ? '$h:$m:$s' : '$m:$s';
  }

  /// §5.2 场景 1/快速提醒：对话框载体（按请求类型装配按钮组）。
  Future<void> _showReminderDialog(ReminderRequest request) async {
    if (!mounted) return;
    final store = widget.app.reminder;
    if (request is OngoingReminder) {
      await showDialog<void>(
        context: context,
        barrierDismissible: false,
        builder: (dialogContext) {
          final l10n = AppLocalizations.of(dialogContext)!;
          return AlertDialog(
            backgroundColor: Theme.of(dialogContext).colorScheme.surface,
            shape:
                RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
            title: Row(children: [
              CircleAvatar(
                radius: 18,
                backgroundColor: const Color(0x14eef2ff),
                child: const Icon(Icons.timer_outlined,
                    size: 20, color: Color(0xff4f46e5)),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(l10n.stillDoingThis,
                        style: const TextStyle(fontSize: 15)),
                    Text(l10n.remOngoingSubtitle,
                        style: TextStyle(
                            fontSize: 12,
                            color: Theme.of(dialogContext)
                                .colorScheme
                                .onSurfaceVariant)),
                  ],
                ),
              ),
            ]),
            content: Text(
              l10n.remOngoingBody(request.activityName,
                  _formatElapsed(request.elapsed)),
            ),
            actions: [
              TextButton(
                onPressed: () {
                  Navigator.of(dialogContext).pop();
                  store.acknowledgeOngoing();
                },
                child: Text(l10n.remindLater),
              ),
              TextButton(
                style: TextButton.styleFrom(
                    foregroundColor: Theme.of(dialogContext).colorScheme.error),
                onPressed: () {
                  Navigator.of(dialogContext).pop();
                  unawaited(store.stopOngoing());
                },
                child: Text(l10n.stop),
              ),
              FilledButton(
                onPressed: () {
                  Navigator.of(dialogContext).pop();
                  store.acknowledgeOngoing();
                },
                child: Text(l10n.continueLabel),
              ),
            ],
          );
        },
      );
      return;
    }
    if (request is QuickStartReminder) {
      await showDialog<void>(
        context: context,
        barrierDismissible: false,
        builder: (dialogContext) {
          final l10n = AppLocalizations.of(dialogContext)!;
          return AlertDialog(
            backgroundColor: Theme.of(dialogContext).colorScheme.surface,
            shape:
                RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
            title: Row(children: [
              CircleAvatar(
                radius: 18,
                backgroundColor: const Color(0x14eef2ff),
                child: const Icon(Icons.notifications_active_outlined,
                    size: 20, color: Color(0xff4f46e5)),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Text(l10n.remQuickTitle,
                    style: const TextStyle(fontSize: 15)),
              ),
            ]),
            content: Text(l10n.remQuickBody),
            actions: [
              TextButton(
                onPressed: () {
                  Navigator.of(dialogContext).pop();
                  store.dismissQuick();
                },
                child: Text(l10n.remDismiss),
              ),
              FilledButton(
                onPressed: () {
                  Navigator.of(dialogContext).pop();
                  store.dismissQuick();
                  widget.navigationShell.goBranch(0, initialLocation: true);
                },
                child: Text(l10n.timerStartRecording),
              ),
            ],
          );
        },
      );
    }
  }

  /// §5.2 场景 4：更新可用 Snackbar（查看 → 设置页；忽略 → 持久化忽略）。
  void _showUpdateAvailableSnackBar(String version) {
    final messenger = ScaffoldMessenger.of(context);
    final l10n = AppLocalizations.of(context)!;
    messenger.showSnackBar(
      SnackBar(
        behavior: SnackBarBehavior.floating,
        duration: const Duration(seconds: 10),
        backgroundColor: const Color(0xff18181b),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        content: Row(children: [
          Container(
            width: 32,
            height: 32,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(8),
              color: const Color(0x33818cf8),
            ),
            child: const Icon(Icons.download_outlined,
                size: 16, color: Color(0xffa5b4fc)),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(l10n.updateAvailablePrompt(version),
                    style:
                        const TextStyle(color: Colors.white, fontSize: 13)),
                Text(l10n.updateAvailableSubtle,
                    style: const TextStyle(
                        color: Color(0xffa1a1aa), fontSize: 11)),
              ],
            ),
          ),
          TextButton(
            onPressed: () {
              messenger.hideCurrentSnackBar();
              widget.navigationShell.goBranch(4, initialLocation: true);
            },
            child: Text(l10n.viewInSettings,
                style: const TextStyle(color: Color(0xffa5b4fc))),
          ),
          TextButton(
            onPressed: () {
              messenger.hideCurrentSnackBar();
              unawaited(widget.app.update.ignoreCurrentVersion());
            },
            child: Text(l10n.updateIgnoreAction,
                style: const TextStyle(color: Color(0xffa1a1aa))),
          ),
        ]),
      ),
    );
  }

  /// §5.2 场景 5：强制更新对话框（不可跳过、无关闭、唯一操作）。
  Future<void> _showForcedUpdateDialog() async {
    if (!mounted) return;
    final update = widget.app.update;
    final l10n = AppLocalizations.of(context)!;
    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) => PopScope(
        canPop: false,
        child: AlertDialog(
          backgroundColor: Theme.of(dialogContext).colorScheme.surface,
          shape:
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          title: Row(children: [
            CircleAvatar(
              radius: 18,
              backgroundColor: const Color(0x14ef4444),
              child: const Icon(Icons.lock_outline,
                  size: 20, color: Color(0xffdc2626)),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(l10n.forcedUpdateTitle,
                      style: const TextStyle(fontSize: 15)),
                  Text(l10n.forcedUpdateSubtitle,
                      style: const TextStyle(
                          fontSize: 12, color: Color(0xffef4444))),
                ],
              ),
            ),
          ]),
          content: Text(l10n.forcedUpdateBody(
              widget.app.currentVersion, update.status.latestVersion)),
          actions: [
            SizedBox(
              width: double.infinity,
              child: FilledButton(
                onPressed: () {
                  Navigator.of(dialogContext).pop();
                  unawaited(update.install());
                },
                child: Text(l10n.forcedUpdateAction),
              ),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final shell = widget.navigationShell;
    final isWide = MediaQuery.sizeOf(context).width >= AppShell.wideBreakpoint;
    final content = Expanded(child: shell);
    final banner = ListenableBuilder(
      listenable: widget.app.reminder,
      builder: (context, _) =>
          _buildReminderBanner() ?? const SizedBox.shrink(),
    );
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
                    children: [
                      // 设计稿：主内容 mx-auto max-w-5xl（min-[840px] 起约束）。
                      // Expanded 必须是 Column 直接子代——约束包在 Expanded 内。
                      banner,
                      Expanded(
                        child: Center(
                          child: ConstrainedBox(
                            constraints: const BoxConstraints(
                              maxWidth: AppShell._contentMaxWidth,
                            ),
                            child: shell,
                          ),
                        ),
                      ),
                      _buildTimerBar(compact: false),
                    ],
                  ),
                ),
              ],
            )
          : Column(
              children: [
                banner,
                content,
                _buildTimerBar(compact: true),
                _buildBottomNav(shell),
              ],
            ),
    );
  }

  /// §5.2 场景 2 载体 A：常驻横幅（banner 方式的待处置提醒；amber 左边条）。
  /// 无待处置提醒或载体非 banner 时返回 null（不占布局）。
  Widget? _buildReminderBanner() {
    final active = widget.app.reminder.active;
    if (active == null || active.method != ReminderMethod.banner) return null;
    if (!mounted) return null;
    final l10n = AppLocalizations.of(context)!;
    final store = widget.app.reminder;
    final dark = Theme.of(context).brightness == Brightness.dark;
    final bg = dark ? const Color(0x1af59e0b) : const Color(0xfffffbeb);
    final titleColor =
        dark ? const Color(0xfffef3c7) : const Color(0xff78350f);
    final subColor =
        dark ? const Color(0xbffcd34d) : const Color(0xffb45309);

    String title;
  String? subtitle;
  List<Widget> actions;
    if (active is OngoingReminder) {
      title = l10n.bannerOngoingTitle(_formatElapsed(active.elapsed));
      subtitle = l10n.bannerOngoingSub(active.activityName);
      actions = [
        TextButton(
          onPressed: store.acknowledgeOngoing,
          child: Text(l10n.remindLater,
              style: TextStyle(fontSize: 12, color: titleColor)),
        ),
        TextButton(
          onPressed: store.acknowledgeOngoing,
          child: Text(l10n.close,
              style: TextStyle(fontSize: 12, color: titleColor)),
        ),
      ];
    } else {
      title = l10n.remQuickTitle;
      actions = [
        TextButton(
          onPressed: () {
            store.dismissQuick();
            widget.navigationShell.goBranch(0, initialLocation: true);
          },
          child: Text(l10n.timerStartRecording,
              style: TextStyle(fontSize: 12, color: titleColor)),
        ),
        TextButton(
          onPressed: store.dismissQuick,
          child: Text(l10n.close,
              style: TextStyle(fontSize: 12, color: titleColor)),
        ),
      ];
    }
    return Container(
      margin: const EdgeInsets.fromLTRB(24, 12, 24, 0),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(12),
        border: Border(
          left: BorderSide(color: const Color(0xfff59e0b), width: 4),
        ),
      ),
      child: Row(children: [
        const Icon(Icons.warning_amber_outlined,
            size: 16, color: Color(0xffd97706)),
        const SizedBox(width: 10),
        Expanded(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title,
                  style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      color: titleColor)),
              if (subtitle != null)
                Text(subtitle,
                    style: TextStyle(fontSize: 11, color: subColor)),
            ],
          ),
        ),
        ...actions,
      ]),
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
        // 托盘状态推送（批次 6；服务内去重，秒级调用无通道流量）。
        _pushTrayStatus();
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