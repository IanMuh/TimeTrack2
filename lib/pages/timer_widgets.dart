import 'package:flutter/material.dart';

import '../components/activity_color_dot.dart';
import '../components/tnum_text.dart';
import '../l10n/app_localizations.dart';

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
        const SizedBox(height: 16),
        _StatusPill(recording: recording, accent: accent),
        const SizedBox(height: 12),
        // FittedBox：系统字号放大/超长计时（100+ 小时）下 48px 大数字可能
        // 超出焦点区宽——等比缩小而非溢出。
        FittedBox(
          fit: BoxFit.scaleDown,
          child: TnumText(formatHms(elapsed), style: timerStyle),
        ),
        const SizedBox(height: 8),
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
                    style: TextStyle(
                      fontSize: 14,
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                ),
              ],
            ],
          ),
        const SizedBox(height: 16),
        // Wrap：textScale 放大时 标签+值+分隔线+标签+值 超出焦点区宽——
        // 换行而非溢出。
        Wrap(
          alignment: WrapAlignment.center,
          crossAxisAlignment: WrapCrossAlignment.center,
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
        const SizedBox(height: 20),
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
          const SizedBox(height: 8),
          SizedBox(
            width: 520,
            child: Text(
              l10n.timerSwitchHint,
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 12,
                height: 1.5,
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
        const SizedBox(height: 12),
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
              color: recording
                  ? const Color(0xffe11d48)
                  : scheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }
}
