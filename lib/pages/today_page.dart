import 'dart:async' show unawaited;

import 'package:go_router/go_router.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../components/activity_color_dot.dart';
import '../components/controls.dart' show AppChip;
import '../components/state_views.dart';
import '../components/tnum_text.dart';
import '../l10n/app_localizations.dart';
import '../stores/app_store.dart';
import '../viewmodels/activity_category.dart';
import '../viewmodels/time_entry.dart';

/// 今日页（契约 §4.2）——任意日期查看 + 4 指标 + 分类分组聚合。
///
/// 口径（批次 3 与数据层统一前的暂定口径，代码注释即挂账单）：
/// - 总时长 = 当日条目时长（运行中截至 now，跨 0 点起点钳制到当日零点）；
/// - 专注 = 非"未分配"活动条目时长；休息 = "未分配"活动条目时长；
/// - 会话数 = 当日条目数（运行中计 1 条）；
/// - 分组按**当前归属**（活动的主分类，不变式 3：展示用快照、统计按当前归属）；
///   条目名/色展示用发生时刻快照。
class TodayPage extends StatefulWidget {
  const TodayPage({super.key, required this.app});

  final AppStore app;

  @override
  State<TodayPage> createState() => _TodayPageState();
}

class _TodayPageState extends State<TodayPage> {
  AppStore get app => widget.app;
  AppLocalizations get l10n => AppLocalizations.of(context)!;

  DateTime _day = _dateOnly(DateTime.now());
  List<TimeEntry> _entries = const [];
  bool _loading = true;
  bool _failed = false;
  int _requestSeq = 0;
  bool _disposed = false;

  /// 当前筛选（主分类根 id 集合 + "__unassigned__" 伪选项；空 = 全部）。
  Set<String> _filters = {};
  final Set<String> _collapsed = {};

  String? _unassignedActivityId;
  List<TimeEntry>? _previousEntries;

  static DateTime _dateOnly(DateTime d) => DateTime(d.year, d.month, d.day);

  bool get _isToday => _day == _dateOnly(DateTime.now());

  @override
  void initState() {
    super.initState();
    _init();
    app.today.addListener(_onStoreChanged);
    app.clock.addListener(_onStoreChanged);
    app.category.addListener(_onStoreChanged);
    app.dataRevision.addListener(_onStoreChanged);
  }

  @override
  void dispose() {
    _disposed = true;
    app.today.removeListener(_onStoreChanged);
    app.clock.removeListener(_onStoreChanged);
    app.category.removeListener(_onStoreChanged);
    app.dataRevision.removeListener(_onStoreChanged);
    super.dispose();
  }

  void _onStoreChanged() {
    if (mounted) setState(() {});
  }

  Future<void> _init() async {
    final unassigned = await app.activities.unassignedActivity();
    if (_disposed) return;
    _unassignedActivityId =
        unassigned.isSuccess ? unassigned.requireValue().id : null;
    await _loadEntries();
  }

  Future<void> _loadEntries() async {
    if (_isToday) {
      // 今天由 TodayStore 驱动（自动随 dataRevision/跨日刷新），框内直接读。
      setState(() {
        _entries = app.today.today;
        _loading = false;
        _failed = false;
      });
      unawaited(_loadPrevious());
      return;
    }
    final seq = ++_requestSeq;
    setState(() {
      _loading = true;
      _failed = false;
    });
    try {
      final loaded = await app.today.entries
          .entriesForRange(_day, _day.add(const Duration(days: 1)));
      if (_disposed || seq != _requestSeq) return;
      setState(() {
        _entries = loaded;
        _loading = false;
      });
      unawaited(_loadPrevious());
    } on Exception {
      if (_disposed || seq != _requestSeq) return;
      setState(() {
        _failed = true;
        _loading = false;
      });
    }
  }

  Future<void> _loadPrevious() async {
    final seq = _requestSeq;
    try {
      final loaded = await app.today.entries
          .entriesForRange(_day.subtract(const Duration(days: 1)), _day);
      if (_disposed || seq != _requestSeq) return;
      setState(() => _previousEntries = loaded);
    } on Exception {
      // 前日对比取不到不阻塞主流程（离线优先，显示为空差异即可）。
    }
  }

  void _changeDay(DateTime date) {
    setState(() {
      _day = _dateOnly(date);
      _entries = const [];
      _previousEntries = null;
      _loading = true;
    });
    unawaited(_loadEntries());
  }

  Future<void> _pickDate() async {
    final picked = await showDatePicker(
      context: context,
      initialDate: _day,
      firstDate: DateTime.now().subtract(const Duration(days: 365 * 3)),
      lastDate: DateTime.now().add(const Duration(days: 365)),
    );
    if (picked != null) _changeDay(picked);
  }

  // ---------------------------------------------------------------------------
  // 口径计算（暂定口径，挂账批次 3 数据层统一）
  // ---------------------------------------------------------------------------

  Duration _entryClamp(TimeEntry e, DateTime dayStart) {
    final start = e.startAt.isBefore(dayStart) ? dayStart : e.startAt;
    final end = e.endAt ?? DateTime.now();
    return end.isAfter(start) ? end.difference(start) : Duration.zero;
  }

  ({Duration total, int sessions, Duration focus, Duration rest}) _metrics(
      List<TimeEntry> entries) {
    final dayStart = _day;
    var total = Duration.zero;
    var focus = Duration.zero;
    var rest = Duration.zero;
    for (final e in entries) {
      final d = _entryClamp(e, dayStart);
      total += d;
      if (e.activityId == _unassignedActivityId) {
        rest += d;
      } else {
        focus += d;
      }
    }
    return (total: total, sessions: entries.length, focus: focus, rest: rest);
  }

  String? _primaryOf(String activityId) {
    for (final link in app.category.links) {
      if (link.activityId == activityId) return link.categoryId;
    }
    return null;
  }

  String? _rootById(String? primary) {
    if (primary == null) return null;
    final chain = app.category.ancestorChains[primary] ?? const [];
    return chain.isEmpty ? null : chain.first;
  }

  String _groupLabel(String? rootId) {
    if (rootId == null) return l10n.unassignedActivity;
    final chain = app.category.ancestorChains[rootId] ?? const [];
    if (chain.length > 1) return chain.join(' / ');
    return app.category.categoryById[rootId]?.name ?? '';
  }

  int? _groupColor(String? rootId) =>
      rootId == null ? 0xffa1a1aa : app.category.categoryById[rootId]?.color;

  Duration _totalOfEntries(List<TimeEntry> entries) {
    var t = Duration.zero;
    for (final e in entries) {
      t += _entryClamp(e, _day);
    }
    return t;
  }

  bool _filterPass(TimeEntry e) {
    if (_filters.isEmpty) return true;
    final root = _rootById(_primaryOf(e.activityId));
    if (_filters.contains('__unassigned__') && root == null) return true;
    return root != null && _filters.contains(root);
  }

  /// 组内聚合行：按活动聚合（展示快照名/色；路径取当前归属）。
  List<GroupRowData> _rowsFor(List<TimeEntry> entries) {
    final map = <String, GroupRowData>{};
    for (final e in entries) {
      final cur = map[e.activityId];
      map[e.activityId] = GroupRowData(
        key: e.activityId,
        name: cur?.name ?? e.activityNameSnapshot,
        color: cur?.color ?? e.activityColorSnapshot,
        duration: (cur?.duration ?? Duration.zero) + _entryClamp(e, _day),
        count: (cur?.count ?? 0) + 1,
        path: cur?.path ?? _pathOf(e.activityId),
      );
    }
    return map.values.toList()
      ..sort((a, b) => b.duration.compareTo(a.duration));
  }

  String _pathOf(String activityId) {
    final primary = _primaryOf(activityId);
    if (primary == null) return '';
    final chain = app.category.ancestorChains[primary] ?? const [];
    return chain.length > 1 ? chain.join(' / ') : '';
  }

  List<({String? rootId, List<TimeEntry> entries})> _groups() {
    final map = <String?, List<TimeEntry>>{};
    for (final e in _entries) {
      if (!_filterPass(e)) continue;
      map.putIfAbsent(_rootById(_primaryOf(e.activityId)), () => []).add(e);
    }
    final groups = map.entries
        .map((g) => (rootId: g.key, entries: g.value))
        .toList();
    groups.sort((a, b) {
      if (a.rootId == null) return 1;
      if (b.rootId == null) return -1;
      return _groupLabel(a.rootId).compareTo(_groupLabel(b.rootId));
    });
    return groups;
  }

  // ---------------------------------------------------------------------------
  // 构建
  // ---------------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    if (_loading) return const LoadingStateView();
    if (_failed) {
      return ErrorStateView(message: l10n.timerLoadFailed, onRetry: _loadEntries);
    }
    if (_entries.isEmpty) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _TodayHeader(
            l10n: l10n,
            day: _day,
            isToday: _isToday,
            onPrev: () => _changeDay(_day.subtract(const Duration(days: 1))),
            onNext: () => _changeDay(_day.add(const Duration(days: 1))),
            onPick: _pickDate,
            onToday: () => _changeDay(DateTime.now()),
          ),
          Expanded(
            child: EmptyStateView(
              icon: Icons.event_available_outlined,
              title: _isToday ? l10n.emptyDayEntries : l10n.todayEmptyDay,
              message: l10n.startRecordingHint,
              actionLabel: _isToday ? l10n.todayStartRecording : null,
              onAction: _isToday ? () => context.go('/timer') : null,
            ),
          ),
        ],
      );
    }
    final wide = MediaQuery.sizeOf(context).width >= 840;
    final metrics = _metrics(_entries);
    final prev = _previousEntries;
    final prevMetrics = prev == null ? null : _metrics(prev);

    final content = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _TodayHeader(
          l10n: l10n,
          day: _day,
          isToday: _isToday,
          onPrev: () => _changeDay(_day.subtract(const Duration(days: 1))),
          onNext: () => _changeDay(_day.add(const Duration(days: 1))),
          onPick: _pickDate,
          onToday: () => _changeDay(DateTime.now()),
        ),
        const SizedBox(height: 16),
        _MetricsRow(l10n: l10n, metrics: metrics, previous: prevMetrics),
        const SizedBox(height: 16),
        _FilterRow(
          l10n: l10n,
          rootCategories: app.category.childrenByParent[null] ?? const [],
          filters: _filters,
          onToggleRoot: (id) => setState(() {
            _filters.contains(id) ? _filters.remove(id) : _filters.add(id);
          }),
          onToggleUnassigned: () => setState(() {
            const key = '__unassigned__';
            _filters.contains(key) ? _filters.remove(key) : _filters.add(key);
          }),
          onClear: () => setState(() => _filters = {}),
        ),
        const SizedBox(height: 16),
        _buildGroups(),
      ],
    );

    if (!wide) return content;

    final previewEntries = _entries.where(_filterPass).toList()
      ..sort((a, b) => a.startAt.compareTo(b.startAt));
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(child: content),
        const SizedBox(width: 20),
        SizedBox(
          width: 320,
          child: _TimelinePreview(l10n: l10n, entries: previewEntries),
        ),
      ],
    );
  }

  Widget _buildGroups() {
    final groups = _groups();
    final dayTotal = _metrics(_entries).total;
    return Column(
      children: [
        for (final group in groups)
          _GroupCard(
            l10n: l10n,
            label: _groupLabel(group.rootId),
            color: _groupColor(group.rootId),
            rows: _rowsFor(group.entries),
            collapsed: _collapsed.contains(group.rootId),
            total: _totalOfEntries(group.entries),
            dayTotal: dayTotal,
            onToggle: () => setState(() {
              final id = group.rootId;
              if (id == null) return;
              _collapsed.contains(id) ? _collapsed.remove(id) : _collapsed.add(id);
            }),
          ),
      ],
    );
  }
}



/// 今日页子件（页面装配数据的纯展示件）。

/// 组内聚合行数据（页面计算、卡片消费）。
class GroupRowData {
  const GroupRowData({
    required this.key,
    required this.name,
    required this.color,
    required this.duration,
    required this.count,
    required this.path,
  });

  final String key;
  final String name;
  final int? color;
  final Duration duration;
  final int count;
  final String path;
}

/// 顶部日期栏：步进 + 日历 + 回到今天。
class _TodayHeader extends StatelessWidget {
  const _TodayHeader({
    required this.l10n,
    required this.day,
    required this.isToday,
    required this.onPrev,
    required this.onNext,
    required this.onPick,
    required this.onToday,
  });

  final AppLocalizations l10n;
  final DateTime day;
  final bool isToday;
  final VoidCallback onPrev;
  final VoidCallback onNext;
  final VoidCallback onPick;
  final VoidCallback onToday;

  @override
  Widget build(BuildContext context) {
    final label = DateFormat('M月d日 EEE', 'zh').format(day);
    final compact =
        MediaQuery.sizeOf(context).width < 600;
    Widget step(VoidCallback cb, IconData i, String tip, bool left) =>
        IconButton(
          tooltip: tip,
          visualDensity:
              compact ? VisualDensity.compact : VisualDensity.standard,
          icon: Icon(i, size: compact ? 20 : 24),
          onPressed: cb,
        );
    return Row(
      children: [
        step(onPrev, Icons.chevron_left_rounded, l10n.todayPrevDay, true),
        Flexible(
          child: LayoutBuilder(
            builder: (context, c) => FittedBox(
              fit: BoxFit.scaleDown,
              child: Text(
                label,
                style: TextStyle(
                  fontSize: c.maxWidth >= 200 ? 26 : 22,
                  fontWeight: FontWeight.w600,
                  letterSpacing: -0.5,
                ),
              ),
            ),
          ),
        ),
        const SizedBox(width: 4),
        step(onPick, Icons.calendar_month_outlined, l10n.todayPickDate, false),
        step(onNext, Icons.chevron_right_rounded, l10n.todayNextDay, false),
        if (!isToday)
        if (!isToday)
          TextButton(onPressed: onToday, child: Text(l10n.todayBackToToday)),
        const Spacer(),
      ],
    );
  }
}

/// 4 指标卡（含前日对比）。
class _MetricsRow extends StatelessWidget {
  const _MetricsRow({
    required this.l10n,
    required this.metrics,
    required this.previous,
  });

  final AppLocalizations l10n;
  final ({Duration total, int sessions, Duration focus, Duration rest}) metrics;
  final ({Duration total, int sessions, Duration focus, Duration rest})? previous;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final columns = constraints.maxWidth >= 600 ? 4 : 2;
        final items = [
          (label: l10n.todayTotalDuration, value: metrics.total),
          (
            label: l10n.timerTodaySessions,
            value: Duration(seconds: metrics.sessions),
          ),
          (label: l10n.todayFocusDuration, value: metrics.focus),
          (label: l10n.todayRestDuration, value: metrics.rest),
        ];
        return GridView.count(
          crossAxisCount: columns,
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          mainAxisSpacing: 10,
          crossAxisSpacing: 10,
          childAspectRatio: 2.4,
          children: [
            for (final item in items)
              _MetricCard(
                l10n: l10n,
                label: item.label,
                duration: item.value,
                previous: switch (item.label) {
                  final l when l == l10n.todayTotalDuration => previous?.total,
                  final l when l == l10n.timerTodaySessions =>
                    previous == null
                        ? null
                        : Duration(seconds: previous!.sessions),
                  final l when l == l10n.todayFocusDuration =>
                    previous?.focus,
                  _ => previous?.rest,
                },
              ),
          ],
        );
      },
    );
  }
}

class _MetricCard extends StatelessWidget {
  const _MetricCard({
    required this.l10n,
    required this.label,
    required this.duration,
    required this.previous,
  });

  final AppLocalizations l10n;
  final String label;
  final Duration duration;
  final Duration? previous;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final isSessions = label == l10n.timerTodaySessions;
    final delta = previous == null ? null : duration - previous!;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: scheme.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: scheme.outline),
      ),
      child: FittedBox(
        fit: BoxFit.scaleDown,
        alignment: Alignment.centerLeft,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
          Text(
            label,
            style: TextStyle(fontSize: 11, color: scheme.onSurfaceVariant),
          ),
          const SizedBox(height: 2),
          TnumText(
            isSessions
                ? '${duration.inSeconds}'
                : formatHms(duration),
            style: TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.w600,
              color: scheme.onSurface,
            ),
          ),
          if (delta != null)
            Row(
              children: [
                Icon(
                  delta >= Duration.zero
                      ? Icons.arrow_upward_rounded
                      : Icons.arrow_downward_rounded,
                  size: 12,
                  color: delta >= Duration.zero
                      ? const Color(0xff10b981)
                      : scheme.onSurfaceVariant,
                ),
                Text(
                  '${l10n.todayVsPrevious} ${formatHms(delta.abs())}',
                  style: TextStyle(fontSize: 10, color: scheme.onSurfaceVariant),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// 顶部分类筛选多选行（根分类 + 未分类伪选项 + 清除）。
class _FilterRow extends StatelessWidget {
  const _FilterRow({
    required this.l10n,
    required this.rootCategories,
    required this.filters,
    required this.onToggleRoot,
    required this.onToggleUnassigned,
    required this.onClear,
  });

  final AppLocalizations l10n;
  final List<ActivityCategory> rootCategories;
  final Set<String> filters;
  final ValueChanged<String> onToggleRoot;
  final VoidCallback onToggleUnassigned;
  final VoidCallback onClear;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 34,
      child: ListView(
        scrollDirection: Axis.horizontal,
        children: [
          Padding(
            padding: const EdgeInsets.only(right: 6),
            child: AppChip(
              label: l10n.todayClearFilters,
              selected: filters.isEmpty,
              onTap: onClear,
            ),
          ),
          for (final c in rootCategories)
            Padding(
              padding: const EdgeInsets.only(right: 6),
              child: AppChip(
                label: c.name,
                dotColor: Color(c.color),
                selected: filters.contains(c.id),
                onTap: () => onToggleRoot(c.id),
              ),
            ),
          AppChip(
            label: l10n.unassignedActivity,
            dotColor: const Color(0xffa1a1aa),
            selected: filters.contains('__unassigned__'),
            onTap: onToggleUnassigned,
          ),
        ],
      ),
    );
  }
}

/// 分类分组卡：组头（折叠箭头 + 色点 + 名 + 小计 + 占比条）+ 组内聚合行。
class _GroupCard extends StatelessWidget {
  const _GroupCard({
    required this.l10n,
    required this.label,
    required this.color,
    required this.rows,
    required this.collapsed,
    required this.total,
    required this.dayTotal,
    required this.onToggle,
  });

  final AppLocalizations l10n;
  final String label;
  final int? color;
  final List<GroupRowData> rows;
  final bool collapsed;
  final Duration total;
  final Duration dayTotal;
  final VoidCallback onToggle;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final dotColor = color == null ? const Color(0xffa1a1aa) : Color(color!);
    final ratio = dayTotal.inMilliseconds == 0
        ? 0.0
        : total.inMilliseconds / dayTotal.inMilliseconds;
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.fromLTRB(12, 4, 12, 8),
      decoration: BoxDecoration(
        color: scheme.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: scheme.outline),
      ),
      child: Column(
        children: [
          InkWell(
            onTap: onToggle,
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 10),
              child: Row(
                children: [
                  Icon(
                    collapsed
                        ? Icons.keyboard_arrow_right_rounded
                        : Icons.keyboard_arrow_down_rounded,
                    size: 18,
                    color: scheme.onSurfaceVariant,
                  ),
                  const SizedBox(width: 4),
                  ActivityColorDot(dotColor, size: 10),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  TnumText(
                    formatHms(total),
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      color: scheme.onSurface,
                    ),
                  ),
                ],
              ),
            ),
          ),
          ActivityColorBar(dotColor, ratio: ratio, height: 4),
          const SizedBox(height: 6),
          if (!collapsed)
            for (final row in rows) _ActivityGroupRow(row: row, dayTotal: dayTotal),
        ],
      ),
    );
  }
}

class _ActivityGroupRow extends StatelessWidget {
  const _ActivityGroupRow({required this.row, required this.dayTotal});

  final GroupRowData row;
  final Duration dayTotal;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final ratio = row.duration == Duration.zero
        ? 0.0
        : row.duration.inMilliseconds / dayTotal.inMilliseconds;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        children: [
          const SizedBox(width: 26),
          ActivityColorDot(
            row.color == null ? const Color(0xffa1a1aa) : Color(row.color!),
            size: 10,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  row.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 13),
                ),
                if (row.path.isNotEmpty)
                  Text(
                    row.path,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 10,
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
              ],
            ),
          ),
          SizedBox(
            width: 60,
            child: ActivityColorBar(
              row.color == null ? const Color(0xffa1a1aa) : Color(row.color!),
              ratio: ratio,
              height: 4,
            ),
          ),
          const SizedBox(width: 8),
          TnumText(
            formatHms(row.duration),
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w600,
              color: scheme.onSurface,
            ),
          ),
        ],
      ),
    );
  }
}

/// 宽屏时间线预览（约 5 条 + 跳转）。
class _TimelinePreview extends StatelessWidget {
  const _TimelinePreview({required this.l10n, required this.entries});

  final AppLocalizations l10n;
  final List<TimeEntry> entries;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final preview = entries.take(5).toList();
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 10),
      decoration: BoxDecoration(
        color: scheme.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: scheme.outline),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(
                l10n.todayPreviewTitle,
                style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
              ),
              const Spacer(),
              if (entries.length > 5)
                Text(
                  '${entries.length} 条',
                  style:
                      TextStyle(fontSize: 11, color: scheme.onSurfaceVariant),
                ),
            ],
          ),
          for (final e in preview) _PreviewRow(entry: e),
          const SizedBox(height: 6),
          TextButton.icon(
            onPressed: () => context.go('/timeline'),
            style: TextButton.styleFrom(padding: EdgeInsets.zero),
            icon: const Icon(Icons.arrow_forward_rounded, size: 14),
            label: Text(l10n.todayViewFullTimeline),
          ),
        ],
      ),
    );
  }
}

class _PreviewRow extends StatelessWidget {
  const _PreviewRow({required this.entry});

  final TimeEntry entry;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final start = DateFormat('HH:mm', 'zh').format(entry.startAt);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          _PreviewTime(start: start),
          const SizedBox(width: 10),
          ActivityColorDot(
            entry.activityColorSnapshot == null
                ? const Color(0xffa1a1aa)
                : Color(entry.activityColorSnapshot!),
            size: 10,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              entry.activityNameSnapshot,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 12.5),
            ),
          ),
          if (entry.isAuto)
            Icon(Icons.auto_awesome_rounded,
                size: 12, color: const Color(0xff0ea5e9)),
          const SizedBox(width: 6),
          TnumText(
            formatHms(entry.durationUntil(DateTime.now())),
            style: TextStyle(fontSize: 11.5, color: scheme.onSurfaceVariant),
          ),
        ],
      ),
    );
  }
}

class _PreviewTime extends StatelessWidget {
  const _PreviewTime({required this.start});

  final String start;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return SizedBox(
      width: 40,
      child: TnumText(
        start,
        style: TextStyle(fontSize: 11.5, color: scheme.onSurfaceVariant),
      ),
    );
  }
}
