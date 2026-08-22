import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../components/activity_color_dot.dart';
import '../components/controls.dart' show AppCheckbox;
import '../components/tnum_text.dart';
import '../l10n/app_localizations.dart';
import '../utils/day_metrics.dart' show formatHm;
import '../viewmodels/activity_category.dart';
import '../viewmodels/stats/stats_models.dart';

/// 统计页子件（对照 design/stats.html：筛选树卡 / 树聚合行 / 图表卡 / 明细表）。

/// 树形分类筛选行（递归缩进 + 展开 + 复选）。
class StFilterTree extends StatelessWidget {
  const StFilterTree({
    super.key,
    required this.l10n,
    required this.roots,
    required this.childrenByParent,
    required this.selected,
    required this.expanded,
    required this.onToggleSelect,
    required this.onToggleExpand,
    required this.onAll,
    required this.onNone,
  });

  final AppLocalizations l10n;
  final List<ActivityCategory> roots;
  final Map<String?, List<ActivityCategory>> childrenByParent;
  final Set<String> selected;
  final Set<String> expanded;
  final ValueChanged<String> onToggleSelect;
  final ValueChanged<String> onToggleExpand;
  final VoidCallback onAll;
  final VoidCallback onNone;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Text(l10n.stFilterTitle,
                style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
            const Spacer(),
            TextButton(onPressed: onAll, child: Text(l10n.stFilterAll)),
            TextButton(onPressed: onNone, child: Text(l10n.stFilterNone)),
          ],
        ),
        ..._nodes(roots, 0, scheme),
      ],
    );
  }

  List<Widget> _nodes(List<ActivityCategory> list, int depth, ColorScheme scheme) {
    return [
      for (final c in list) ...[
        Row(
          children: [
            SizedBox(
              width: 16 + depth * 14.0,
              child: (childrenByParent[c.id] ?? const []).isEmpty
                  ? null
                  : InkWell(
                      onTap: () => onToggleExpand(c.id),
                      child: Icon(
                        expanded.contains(c.id)
                            ? Icons.keyboard_arrow_down_rounded
                            : Icons.keyboard_arrow_right_rounded,
                        size: 14,
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
            ),
            AppCheckbox(
              checked: selected.contains(c.id),
              size: 16,
              onChanged: (_) => onToggleSelect(c.id),
            ),
            const SizedBox(width: 6),
            ActivityColorDot(Color(c.color), size: 8, ringWidth: 0),
            const SizedBox(width: 6),
            Expanded(
              child: Text(
                c.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 12.5),
              ),
            ),
          ],
        ),
        if (expanded.contains(c.id))
          ..._nodes(childrenByParent[c.id] ?? const [], depth + 1, scheme),
      ],
    ];
  }
}

/// 树聚合行（契约"树统计覆盖全屏宽"：紧凑档字段换行保层级）。
class StTreeRow extends StatelessWidget {
  const StTreeRow({
    super.key,
    required this.row,
    required this.totalDuration,
    required this.collapsed,
    required this.onToggle,
  });

  final StatsGroupRow row;
  final Duration totalDuration;
  final bool collapsed;
  final VoidCallback onToggle;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final l10n = AppLocalizations.of(context)!;
    final ratio = totalDuration.inMilliseconds == 0
        ? 0.0
        : row.totalDuration.inMilliseconds / totalDuration.inMilliseconds;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              SizedBox(width: row.depth * 16.0),
              Icon(
                collapsed
                    ? Icons.keyboard_arrow_right_rounded
                    : Icons.keyboard_arrow_down_rounded,
                size: 14,
                color: scheme.onSurfaceVariant,
              ),
              const SizedBox(width: 4),
              ActivityColorDot(Color(row.color), size: 8, ringWidth: 0),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  row.label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: row.depth == 0
                        ? FontWeight.w600
                        : FontWeight.w500,
                  ),
                ),
              ),
              const SizedBox(width: 12),
              SizedBox(
                width: 140,
                child: ActivityColorBar2(Color(row.color), ratio: ratio),
              ),
              const SizedBox(width: 8),
              TnumText(
                '${(ratio * 100).toStringAsFixed(0)}%',
                style: TextStyle(
                    fontSize: 11.5, color: scheme.onSurfaceVariant),
              ),
              const SizedBox(width: 12),
              TnumText(
                formatHm(row.totalDuration),
                style: const TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(width: 10),
              Text(
                l10n.stCountShort(row.count),
                style: TextStyle(fontSize: 11, color: scheme.onSurfaceVariant),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// 占比条（与 components 版一致——stats 内联避免跨页依赖色值换算）。
class ActivityColorBar2 extends StatelessWidget {
  const ActivityColorBar2(this.color, {super.key, required this.ratio, this.height = 5});

  final Color color;
  final double ratio;
  final double height;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return ClipRRect(
      borderRadius: BorderRadius.circular(height),
      child: SizedBox(
        height: height,
        child: Stack(
          fit: StackFit.expand,
          children: [
            ColoredBox(color: scheme.surfaceContainerHighest),
            Align(
              alignment: Alignment.centerLeft,
              child: FractionallySizedBox(
                widthFactor: ratio.clamp(0.0, 1.0),
                child: ColoredBox(color: color),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 每日分布柱状图（fl_chart；深浅主题适配刻度/网格）。
class StDailyBarChart extends StatelessWidget {
  const StDailyBarChart({
    super.key,
    required this.days,
    required this.values,
  });

  final List<DateTime> days;
  final List<Duration> values;

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    final grid = dark ? const Color(0x33ffffff) : const Color(0x22000000);
    final label = dark ? const Color(0x99ffffff) : const Color(0x99000000);
    final maxV = values.fold<double>(
        0, (m, v) => v.inMinutes > m ? v.inMinutes.toDouble() : m);
    return SizedBox(
      height: 200,
      child: BarChart(
        BarChartData(
          alignment: BarChartAlignment.spaceAround,
          maxY: maxV <= 0 ? 60 : maxV * 1.15,
          gridData: FlGridData(
            show: true,
            drawVerticalLine: false,
            horizontalInterval: maxV <= 0 ? 30 : (maxV / 4),
            getDrawingHorizontalLine: (v) =>
                FlLine(color: grid, strokeWidth: 1),
          ),
          titlesData: FlTitlesData(
            leftTitles: AxisTitles(
              sideTitles: SideTitles(
                showTitles: true,
                reservedSize: 42,
                getTitlesWidget: (v, meta) => SideTitleWidget(
                  meta: meta,
                  child: Text(
                    _hmLabel(v),
                    style: TextStyle(fontSize: 10, color: label),
                  ),
                ),
              ),
            ),
            bottomTitles: AxisTitles(
              sideTitles: SideTitles(
                showTitles: true,
                getTitlesWidget: (i, meta) => SideTitleWidget(
                  meta: meta,
                  child: Text(
                    DateFormat('M/d', 'zh')
                        .format(days[i.toInt().clamp(0, days.length - 1)]),
                    style: TextStyle(fontSize: 10, color: label),
                  ),
                ),
              ),
            ),
            topTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
            rightTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
          ),
          borderData: FlBorderData(show: false),
          barGroups: [
            for (var i = 0; i < values.length; i++)
              BarChartGroupData(
                x: i,
                barRods: [
                  BarChartRodData(
                    toY: values[i].inMinutes.toDouble(),
                    width: 18,
                    borderRadius: const BorderRadius.vertical(
                        top: Radius.circular(4)),
                    color: const Color(0xff4f46e5),
                  ),
                ],
              ),
          ],
        ),
      ),
    );
  }

  static String _hmLabel(double minutes) {
    final h = minutes ~/ 60;
    return '${h}h';
  }
}

/// 占比环形图（top N + 其他）。
class StSharePieChart extends StatelessWidget {
  const StSharePieChart({
    super.key,
    required this.slices, // (label, color, duration)
  });

  final List<(String, Color, Duration)> slices;

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    final total = slices.fold<int>(0, (m, s) => m + s.$3.inMinutes);
    if (total == 0) return const SizedBox(height: 180);
    return SizedBox(
      height: 180,
      child: Row(
        children: [
          Expanded(
            child: PieChart(
              PieChartData(
                sectionsSpace: 2,
                centerSpaceRadius: 42,
                sections: [
                  for (final s in slices)
                    PieChartSectionData(
                      value: s.$3.inMinutes.toDouble(),
                      color: s.$2,
                      radius: 14,
                      title: '',
                    ),
                ],
              ),
            ),
          ),
          const SizedBox(width: 12),
          // 图例。
          SizedBox(
            width: 180,
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                for (final s in slices)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 2),
                    child: Row(
                      children: [
                        Container(
                          width: 8,
                          height: 8,
                          decoration:
                              BoxDecoration(color: s.$2, shape: BoxShape.circle),
                        ),
                        const SizedBox(width: 6),
                        Expanded(
                          child: Text(
                            s.$1,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(fontSize: 11.5),
                          ),
                        ),
                        TnumText(
                          '${(s.$3.inMinutes / total * 100).toStringAsFixed(0)}%',
                          style: TextStyle(
                            fontSize: 11,
                            color: dark
                                ? const Color(0x99ffffff)
                                : const Color(0x99000000),
                          ),
                        ),
                      ],
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
