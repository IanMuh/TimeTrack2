import 'package:flutter/material.dart';

import '../components/activity_color_dot.dart';
import '../components/controls.dart' show AppChip;
import '../components/tnum_text.dart';
import '../l10n/app_localizations.dart';
import '../viewmodels/activity.dart';
import '../viewmodels/activity_category.dart';

/// 计时页子件（对照 design/timer.html：居中式会话焦点区 + 快捷活动区）。

/// 会话焦点区（设计稿：居中列——呼吸徽标 / 48-72px 大计时 / 活动行 /
/// 统计行 / 按钮组 / 说明小字；无卡片底）。
class TimerFocusSection extends StatelessWidget {
  const TimerFocusSection({
    super.key,
    required this.l10n,
    required this.recording,
    required this.runningName,
    required this.runningColor,
    required this.runningPath,
    required this.elapsed,
    required this.todayTotal,
    required this.todaySessions,
    required this.onStop,
    required this.onSwitch,
    required this.onStart,
  });

  final AppLocalizations l10n;
  final bool recording;
  final String? runningName;
  final int? runningColor;
  final String? runningPath;
  final Duration elapsed;
  final Duration todayTotal;
  final int todaySessions;
  final VoidCallback? onStop;
  final VoidCallback? onSwitch;
  final VoidCallback? onStart;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final width = MediaQuery.sizeOf(context).width;
    final timerStyle = TextStyle(
      fontSize: width >= 840 ? 72.0 : (width >= 600 ? 60.0 : 48.0),
      fontWeight: FontWeight.w600,
      letterSpacing: -2,
      height: 1.05,
      color: recording ? scheme.onSurface : scheme.onSurfaceVariant,
    );
    final accent = const Color(0xfff43f5e); // rose-500（运行色系）

    return Column(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        const SizedBox(height: 40),
        _StatusPill(recording: recording, accent: accent),
        const SizedBox(height: 20),
        TnumText(formatHms(elapsed), style: timerStyle),
        const SizedBox(height: 12),
        if (recording)
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              ActivityColorDot(
                runningColor == null ? accent : Color(runningColor!),
                size: 8,
                ringWidth: 0,
              ),
              const SizedBox(width: 8),
              Flexible(
                child: Text(
                  runningName ?? '',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w500,
                    color: scheme.onSurface,
                  ),
                ),
              ),
              if (runningPath != null && runningPath!.isNotEmpty) ...[
                const SizedBox(width: 6),
                Text('·', style: TextStyle(color: scheme.outline)),
                const SizedBox(width: 6),
                Flexible(
                  child: Text(
                    runningPath!,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style:
                        TextStyle(fontSize: 14, color: scheme.onSurfaceVariant),
                  ),
                ),
              ],
            ],
          ),
        const SizedBox(height: 24),
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(l10n.timerTodayTotal, style: _statLabel(scheme)),
            const SizedBox(width: 6),
            TnumText(_hm(todayTotal), style: _statValue(scheme)),
            const SizedBox(width: 20),
            Container(width: 1, height: 12, color: scheme.outline),
            const SizedBox(width: 20),
            Text(l10n.timerTodaySessions, style: _statLabel(scheme)),
            const SizedBox(width: 6),
            TnumText('$todaySessions', style: _statValue(scheme)),
          ],
        ),
        const SizedBox(height: 32),
        if (recording) ...[
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              OutlinedButton.icon(
                onPressed: onStop,
                style: OutlinedButton.styleFrom(
                  foregroundColor: scheme.error,
                  side: BorderSide(color: scheme.outlineVariant),
                ),
                icon: const Icon(Icons.stop_rounded, size: 16),
                label: Text(l10n.stop),
              ),
              const SizedBox(width: 12),
              FilledButton.icon(
                onPressed: onSwitch,
                icon: const Icon(Icons.swap_horiz_rounded, size: 16),
                label: Text(l10n.switchActivity),
              ),
            ],
          ),
          const SizedBox(height: 12),
          SizedBox(
            width: 420,
            child: Text(
              l10n.timerSwitchHint,
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 12,
                height: 1.6,
                color: scheme.onSurfaceVariant.withValues(alpha: 0.8),
              ),
            ),
          ),
        ] else
          FilledButton.icon(
            onPressed: onStart,
            icon: const Icon(Icons.play_arrow_rounded, size: 18),
            label: Text(l10n.timerStartRecording),
          ),
        const SizedBox(height: 16),
      ],
    );
  }

  TextStyle _statLabel(ColorScheme scheme) =>
      TextStyle(fontSize: 14, color: scheme.onSurfaceVariant);
  TextStyle _statValue(ColorScheme scheme) => TextStyle(
        fontSize: 14,
        fontWeight: FontWeight.w600,
        color: scheme.onSurface,
      );

  /// H:MM（设计稿今日累计短格式，如 10:42）。
  static String _hm(Duration d) {
    final h = d.inHours;
    final m = d.inMinutes.remainder(60);
    return '$h:${m.toString().padLeft(2, '0')}';
  }
}

/// 状态徽标（rose 呼吸 / 灰弱化）。
class _StatusPill extends StatelessWidget {
  const _StatusPill({required this.recording, required this.accent});

  final bool recording;
  final Color accent;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final l10n = AppLocalizations.of(context)!;
    final color = recording ? accent : scheme.onSurfaceVariant;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: color.withValues(alpha: 0.25)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          TweenAnimationBuilder<double>(
            tween: Tween(begin: 0.35, end: 1),
            duration: const Duration(milliseconds: 900),
            builder: (context, opacity, _) => Opacity(
              opacity: recording ? opacity : 0.6,
              child: Container(
                width: 8,
                height: 8,
                decoration: BoxDecoration(color: color, shape: BoxShape.circle),
              ),
            ),
          ),
          const SizedBox(width: 8),
          Text(
            recording ? l10n.timerRunning : l10n.notRecording,
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w500,
              color:
                  recording ? const Color(0xffe11d48) : scheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }
}

/// 快捷活动区（设计稿：标题行 + 分类 chip 行 + 分组说明行 + 2/3/4 列网格）。
class TimerQuickSection extends StatelessWidget {
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

  bool _inCategory(String activityId, String categoryId) {
    final set = categoryIdsByActivity[activityId] ?? const {};
    final desc = descendantsOf[categoryId] ?? const <String>{};
    return set.contains(categoryId) || set.any(desc.contains);
  }

  int _countFor(String categoryId) => activities
      .where((a) => !a.isUnassigned && _inCategory(a.id, categoryId))
      .length;

  String _pathOf(String activityId) {
    final set = categoryIdsByActivity[activityId] ?? const {};
    for (final c in set) {
      final chain = ancestorChain[c];
      if (chain != null && chain.isNotEmpty) return chain.join(' / ');
    }
    return '';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final selected = categoryFilterId;
    final visible = selected == null
        ? activities
        : activities
            .where((a) => !a.isUnassigned && _inCategory(a.id, selected))
            .toList();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // 标题行（左：快捷活动；右：交互约定小字——设计稿同排）。
        Row(
          children: [
            Text(
              l10n.timerQuickSection,
              style: const TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.w500,
                letterSpacing: -0.2,
              ),
            ),
            const Spacer(),
            Flexible(
              child: Text(
                l10n.timerInteractionHint,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 12,
                  color: scheme.onSurfaceVariant.withValues(alpha: 0.8),
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 16),
        // 分类 chip 行（固定入口以竖分割线区隔，常驻行尾）。
        SizedBox(
          height: 34,
          child: ListView(
            scrollDirection: Axis.horizontal,
            children: [
              AppChip(
                label: l10n.timerAll,
                count: activities.length,
                selected: selected == null,
                onTap: () => onFilter(null),
              ),
              const SizedBox(width: 8),
              for (final c in rootCategories) ...[
                AppChip(
                  label: c.name,
                  dotColor: Color(c.color),
                  count: _countFor(c.id),
                  selected: selected == c.id,
                  onTap: () => onFilter(c.id),
                ),
                const SizedBox(width: 8),
              ],
              Container(width: 1, height: 20, color: scheme.outline),
              const SizedBox(width: 8),
              AppChip(label: l10n.timerTemporaryActivity, onTap: onTemporary),
              const SizedBox(width: 8),
              AppChip(label: l10n.timerNewActivity, onTap: onNewActivity),
            ],
          ),
        ),
        const SizedBox(height: 14),
        _GroupHeaderLine(
          scheme: scheme,
          selected: selected,
          rootCategories: rootCategories,
          childrenByParent: childrenByParent,
          countFor: _countFor,
          visibleCount: visible.length,
          l10n: l10n,
        ),
        const SizedBox(height: 16),
        LayoutBuilder(
          builder: (context, constraints) {
            final columns = constraints.maxWidth >= 840
                ? 4
                : constraints.maxWidth >= 600
                    ? 3
                    : 2;
            return GridView.count(
              crossAxisCount: columns,
              mainAxisSpacing: 12,
              crossAxisSpacing: 12,
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              childAspectRatio: 1.75,
              children: [
                for (final a in visible)
                  _ActivityCard(
                    activity: a,
                    path: _pathOf(a.id),
                    running: runningActivityId == a.id,
                    pending: pendingActivityId == a.id,
                    today: todayByActivity[a.id] ?? Duration.zero,
                    scheme: scheme,
                    l10n: l10n,
                    onTap: () => onActivityTap(a),
                    onDoubleTap: () => onActivityDoubleTap(a),
                    onLongPress: () => onActivityLongPress(a),
                  ),
              ],
            );
          },
        ),
      ],
    );
  }
}

/// 分组说明行：全部态"全部活动 · 共 N 个"；选中态"色点 分类 / 子组 · N、…"。
class _GroupHeaderLine extends StatelessWidget {
  const _GroupHeaderLine({
    required this.scheme,
    required this.selected,
    required this.rootCategories,
    required this.childrenByParent,
    required this.countFor,
    required this.visibleCount,
    required this.l10n,
  });

  final ColorScheme scheme;
  final String? selected;
  final List<ActivityCategory> rootCategories;
  final Map<String?, List<ActivityCategory>> childrenByParent;
  final int Function(String) countFor;
  final int visibleCount;
  final AppLocalizations l10n;

  @override
  Widget build(BuildContext context) {
    final muted = scheme.onSurfaceVariant;
    if (selected == null) {
      return Row(
        children: [
          Icon(Icons.layers_outlined, size: 14, color: muted),
          const SizedBox(width: 6),
          Text(l10n.timerAllActivities,
              style: TextStyle(fontSize: 12, color: muted)),
          const SizedBox(width: 6),
          Text('·', style: TextStyle(fontSize: 12, color: scheme.outline)),
          const SizedBox(width: 6),
          Text(l10n.timerGroupCount(visibleCount),
              style: TextStyle(fontSize: 12, color: muted)),
        ],
      );
    }
    final cat = rootCategories.where((c) => c.id == selected).firstOrNull;
    if (cat == null) return const SizedBox(height: 16);
    final subs = childrenByParent[cat.id] ?? const [];
    final subText =
        subs.map((s) => '${s.name} · ${countFor(s.id)}').join('、');
    return Row(
      children: [
        ActivityColorDot(Color(cat.color), size: 8, ringWidth: 0),
        const SizedBox(width: 6),
        Text(
          cat.name,
          style: TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.w500,
            color: scheme.onSurface,
          ),
        ),
        const SizedBox(width: 6),
        Text('/', style: TextStyle(fontSize: 12, color: scheme.outline)),
        const SizedBox(width: 6),
        Expanded(
          child: Text(
            subText.isEmpty
                ? l10n.timerGroupCount(visibleCount)
                : '$subText（${l10n.timerGroupCount(visibleCount)}）',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(fontSize: 12, color: muted),
          ),
        ),
      ],
    );
  }
}

/// 活动卡（设计稿：竖排 rounded-2xl p-3——色点+名(+运行徽标) / 祖先链 /
/// 底行 今日时长+悬停铅笔；待确认 = 描边 + 卡底内嵌提示条）。
class _ActivityCard extends StatelessWidget {
  const _ActivityCard({
    required this.activity,
    required this.path,
    required this.running,
    required this.pending,
    required this.today,
    required this.scheme,
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
  final ColorScheme scheme;
  final AppLocalizations l10n;
  final VoidCallback onTap;
  final VoidCallback onDoubleTap;
  final VoidCallback onLongPress;

  @override
  Widget build(BuildContext context) {
    final rose = const Color(0xfff43f5e);
    final accent = running ? rose : (pending ? scheme.primary : null);
    final dot = Color(activity.color);
    final body = Padding(
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              ActivityColorDot(dot, size: 10, ringWidth: 0),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  activity.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ),
              if (running)
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                  decoration: BoxDecoration(
                    color: rose.withValues(alpha: 0.08),
                    borderRadius: BorderRadius.circular(999),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      TweenAnimationBuilder<double>(
                        tween: Tween(begin: 0.3, end: 1),
                        duration: const Duration(milliseconds: 900),
                        builder: (context, o, _) => Opacity(
                          opacity: o,
                          child: Container(
                            width: 4,
                            height: 4,
                            decoration: BoxDecoration(
                                color: rose, shape: BoxShape.circle),
                          ),
                        ),
                      ),
                      const SizedBox(width: 4),
                      Text(
                        l10n.timerRunning,
                        style: TextStyle(
                          fontSize: 10,
                          fontWeight: FontWeight.w500,
                          color: const Color(0xffe11d48),
                        ),
                      ),
                    ],
                  ),
                ),
            ],
          ),
          const SizedBox(height: 3),
          Text(
            path,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
          ),
          const Spacer(),
          Row(
            children: [
              Text(
                l10n.timerTodayShort,
                style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
              ),
              const SizedBox(width: 4),
              TnumText(
                _hm(today),
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  letterSpacing: -0.2,
                  color: running ? rose : scheme.onSurface,
                ),
              ),
              const Spacer(),
              Icon(Icons.edit_outlined, size: 14, color: scheme.outlineVariant),
            ],
          ),
        ],
      ),
    );
    return GestureDetector(
      onTap: onTap,
      onDoubleTap: onDoubleTap,
      onLongPress: onLongPress,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 120),
        clipBehavior: Clip.antiAlias,
        decoration: BoxDecoration(
          color: scheme.surface,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(
            color: accent ?? scheme.outline,
            width: accent != null ? 1.5 : 1,
          ),
        ),
        child: pending
            ? Column(
                children: [
                  Expanded(child: body),
                  Container(
                    width: double.infinity,
                    padding:
                        const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                    color: scheme.primary.withValues(alpha: 0.08),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(Icons.touch_app_rounded,
                            size: 12, color: scheme.primary),
                        const SizedBox(width: 4),
                        Text(
                          l10n.timerTapToConfirm,
                          style: TextStyle(
                            fontSize: 11,
                            fontWeight: FontWeight.w500,
                            color: scheme.primary,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              )
            : body,
      ),
    );
  }

  static String _hm(Duration d) {
    final h = d.inHours;
    final m = d.inMinutes.remainder(60);
    return '$h:${m.toString().padLeft(2, '0')}';
  }
}
