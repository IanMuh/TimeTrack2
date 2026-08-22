import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../components/controls.dart' show AppToggle;
import '../components/feedback.dart';
import '../components/state_views.dart';
import '../components/tnum_text.dart';
import '../l10n/app_localizations.dart';
import '../stores/app_store.dart';
import '../utils/day_metrics.dart' show formatHm;
import '../viewmodels/stats/stats_models.dart';
import '../viewmodels/time_entry.dart';
import 'stats_widgets.dart';

/// 统计页（契约 §4.4）：范围 5 预设 + 步进、维度 4 种、树形筛选、
/// 树聚合全屏宽、fl_chart 柱状+环形+每日明细、排除自动、AI 入口预留。
///
/// **挂账（批次 5）**：compute 暂无分类过滤/排除自动参数——筛选与排除
/// 在页内生效于图表/明细（条目层），聚合行过滤随 compute 参数收口。
class StatsPage extends StatefulWidget {
  const StatsPage({super.key, required this.app});

  final AppStore app;

  @override
  State<StatsPage> createState() => _StatsPageState();
}

class _StatsPageState extends State<StatsPage> {
  AppStore get app => widget.app;
  AppLocalizations get l10n => AppLocalizations.of(context)!;

  int _rangeIndex = 0; // 今天/昨天/本周/上周/自定义
  DateTime _customStart = _today();
  DateTime _customEnd = _today();
  StatsDimension _dimension = StatsDimension.categoryTree;
  bool _excludeAuto = false;
  bool _filterExpanded = false;
  final Set<String> _selectedCategories = {};
  final Set<String> _treeExpanded = {};

  static DateTime _today() {
    final n = DateTime.now();
    return DateTime(n.year, n.month, n.day);
  }

  (DateTime, DateTime) get _range {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final weekDay = today.weekday - 1; // 周一始
    switch (_rangeIndex) {
      case 0:
        return (today, today.add(const Duration(days: 1)));
      case 1:
        return (
          today.subtract(const Duration(days: 1)),
          today,
        );
      case 2:
        return (
          today.subtract(Duration(days: weekDay)),
          today.add(const Duration(days: 1)),
        );
      case 3:
        return (
          today.subtract(Duration(days: weekDay + 7)),
          today.subtract(Duration(days: weekDay)),
        );
      default:
        final end = _customEnd.isBefore(_customStart)
            ? _customStart.add(const Duration(days: 1))
            : _customEnd.add(const Duration(days: 1));
        return (_customStart, end);
    }
  }

  @override
  void initState() {
    super.initState();
    _compute();
    _loadEntries();
    app.stats.addListener(_onChange);
    app.dataRevision.addListener(_onChange);
    app.category.addListener(_onChange);
  }

  @override
  void dispose() {
    app.stats.removeListener(_onChange);
    app.dataRevision.removeListener(_onChange);
    app.category.removeListener(_onChange);
    super.dispose();
  }

  void _onChange() {
    if (mounted) setState(() {});
  }

  Future<void> _compute() async {
    final (s, e) = _range;
    await app.stats.compute(start: s, end: e, dimension: _dimension);
  }

  Future<void> _loadEntries() async {
    final (s, e) = _range;
    await app.timeline.loadRange(s, e);
  }

  /// 页内过滤后的明细条目（排除自动 / 分类筛选生效——图表与明细用）。
  List<TimeEntry> get _filteredEntries {
    var list = app.timeline.entriesForRange;
    if (_excludeAuto) list = list.where((e) => !e.isAuto).toList();
    if (_selectedCategories.isNotEmpty) {
      list = list.where((e) {
        for (final link in app.category.links) {
          if (link.activityId == e.activityId &&
              _selectedCategories.contains(link.categoryId)) {
            return true;
          }
        }
        return false;
      }).toList();
    }
    return list;
  }

  /// 按日聚合（明细/柱状图数据）。
  Map<DateTime, Duration> get _byDay {
    final now = DateTime.now();
    final map = <DateTime, Duration>{};
    for (final e in _filteredEntries) {
      final d = DateTime(e.startAt.year, e.startAt.month, e.startAt.day);
      map[d] = (map[d] ?? Duration.zero) + e.durationUntil(now);
    }
    return map;
  }

  // ---------------------------------------------------------------------------
  // 构建
  // ---------------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final snapshot = app.stats.snapshot;
    final scheme = Theme.of(context).colorScheme;
    final wide = MediaQuery.sizeOf(context).width >= 840;

    final body = ListView(
      padding: const EdgeInsets.fromLTRB(24, 20, 24, 40),
      children: [
        _buildToolbar(scheme),
        const SizedBox(height: 16),
        if (snapshot == null)
          const LoadingStateView()
        else if (snapshot.rows.isEmpty && _filteredEntries.isEmpty)
          EmptyStateView(
            icon: Icons.pie_chart_outline,
            title: l10n.stEmpty,
            message: l10n.stEmptyHint,
            actionLabel: l10n.todayStartRecording,
            onAction: () => context.go('/timer'),
          )
        else
          wide
              ? Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    SizedBox(width: 260, child: _buildFilterCard(scheme)),
                    const SizedBox(width: 16),
                    Expanded(child: _buildMainArea(snapshot, scheme)),
                  ],
                )
              : Column(
                  children: [
                    _buildCompactFilter(scheme),
                    _buildMainArea(snapshot, scheme),
                  ],
                ),
      ],
    );
    return body;
  }

  Widget _buildToolbar(ColorScheme scheme) {
    return Wrap(
      spacing: 10,
      runSpacing: 8,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        Text(
          l10n.navStats,
          style: const TextStyle(
            fontSize: 18,
            fontWeight: FontWeight.w600,
            letterSpacing: -0.3,
          ),
        ),
        IconButton(
          tooltip: l10n.todayPrevDay,
          icon: const Icon(Icons.chevron_left_rounded),
          onPressed: () => _shift(-1),
        ),
        IconButton(
          tooltip: l10n.todayNextDay,
          icon: const Icon(Icons.chevron_right_rounded),
          onPressed: () => _shift(1),
        ),
        _segmented(
          options: [
            l10n.stRangeToday,
            l10n.stRangeYesterday,
            l10n.stRangeThisWeek,
            l10n.stRangeLastWeek,
            l10n.stRangeCustom,
          ],
          selected: _rangeIndex,
          onSelect: _selectRange,
        ),
        // AI 入口（二期预留：未配置点击引导，不报错——契约 §4.4）。
        OutlinedButton.icon(
          onPressed: _showAiGuide,
          icon: const Icon(Icons.auto_awesome_rounded, size: 14),
          label: Text(l10n.stAiButton),
        ),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
          decoration: BoxDecoration(
            color: const Color(0xfff59e0b).withValues(alpha: 0.14),
            borderRadius: BorderRadius.circular(999),
          ),
          child: Text(
            l10n.stAiPhase2,
            style: const TextStyle(
              fontSize: 10,
              fontWeight: FontWeight.w600,
              color: Color(0xffb45309),
            ),
          ),
        ),
      ],
    );
  }

  void _showAiGuide() {
    showAppConfirmationDialog(
      context,
      title: l10n.stAiGuideTitle,
      message: l10n.stAiGuideMessage,
      confirmLabel: l10n.stAiGoSettings,
      cancelLabel: l10n.stAiNotNow,
    ).then((go) {
      if (go == true && mounted) context.go('/settings');
    });
  }

  void _selectRange(int i) {
    setState(() => _rangeIndex = i);
    if (i == 4) _pickCustom();
    _compute();
    _loadEntries();
  }

  Future<void> _pickCustom() async {
    final s = await showDatePicker(
      context: context,
      initialDate: _customStart,
      firstDate: DateTime(2020),
      lastDate: DateTime.now().add(const Duration(days: 365)),
      helpText: l10n.stPickStart,
    );
    if (s == null || !mounted) return;
    final e = await showDatePicker(
      context: context,
      initialDate: _customEnd.isBefore(s) ? s : _customEnd,
      firstDate: s,
      lastDate: DateTime.now().add(const Duration(days: 365)),
      helpText: l10n.stPickEnd,
    );
    if (e == null) return;
    setState(() {
      _customStart = s;
      _customEnd = e;
    });
    _compute();
    _loadEntries();
  }

  void _shift(int days) {
    // 步进单位随范围：今天/昨天=1 天；周=7 天；自定义=1 天。
    final step = (_rangeIndex == 2 || _rangeIndex == 3) ? 7 : 1;
    setState(() {
      _customStart = _customStart.add(Duration(days: days * step));
      _customEnd = _customEnd.add(Duration(days: days * step));
      if (_rangeIndex <= 1) {
        // 今天/昨天切换为自定义窗口并平移（保持"任意日期查看"能力）。
        _rangeIndex = 4;
      }
    });
    _compute();
    _loadEntries();
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
                    fontWeight: i == selected ? FontWeight.w600 : FontWeight.w500,
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

  Widget _buildFilterCard(ColorScheme scheme) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: scheme.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: scheme.outline),
      ),
      child: StFilterTree(
        l10n: l10n,
        roots: app.category.childrenByParent[null] ?? const [],
        childrenByParent: app.category.childrenByParent,
        selected: _selectedCategories,
        expanded: _treeExpanded,
        onToggleSelect: (id) => setState(() {
          _selectedCategories.contains(id)
              ? _selectedCategories.remove(id)
              : _selectedCategories.add(id);
        }),
        onToggleExpand: (id) => setState(() {
          _treeExpanded.contains(id)
              ? _treeExpanded.remove(id)
              : _treeExpanded.add(id);
        }),
        onAll: () => setState(
            () => _selectedCategories.addAll(app.category.all.map((c) => c.id))),
        onNone: () => setState(_selectedCategories.clear),
      ),
    );
  }

  Widget _buildCompactFilter(ColorScheme scheme) {
    return Container(
      margin: const EdgeInsets.only(bottom: 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          TextButton.icon(
            onPressed: () => setState(() => _filterExpanded = !_filterExpanded),
            icon: Icon(
              _filterExpanded
                  ? Icons.keyboard_arrow_up_rounded
                  : Icons.keyboard_arrow_down_rounded,
              size: 16,
            ),
            label: Text(
              '${l10n.stFilterTitle}（${_selectedCategories.length}）',
              style: const TextStyle(fontSize: 13),
            ),
          ),
          if (_filterExpanded) _buildFilterCard(scheme),
        ],
      ),
    );
  }

  Widget _buildMainArea(dynamic snapshot, ColorScheme scheme) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // 维度 tab（4 种）。
        _segmented(
          options: [
            l10n.stDimTree,
            l10n.stDimActivity,
            l10n.stDimBucket,
            l10n.stDimCross,
          ],
          selected: switch (_dimension) {
            StatsDimension.categoryTree => 0,
            StatsDimension.activity => 1,
            StatsDimension.durationBucket => 2,
            _ => 3,
          },
          onSelect: (i) {
            setState(() {
              _dimension = switch (i) {
                0 => StatsDimension.categoryTree,
                1 => StatsDimension.activity,
                2 => StatsDimension.durationBucket,
                _ => StatsDimension.primaryCategoryAndDurationBucket,
              };
            });
            _compute();
          },
        ),
        const SizedBox(height: 8),
        // 排除自动条目开关（页内生效于图表/明细；聚合行过滤挂账批次 5）。
        Row(
          children: [
            AppToggle(
              value: _excludeAuto,
              onChanged: (v) => setState(() => _excludeAuto = v),
              label: l10n.stExcludeAuto,
            ),
          ],
        ),
        Padding(
          padding: const EdgeInsets.only(top: 4),
          child: Text(
            l10n.stExcludeAutoHint,
            style: TextStyle(
              fontSize: 10.5,
              color: scheme.onSurfaceVariant.withValues(alpha: 0.8),
            ),
          ),
        ),
        const SizedBox(height: 14),
        // 聚合行（树维度含折叠；全宽行——契约"树统计覆盖全屏宽"）。
        ..._buildRows(snapshot, scheme),
        const SizedBox(height: 18),
        // 图表区。
        _card(scheme, l10n.stDailyChart, StDailyBarChart(
          days: _byDay.keys.toList()..sort(),
          values: [
            for (final d in (_byDay.keys.toList()..sort())) _byDay[d]!,
          ],
        )),
        const SizedBox(height: 14),
        _card(scheme, l10n.stShareChart, StSharePieChart(slices: _slices(snapshot))),
        const SizedBox(height: 14),
        _buildDailyDetail(scheme),
      ],
    );
  }

  List<Widget> _buildRows(dynamic snapshot, ColorScheme scheme) {
    final rows = (snapshot.rows as List<dynamic>)
        .where((r) => _rowPassesFilter(r))
        .toList()
      ..sort((a, b) => b.totalDuration.compareTo(a.totalDuration));
    final collapsedAncestors = <String>{};
    final out = <Widget>[];
    for (final row in rows) {
      final hidden = row.ancestorIds.any(collapsedAncestors.contains);
      if (hidden) continue;
      out.add(StTreeRow(
        row: row,
        totalDuration: snapshot.totalDuration,
        collapsed: _treeExpanded.contains('row:${row.id}'),
        onToggle: () => setState(() {
          final key = 'row:${row.id}';
          _treeExpanded.contains(key)
              ? _treeExpanded.remove(key)
              : _treeExpanded.add(key);
          collapsedAncestors.clear();
          for (final r in rows) {
            if (_treeExpanded.contains('row:${r.id}')) {
              collapsedAncestors.add(r.id);
            }
          }
        }),
      ));
      if (_treeExpanded.contains('row:${row.id}')) {
        collapsedAncestors.add(row.id);
      }
    }
    return out;
  }

  /// 行过滤（页内：分类筛选对 category 前缀行生效——挂账 compute 参数）。
  bool _rowPassesFilter(dynamic row) {
    if (_selectedCategories.isEmpty) return true;
    final id = row.id as String;
    if (!id.startsWith('category:')) return true;
    final catId = id.substring('category:'.length);
    if (_selectedCategories.contains(catId)) return true;
    final desc = app.category.descendantsOf[catId] ?? const <String>{};
    return desc.any(_selectedCategories.contains);
  }

  /// 环形图切片（当前维度 top6 + 其他）。
  List<(String, Color, Duration)> _slices(dynamic snapshot) {
    final rows = (snapshot.rows as List<dynamic>)
        .where((r) => _rowPassesFilter(r))
        .toList()
      ..sort((a, b) => b.totalDuration.compareTo(a.totalDuration));
    final top = rows.take(6).toList();
    var others = Duration.zero;
    for (final r in rows.skip(6)) {
      others += r.totalDuration as Duration;
    }
    return [
      for (final r in top)
        (r.label as String, Color(r.color as int), r.totalDuration as Duration),
      if (others > Duration.zero)
        (l10n.stLegendOther, const Color(0xffa1a1aa), others),
    ];
  }

  Widget _card(ColorScheme scheme, String title, Widget child) {
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
      decoration: BoxDecoration(
        color: scheme.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: scheme.outline),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title,
              style:
                  const TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
          const SizedBox(height: 10),
          child,
        ],
      ),
    );
  }

  Widget _buildDailyDetail(ColorScheme scheme) {
    final days = _byDay.keys.toList()..sort();
    final total = _byDay.values.fold<int>(0, (m, d) => m + d.inMinutes);
    return _card(
      scheme,
      l10n.stDailyDetail,
      Column(
        children: [
          for (final d in days)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: Row(
                children: [
                  TnumText(
                    '${d.month}/${d.day}',
                    style: TextStyle(
                        fontSize: 12, color: scheme.onSurfaceVariant),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: ActivityColorBar2(
                      const Color(0xff4f46e5),
                      ratio: total == 0
                          ? 0.0
                          : _byDay[d]!.inMinutes / total,
                    ),
                  ),
                  const SizedBox(width: 10),
                  TnumText(
                    formatHm(_byDay[d]!),
                    style: const TextStyle(
                      fontSize: 12.5,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}
