import 'package:flutter/material.dart';

import '../components/activity_picker/activity_picker.dart';
import '../components/entry_editor_dialog.dart';
import '../components/feedback.dart';
import '../components/state_views.dart';
import '../components/tnum_text.dart';
import '../data/repositories/action_log_repository.dart';
import '../l10n/app_localizations.dart';
import '../stores/app_store.dart';
import '../utils/day_metrics.dart';
import '../viewmodels/action_log.dart';
import '../viewmodels/activity.dart';
import '../viewmodels/commands/command_invocation.dart';
import '../viewmodels/time_entry.dart';
import 'timeline_widgets.dart';

/// 时间线页（契约 §4.3）：竖向时间轴主视图 + 比例条次要 tab + 条目明细 +
/// 条目编辑对话框 + 日志视图。
///
/// 动作全部经 [CommandDispatcher]（铁律 7）。批次 5a 收口：编辑保存与
/// "延伸到当前时刻"均走单条 entry_update 指令（一条撤销记录）；时间选项
/// 相对条目所在日还原，显式 --end 早于起点视为次日凌晨（跨零点延伸）。
/// **仍挂账**：
/// - add 指令的 start/end 仅支持当日时刻（跨日移动条目能力未收口）；
/// - "最长连续" 口径暂取单条最大时长（未接合并阈值设置）。
class TimelinePage extends StatefulWidget {
  const TimelinePage({super.key, required this.app});

  final AppStore app;

  @override
  State<TimelinePage> createState() => _TimelinePageState();
}

class _TimelinePageState extends State<TimelinePage> {
  AppStore get app => widget.app;

  /// 时制偏好（设置即时生效——settings 监听驱动重建）。
  bool get _use24 => app.settings.current?.use24HourFormat ?? true;
  AppLocalizations get l10n => AppLocalizations.of(context)!;

  static const _spans = [1, 3, 7]; // 今天/三天/本周（天）

  int _spanIndex = 0;
  bool _viewEntries = true; // 条目 / 日志
  int _axisTab = 0; // 0=时间轴 1=比例条
  DateTime _anchor = _today();
  double _zoom = 1.0;
  int _segments = 4;
  bool _disposed = false;

  List<Activity> _activities = const [];
  List<ActionLog> _logs = const [];
  bool _logsLoaded = false;
  String? _unassignedId;

  static DateTime _today() {
    final n = DateTime.now();
    return DateTime(n.year, n.month, n.day);
  }

  (DateTime, DateTime) get _range => (
        _anchor,
        _anchor.add(Duration(days: _spans[_spanIndex])),
      );

  List<TimeEntry> get _entries => app.timeline.entriesForRange;
  bool get _isFuture => _anchor.isAfter(_today());

  @override
  void initState() {
    super.initState();
    _reload();
    _initData();
    app.timeline.addListener(_onChange);
    app.clock.addListener(_onChange);
    app.dataRevision.addListener(_onChange);
    // 时制等偏好变更即时一致（不变式 7）：设置保存后 SettingsStore notify。
    app.settings.addListener(_onChange);
  }

  @override
  void dispose() {
    _disposed = true;
    app.settings.removeListener(_onChange);
    app.timeline.removeListener(_onChange);
    app.clock.removeListener(_onChange);
    app.dataRevision.removeListener(_onChange);
    super.dispose();
  }

  void _onChange() {
    if (mounted) setState(() {});
  }

  Future<void> _reload() async {
    final (s, e) = _range;
    await app.timeline.loadRange(s, e);
  }

  Future<void> _initData() async {
    final u = await app.activities.unassignedActivity();
    if (_disposed) return;
    _unassignedId = u.isSuccess ? u.requireValue().id : null;
    final acts = await app.activities.activities();
    if (_disposed) return;
    setState(() {
      if (acts.isSuccess) _activities = acts.requireValue();
    });
  }

  Future<void> _loadLogs() async {
    if (_logsLoaded) return;
    final repo = ActionLogRepository(database: app.database);
    final result = await repo.logs(limit: 50);
    if (_disposed) return;
    setState(() {
      if (result.isSuccess) _logs = result.requireValue();
      _logsLoaded = true;
    });
  }

  // ---------------------------------------------------------------------------
  // 汇总（口径：范围条目裁剪；最长连续暂取单条最大——挂账批次 5）
  // ---------------------------------------------------------------------------

  Duration get _longest {
    var v = Duration.zero;
    for (final e in _entries) {
      final d = e.durationUntil(DateTime.now());
      if (d > v) v = d;
    }
    return v;
  }

  DayMetrics get _metrics => computeDayMetrics(
        _entries,
        dayStart: _range.$1,
        now: DateTime.now(),
        unassignedActivityId: _unassignedId,
      );

  // ---------------------------------------------------------------------------
  // 指令通道动作
  // ---------------------------------------------------------------------------

  static String _hm(DateTime t) =>
      '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';

  Activity? _activityById(String? id) {
    if (id == null) return null;
    for (final a in _activities) {
      if (a.id == id) return a;
    }
    return null;
  }


  /// CommandResult 成败（fold 语义——CommandResult 无 isSuccess getter）。
  bool _ok(CommandResult r) => r.fold(
        onSuccess: (_) => true,
        onFailure: (_) => false,
      );

  Future<bool> _submitEntry(EntryEditDraft draft) async {
    final options = <String, String>{
      'start': _hm(draft.start),
      'end': _hm(draft.end ?? DateTime.now()),
      if (draft.note.isNotEmpty) 'note': draft.note,
    };
    if (draft.entryId != null) {
      // 编辑 = 单条 entry_update 指令（一条撤销记录，批次 5a 收口）。
      // 目标活动按名解析；原活动已删/未选中时不传 --activity——保持条目
      // 现有活动（部分更新语义），不静默改挂到其他活动。
      final target = _activityById(draft.activityId);
      final r = await app.dispatcher.dispatch(CommandInvocation(
        name: 'entry_update',
        args: [draft.entryId!],
        options: {
          ...options,
          if (target != null) 'activity': target.name,
        },
      ));
      return _ok(r);
    }
    final targetNew = _activityById(draft.activityId) ?? _activities.firstOrNull;
    if (targetNew == null) return false;
    final r = await app.dispatcher.dispatch(
      CommandInvocation(name: 'add', args: [targetNew.name], options: options),
    );
    return _ok(r);
  }

  // ---------------------------------------------------------------------------
  // 编辑对话框（活动选择复用合并选择器）
  // ---------------------------------------------------------------------------

  Future<void> _openEditor({TimeEntry? entry}) async {
    if (_activities.isEmpty) {
      showAppSnackBar(context, message: l10n.tlNoActivity, isError: true);
      return;
    }
    var selected = entry == null
        ? _activities.firstWhere(
            (a) => a.id != _unassignedId,
            orElse: () => _activities.first,
          )
        : (_activityById(entry.activityId) ?? _activities.first);
    await showEntryEditorDialog(
      context,
      use24: _use24,
      entry: entry,
      currentActivityId: selected.id,
      currentActivityName: selected.name,
      currentActivityColor: selected.color,
      onPickActivity: () async {
        // 在编辑器之上打开合并选择器（选择即回填编辑器字段——通过
        // showDialog 返回前先让用户选完：这里简化为直接打开选择器并
        // await 完成后关闭编辑器重新打开（数据流简单可靠）。
        final picked = await _pickActivity();
        if (picked != null) {
          setState(() => selected = picked);
        }
      },
      existing: _entries,
      onSubmit: _submitEntry,
      onDelete: (id) async => _ok(await app.dispatcher
          .dispatch(CommandInvocation(name: 'delete', args: [id]))),
      onMerge: (id, direction) async => _ok(await app.dispatcher.dispatch(
          CommandInvocation(
              name: 'merge', args: [id], options: {'direction': direction}))),
      onSplit: (id, at) async => _ok(await app.dispatcher.dispatch(
          CommandInvocation(
              name: 'split', args: [id], options: {'at': _hm(at)}))),
      onExtendToNow: (id) async {
        // 延伸 = 单条 entry_update（end=now；跨零点由分发器 +1 天启发处理）。
        return _ok(await app.dispatcher.dispatch(CommandInvocation(
          name: 'entry_update',
          args: [id],
          options: {'end': _hm(DateTime.now())},
        )));
      },
    );
  }

  Future<Activity?> _pickActivity() async {
    final category = app.category;
    final primary = <String, String?>{};
    final all = <String, Set<String>>{};
    for (final link in category.links) {
      all.putIfAbsent(link.activityId, () => {}).add(link.categoryId);
      if (link.isPrimary) primary[link.activityId] = link.categoryId;
    }
    for (final a in _activities) {
      primary.putIfAbsent(a.id, () => null);
      all.putIfAbsent(a.id, () => {});
    }
    final model = ActivityPickerModel(
      activities: _activities,
      categories: category.all,
      descendantsOf: category.descendantsOf,
      childrenByParent: category.childrenByParent,
      ancestorChain: category.ancestorChains,
      primaryCategoryIdByActivity: primary,
      categoryIdsByActivity: all,
    );
    Activity? picked;
    await showActivityCategoryPickerDialog(
      context,
      model: model,
      events: ActivityPickerEvents(onSelectActivity: (a) => picked = a),
    );
    return picked;
  }

  // ---------------------------------------------------------------------------
  // 构建
  // ---------------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    if (!_viewEntries) _loadLogs();
    final scheme = Theme.of(context).colorScheme;
    final m = _metrics;
    final loading =
        app.timeline.loadedRange == null && !app.timeline.loadFailed;
    if (loading) return const LoadingStateView();
    if (app.timeline.loadFailed) {
      return ErrorStateView(
        message: l10n.timerLoadFailed,
        onRetry: _reload,
      );
    }

    return ListView(
      padding: const EdgeInsets.fromLTRB(24, 20, 24, 40),
      children: [
        _buildToolbar(scheme),
        const SizedBox(height: 12),
        TlSummaryStrip(
          l10n: l10n,
          total: m.total,
          sessions: m.sessions,
          longest: _longest,
        ),
        const SizedBox(height: 14),
        if (_isFuture)
          AppBanner(
            type: AppBannerType.info,
            title: l10n.tlFutureBanner,
          ),
        const SizedBox(height: 8),
        if (!_viewEntries) ..._buildLogs(),
        if (_viewEntries) ...[
          if (_entries.isEmpty)
            EmptyStateView(
              icon: Icons.view_timeline_outlined,
              title: l10n.todayEmptyDay,
              message: l10n.startRecordingHint,
            )
          else ..._buildEntriesArea(scheme),
        ],
      ],
    );
  }

  Widget _buildToolbar(ColorScheme scheme) {
    return Wrap(
      spacing: 10,
      runSpacing: 8,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        Text(
          l10n.navTimeline,
          style: const TextStyle(
            fontSize: 18,
            fontWeight: FontWeight.w600,
            letterSpacing: -0.3,
          ),
        ),
        FilledButton.icon(
          onPressed: () => _openEditor(),
          icon: const Icon(Icons.add, size: 16),
          label: Text(l10n.tlAdd),
        ),
        IconButton(
          tooltip: l10n.todayPrevDay,
          icon: const Icon(Icons.chevron_left_rounded),
          onPressed: () => _shift(-1),
        ),
        IconButton(
          tooltip: l10n.todayPickDate,
          icon: const Icon(Icons.calendar_month_outlined, size: 18),
          onPressed: _pickDate,
        ),
        IconButton(
          tooltip: l10n.todayNextDay,
          icon: const Icon(Icons.chevron_right_rounded),
          onPressed: () => _shift(1),
        ),
        _segmented(
          options: [l10n.tlSpanToday, l10n.tlSpanThree, l10n.tlSpanWeek],
          selected: _spanIndex,
          onSelect: (i) => setState(() {
            _spanIndex = i;
            _reload();
          }),
        ),
        _segmented(
          options: [l10n.tlViewEntries, l10n.tlViewLogs],
          selected: _viewEntries ? 0 : 1,
          onSelect: (i) => setState(() => _viewEntries = i == 0),
        ),
      ],
    );
  }

  Widget _segmented({
    required List<String> options,
    required int selected,
    required ValueChanged<int> onSelect,
  }) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.all(2),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (var i = 0; i < options.length; i++)
            GestureDetector(
              onTap: () => onSelect(i),
              child: Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                decoration: BoxDecoration(
                  color: i == selected ? scheme.surface : Colors.transparent,
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Text(
                  options[i],
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight:
                        i == selected ? FontWeight.w600 : FontWeight.w500,
                    color: i == selected ? scheme.onSurface : scheme.onSurfaceVariant,
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  void _shift(int days) {
    setState(() => _anchor = _anchor.add(Duration(days: days)));
    _reload();
  }

  Future<void> _pickDate() async {
    final picked = await showDatePicker(
      context: context,
      initialDate: _anchor,
      firstDate: DateTime.now().subtract(const Duration(days: 365 * 3)),
      lastDate: DateTime.now().add(const Duration(days: 365)),
    );
    if (picked != null) {
      setState(() => _anchor = picked);
      _reload();
    }
  }

  List<Widget> _buildEntriesArea(ColorScheme scheme) {
    return [
      // 视图 tab：时间轴（竖向主视图）/ 比例条（横向+缩放+分段）。
      _segmented(
        options: [l10n.tlAxisTab, l10n.tlStripTab],
        selected: _axisTab,
        onSelect: (i) => setState(() => _axisTab = i),
      ),
      const SizedBox(height: 12),
      if (_axisTab == 0)
        TlVerticalTimeline(
          use24: _use24,
          entries: _entries,
          unassignedActivityId: _unassignedId,
          now: DateTime.now(),
          onEntryTap: (e) => _openEditor(entry: e),
          dayGroups: _spanIndex > 0,
        )
      else ...[
        TlStripTrack(
          entries: _entries,
          unassignedActivityId: _unassignedId,
          now: DateTime.now(),
          zoom: _zoom,
          segments: _segments,
          onEntryTap: (e) => _openEditor(entry: e),
        ),
        const SizedBox(height: 10),
        // 工具行：缩放 + 分段 1-12。
        Row(
          children: [
            Text(l10n.tlZoom,
                style: TextStyle(fontSize: 11, color: scheme.onSurfaceVariant)),
            IconButton(
              iconSize: 16,
              visualDensity: VisualDensity.compact,
              icon: const Icon(Icons.remove_rounded),
              onPressed: _zoom <= 1.0
                  ? null
                  : () => setState(() => _zoom = (_zoom - 0.25).clamp(1.0, 3.0)),
            ),
            IconButton(
              iconSize: 16,
              visualDensity: VisualDensity.compact,
              icon: const Icon(Icons.add_rounded),
              onPressed: _zoom >= 3.0
                  ? null
                  : () => setState(() => _zoom = (_zoom + 0.25).clamp(1.0, 3.0)),
            ),
            const SizedBox(width: 16),
            Text(l10n.tlSegments,
                style: TextStyle(fontSize: 11, color: scheme.onSurfaceVariant)),
            IconButton(
              iconSize: 16,
              visualDensity: VisualDensity.compact,
              icon: const Icon(Icons.remove_rounded),
              onPressed: _segments <= 1
                  ? null
                  : () => setState(() => _segments--),
            ),
            TnumText('$_segments', style: const TextStyle(fontSize: 12)),
            IconButton(
              iconSize: 16,
              visualDensity: VisualDensity.compact,
              icon: const Icon(Icons.add_rounded),
              onPressed: _segments >= 12
                  ? null
                  : () => setState(() => _segments++),
            ),
          ],
        ),
      ],
      const SizedBox(height: 18),
      // 条目明细（全宽表格化行）。
      Container(
        decoration: BoxDecoration(
          color: scheme.surface,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: scheme.outline),
        ),
        child: Column(
          children: [
            for (final e in _entries)
              TlEntryListRow(
                use24: _use24,
                entry: e,
                now: DateTime.now(),
                onTap: () => _openEditor(entry: e),
              ),
          ],
        ),
      ),
    ];
  }

  List<Widget> _buildLogs() {
    final scheme = Theme.of(context).colorScheme;
    if (_logs.isEmpty) {
      return [
        EmptyStateView(
          icon: Icons.receipt_long_outlined,
          title: l10n.tlLogsEmpty,
        ),
      ];
    }
    return [
      Container(
        decoration: BoxDecoration(
          color: scheme.surface,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: scheme.outline),
        ),
        child: Column(
          children: [
            for (final log in _logs)
              TlLogRow(
                typeLabel: _logLabel(log.actionType),
                typeColor: _logColor(log.actionType),
                occurredAt: log.occurredAt,
                message: log.message,
                deviceId: log.deviceId,
              ),
          ],
        ),
      ),
    ];
  }

  String _logLabel(ActionType t) => switch (t) {
        ActionType.switch_ => l10n.logSwitch,
        ActionType.stop => l10n.logStop,
        ActionType.edit => l10n.logEdit,
        ActionType.delete => l10n.logDelete,
        ActionType.undo => l10n.logUndo,
        ActionType.redo => l10n.logRedo,
        ActionType.merge => l10n.logMerge,
        ActionType.manual => l10n.logManual,
        ActionType.split => l10n.logSplit,
        ActionType.activityDelete => l10n.logActivityDelete,
        ActionType.categoryCreate => l10n.logCategoryCreate,
        ActionType.categoryUpdate => l10n.logCategoryUpdate,
        _ => t.name,
      };

  Color _logColor(ActionType t) => switch (t) {
        ActionType.switch_ => const Color(0xff6366f1),
        ActionType.stop => const Color(0xfff43f5e),
        ActionType.edit => const Color(0xff0ea5e9),
        ActionType.delete => const Color(0xffdc2626),
        ActionType.undo => const Color(0xff8b5cf6),
        ActionType.redo => const Color(0xffa78bfa),
        ActionType.merge => const Color(0xfff59e0b),
        ActionType.manual => const Color(0xff10b981),
        ActionType.split => const Color(0xff14b8a6),
        _ => const Color(0xff71717a),
      };
}
