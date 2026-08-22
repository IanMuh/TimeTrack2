import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../components/activity_color_dot.dart';
import '../components/tnum_text.dart';
import '../l10n/app_localizations.dart';
import '../viewmodels/time_entry.dart';

/// 计时页"今日记录"面板（宽屏右栏 / 紧凑折叠卡）：时间分布条 + 最近条目 +
/// 分类占比迷你列表——给主页面提供与今日页呼应的上下文搭配。
///
/// 无业务状态：全部数据由 TimerPage 注入（口径与今日页一致的暂定口径，
/// 批次 3 统一到数据层）。
class TimerOverviewPanel extends StatelessWidget {
  const TimerOverviewPanel({
    super.key,
    required this.entries,
    required this.unassignedActivityId,
    required this.l10n,
    this.maxRecent = 3,
  });

  final List<TimeEntry> entries;
  final String? unassignedActivityId;
  final AppLocalizations l10n;
  final int maxRecent;

  static const _slotCount = 6; // 4 小时一槽（00–24）

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final sorted = [...entries]
      ..sort((a, b) => a.startAt.compareTo(b.startAt));
    final recent = sorted.reversed.take(maxRecent).toList();

    return Container(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 12),
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
              Text(
                l10n.timerTodayPanelHeader,
                style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
              ),
              const Spacer(),
              if (entries.isNotEmpty)
                Text(
                  '${entries.length} ${l10n.timerTodaySessions}',
                  style: TextStyle(fontSize: 11, color: scheme.onSurfaceVariant),
                ),
            ],
          ),
          const SizedBox(height: 10),
          _SlotStrip(
            entries: sorted,
            unassignedActivityId: unassignedActivityId,
          ),
          const SizedBox(height: 12),
          if (recent.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: Text(
                l10n.emptyDayEntries,
                style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
              ),
            )
          else ...[
            for (final e in recent) _RecentRow(entry: e),
          ],
          const Divider(height: 20),
          _MiniBars(entries: sorted, unassignedActivityId: unassignedActivityId),
        ],
      ),
    );
  }

  /// 时长总和（运行中截至 now，起点不钳制到槽——槽内由 _SlotStrip 处理）。
  static Duration totalOf(List<TimeEntry> entries) {
    var t = Duration.zero;
    for (final e in entries) {
      t += e.durationUntil(DateTime.now());
    }
    return t;
  }
}

/// 时段分布：6 槽，槽内有了条目即点亮（取该时段首条活动快照色）；
/// 空槽弱化灰。跨槽条目按 [slotStart, slotEnd) 归属——仅展示语义。
class _SlotStrip extends StatelessWidget {
  const _SlotStrip({
    required this.entries,
    required this.unassignedActivityId,
  });

  final List<TimeEntry> entries;
  final String? unassignedActivityId;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final now = DateTime.now();
    final todayStart = DateTime(now.year, now.month, now.day);
    return Row(
      children: [
        for (var slot = 0; slot < TimerOverviewPanel._slotCount; slot++) ...[
          if (slot > 0) const SizedBox(width: 4),
          Expanded(child: _slot(slot, todayStart, scheme)),
        ],
      ],
    );
  }

  Widget _slot(int slot, DateTime todayStart, ColorScheme scheme) {
    final slotStart = todayStart.add(Duration(hours: slot * 4));
    final slotEnd = slotStart.add(const Duration(hours: 4));
    Color? color;
    for (final e in entries) {
      final start = e.startAt.isBefore(slotStart) ? slotStart : e.startAt;
      final end = e.endAt ?? DateTime.now();
      if (end.isAfter(start) && start.isBefore(slotEnd)) {
        // 取槽内首条的快照色；未分配条目标记灰（休息空档感）。
        if (e.activityId == unassignedActivityId) {
          color = const Color(0xffa1a1aa);
        } else {
          color = e.activityColorSnapshot == null
              ? const Color(0xff10b981)
              : Color(e.activityColorSnapshot!);
          break;
        }
      }
    }
    return Container(
      height: 22,
      decoration: BoxDecoration(
        color: color ?? scheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(5),
      ),
      alignment: Alignment.center,
      child: Text(
        (slot * 4).toString().padLeft(2, '0'),
        style: TextStyle(
          fontSize: 9,
          color: color != null
              ? Colors.white
              : scheme.onSurfaceVariant,
          fontFeatures: const [FontFeature.tabularFigures()],
        ),
      ),
    );
  }
}

class _RecentRow extends StatelessWidget {
  const _RecentRow({required this.entry});

  final TimeEntry entry;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final start = DateFormat('HH:mm', 'zh').format(entry.startAt);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          TnumText(
            start,
            style: TextStyle(fontSize: 11.5, color: scheme.onSurfaceVariant),
          ),
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
                size: 11, color: const Color(0xff0ea5e9)),
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

/// 分类占比迷你列表（口径同今日页：未分配 = 休息段，其余 = 专注段按活动）。
class _MiniBars extends StatelessWidget {
  const _MiniBars({
    required this.entries,
    required this.unassignedActivityId,
  });

  final List<TimeEntry> entries;
  final String? unassignedActivityId;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    // 按活动聚合（快照名/色 + 尚未按当前分类归属——标签沿用"专注/休息"两档，
    // 批次 3 随统计页统一为数据层分组口径）。
    final map = <String, ({String name, int? color, Duration d})>{};
    var total = Duration.zero;
    for (final e in entries) {
      final d = e.durationUntil(DateTime.now());
      total += d;
      final cur = map[e.activityId];
      map[e.activityId] = (
        name: cur?.name ?? e.activityNameSnapshot,
        color: cur?.color ?? e.activityColorSnapshot,
        d: (cur?.d ?? Duration.zero) + d,
      );
    }
    final rows = map.values.toList()
      ..sort((a, b) => b.d.compareTo(a.d));
    if (rows.isEmpty) return const SizedBox(height: 4);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (final row in rows.take(4))
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Row(
              children: [
                ActivityColorDot(
                  row.color == null ? const Color(0xffa1a1aa) : Color(row.color!),
                  size: 8,
                ),
                const SizedBox(width: 6),
                SizedBox(
                  width: 52,
                  child: Text(
                    row.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 11),
                  ),
                ),
                Expanded(
                  child: Column(
                    children: [
                      const SizedBox(height: 1),
                      LayoutBuilder(
                        builder: (context, c) {
                          final ratio = total.inMilliseconds == 0
                              ? 0.0
                              : row.d.inMilliseconds / total.inMilliseconds;
                          return Stack(
                            children: [
                              Container(
                                height: 4,
                                decoration: BoxDecoration(
                                  color: scheme.surfaceContainerHighest,
                                  borderRadius: BorderRadius.circular(2),
                                ),
                              ),
                              FractionallySizedBox(
                                widthFactor: ratio,
                                child: Container(
                                  height: 4,
                                  decoration: BoxDecoration(
                                    color: row.color == null
                                        ? const Color(0xffa1a1aa)
                                        : Color(row.color!),
                                    borderRadius: BorderRadius.circular(2),
                                  ),
                                ),
                              ),
                            ],
                          );
                        },
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                TnumText(
                  formatHms(row.d),
                  style: TextStyle(fontSize: 11, color: scheme.onSurfaceVariant),
                ),
              ],
            ),
          ),
      ],
    );
  }
}
