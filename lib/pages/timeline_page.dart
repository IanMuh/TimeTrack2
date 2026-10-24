import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../components/activity_picker/activity_picker.dart';
import '../components/entry_editor_dialog.dart';
import '../components/feedback.dart';
import '../components/state_views.dart';
import '../components/tnum_text.dart';
import '../l10n/app_localizations.dart';
import '../providers/bootstrap.dart';
import '../providers/data.dart';
import '../providers/engines.dart';
import '../providers/foundation.dart';
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
class TimelinePage extends ConsumerStatefulWidget {
  const TimelinePage({super.key});

  @override
  ConsumerState<TimelinePage> createState() => _TimelinePageState();
}

class _TimelinePageState extends ConsumerState<TimelinePage> {
  /// 时制偏好（设置即时生效——设置保存会 bump 修订号，查询 provider 失效重建）。
  bool get _use24 =>
      ref.read(settingsStoreProvider).current?.use24HourFormat ?? true;
  AppLocalizations get l10n => AppLocalizations.of(context)!;

  static const _spans = [1, 3, 7]; // 今天/三天/本周（天）

  int _spanIndex = 0;
  bool _viewEntries = true; // 条目 / 日志
  int _axisTab = 0; // 0=时间轴 1=比例条

  /// 锚点日；[_followToday] 为真时 build 中跟随 [currentDayProvider] 前移
  /// （跨午夜不再停留昨日）。
  DateTime _anchor = _today();
  bool _followToday = true;
  double _zoom = 1.0;
  int _segments = 4;

  /// 迁移期：每次 build 从 provider 同步的只读快照（指令送达/对话框里要用
  /// 同一份数据；不再是“缓存事实源”，失效由 provider 负责）。
  List<Activity> _activities = const [];
  List<ActionLog> _logs = const [];
  List<TimeEntry> _entries = const [];
  String? _unassignedId;

  /// 编辑对话框打开时的初始活动 id（编辑态）：--activity 仅在用户显式
  /// 更换活动时传入的比对基准（防预填的首个活动被静默落库）。
  String? _editorInitialActivityId;

  static DateTime _today() {
    final n = DateTime.now();
    return DateTime(n.year, n.month, n.day);
  }

  (DateTime, DateTime) get _range =>
      (_anchor, _anchor.add(Duration(days: _spans[_spanIndex])));

  bool get _isFuture => _anchor.isAfter(_today());

  // ---------------------------------------------------------------------------
  // 汇总（口径：范围条目裁剪；最长连续暂取单条最大——挂账批次 6）
  // ---------------------------------------------------------------------------

  Duration _longest(DateTime now) {
    var v = Duration.zero;
    for (final e in _entries) {
      final d = e.durationUntil(now);
      if (d > v) v = d;
    }
    return v;
  }

  DayMetrics _metricsAt(DateTime now) => computeDayMetrics(
    _entries,
    dayStart: _range.$1,
    now: now,
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
  bool _ok(CommandResult r) =>
      r.fold(onSuccess: (_) => true, onFailure: (_) => false);

  Future<bool> _submitEntry(EntryEditDraft draft) async {
    // --end 三态：keepRunning = 不传（部分更新语义下运行条目保持无 end，
    // 防"编辑运行中条目保存即被结束"）；endIsNow = 特值 'now'（绝对当前
    // 时刻，跨天条目不受 HH:MM 按条目所在日还原影响）；其余 = HH:MM。
    final options = <String, String>{
      'start': _hm(draft.start),
      if (!draft.keepRunning) //
        'end': draft.endIsNow ? 'now' : _hm(draft.end!),
      // 无条件传（含空串 = 清空备注）——按非空省略会让"删光备注保存"失效。
      'note': draft.note,
    };
    if (draft.entryId != null) {
      // 编辑 = 单条 entry_update 指令（一条撤销记录，批次 5a 收口）。
      // --activity 仅在用户显式更换活动时传（与打开对话框时的初始选择
      // 比对）：条目原活动不在当前列表（已删/页面加载后新建）时对话框
      // 会预填首个活动，无条件传会把条目静默改挂——不传 = 部分更新语义
      // 下的"保持现有活动"。
      final target = _activityById(draft.activityId);
      final r = await ref
          .read(commandDispatcherProvider)
          .dispatch(
            CommandInvocation(
              name: 'entry_update',
              args: [draft.entryId!],
              options: {
                ...options,
                if (target != null && target.id != _editorInitialActivityId)
                  'activity': target.name,
              },
            ),
          );
      return _ok(r);
    }
    final targetNew =
        _activityById(draft.activityId) ?? _activities.firstOrNull;
    if (targetNew == null) return false;
    final r = await ref
        .read(commandDispatcherProvider)
        .dispatch(
          CommandInvocation(
            name: 'add',
            args: [targetNew.name],
            options: {
              ...options,
              // add 指令需要 HH:MM（不支持 now 特值）；新条目必在今日，HH:MM
              // 锚定无漂移。
              'end': _hm(draft.end ?? DateTime.now()),
            },
          ),
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
    _editorInitialActivityId = entry == null ? null : selected.id;
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
        if (picked != null && mounted) {
          setState(() => selected = picked);
        }
      },
      existing: _entries,
      onSubmit: _submitEntry,
      onDelete: (id) async => _ok(
        await ref
            .read(commandDispatcherProvider)
            .dispatch(CommandInvocation(name: 'delete', args: [id])),
      ),
      onMerge: (id, direction) async => _ok(
        await ref
            .read(commandDispatcherProvider)
            .dispatch(
              CommandInvocation(
                name: 'merge',
                args: [id],
                options: {'direction': direction},
              ),
            ),
      ),
      onSplit: (id, at) async => _ok(
        await ref
            .read(commandDispatcherProvider)
            .dispatch(
              CommandInvocation(
                name: 'split',
                args: [id],
                options: {'at': _hm(at)},
              ),
            ),
      ),
      onExtendToNow: (id) async {
        // 延伸 = 单条 entry_update（--end=now 绝对语义，跨天遗留条目也
        // 精确结束在当前时刻；HH:MM 会按条目所在日还原，≥2 天前的条目
        // 会算错）。
        return _ok(
          await ref
              .read(commandDispatcherProvider)
              .dispatch(
                CommandInvocation(
                  name: 'entry_update',
                  args: [id],
                  options: const {'end': 'now'},
                ),
              ),
        );
      },
    );
  }

  Future<Activity?> _pickActivity() async {
    final category = ref.read(categoryStoreProvider);
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
    final events = ActivityPickerEvents(onSelectActivity: (a) => picked = a);
    // 契约 §5.1：移动（<600）= 底部抽屉形态——桌面双栏弹窗左栏固定 232px，
    // 紧凑视口下活动列表只剩几十像素（与计时页同款分支）。
    if (MediaQuery.sizeOf(context).width >= 600) {
      await showActivityCategoryPickerDialog(
        context,
        model: model,
        events: events,
      );
    } else {
      await showActivityCategoryPickerSheet(
        context,
        model: model,
        events: events,
      );
    }
    return picked;
  }

  // ---------------------------------------------------------------------------
  // 构建
  // ---------------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    // 跟随今天：跨午夜由 currentDayProvider 驱动翻日（旧实现锚点固定在
    // initState，午夜后与数据窗口错位）。
    final today = ref.watch(currentDayProvider);
    if (_followToday) _anchor = today;
    // 迁移期桥接：24 小时制等设置变更需重建时间轴。
    ref.watch(settingsChangeProvider);

    // 查询即 provider：切日/切跨度只改键，不手工 reload；写操作会 bump
    // 修订号 → provider 失效 → 本页重建。
    final range = _range;
    final entriesAsync = ref.watch(rangeEntriesProvider(range));
    _entries = entriesAsync.value ?? const [];
    _activities = ref.watch(activitiesProvider).value ?? _activities;
    _unassignedId = ref.watch(unassignedActivityIdProvider).value;
    if (!_viewEntries) {
      // 日志改为 provider：此前 _logsLoaded 永久守卫导致打开一次后永不刷新。
      _logs = ref.watch(actionLogsProvider(50)).value ?? const [];
    }

    if (!entriesAsync.hasValue) {
      if (entriesAsync.hasError) {
        return ErrorStateView(
          message: l10n.timerLoadFailed,
          onRetry: () => ref.invalidate(rangeEntriesProvider(range)),
        );
      }
      return const LoadingStateView();
    }

    // 运行中条目时长随时间增长：仅存在运行条目时订阅 1Hz tick。
    final hasRunning = _entries.any((e) => e.endAt == null);
    final now = hasRunning ? ref.watch(clockTickProvider) : DateTime.now();

    final scheme = Theme.of(context).colorScheme;
    final m = _metricsAt(now);

    return ListView(
      padding: const EdgeInsets.fromLTRB(24, 20, 24, 40),
      children: [
        _buildToolbar(scheme),
        const SizedBox(height: 12),
        TlSummaryStrip(
          l10n: l10n,
          total: m.total,
          sessions: m.sessions,
          longest: _longest(now),
        ),
        const SizedBox(height: 14),
        if (_isFuture)
          AppBanner(type: AppBannerType.info, title: l10n.tlFutureBanner),
        const SizedBox(height: 8),
        if (!_viewEntries) ..._buildLogs(),
        if (_viewEntries) ...[
          if (_entries.isEmpty)
            EmptyStateView(
              icon: Icons.view_timeline_outlined,
              title: l10n.todayEmptyDay,
              message: l10n.startRecordingHint,
            )
          else
            ..._buildEntriesArea(scheme),
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
          onSelect: (i) => setState(() => _spanIndex = i),
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
                padding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 5,
                ),
                decoration: BoxDecoration(
                  color: i == selected ? scheme.surface : Colors.transparent,
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Text(
                  options[i],
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: i == selected
                        ? FontWeight.w600
                        : FontWeight.w500,
                    color: i == selected
                        ? scheme.onSurface
                        : scheme.onSurfaceVariant,
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  void _shift(int days) {
    setState(() {
      _followToday = false;
      _anchor = _anchor.add(Duration(days: days));
    });
  }

  Future<void> _pickDate() async {
    final picked = await showDatePicker(
      context: context,
      initialDate: _anchor,
      firstDate: DateTime.now().subtract(const Duration(days: 365 * 3)),
      lastDate: DateTime.now().add(const Duration(days: 365)),
    );
    if (picked != null) {
      setState(() {
        _followToday = false;
        _anchor = DateTime(picked.year, picked.month, picked.day);
      });
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
        // 工具行：缩放 + 分段 1-12。Wrap：en 文案 + 5 个按钮在紧凑视口
        // 临界，textScale 放大即溢出——超宽自动换行。
        Wrap(
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            Text(
              l10n.tlZoom,
              style: TextStyle(fontSize: 11, color: scheme.onSurfaceVariant),
            ),
            IconButton(
              iconSize: 16,
              visualDensity: VisualDensity.compact,
              icon: const Icon(Icons.remove_rounded),
              onPressed: _zoom <= 1.0
                  ? null
                  : () =>
                        setState(() => _zoom = (_zoom - 0.25).clamp(1.0, 3.0)),
            ),
            IconButton(
              iconSize: 16,
              visualDensity: VisualDensity.compact,
              icon: const Icon(Icons.add_rounded),
              onPressed: _zoom >= 3.0
                  ? null
                  : () =>
                        setState(() => _zoom = (_zoom + 0.25).clamp(1.0, 3.0)),
            ),
            const SizedBox(width: 16),
            Text(
              l10n.tlSegments,
              style: TextStyle(fontSize: 11, color: scheme.onSurfaceVariant),
            ),
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

