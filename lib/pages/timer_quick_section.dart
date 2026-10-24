import 'package:flutter/material.dart';

import '../components/activity_color_dot.dart';
import '../components/controls.dart' show AppChip;
import '../components/tnum_text.dart';
import '../l10n/app_localizations.dart';
import '../viewmodels/activity.dart';
import '../viewmodels/activity_category.dart';

/// 快捷活动区（紧凑分组列表）：搜索 + 分类筛选 + 按根分类分组的 56px 行。
///
/// 设计取舍见 `docs/UI重建方案.md` §3：
/// - 一行承载 活动名（15）/ 分类路径（12）/ 今日时长（13 等宽）；
/// - 运行中：左侧 3px rose 指示条 + 淡色底；待确认：主色描边 + 行尾进度环；
/// - 列数按可用宽：< 640 单列、640–1199 双列、≥ 1200 三列（每列 ≥ 320）。
class TimerQuickSection extends StatefulWidget {
  const TimerQuickSection({
    super.key,
    required this.l10n,
    required this.categoryFilterId,
    required this.rootCategories,
    required this.childrenByParent,
    required this.ancestorChain,
    required this.descendantsOf,
    required this.activities,
    required this.categoryIdsByActivity,
    required this.runningActivityId,
    required this.pendingActivityId,
    required this.todayByActivity,
    required this.onFilter,
    required this.onActivityTap,
    required this.onActivityDoubleTap,
    required this.onActivityLongPress,
    required this.onTemporary,
    required this.onNewActivity,
  });

  final AppLocalizations l10n;
  final String? categoryFilterId;
  final List<ActivityCategory> rootCategories;
  final Map<String?, List<ActivityCategory>> childrenByParent;
  final Map<String, List<String>> ancestorChain;
  final Map<String, Set<String>> descendantsOf;
  final List<Activity> activities;
  final Map<String, Set<String>> categoryIdsByActivity;
  final String? runningActivityId;
  final String? pendingActivityId;
  final Map<String, Duration> todayByActivity;
  final ValueChanged<String?> onFilter;
  final ValueChanged<Activity> onActivityTap;
  final ValueChanged<Activity> onActivityDoubleTap;
  final ValueChanged<Activity> onActivityLongPress;
  final VoidCallback onTemporary;
  final VoidCallback onNewActivity;

  @override
  State<TimerQuickSection> createState() => _TimerQuickSectionState();
}

class _TimerQuickSectionState extends State<TimerQuickSection> {
  final TextEditingController _search = TextEditingController();
  String _query = '';

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  bool _inCategory(String activityId, String categoryId) {
    final set = widget.categoryIdsByActivity[activityId] ?? const {};
    final desc = widget.descendantsOf[categoryId] ?? const <String>{};
    return set.contains(categoryId) || set.any(desc.contains);
  }

  int _countFor(String categoryId) => widget.activities
      .where((a) => !a.isUnassigned && _inCategory(a.id, categoryId))
      .length;

  String _pathOf(String activityId) {
    final set = widget.categoryIdsByActivity[activityId] ?? const {};
    for (final c in set) {
      final chain = widget.ancestorChain[c];
      if (chain != null && chain.isNotEmpty) return chain.join(' / ');
    }
    return '';
  }

  /// 由 childrenByParent 反推 parentOf（用于从任意层级分类回溯根分类）。
  Map<String, String?> _parentOf() {
    final map = <String, String?>{};
    widget.childrenByParent.forEach((parent, children) {
      for (final c in children) {
        map[c.id] = parent;
      }
    });
    return map;
  }

  String? _rootOf(String categoryId, Map<String, String?> parentOf) {
    var current = categoryId;
    var parent = parentOf[current];
    var guard = 0;
    while (parent != null && guard < 64) {
      current = parent;
      parent = parentOf[current];
      guard++;
    }
    return current;
  }

  List<_Group> _group(List<Activity> visible) {
    final parentOf = _parentOf();
    final byRoot = <String, List<Activity>>{};
    for (final a in visible) {
      final categories = widget.categoryIdsByActivity[a.id] ?? const <String>{};
      String? root;
      for (final c in categories) {
        final chain = widget.ancestorChain[c];
        if (chain != null && chain.isNotEmpty) {
          root = _rootOf(c, parentOf);
          break;
        }
      }
      byRoot.putIfAbsent(root ?? '', () => []).add(a);
    }
    final groups = <_Group>[];
    byRoot.forEach((rootId, items) {
      final category = widget.rootCategories
          .where((c) => c.id == rootId)
          .firstOrNull;
      items.sort(
        (a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()),
      );
      groups.add(
        _Group(
          label: category?.name ?? widget.l10n.uncategorized,
          color: category?.color,
          items: items,
        ),
      );
    });
    groups.sort((a, b) => a.label.compareTo(b.label));
    return groups;
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final selected = widget.categoryFilterId;
    final query = _query.trim().toLowerCase();
    final visible = widget.activities.where((a) {
      if (selected != null &&
          (a.isUnassigned || !_inCategory(a.id, selected))) {
        return false;
      }
      if (query.isEmpty) return true;
      return a.name.toLowerCase().contains(query) ||
          _pathOf(a.id).toLowerCase().contains(query);
    }).toList();
    final groups = _group(visible);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _header(scheme),
        const SizedBox(height: 12),
        LayoutBuilder(
          builder: (context, constraints) {
            final search = _searchField(scheme);
            final chips = _chips(scheme);
            if (constraints.maxWidth >= 900) {
              return Row(
                children: [
                  SizedBox(width: 260, child: search),
                  const SizedBox(width: 12),
                  Expanded(child: chips),
                ],
              );
            }
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [search, const SizedBox(height: 8), chips],
            );
          },
        ),
        const SizedBox(height: 12),
        if (visible.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 24),
            child: Center(
              child: Text(
                widget.l10n.timerNoMatch,
                style: TextStyle(fontSize: 13, color: scheme.onSurfaceVariant),
              ),
            ),
          )
        else
          LayoutBuilder(
            builder: (context, constraints) {
              final columns = constraints.maxWidth >= 1200
                  ? 3
                  : (constraints.maxWidth >= 640 ? 2 : 1);
              if (columns == 1) {
                return Column(
                  children: [for (final g in groups) _groupBlock(g)],
                );
              }
              final buckets = List.generate(columns, (_) => <_Group>[]);
              final heights = List<int>.filled(columns, 0);
              for (final g in groups) {
                var target = 0;
                for (var i = 1; i < columns; i++) {
                  if (heights[i] < heights[target]) target = i;
                }
                buckets[target].add(g);
                heights[target] += 28 + g.items.length * 60;
              }
              return Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  for (var i = 0; i < columns; i++) ...[
                    if (i > 0) const SizedBox(width: 16),
                    Expanded(
                      child: Column(
                        children: [for (final g in buckets[i]) _groupBlock(g)],
                      ),
                    ),
                  ],
                ],
              );
            },
          ),
      ],
    );
  }

  Widget _header(ColorScheme scheme) {
    return Row(
      children: [
        Text(
          widget.l10n.timerQuickSection,
          style: const TextStyle(
            fontSize: 16,
            fontWeight: FontWeight.w500,
            letterSpacing: -0.2,
          ),
        ),
        const SizedBox(width: 8),
        Text(
          '${widget.activities.length}',
          style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
        ),
        const Spacer(),
        Flexible(
          child: Text(
            widget.l10n.timerInteractionHint,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: 12,
              color: scheme.onSurfaceVariant.withValues(alpha: 0.8),
            ),
          ),
        ),
      ],
    );
  }

  Widget _searchField(ColorScheme scheme) {
    return TextField(
      controller: _search,
      onChanged: (value) => setState(() => _query = value),
      style: const TextStyle(fontSize: 13),
      decoration: InputDecoration(
        hintText: widget.l10n.searchActivities,
        hintStyle: const TextStyle(fontSize: 13),
        prefixIcon: const Icon(Icons.search_rounded, size: 16),
        prefixIconConstraints: const BoxConstraints(minWidth: 32),
        isDense: true,
        contentPadding: const EdgeInsets.symmetric(horizontal: 8, vertical: 9),
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
      ),
    );
  }

  Widget _chips(ColorScheme scheme) {
    final selected = widget.categoryFilterId;
    return SizedBox(
      height: 34,
      child: ListView(
        scrollDirection: Axis.horizontal,
        children: [
          AppChip(
            label: widget.l10n.timerAll,
            count: widget.activities.length,
            selected: selected == null,
            onTap: () => widget.onFilter(null),
          ),
          const SizedBox(width: 8),
          for (final c in widget.rootCategories) ...[
            AppChip(
              label: c.name,
              dotColor: Color(c.color),
              count: _countFor(c.id),
              selected: selected == c.id,
              onTap: () => widget.onFilter(c.id),
            ),
            const SizedBox(width: 8),
          ],
          Container(width: 1, height: 20, color: scheme.outline),
          const SizedBox(width: 8),
          AppChip(
            label: widget.l10n.timerTemporaryActivity,
            onTap: widget.onTemporary,
          ),
          const SizedBox(width: 8),
          AppChip(
            label: widget.l10n.timerNewActivity,
            onTap: widget.onNewActivity,
          ),
        ],
      ),
    );
  }

  Widget _groupBlock(_Group group) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            height: 28,
            child: Row(
              children: [
                if (group.color != null) ...[
                  ActivityColorDot(Color(group.color!), size: 8, ringWidth: 0),
                  const SizedBox(width: 6),
                ],
                Text(
                  group.label,
                  style: const TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w500,
                  ),
                ),
                const SizedBox(width: 6),
                Text(
                  '${group.items.length}',
                  style: TextStyle(
                    fontSize: 12,
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
          for (final a in group.items)
            _ActivityRow(
              activity: a,
              path: _pathOf(a.id),
              running: widget.runningActivityId == a.id,
              pending: widget.pendingActivityId == a.id,
              today: widget.todayByActivity[a.id] ?? Duration.zero,
              l10n: widget.l10n,
              onTap: () => widget.onActivityTap(a),
              onDoubleTap: () => widget.onActivityDoubleTap(a),
              onLongPress: () => widget.onActivityLongPress(a),
            ),
        ],
      ),
    );
  }
}

class _Group {
  _Group({required this.label, required this.items, this.color});

  final String label;
  final List<Activity> items;
  final int? color;
}

/// 单行活动：56px，两行文本 + 行尾今日时长；运行/待确认各有视觉态。
class _ActivityRow extends StatefulWidget {
  const _ActivityRow({
    required this.activity,
    required this.path,
    required this.running,
    required this.pending,
    required this.today,
    required this.l10n,
    required this.onTap,
    required this.onDoubleTap,
    required this.onLongPress,
  });

  final Activity activity;
  final String path;
  final bool running;
  final bool pending;
  final Duration today;
  final AppLocalizations l10n;
  final VoidCallback onTap;
  final VoidCallback onDoubleTap;
  final VoidCallback onLongPress;

  @override
  State<_ActivityRow> createState() => _ActivityRowState();
}

class _ActivityRowState extends State<_ActivityRow> {
  static const Color _rose = Color(0xfff43f5e);
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final accent = widget.running
        ? _rose
        : (widget.pending ? scheme.primary : null);
    final bg = widget.running
        ? _rose.withValues(alpha: 0.05)
        : (widget.pending
              ? scheme.primary.withValues(alpha: 0.05)
              : (_hover
                    ? scheme.surfaceContainerHighest.withValues(alpha: 0.5)
                    : Colors.transparent));
    return MouseRegion(
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: widget.onTap,
        onDoubleTap: widget.onDoubleTap,
        onLongPress: widget.onLongPress,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 120),
          height: 56,
          margin: const EdgeInsets.only(bottom: 4),
          clipBehavior: Clip.antiAlias,
          decoration: BoxDecoration(
            color: bg,
            borderRadius: BorderRadius.circular(10),
            border: Border.all(
              color: scheme.outlineVariant.withValues(alpha: 0.6),
            ),
          ),
          child: Row(
            children: [
              if (accent != null) Container(width: 3, color: accent),
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  child: Row(
                    children: [
                      ActivityColorDot(
                        Color(widget.activity.color),
                        size: 10,
                        ringWidth: 0,
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Text(
                              widget.activity.name,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontSize: 15,
                                fontWeight: FontWeight.w500,
                                color: widget.running
                                    ? const Color(0xffe11d48)
                                    : scheme.onSurface,
                              ),
                            ),
                            if (widget.pending) ...[
                              const SizedBox(height: 2),
                              Text(
                                widget.l10n.timerTapToConfirm,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  fontSize: 11,
                                  fontWeight: FontWeight.w500,
                                  color: scheme.primary,
                                ),
                              ),
                            ] else if (widget.path.isNotEmpty) ...[
                              const SizedBox(height: 2),
                              Text(
                                widget.path,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  fontSize: 12,
                                  color: scheme.onSurfaceVariant,
                                ),
                              ),
                            ],
                          ],
                        ),
                      ),
                      const SizedBox(width: 12),
                      if (widget.pending)
                        Padding(
                          padding: const EdgeInsets.only(right: 8),
                          child: Icon(
                            Icons.touch_app_rounded,
                            size: 14,
                            color: scheme.primary,
                          ),
                        ),
                      if (widget.running)
                        Container(
                          width: 6,
                          height: 6,
                          margin: const EdgeInsets.only(right: 6),
                          decoration: const BoxDecoration(
                            color: _rose,
                            shape: BoxShape.circle,
                          ),
                        ),
                      TnumText(
                        _hm(widget.today),
                        style: TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                          letterSpacing: -0.2,
                          color: widget.running ? _rose : scheme.onSurface,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  static String _hm(Duration d) {
    final h = d.inHours;
    final m = d.inMinutes.remainder(60);
    return '$h:${m.toString().padLeft(2, '0')}';
  }
}
