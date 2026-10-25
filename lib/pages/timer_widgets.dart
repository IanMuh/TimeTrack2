import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../components/activity_color_dot.dart';
import '../components/tnum_text.dart';
import '../l10n/app_localizations.dart';

/// 计时页子件：环形会话焦点区（参考设计：进度环包住计时 + 当前会话/活动名）
/// 与紧凑活动区。
///
/// 环的语义：运行中按「当前一分钟内的秒进度」扫过一圈，随每次秒级 tick 用
/// 900ms 线性补间连续推进；停止后回落到零并保留底环。所有动画都是一次性
/// 补间（无无限循环），测试与低性能设备上都可收敛。

/// 会话焦点区：宽屏为「环 + 右侧控制栏」横排，窄屏为环 + 统计行 + 按钮。
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
    final scheme = Theme.of(context).colorScheme;
    return LayoutBuilder(
      builder: (context, constraints) {
        final wide = constraints.maxWidth >= 1024;
        final ringSize = wide
            ? 300.0
            : (constraints.maxWidth >= 600 ? 260.0 : 216.0);
        final ring = _SessionRing(
          size: ringSize,
          recording: recording,
          elapsed: elapsed,
          runningName: runningName,
          runningColor: runningColor,
          l10n: l10n,
        );

        if (wide) {
          return Padding(
            padding: const EdgeInsets.symmetric(vertical: 24),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                ring,
                const SizedBox(width: 64),
                SizedBox(
                  width: 280,
                  child: _controls(context, scheme, verticalStats: true),
                ),
              ],
            ),
          );
        }
        return Column(
          children: [
            const SizedBox(height: 12),
            ring,
            const SizedBox(height: 20),
            _statsRow(scheme),
            const SizedBox(height: 18),
            _buttons(scheme),
            if (recording) ...[const SizedBox(height: 8), _hint(scheme)],
            const SizedBox(height: 8),
          ],
        );
      },
    );
  }

  Widget _controls(
    BuildContext context,
    ColorScheme scheme, {
    required bool verticalStats,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _statsColumn(scheme),
        const SizedBox(height: 24),
        _buttons(scheme, alignment: MainAxisAlignment.start),
        if (recording) ...[
          const SizedBox(height: 10),
          _hint(scheme, align: TextAlign.start),
        ],
      ],
    );
  }

  /// 宽屏：两行「标签 / 值」；窄屏：一行 Wrap。
  Widget _statsColumn(ColorScheme scheme) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _statLine(scheme, l10n.timerTodayTotal, _hm(todayTotal)),
        const SizedBox(height: 8),
        _statLine(scheme, l10n.timerTodaySessions, '$todaySessions'),
      ],
    );
  }

  Widget _statLine(ColorScheme scheme, String label, String value) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          label,
          style: TextStyle(fontSize: 13, color: scheme.onSurfaceVariant),
        ),
        const SizedBox(width: 10),
        TnumText(
          value,
          style: TextStyle(
            fontSize: 16,
            fontWeight: FontWeight.w600,
            color: scheme.onSurface,
          ),
        ),
      ],
    );
  }

  Widget _statsRow(ColorScheme scheme) {
    return Wrap(
      alignment: WrapAlignment.center,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        Text(
          l10n.timerTodayTotal,
          style: TextStyle(fontSize: 13, color: scheme.onSurfaceVariant),
        ),
        const SizedBox(width: 6),
        TnumText(
          _hm(todayTotal),
          style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
        ),
        const SizedBox(width: 18),
        Container(width: 1, height: 12, color: scheme.outlineVariant),
        const SizedBox(width: 18),
        Text(
          l10n.timerTodaySessions,
          style: TextStyle(fontSize: 13, color: scheme.onSurfaceVariant),
        ),
        const SizedBox(width: 6),
        TnumText(
          '$todaySessions',
          style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
        ),
      ],
    );
  }

  Widget _buttons(
    ColorScheme scheme, {
    MainAxisAlignment alignment = MainAxisAlignment.center,
  }) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      mainAxisAlignment: alignment,
      children: [
        if (recording) ...[
          OutlinedButton.icon(
            onPressed: onStop,
            style: OutlinedButton.styleFrom(
              foregroundColor: scheme.error,
              side: BorderSide(color: scheme.outlineVariant),
              minimumSize: const Size(96, 44),
              shape: const StadiumBorder(),
            ),
            icon: const Icon(Icons.stop_rounded, size: 17),
            label: Text(l10n.stop),
          ),
          const SizedBox(width: 12),
          FilledButton.icon(
            onPressed: onSwitch,
            style: FilledButton.styleFrom(
              minimumSize: const Size(120, 44),
              shape: const StadiumBorder(),
            ),
            icon: const Icon(Icons.swap_horiz_rounded, size: 17),
            label: Text(l10n.switchActivity),
          ),
        ] else
          FilledButton.icon(
            onPressed: onStart,
            style: FilledButton.styleFrom(
              minimumSize: const Size(148, 48),
              shape: const StadiumBorder(),
            ),
            icon: const Icon(Icons.play_arrow_rounded, size: 20),
            label: Text(l10n.timerStartRecording),
          ),
      ],
    );
  }

  Widget _hint(ColorScheme scheme, {TextAlign align = TextAlign.center}) {
    return Text(
      l10n.timerSwitchHint,
      textAlign: align,
      style: TextStyle(
        fontSize: 12,
        height: 1.5,
        color: scheme.onSurfaceVariant.withValues(alpha: 0.8),
      ),
    );
  }

  /// H:MM（今日累计短格式，如 10:42）。
  static String _hm(Duration d) {
    final h = d.inHours;
    final m = d.inMinutes.remainder(60);
    return '$h:${m.toString().padLeft(2, '0')}';
  }
}

/// 进度环 + 环内计时/会话信息。
class _SessionRing extends StatelessWidget {
  const _SessionRing({
    required this.size,
    required this.recording,
    required this.elapsed,
    required this.runningName,
    required this.runningColor,
    required this.l10n,
  });

  final double size;
  final bool recording;
  final Duration elapsed;
  final String? runningName;
  final int? runningColor;
  final AppLocalizations l10n;

  static const Color _rose = Color(0xfff43f5e);

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final accent = recording ? _rose : scheme.outlineVariant;
    // 当前一分钟内的秒进度；停止后归零。
    final target = recording ? (elapsed.inMilliseconds % 60000) / 60000.0 : 0.0;
    final timeSize = size * 0.158;

    return Semantics(
      label: recording
          ? '${l10n.timerRunning} ${runningName ?? ''}'
          : l10n.notRecording,
      child: AnimatedScale(
        scale: recording ? 1 : 0.985,
        duration: const Duration(milliseconds: 320),
        curve: Curves.easeOutCubic,
        child: TweenAnimationBuilder<double>(
          tween: Tween<double>(end: target),
          duration: const Duration(milliseconds: 900),
          curve: Curves.linear,
          builder: (context, progress, _) {
            return CustomPaint(
              painter: _RingPainter(
                progress: progress,
                accent: accent,
                track: scheme.outlineVariant.withValues(alpha: 0.42),
                glow: recording
                    ? _rose.withValues(alpha: 0.16)
                    : Colors.transparent,
              ),
              child: SizedBox(
                width: size,
                height: size,
                child: Center(
                  child: Padding(
                    padding: EdgeInsets.symmetric(horizontal: size * 0.15),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        FittedBox(
                          fit: BoxFit.scaleDown,
                          child: TnumText(
                            formatHms(elapsed),
                            style: TextStyle(
                              fontSize: timeSize,
                              fontWeight: FontWeight.w600,
                              letterSpacing: -1.6,
                              height: 1.0,
                              color: recording
                                  ? scheme.onSurface
                                  : scheme.onSurfaceVariant,
                            ),
                          ),
                        ),
                        SizedBox(height: size * 0.022),
                        Text(
                          recording
                              ? l10n.timerCurrentSession
                              : l10n.notRecording,
                          style: TextStyle(
                            fontSize: 11,
                            fontWeight: FontWeight.w500,
                            letterSpacing: 0.8,
                            color: scheme.onSurfaceVariant,
                          ),
                        ),
                        AnimatedSwitcher(
                          duration: const Duration(milliseconds: 260),
                          child: recording && runningName != null
                              ? Padding(
                                  key: const ValueKey('running'),
                                  padding: EdgeInsets.only(top: size * 0.035),
                                  child: Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      ActivityColorDot(
                                        runningColor == null
                                            ? _rose
                                            : Color(runningColor!),
                                        size: 8,
                                        ringWidth: 0,
                                      ),
                                      const SizedBox(width: 6),
                                      Flexible(
                                        child: Text(
                                          runningName!,
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                          style: TextStyle(
                                            fontSize: 13,
                                            fontWeight: FontWeight.w500,
                                            color: scheme.onSurface,
                                          ),
                                        ),
                                      ),
                                    ],
                                  ),
                                )
                              : const SizedBox.shrink(key: ValueKey('idle')),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            );
          },
        ),
      ),
    );
  }
}

class _RingPainter extends CustomPainter {
  _RingPainter({
    required this.progress,
    required this.accent,
    required this.track,
    required this.glow,
  });

  final double progress;
  final Color accent;
  final Color track;
  final Color glow;

  @override
  void paint(Canvas canvas, Size size) {
    final stroke = size.width * 0.028;
    final center = Offset(size.width / 2, size.height / 2);
    final radius = (size.shortestSide - stroke) / 2;

    canvas.drawCircle(
      center,
      radius,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = stroke
        ..color = track,
    );

    if (progress <= 0) return;
    final p = progress.clamp(0.004, 1.0);
    final rect = Rect.fromCircle(center: center, radius: radius);

    if (glow.a > 0) {
      canvas.drawArc(
        rect,
        -math.pi / 2,
        2 * math.pi * p,
        false,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = stroke * 1.8
          ..strokeCap = StrokeCap.round
          ..color = glow
          ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 8),
      );
    }

    final arc = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = stroke
      ..strokeCap = StrokeCap.round
      ..shader = SweepGradient(
        transform: const GradientRotation(-math.pi / 2),
        colors: [accent.withValues(alpha: 0.35), accent],
      ).createShader(rect);
    canvas.drawArc(rect, -math.pi / 2, 2 * math.pi * p, false, arc);
  }

  @override
  bool shouldRepaint(_RingPainter old) =>
      old.progress != progress ||
      old.accent != accent ||
      old.track != track ||
      old.glow != glow;
}
