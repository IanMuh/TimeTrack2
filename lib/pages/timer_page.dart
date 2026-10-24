import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../components/activity_picker/activity_picker.dart';
import '../components/feedback.dart';
import '../components/state_views.dart';
import '../constants/theme_tokens.dart' show ActivityPalette;
import '../l10n/app_localizations.dart';
import '../providers/bootstrap.dart';
import '../providers/data.dart';
import '../providers/engines.dart';
import '../providers/foundation.dart';
import '../stores/category_store.dart';
import '../utils/day_metrics.dart';
import '../viewmodels/activity.dart';
import '../viewmodels/commands/command_invocation.dart';
import '../viewmodels/time_entry.dart';
import 'timer_widgets.dart';

/// 计时页（契约 §4.1）——默认着陆页，会话焦点 + 快捷活动区。
///
/// 页面职责：把 store 数据装配给无业务状态子件；一切动作经
/// [CommandDispatcher] 指令通道（不变式 6/7），活动选择复用 §5.1 合并选择器
/// （契约文件 `components/activity_picker/activity_picker.dart`）。
///
/// 已知边界（注释即挂账单）：
/// - 活动 isOneOff 的编辑切换仓储 updateActivity 暂不支持（只支持 名/色），
///   表单提交后 oneOff 变更不落库（按钮语义保留，落库能力随批次 6）。
///
/// 批次 5a 收口：新建活动（选择器表单 + "临时活动"）统一经 activity_create
/// 指令通道——单条撤销记录（undo=软删/redo=复活）；分类关联仍走
/// CategoryStore.setActivityCategories（指令通道化挂账不变）。
class TimerPage extends ConsumerStatefulWidget {
  const TimerPage({super.key});

  @override
  ConsumerState<TimerPage> createState() => _TimerPageState();
}

class _TimerPageState extends ConsumerState<TimerPage> {
  AppLocalizations get l10n => AppLocalizations.of(context)!;

  // ---------------------------------------------------------------------------
  // 数据状态
  // ---------------------------------------------------------------------------

  String? _categoryFilterId; // null = 全部
  String? _pendingActivityId; // 单击选中待确认（再击 = 确认切换）
  Timer? _pendingTimer;

  /// 今日条目只读快照：每次 build 从 provider 同步（动作回调需要同一份数据）。
  List<TimeEntry> _todayEntries = const [];

  static const _pendingTimeout = Duration(milliseconds: 2500);

  @override
  void dispose() {
    _pendingTimer?.cancel();
    super.dispose();
  }

  /// 动作回调用的活动列表（build 之外读取，不持有页面副本）。
  List<Activity> get _loadedActivities =>
      ref.read(activitiesProvider).value ?? const [];

  /// 变更桥接：分类树是普通服务对象，由 provider 变更计数驱动重建，
  /// build 里 watch 变更计数保证重建，这里读当前快照。
  CategoryStore get _categories => ref.read(categoryStoreProvider);

  /// 今日累计（口径：含全部条目含未分配，运行中按当前时刻计）。
  Duration _todayTotal(DateTime dayStart, DateTime now, String? unassignedId) =>
      computeDayMetrics(
        _todayEntries,
        dayStart: dayStart,
        now: now,
        unassignedActivityId: unassignedId,
      ).total;

  int get _todaySessions => _todayEntries.length;

  // ---------------------------------------------------------------------------
  // 动作（全部经指令通道 / 选择器）
  // ---------------------------------------------------------------------------

  Future<void> _dispatch(CommandInvocation invocation) async {
    final messenger = ScaffoldMessenger.of(context);
    final result = await ref
        .read(commandDispatcherProvider)
        .dispatch(invocation);
    if (!mounted) return;
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

  void _switchTo(Activity activity) {
    _dispatch(CommandInvocation(name: 'switch', args: [activity.name]));
  }

  Future<void> _openPicker({String? focusedActivityId}) async {
    final model = _buildPickerModel();
    final isWide = MediaQuery.sizeOf(context).width >= 600;
    final events = ActivityPickerEvents(
      onSelectActivity: _switchTo,
      onCreateActivity: _createActivity,
      onCreateCategory: (d) async => (await _categories.createCategory(
        name: d.name,
        color: d.color,
        parentId: d.parentId,
      )).isSuccess,
      onEditCategory: (c) async => (await _categories.updateCategory(
        name: c.name,
        color: c.color,
        parentId: c.parentId,
        category: c,
      )).isSuccess,
      onDeleteCategory: (c) async =>
          (await _categories.deleteCategory(c.id)).isSuccess,
      onEditActivity: _editActivity,
    );
    if (isWide) {
      await showActivityCategoryPickerDialog(
        context,
        model: model,
        events: events,
        currentActivityId: _runningActivityId(),
      );
    } else {
      await showActivityCategoryPickerSheet(
        context,
        model: model,
        events: events,
        currentActivityId: _runningActivityId(),
      );
    }
  }

  String? _runningActivityId() => ref.read(timerSnapshotProvider).activityId;

  ActivityPickerModel _buildPickerModel() {
    final category = _categories;
    final primary = <String, String?>{};
    final all = <String, Set<String>>{};
    for (final link in category.links) {
      all.putIfAbsent(link.activityId, () => {}).add(link.categoryId);
      if (link.isPrimary) primary[link.activityId] = link.categoryId;
    }
    // 无主分类键显式 null（"未分类"可辨识）。
    for (final a in _loadedActivities) {
      primary.putIfAbsent(a.id, () => null);
      all.putIfAbsent(a.id, () => {});
    }
    return ActivityPickerModel(
      activities: _loadedActivities,
      categories: category.all,
      descendantsOf: category.descendantsOf,
      childrenByParent: category.childrenByParent,
      ancestorChain: category.ancestorChains,
      primaryCategoryIdByActivity: primary,
      categoryIdsByActivity: all,
    );
  }

  Future<bool> _createActivity(ActivityDraft draft) async {
    // 经指令通道新建（activity_create，单条撤销记录）；从结果载荷取回
    // 新活动实体以继续分类关联。
    final result = await ref
        .read(commandDispatcherProvider)
        .dispatch(
          CommandInvocation(
            name: 'activity_create',
            args: [draft.name],
            options: {
              'color': draft.color.toString(),
              if (draft.oneOff) 'one_off': 'true',
            },
          ),
        );
    final created = _payloadOf(result);
    if (created is! Activity) return false;
    return _applyLinks(
      created.id,
      draft.mainCategoryId,
      draft.secondaryCategoryIds,
    );
  }

  /// CommandResult 载荷提取（成功返回 data；失败/空载返回 null）。
  static Object? _payloadOf(CommandResult result) => switch (result) {
    final CommandSuccess success => success.data,
    final CommandFailure _ => null,
  };

  Future<bool> _editActivity(Activity activity) async {
    // 名/色支持；isOneOff 切换落库能力批次 5（仓储 updateActivity 仅名/色）。
    final result = await ref
        .read(activityRepositoryProvider)
        .updateActivity(
          activity: activity,
          name: activity.name,
          color: activity.color,
        );
    return result.isSuccess;
  }

  Future<bool> _applyLinks(
    String activityId,
    String? mainCategoryId,
    List<String> secondaryIds,
  ) async {
    final result = await _categories.setActivityCategories(
      activityId: activityId,
      primaryCategoryId: mainCategoryId,
      secondaryCategoryIds: secondaryIds,
    );
    return result.isSuccess;
  }

  Future<void> _startTemporary() async {
    final name = l10n.timerTemporaryActivity;
    Activity? existing;
    for (final a in _loadedActivities) {
      if (a.isOneOff && a.name == name) {
        existing = a;
        break;
      }
    }
    final Activity activity;
    if (existing != null) {
      activity = existing;
    } else {
      // 创建同样经 activity_create 指令通道（单条撤销记录，批次 5a）。
      final result = await ref
          .read(commandDispatcherProvider)
          .dispatch(
            CommandInvocation(
              name: 'activity_create',
              args: [name],
              options: {
                'color': ActivityPalette.of(
                  ActivityPalette.amber,
                  dark: false,
                ).toString(),
                'one_off': 'true',
              },
            ),
          );
      final created = _payloadOf(result);
      if (created is! Activity) {
        if (mounted) {
          showAppSnackBar(context, message: l10n.createFailed, isError: true);
        }
        return;
      }
      activity = created;
    }
    if (!mounted) return;
    _switchTo(activity);
  }

  // ---------------------------------------------------------------------------
  // 构建
  // ---------------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    // 变更桥：分类树仍由 CategoryStore 持有，变更计数
    // 驱动重建让筛选树与运行路径随库刷新。
    ref.watch(categoryChangeProvider);
    // 今日条目/活动列表均由 provider 提供（TodayStore 已删）：写操作/跨日失效。
    final today = ref.watch(currentDayProvider);
    _todayEntries = ref.watch(dayEntriesProvider(today)).value ?? const [];
    final unassignedId = ref.watch(unassignedActivityIdProvider).value;
    final activitiesAsync = ref.watch(activitiesProvider);

    if (activitiesAsync.isLoading && !activitiesAsync.hasValue) {
      return const LoadingStateView();
    }
    final activities = activitiesAsync.value;
    if (activities == null) {
      return ErrorStateView(
        message: l10n.timerLoadFailed,
        onRetry: () => ref.invalidate(activitiesProvider),
      );
    }
    final running = ref.watch(timerSnapshotProvider);
    // 1Hz 只在有运行条目时订阅：空闲页面不随秒重建。
    final now = !running.isRunning
        ? DateTime.now()
        : ref.watch(clockTickProvider);
    final recording = running.isRunning && running.activityId != unassignedId;
    if (activities.isEmpty) {
      return EmptyStateView(
        icon: Icons.business_center_outlined,
        title: l10n.timerNoActivities,
        message: l10n.startRecordingHint,
        actionLabel: l10n.newActivity,
        onAction: _openPicker,
      );
    }
    final visible = activities
        .where((a) => a.isUnassigned || _matchesFilter(a))
        .toList();
    final quick = TimerQuickSection(
      l10n: l10n,
      categoryFilterId: _categoryFilterId,
      rootCategories: _categories.childrenByParent[null] ?? const [],
      childrenByParent: _categories.childrenByParent,
      ancestorChain: _categories.ancestorChains,
      descendantsOf: _categories.descendantsOf,
      activities: visible,
      categoryIdsByActivity: _categoryIdsByActivity(),
      runningActivityId: _runningActivityId(),
      pendingActivityId: _pendingActivityId,
      todayByActivity: _todayByActivity(now),
      onFilter: (id) => setState(() => _categoryFilterId = id),
      onActivityTap: _onActivityTap,
      onActivityDoubleTap: _onActivityDoubleTap,
      onActivityLongPress: (_) => _openPicker(),
      onTemporary: _startTemporary,
      onNewActivity: _openPicker,
    );
    final content = ListView(
      padding: const EdgeInsets.fromLTRB(24, 8, 24, 40),
      children: [
        TimerFocusSection(
          l10n: l10n,
          recording: recording,
          runningName: running.activityName,
          runningColor: running.activityColor,
          runningPath: _pathOfActivity(running.activityId),
          elapsed: running.isRunning
              ? now.difference(running.startAt!)
              : Duration.zero,
          todayTotal: _todayTotal(today, now, unassignedId),
          todaySessions: _todaySessions,
          onStop: recording
              ? () => _dispatch(CommandInvocation(name: 'stop'))
              : null,
          onSwitch: _openPicker,
          onStart: recording ? null : _openPicker,
        ),
        const SizedBox(height: 48),
        quick,
      ],
    );
    return content;
  }

  String? _pathOfActivity(String? activityId) {
    if (activityId == null) return null;
    final primary = _primaryCategoryIdOf(activityId);
    if (primary == null) return null;
    final chain = _categories.ancestorChains[primary] ?? const [];
    return chain.isEmpty ? null : chain.join(' / ');
  }

  String? _primaryCategoryIdOf(String activityId) {
    for (final link in _categories.links) {
      if (link.activityId == activityId && link.isPrimary) {
        return link.categoryId;
      }
    }
    return null;
  }

  Map<String, Set<String>> _categoryIdsByActivity() {
    final map = <String, Set<String>>{};
    for (final link in _categories.links) {
      map.putIfAbsent(link.activityId, () => {}).add(link.categoryId);
    }
    return map;
  }

  /// 活动 id → 今日时长（表单与网格角标共用）。
  Map<String, Duration> _todayByActivity(DateTime now) {
    final map = <String, Duration>{};
    for (final e in _todayEntries) {
      map[e.activityId] =
          (map[e.activityId] ?? Duration.zero) + e.durationUntil(now);
    }
    return map;
  }

  bool _matchesFilter(Activity activity) {
    final filter = _categoryFilterId;
    if (filter == null) return true;
    final descendants = _categories.descendantsOf[filter] ?? const <String>{};
    final cats = <String>{};
    for (final link in _categories.links) {
      if (link.activityId == activity.id) cats.add(link.categoryId);
    }
    return cats.contains(filter) || cats.any(descendants.contains);
  }

  void _onActivityTap(Activity activity) {
    if (activity.isUnassigned) return; // 未分配不可作为切换目标
    if (_runningActivityId() == activity.id) return;
    if (_pendingActivityId == activity.id) {
      _pendingTimer?.cancel();
      setState(() => _pendingActivityId = null);
      _switchTo(activity);
      return;
    }
    _pendingTimer?.cancel();
    setState(() => _pendingActivityId = activity.id);
    _pendingTimer = Timer(_pendingTimeout, () {
      if (mounted && _pendingActivityId == activity.id) {
        setState(() => _pendingActivityId = null);
      }
    });
  }

  void _onActivityDoubleTap(Activity activity) {
    if (activity.isUnassigned || _runningActivityId() == activity.id) return;
    _pendingTimer?.cancel();
    _pendingActivityId = null;
    _switchTo(activity);
  }
}

