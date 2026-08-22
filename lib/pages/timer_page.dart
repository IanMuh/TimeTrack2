import 'dart:async';

import 'package:flutter/material.dart';

import '../components/activity_picker/activity_picker.dart';
import '../components/feedback.dart';
import '../components/state_views.dart';
import '../constants/theme_tokens.dart' show ActivityPalette;
import '../l10n/app_localizations.dart';
import '../stores/app_store.dart';
import '../viewmodels/activity.dart';
import '../viewmodels/commands/command_invocation.dart';
import 'timer_widgets.dart';

/// 计时页（契约 §4.1）——默认着陆页，会话焦点 + 快捷活动区。
///
/// 页面职责：把 store 数据装配给无业务状态子件；一切动作经
/// [CommandDispatcher] 指令通道（不变式 6/7），活动选择复用 §5.1 合并选择器
/// （契约文件 `components/activity_picker/activity_picker.dart`）。
///
/// 已知边界（注释即挂账单，批次 5 收口）：
/// - "临时活动"= 创建一次性活动再切换，属两条数据操作，**非单条撤销记录**
///   （缺 ActivityChangeApplier，收口时并入 activity_create 指令）；
/// - 活动 isOneOff 的编辑切换仓储 updateActivity 暂不支持（只支持 名/色），
///   表单提交后 oneOff 变更不落库（按钮语义保留，落库能力随批次 5）。
class TimerPage extends StatefulWidget {
  const TimerPage({super.key, required this.app});

  final AppStore app;

  @override
  State<TimerPage> createState() => _TimerPageState();
}

class _TimerPageState extends State<TimerPage> {
  AppStore get app => widget.app;
  AppLocalizations get l10n => AppLocalizations.of(context)!;

  // ---------------------------------------------------------------------------
  // 数据状态
  // ---------------------------------------------------------------------------

  List<Activity> _activities = const [];
  bool _loading = true;
  bool _failed = false;
  String? _categoryFilterId; // null = 全部
  String? _pendingActivityId; // 单击选中待确认（再击 = 确认切换）
  Timer? _pendingTimer;
  String? _checkedRunningActivityId;
  bool _recording = false; // 运行条目是否处于"记录中"（未分配 = 未记录）
  bool _disposed = false;

  static const _pendingTimeout = Duration(milliseconds: 2500);

  @override
  void initState() {
    super.initState();
    _load();
    app.timer.addListener(_onLiveChanged);
    app.clock.addListener(_onLiveChanged);
    app.today.addListener(_onLiveChanged);
    app.category.addListener(_load);
    app.dataRevision.addListener(_load);
  }

  @override
  void dispose() {
    _disposed = true;
    _pendingTimer?.cancel();
    app.timer.removeListener(_onLiveChanged);
    app.clock.removeListener(_onLiveChanged);
    app.today.removeListener(_onLiveChanged);
    app.category.removeListener(_load);
    app.dataRevision.removeListener(_load);
    super.dispose();
  }

  void _onLiveChanged() {
    _refreshRecordingState();
    if (mounted) setState(() {});
  }

  void _refreshRecordingState() {
    final running = app.timer.runningEntry;
    if (running == null) {
      _checkedRunningActivityId = null;
      _recording = false;
      return;
    }
    if (_checkedRunningActivityId == running.activityId) return;
    _checkedRunningActivityId = running.activityId;
    _recording = false; // 查询期间先按记录中渲染，防闪烁
    final id = running.activityId;
    Future.microtask(() async {
      final isUnassigned = await app.activities.activityIdIsUnassigned(id);
      if (_disposed || _checkedRunningActivityId != id) return;
      setState(() => _recording = !isUnassigned);
    });
  }

  Future<void> _load() async {
    if (_disposed) return;
    final result = await app.activities.activities();
    if (_disposed) return;
    setState(() {
      _loading = false;
      if (result.isSuccess) {
        _activities = result.requireValue();
        _failed = false;
      } else {
        _failed = true;
      }
    });
  }

  /// 今日累计（running 条目截至 now——口径：含全部条目含未分配，运行中按
  /// 当前时刻计；与今日页/统计页口径在批次 3 统一为数据层计算）。
  Duration get _todayTotal {
    if (app.today.today.isEmpty) return app.today.totalDuration();
    return app.today.totalDuration();
  }

  int get _todaySessions => app.today.today.length;

  /// 活动 id → 今日时长（运行中条目仅当活动本身就是运行条目且非未分配）。
  bool get _isRecording => _recording;

  // ---------------------------------------------------------------------------
  // 动作（全部经指令通道 / 选择器）
  // ---------------------------------------------------------------------------

  Future<void> _dispatch(CommandInvocation invocation) async {
    final messenger = ScaffoldMessenger.of(context);
    final result = await app.dispatcher.dispatch(invocation);
    if (!mounted) return;
    messenger.hideCurrentSnackBar();
    messenger.showSnackBar(
      SnackBar(
        content: Text(
          result.fold(onSuccess: (s) => s.message ?? l10n.commandDone, onFailure: (f) => f.reason),
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
      onCreateCategory: (d) async =>
            (await app.category.createCategory(
              name: d.name,
              color: d.color,
              parentId: d.parentId,
            )).isSuccess,
      onEditCategory: (c) async =>
            (await app.category.updateCategory(
              name: c.name,
              color: c.color,
              parentId: c.parentId,
              category: c,
            )).isSuccess,
      onDeleteCategory: (c) async =>
          (await app.category.deleteCategory(c.id)).isSuccess,
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

  String? _runningActivityId() => app.timer.runningEntry?.activityId;

  ActivityPickerModel _buildPickerModel() {
    final category = app.category;
    final primary = <String, String?>{};
    final all = <String, Set<String>>{};
    for (final link in category.links) {
      all.putIfAbsent(link.activityId, () => {}).add(link.categoryId);
      if (link.isPrimary) primary[link.activityId] = link.categoryId;
    }
    // 无主分类键显式 null（"未分类"可辨识）。
    for (final a in _activities) {
      primary.putIfAbsent(a.id, () => null);
      all.putIfAbsent(a.id, () => {});
    }
    return ActivityPickerModel(
      activities: _activities,
      categories: category.all,
      descendantsOf: category.descendantsOf,
      childrenByParent: category.childrenByParent,
      ancestorChain: category.ancestorChains,
      primaryCategoryIdByActivity: primary,
      categoryIdsByActivity: all,
    );
  }

  Future<bool> _createActivity(ActivityDraft draft) async {
    final result = await app.activities.createActivity(
      name: draft.name,
      color: draft.color,
      isOneOff: draft.oneOff,
    );
    if (result.isSuccess == false) return false;
    final activity = result.requireValue();
    return _applyLinks(activity.id, draft.mainCategoryId, draft.secondaryCategoryIds);
  }

  Future<bool> _editActivity(Activity activity) async {
    // 名/色支持；isOneOff 切换落库能力批次 5（仓储 updateActivity 仅名/色）。
    final result = await app.activities.updateActivity(
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
    final result = await app.category.setActivityCategories(
      activityId: activityId,
      primaryCategoryId: mainCategoryId,
      secondaryCategoryIds: secondaryIds,
    );
    return result.isSuccess;
  }

  Future<void> _startTemporary() async {
    final name = l10n.timerTemporaryActivity;
    Activity? existing;
    for (final a in _activities) {
      if (a.isOneOff && a.name == name) {
        existing = a;
        break;
      }
    }
    final Activity activity;
    if (existing != null) {
      activity = existing;
    } else {
      final result = await app.activities.createActivity(
        name: name,
        color: ActivityPalette.of(ActivityPalette.amber, dark: false),
        isOneOff: true,
      );
      if (result.isSuccess == false) {
        if (mounted) {
          showAppSnackBar(context, message: l10n.createFailed, isError: true);
        }
        return;
      }
      activity = result.requireValue();
    }
    if (!mounted) return;
    _switchTo(activity);
  }


  // ---------------------------------------------------------------------------
  // 构建
  // ---------------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    if (_loading) return const LoadingStateView();
    final running = app.timer.runningEntry;
    if (_failed) {
      return ErrorStateView(
        message: l10n.timerLoadFailed,
        onRetry: () {
          setState(() {
            _loading = true;
            _failed = false;
          });
          _load();
        },
      );
    }
    if (_activities.isEmpty) {
      return EmptyStateView(
        icon: Icons.business_center_outlined,
        title: l10n.timerNoActivities,
        message: l10n.startRecordingHint,
        actionLabel: l10n.newActivity,
        onAction: _openPicker,
      );
    }
    final visible = _activities
        .where((a) => a.isUnassigned || _matchesFilter(a))
        .toList();

    return ListView(
      padding: const EdgeInsets.fromLTRB(20, 24, 20, 24),
      children: [
        TimerFocusCard(
          l10n: l10n,
          recording: _isRecording,
          runningName: running?.activityNameSnapshot,
          runningColor: running?.activityColorSnapshot,
          elapsed:
              running == null ? Duration.zero : running.durationUntil(DateTime.now()),
          todayTotal: _todayTotal,
          todaySessions: _todaySessions,
          onStartRecording: _isRecording ? null : _openPicker,
        ),
        const SizedBox(height: 16),
        TimerActionRow(
          l10n: l10n,
          onStop: _isRecording
              ? () => _dispatch(CommandInvocation(name: 'stop'))
              : null,
          onSwitch: _openPicker,
        ),
        const SizedBox(height: 20),
        TimerQuickSection(
          l10n: l10n,
          categoryFilterId: _categoryFilterId,
          rootCategories: app.category.childrenByParent[null] ?? const [],
          ancestors: app.category.ancestorChains,
          descendantsOf: app.category.descendantsOf,
          activities: visible,
          categoryIdsByActivity: _categoryIdsByActivity(),
          runningActivityId: _runningActivityId(),
          pendingActivityId: _pendingActivityId,
          todayByActivity: _todayByActivity(),
          onFilter: (id) => setState(() => _categoryFilterId = id),
          onActivityTap: _onActivityTap,
          onActivityDoubleTap: _onActivityDoubleTap,
          onActivityLongPress: (_) => _openPicker(),
          onTemporary: _startTemporary,
          onNewActivity: _openPicker,
        ),
        const SizedBox(height: 12),
        Text(
          l10n.timerInteractionHint,
          style: TextStyle(
            fontSize: 11,
            color: Theme.of(context).colorScheme.onSurfaceVariant,
          ),
        ),
      ],
    );
  }

  Map<String, Set<String>> _categoryIdsByActivity() {
    final map = <String, Set<String>>{};
    for (final link in app.category.links) {
      map.putIfAbsent(link.activityId, () => {}).add(link.categoryId);
    }
    return map;
  }

  /// 活动 id → 今日时长（表单与网格角标共用）。
  Map<String, Duration> _todayByActivity() {
    final map = <String, Duration>{};
    for (final e in app.today.today) {
      map[e.activityId] = (map[e.activityId] ?? Duration.zero) +
          e.durationUntil(DateTime.now());
    }
    return map;
  }

  bool _matchesFilter(Activity activity) {
    final filter = _categoryFilterId;
    if (filter == null) return true;
    final descendants = app.category.descendantsOf[filter] ?? const <String>{};
    final cats = <String>{};
    for (final link in app.category.links) {
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
