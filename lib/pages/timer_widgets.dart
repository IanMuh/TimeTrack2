import 'package:flutter/material.dart';

import '../components/activity_color_dot.dart';
import '../components/controls.dart' show AppChip;
import '../components/tnum_text.dart';
import '../l10n/app_localizations.dart';
import '../viewmodels/activity.dart';
import '../viewmodels/activity_category.dart';

/// 计时页子件（页面组装数据的纯展示件；lib/pages/timer_page.dart 使用）。

/// 会话焦点卡：运行中（色点+名+大计时+今日累计/会话数）或未运行引导。
class TimerFocusCard extends StatelessWidget {
  const TimerFocusCard({
    super.key,
    required this.l10n,
    required this.recording,
    required this.runningName,
    required this.runningColor,
    required this.elapsed,
    required this.todayTotal,
    required this.todaySessions,
    required this.onStartRecording,
  });

  final AppLocalizations l10n;
  final bool recording;
  final String? runningName;
  final int? runningColor;
  final Duration elapsed;
  final Duration todayTotal;
  final int todaySessions;
  final VoidCallback? onStartRecording;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Container(
      padding: const EdgeInsets.fromLTRB(20, 20, 20, 16),
      decoration: BoxDecoration(
        color: scheme.surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: scheme.outline),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              if (recording && runningColor != null)
                ActivityColorDot(Color(runningColor!), size: 14),
              if (recording && runningColor != null) const SizedBox(width: 10),
              Expanded(
                child: Text(
                  recording ? (runningName ?? '') : l10n.notRecording,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w600,
                    color: recording
                        ? scheme.onSurface
                        : scheme.onSurfaceVariant,
                  ),
                ),
              ),
              if (recording)
                _PulseDot(color: const Color(0xfff43f5e)),
            ],
          ),
          const SizedBox(height: 8),
          if (recording)
            TnumText(
              formatHms(elapsed),
              style: theme.textTheme.displaySmall?.copyWith(
                fontWeight: FontWeight.w600,
                letterSpacing: -1,
              ),
            )
          else
            FilledButton(
              onPressed: onStartRecording,
              child: Text(l10n.timerStartRecording),
            ),
          const SizedBox(height: 14),
          Row(
            children: [
              _StatPill(
                label: l10n.timerTodayTotal,
                value: formatHms(todayTotal),
              ),
              const SizedBox(width: 10),
              _StatPill(
                label: l10n.timerTodaySessions,
                value: '$todaySessions',
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _StatPill extends StatelessWidget {
  const _StatPill({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            label,
            style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
          ),
          const SizedBox(width: 6),
          TnumText(
            value,
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w600,
              color: scheme.onSurface,
            ),
          ),
        ],
      ),
    );
  }
}

class _PulseDot extends StatelessWidget {
  const _PulseDot({required this.color});

  final Color color;

  @override
  Widget build(BuildContext context) {
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0.4, end: 1),
      duration: const Duration(milliseconds: 900),
      builder: (context, opacity, _) => Opacity(
        opacity: opacity,
        child: Container(
          width: 8,
          height: 8,
          decoration: BoxDecoration(color: color, shape: BoxShape.circle),
        ),
      ),
    );
  }
}

/// 操作行：停止（危险描边）/ 切换活动（主按钮）。
class TimerActionRow extends StatelessWidget {
  const TimerActionRow({
    super.key,
    required this.l10n,
    this.onStop,
    this.onSwitch,
  });

  final AppLocalizations l10n;
  final VoidCallback? onStop;
  final VoidCallback? onSwitch;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Row(
      children: [
        Expanded(
          child: OutlinedButton.icon(
            onPressed: onStop,
            style: OutlinedButton.styleFrom(
              foregroundColor: scheme.error,
              side: BorderSide(color: scheme.error.withValues(alpha: 0.45)),
            ),
            icon: const Icon(Icons.stop_rounded, size: 16),
            label: Text(l10n.stop),
          ),
        ),
        const SizedBox(width: 10),
        Expanded(
          flex: 2,
          child: FilledButton.icon(
            onPressed: onSwitch,
            icon: const Icon(Icons.swap_horiz_rounded, size: 16),
            label: Text(l10n.switchActivity),
          ),
        ),
      ],
    );
  }
}

/// 快捷活动区：分类 chip 过滤行（含固定"临时活动/新增活动"入口）+ 活动卡网格。
class TimerQuickSection extends StatelessWidget {
  const TimerQuickSection({
    super.key,
    required this.l10n,
    required this.categoryFilterId,
    required this.rootCategories,
    required this.ancestors,
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
  final Map<String, List<String>> ancestors;
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

  int _activityCountFor(String categoryId) {
    final descendants = descendantsOf[categoryId] ?? const <String>{};
    var count = 0;
    for (final a in activities) {
      final set = categoryIdsByActivity[a.id] ?? const {};
      if (set.contains(categoryId) || set.any(descendants.contains)) count++;
    }
    return count;
  }

  void _filterFor(String? categoryId) {
    onFilter(categoryId);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final selected = categoryFilterId;
    final visible = selected == null
        ? activities
        : activities
            .where((a) {
              if (a.isUnassigned) return false;
              final set = categoryIdsByActivity[a.id] ?? const {};
              final desc = descendantsOf[selected] ?? const <String>{};
              return set.contains(selected) || set.any(desc.contains);
            })
            .toList();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          '${l10n.timerAll} ${visible.length}',
          style: theme.textTheme.titleSmall?.copyWith(
            fontWeight: FontWeight.w600,
          ),
        ),
        const SizedBox(height: 8),
        // 分类 chip 过滤行（含固定入口，横滚）。
        SizedBox(
          height: 34,
          child: ListView(
            scrollDirection: Axis.horizontal,
            children: [
              Padding(
                padding: const EdgeInsets.only(right: 6),
                child: AppChip(
                  label: l10n.timerAll,
                  count: activities.length,
                  selected: selected == null,
                  onTap: () => _filterFor(null),
                ),
              ),
              for (final c in rootCategories)
                Padding(
                  padding: const EdgeInsets.only(right: 6),
                  child: AppChip(
                    label: c.name,
                    dotColor: Color(c.color),
                    count: _activityCountFor(c.id),
                    selected: selected == c.id,
                    onTap: () => _filterFor(c.id),
                  ),
                ),
              const SizedBox(width: 8),
              _DividerDots(),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 6),
                child: AppChip(
                  label: l10n.timerTemporaryActivity,
                  onTap: onTemporary,
                ),
              ),
              AppChip(
                label: l10n.timerNewActivity,
                onTap: onNewActivity,
              ),
            ],
          ),
        ),
        if (pendingActivityId != null) ...[
          const SizedBox(height: 4),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            decoration: BoxDecoration(
              color: scheme.primary.withValues(alpha: 0.10),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Text(
              l10n.timerTapToConfirm,
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w600,
                color: scheme.primary,
              ),
            ),
          ),
        ],
        const SizedBox(height: 12),
        // 活动卡网格（列数随断点：紧凑 2 / 中宽 3 / 宽屏 4）。
        LayoutBuilder(
          builder: (context, constraints) {
            final columns = constraints.maxWidth >= 840
                ? 4
                : constraints.maxWidth >= 600
                    ? 3
                    : 2;
            return GridView.count(
              crossAxisCount: columns,
              mainAxisSpacing: 10,
              crossAxisSpacing: 10,
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              childAspectRatio: 1.9,
              children: [
                for (final a in visible)
                  _ActivityCard(
                    activity: a,
                    running: runningActivityId == a.id,
                    pending: pendingActivityId == a.id,
                    today: todayByActivity[a.id] ?? Duration.zero,
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

class _DividerDots extends StatelessWidget {
  const _DividerDots();

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 1,
      height: 20,
      color: Theme.of(context).colorScheme.outline,
    );
  }
}

class _ActivityCard extends StatelessWidget {
  const _ActivityCard({
    required this.activity,
    required this.running,
    required this.pending,
    required this.today,
    required this.onTap,
    required this.onDoubleTap,
    required this.onLongPress,
  });

  final Activity activity;
  final bool running;
  final bool pending;
  final Duration today;
  final VoidCallback onTap;
  final VoidCallback onDoubleTap;
  final VoidCallback onLongPress;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final accent = running || pending;
    return GestureDetector(
      onTap: onTap,
      onDoubleTap: onDoubleTap,
      onLongPress: onLongPress,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 120),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(
          color: scheme.surface,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: accent ? scheme.primary : scheme.outline,
            width: accent ? 1.5 : 1,
          ),
        ),
        child: Row(
          children: [
            ActivityColorDot(Color(activity.color), size: 10),
            const SizedBox(width: 8),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Text(
                    activity.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodySmall?.copyWith(
                      fontWeight: FontWeight.w500,
                      color: scheme.onSurface,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Row(
                    children: [
                      TnumText(
                        formatHms(today),
                        style: TextStyle(
                          fontSize: 10,
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                      if (running) ...[
                        const SizedBox(width: 5),
                        _RunningBadge(scheme: scheme),
                      ],
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _RunningBadge extends StatelessWidget {
  const _RunningBadge({required this.scheme});

  final ColorScheme scheme;

  @override
  Widget build(BuildContext context) {
    return Icon(
      Icons.fiber_manual_record_rounded,
      size: 8,
      color: const Color(0xfff43f5e),
    );
  }
}
