import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../components/activity_color_dot.dart';
import '../components/tnum_text.dart';
import '../l10n/app_localizations.dart';
import '../utils/time_format.dart';
import '../utils/day_metrics.dart' show formatHm;
import '../viewmodels/time_entry.dart';

/// 时间线页子件（对照 design/timeline.html：竖向时间轴主视图 + 比例条 +
/// 条目列表行 + 汇总数字带）。

/// 汇总数字带（轻量一行：总时长 · 会话 · 最长连续）。
class TlSummaryStrip extends StatelessWidget {
  const TlSummaryStrip({
    super.key,
    required this.l10n,
    required this.total,
    required this.sessions,
    required this.longest,
  });

  final AppLocalizations l10n;
  final Duration total;
  final int sessions;
  final Duration longest;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final items = [
      (l10n.todayTotalDuration, formatHm(total)),
      (l10n.timerTodaySessions, '$sessions'),
      (l10n.tlLongest, formatHm(longest)),
    ];
    return FittedBox(
      fit: BoxFit.scaleDown,
      alignment: Alignment.centerLeft,
      child: Row(
        children: [
          for (var i = 0; i < items.length; i++) ...[
            if (i > 0) ...[
              Text(' · ', style: TextStyle(color: scheme.outline)),
              const SizedBox(width: 2),
            ],
            Text(items[i].$1,
                style:
                    TextStyle(fontSize: 12, color: scheme.onSurfaceVariant)),
            const SizedBox(width: 4),
            TnumText(items[i].$2,
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: scheme.onSurface,
                )),
          ],
        ],
      ),
    );
  }
}

/// 竖向时间轴（主视图）：左列时刻+时长 / 中列彩色节点竖轴 / 右列浅染卡。
class TlVerticalTimeline extends StatelessWidget {
  const TlVerticalTimeline({
    this.use24 = true,
    super.key,
    required this.entries,
    required this.unassignedActivityId,
    required this.now,
    required this.onEntryTap,
    this.dayGroups = false,
  });

  /// 24 小时制（用户偏好，透传行组件）。
  final bool use24;

  final List<TimeEntry> entries;
  final String? unassignedActivityId;
  final DateTime now;
  final ValueChanged<TimeEntry> onEntryTap;

  /// 跨度模式下按日期分组（分组头：日期 · N 条 · 小计）。
  final bool dayGroups;

  @override
  Widget build(BuildContext context) {
    if (entries.isEmpty) return const SizedBox.shrink();
    final sorted = [...entries]..sort((a, b) => a.startAt.compareTo(b.startAt));
    if (!dayGroups) {
      return Column(children: [_axis(sorted, context)]);
    }
    final byDay = <DateTime, List<TimeEntry>>{};
    for (final e in sorted) {
      final d = DateTime(e.startAt.year, e.startAt.month, e.startAt.day);
      byDay.putIfAbsent(d, () => []).add(e);
    }
    return Column(
      children: [
        for (final day in byDay.keys) ...[
          _DayGroupHeader(day: day, count: byDay[day]!.length),
          _axis(byDay[day]!, context),
        ],
      ],
    );
  }

  Widget _axis(List<TimeEntry> list, BuildContext context) {
    return Column(
      children: [
        for (var i = 0; i < list.length; i++)
          TlTimelineRow(
            use24: use24,
            entry: list[i],
            previous: i > 0 ? list[i - 1] : null,
            unassigned: list[i].activityId == unassignedActivityId,
            now: now,
            onTap: () => onEntryTap(list[i]),
          ),
      ],
    );
  }
}

class _DayGroupHeader extends StatelessWidget {
  const _DayGroupHeader({required this.day, required this.count});

  final DateTime day;
  final int count;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final l10n = AppLocalizations.of(context)!;
    final label = DateFormat('M月d日 EEE', 'zh').format(day);
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 18, 4, 8),
      child: Row(
        children: [
          Text(
            label,
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w600,
              color: scheme.onSurface,
            ),
          ),
          const SizedBox(width: 8),
          Text(
            l10n.tlEntriesCount(count),
            style: TextStyle(fontSize: 11, color: scheme.onSurfaceVariant),
          ),
        ],
      ),
    );
  }
}

/// 单条时间轴行：时刻+时长 | 节点 | 浅染卡。
class TlTimelineRow extends StatelessWidget {
  const TlTimelineRow({
    super.key,
    required this.entry,
    required this.previous,
    required this.unassigned,
    required this.now,
    required this.onTap,
    this.use24 = true,
  });

  final TimeEntry entry;
  final TimeEntry? previous;

  /// 该条目是否属于"未分配"活动。
  final bool unassigned;
  final DateTime now;
  final VoidCallback onTap;

  /// 24 小时制（用户偏好；12 时制显示 09:05 AM 形态）。
  final bool use24;

  /// 左列宽度：12 时制 "09:05 AM" 8 字符在 56px 内折行破坏对齐——加宽。
  double get _leftColumn => use24 ? 56.0 : 76.0;
  static const _trackWidth = 26.0;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final l10n = AppLocalizations.of(context)!;
    final dark = theme.brightness == Brightness.dark;
    final running = entry.isRunning;
    final color = unassigned
        ? const Color(0xffa1a1aa)
        : Color(entry.activityColorSnapshot ?? 0xff10b981);
    final gap = previous == null
        ? 0.0
        : entry.startAt.difference(previous!.startAt).inMinutes >= 120
            ? 10.0
            : 0.0;

    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: Padding(
        padding: EdgeInsets.only(top: 6 + gap, bottom: 6),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // 左列：开始时刻 + 时长。
            SizedBox(
              width: _leftColumn,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  TnumText(
                    formatClockOf(entry.startAt, use24: use24),
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w500,
                      color: scheme.onSurface,
                    ),
                  ),
                  const SizedBox(height: 2),
                  TnumText(
                    formatHm(entry.durationUntil(now)),
                    style: TextStyle(
                        fontSize: 11, color: scheme.onSurfaceVariant),
                  ),
                ],
              ),
            ),
            // 中列：竖向轨道 + 节点。
            SizedBox(
              width: _trackWidth,
              child: Column(
                children: [
                  Container(width: 2, height: 8, color: scheme.outline),
                  Container(
                    width: 12,
                    height: 12,
                    decoration: BoxDecoration(
                      color: color,
                      shape: BoxShape.circle,
                      border: Border.all(
                        color: scheme.surface,
                        width: 2.5,
                      ),
                      boxShadow: [
                        BoxShadow(
                          color: color.withValues(alpha: 0.3),
                          blurRadius: 4,
                        ),
                      ],
                    ),
                  ),
                  Container(width: 2, height: 34, color: scheme.outline),
                ],
              ),
            ),
            const SizedBox(width: 4),
            // 右列：浅染卡。
            Expanded(
              child: Container(
                padding: const EdgeInsets.fromLTRB(12, 9, 12, 9),
                decoration: BoxDecoration(
                  color: color.withValues(alpha: dark ? 0.10 : 0.07),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            entry.activityNameSnapshot,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 13.5,
                              fontWeight: FontWeight.w600,
                              color: dark ? _lighter(color) : _darker(color),
                            ),
                          ),
                        ),
                        if (entry.isAuto) ...[
                          _Tag(
                            color: const Color(0xff0ea5e9),
                            label: l10n.tlAuto,
                            icon: Icons.auto_awesome_rounded,
                          ),
                          const SizedBox(width: 4),
                        ],
                        if (unassigned) ...[
                          _Tag(
                            color: const Color(0xff71717a),
                            label: l10n.tlMerged,
                          ),
                          const SizedBox(width: 4),
                        ],
                        if (running)
                          _Tag(
                            color: const Color(0xff6366f1),
                            label: l10n.tlContinueNext,
                            pulsing: true,
                          ),
                      ],
                    ),
                    if (entry.note.isNotEmpty) ...[
                      const SizedBox(height: 2),
                      Text(
                        entry.note,
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
            ),
          ],
        ),
      ),
    );
  }

  /// 活动名用色：浅色底卡用深阶（darken 28%）、深色底卡用亮阶（lighten）。
  static Color _darker(Color c) => _shift(c, 0.72);
  static Color _lighter(Color c) => _shift(c, 1.35);

  static Color _shift(Color c, double f) => Color.fromARGB(
        255,
        (c.r * 255.0 * f).round().clamp(0, 255),
        (c.g * 255.0 * f).round().clamp(0, 255),
        (c.b * 255.0 * f).round().clamp(0, 255),
      );
}

class _Tag extends StatelessWidget {
  const _Tag({
    required this.color,
    required this.label,
    this.icon,
    this.pulsing = false,
  });

  final Color color;
  final String label;
  final IconData? icon;
  final bool pulsing;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon != null)
            Icon(icon, size: 10, color: color)
          else if (pulsing)
            TweenAnimationBuilder<double>(
              tween: Tween(begin: 0.3, end: 1),
              duration: const Duration(milliseconds: 900),
              builder: (context, o, _) => Opacity(
                opacity: o,
                child: Container(
                  width: 4,
                  height: 4,
                  decoration:
                      BoxDecoration(color: color, shape: BoxShape.circle),
                ),
              ),
            ),
          if (icon != null || pulsing) const SizedBox(width: 3),
          Text(
            label,
            style: TextStyle(
              fontSize: 10,
              fontWeight: FontWeight.w500,
              color: color,
            ),
          ),
        ],
      ),
    );
  }
}

/// 比例条轨道（次要 tab）：24h 等比色块 + 整点刻度 + 现在线 + 缩放。
class TlStripTrack extends StatelessWidget {
  const TlStripTrack({
    super.key,
    required this.entries,
    required this.unassignedActivityId,
    required this.now,
    required this.zoom,
    required this.onEntryTap,
    this.segments = 1,
  });

  final List<TimeEntry> entries;
  final String? unassignedActivityId;
  final DateTime now;
  final double zoom; // 1.0 = 视口宽；>1 横向滚动
  final ValueChanged<TimeEntry> onEntryTap;

  /// 分段堆叠（1–12）：24h 分 N 段纵向堆叠窄轨道（契约 §4.3 已定交互）。
  final int segments;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final l10n = AppLocalizations.of(context)!;
    final dayStart = DateTime(now.year, now.month, now.day);
    final totalMin = 24 * 60.0;

    return LayoutBuilder(
      builder: (context, constraints) {
        final trackWidth = constraints.maxWidth * zoom;
        double dxOf(DateTime t) {
          final m = t.difference(dayStart).inMinutes
              .clamp(0, 24 * 60);
          return m / totalMin * trackWidth;
        }

        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // 图例小字。
            Wrap(
              spacing: 12,
              children: [
                _legend(l10n.tlLegendAuto, const Color(0xff0ea5e9)),
                _legend(l10n.tlLegendUnassigned, const Color(0xffa1a1aa)),
                _legend(l10n.tlLegendContinue, const Color(0xff6366f1)),
              ],
            ),
            const SizedBox(height: 8),
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: SizedBox(
                width: trackWidth,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // 整点刻度（每 4h 一个标签 + 竖线贯穿轨道）。
                    SizedBox(
                      height: 16,
                      child: Stack(
                        children: [
                          for (var h = 0; h <= 24; h += 4)
                            Positioned(
                              left: h / 24.0 * trackWidth - (h == 24 ? 30 : 0),
                              child: TnumText(
                                '${h.toString().padLeft(2, '0')}:00',
                                style: TextStyle(
                                  fontSize: 10,
                                  color: scheme.onSurfaceVariant,
                                ),
                              ),
                            ),
                        ],
                      ),
                    ),
                    // 轨道 + 色块（segments 段堆叠：每段一行窄轨道）。
                    for (var seg = 0; seg < segments; seg++)
                      ..._segmentRow(
                        context,
                        seg: seg,
                        segments: segments,
                        trackWidth: trackWidth,
                        dxOf: dxOf,
                        scheme: scheme,
                        entries: entries,
                        now: now,
                        unassignedActivityId: unassignedActivityId,
                        onEntryTap: onEntryTap,
                        showNow: seg ==
                            (now.hour * 60 + now.minute) ~/
                                (24 * 60 ~/ segments),
                      ),
                  ],
                ),
              ),
            ),
          ],
        );
      },
    );
  }


  /// 单段窄轨道（段内窗口 = 24h/segments；色块按全局时刻映射到段内）。
  List<Widget> _segmentRow(
    BuildContext context, {
    required int seg,
    required int segments,
    required double trackWidth,
    required double Function(DateTime) dxOf,
    required ColorScheme scheme,
    required List<TimeEntry> entries,
    required DateTime now,
    required String? unassignedActivityId,
    required ValueChanged<TimeEntry> onEntryTap,
    required bool showNow,
  }) {
    final winMin = 24 * 60 / segments;
    final segStartMin = seg * winMin;
    final dayStart = DateTime(now.year, now.month, now.day);
    double localX(DateTime t) {
      final m = t.difference(dayStart).inMinutes - segStartMin;
      return (m / winMin).clamp(0.0, 1.0) * trackWidth;
    }

    return [
      if (seg > 0) const SizedBox(height: 6),
      Stack(
        children: [
          Container(
            height: 34,
            decoration: BoxDecoration(
              color: scheme.surfaceContainerHighest.withValues(alpha: 0.4),
              borderRadius: BorderRadius.circular(6),
            ),
          ),
          for (final e in entries)
            () {
              final x = localX(e.startAt);
              final end = e.endAt ?? now;
              final w = (localX(end) - x).clamp(2.0, trackWidth);
              if (w <= 2.0) return const SizedBox.shrink();
              final color = e.activityId == unassignedActivityId
                  ? const Color(0xffa1a1aa)
                  : Color(e.activityColorSnapshot ?? 0xff10b981);
              final showLabel = w > 64 && segments <= 3;
              return Positioned(
                left: x,
                top: 4,
                width: w,
                child: GestureDetector(
                  onTap: () => onEntryTap(e),
                  child: Container(
                    height: 26,
                    padding: const EdgeInsets.symmetric(horizontal: 6),
                    decoration: BoxDecoration(
                      color: color,
                      borderRadius: BorderRadius.circular(5),
                    ),
                    alignment: Alignment.centerLeft,
                    child: showLabel
                        ? Text(
                            e.activityNameSnapshot,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              fontSize: 10.5,
                              fontWeight: FontWeight.w500,
                              color: Colors.white,
                            ),
                          )
                        : null,
                  ),
                ),
              );
            }(),
          if (showNow)
            Positioned(
              left: localX(now),
              top: 0,
              bottom: 0,
              child: Container(
                width: 1.5,
                color: const Color(0xfff43f5e),
              ),
            ),
          Positioned(
            left: 6,
            top: 10,
            child: TnumText(
              segments > 6
                  ? (segStartMin ~/ 60).toString().padLeft(2, '0')
                  : '${(segStartMin ~/ 60).toString().padLeft(2, '0')}–'
                      '${((segStartMin + winMin) ~/ 60).toString().padLeft(2, '0')}',
              style: TextStyle(
                fontSize: 10,
                color: scheme.onSurfaceVariant.withValues(alpha: 0.7),
              ),
            ),
          ),
        ],
      ),
    ];
  }

  Widget _legend(String label, Color c) => Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 8,
            height: 8,
            decoration: BoxDecoration(color: c, shape: BoxShape.circle),
          ),
          const SizedBox(width: 4),
          Text(label,
              style: const TextStyle(fontSize: 10.5, color: Color(0xff71717a))),
        ],
      );
}

/// 条目列表行（全宽表格化：时刻+时长 | 色点+名+备注 | 徽标）。
class TlEntryListRow extends StatelessWidget {
  const TlEntryListRow({
    super.key,
    required this.entry,
    required this.now,
    required this.onTap,
    this.use24 = true,
  });

  final TimeEntry entry;
  final DateTime now;
  final VoidCallback onTap;

  /// 24 小时制（用户偏好）。
  final bool use24;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 10),
        child: Row(
          children: [
            SizedBox(
              width: 84,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  TnumText(
                    formatClockOf(entry.startAt, use24: use24),
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w500,
                      color: scheme.onSurface,
                    ),
                  ),
                  TnumText(
                    formatHm(entry.durationUntil(now)),
                    style: TextStyle(
                        fontSize: 11, color: scheme.onSurfaceVariant),
                  ),
                ],
              ),
            ),
            ActivityColorDot(
              Color(entry.activityColorSnapshot ?? 0xffa1a1aa),
              size: 10,
              ringWidth: 0,
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    entry.activityNameSnapshot,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                        fontSize: 13.5, fontWeight: FontWeight.w500),
                  ),
                  if (entry.note.isNotEmpty)
                    Text(
                      entry.note,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                          fontSize: 11.5, color: scheme.onSurfaceVariant),
                    ),
                ],
              ),
            ),
            if (entry.isAuto)
              Padding(
                padding: const EdgeInsets.only(left: 6),
                child: Icon(Icons.auto_awesome_rounded,
                    size: 12, color: const Color(0xff0ea5e9)),
              ),
            if (entry.isRunning)
              Padding(
                padding: const EdgeInsets.only(left: 6),
                child: TweenAnimationBuilder<double>(
                  tween: Tween(begin: 0.3, end: 1),
                  duration: const Duration(milliseconds: 900),
                  builder: (context, o, _) => Opacity(
                    opacity: o,
                    child: Container(
                      width: 6,
                      height: 6,
                      decoration: const BoxDecoration(
                          color: Color(0xff6366f1), shape: BoxShape.circle),
                    ),
                  ),
                ),
              ),
            const SizedBox(width: 6),
            Icon(Icons.chevron_right_rounded,
                size: 16, color: scheme.onSurfaceVariant),
          ],
        ),
      ),
    );
  }
}

/// 日志视图行：类型徽标 + 时间 + 消息 + 设备名。
class TlLogRow extends StatelessWidget {
  const TlLogRow({super.key, required this.typeLabel, required this.typeColor,
      required this.occurredAt, required this.message, required this.deviceId});

  final String typeLabel;
  final Color typeColor;
  final DateTime occurredAt;
  final String message;
  final String deviceId;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
      child: Row(
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
            decoration: BoxDecoration(
              color: typeColor.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(999),
            ),
            child: Text(
              typeLabel,
              style: TextStyle(
                fontSize: 10.5,
                fontWeight: FontWeight.w600,
                color: typeColor,
              ),
            ),
          ),
          const SizedBox(width: 10),
          TnumText(
            DateFormat('MM-dd HH:mm', 'zh').format(occurredAt),
            style: TextStyle(fontSize: 11.5, color: scheme.onSurfaceVariant),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              message,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 12.5),
            ),
          ),
          const SizedBox(width: 8),
          // 设备名可能任意长：Flexible + ellipsis 防顶出行尾。
          Flexible(
            child: Text(
              deviceId,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 10.5, color: scheme.onSurfaceVariant),
            ),
          ),
        ],
      ),
    );
  }
}
