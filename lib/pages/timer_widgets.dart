import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../components/activity_color_dot.dart';
import '../components/tnum_text.dart';
import '../l10n/app_localizations.dart';

/// 计时页子件：缺口圆环焦点区 + 紧凑活动区。
///
/// 环：固定缺口的圆弧（缺口在正下方），白天模式蓝绿、夜间模式青绿；运行中
/// 一段高亮沿弧从左往右循环传递（由 1Hz tick 驱动的 1s 线性补间，无无限
/// AnimationController，测试可收敛），停止后高亮停在起始位置并压暗。

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
            ? 236.0
            : (constraints.maxWidth >= 600 ? 196.0 : 168.0);
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
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                ring,
                const SizedBox(width: 40),
                SizedBox(width: 262, child: _controls(context, scheme)),
              ],
            ),
          );
        }
        return Column(
          children: [
            const SizedBox(height: 4),
            ring,
            const SizedBox(height: 12),
            _statsRow(scheme),
            const SizedBox(height: 14),
            _buttons(scheme),
            const SizedBox(height: 4),
          ],
        );
      },
    );
  }

  Widget _controls(BuildContext context, ColorScheme scheme) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _statsColumn(scheme),
        const SizedBox(height: 18),
        _buttons(scheme, alignment: MainAxisAlignment.start),
        if (recording) ...[const SizedBox(height: 10), _hint(scheme)],
      ],
    );
  }

  /// 宽屏：两行「标签 / 值」；窄屏：一行 Wrap。
  Widget _statsColumn(ColorScheme scheme) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _statLine(scheme, l10n.timerTodayTotal, _hm(todayTotal)),
        const SizedBox(height: 6),
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
        const SizedBox(width: 16),
        Container(width: 1, height: 12, color: scheme.outlineVariant),
        const SizedBox(width: 16),
        Text(
          l10n.timerTodaySessions,
          style: TextStyle(fontSize: 13, color: scheme.onSurfaceVariant),
        ),
        const SizedBox(width: 6),
        TnumText(
          '$todaySessions',
          style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
        ),
        const SizedBox(width: 10),
        Tooltip(
          message: l10n.timerSwitchHint,
          child: Icon(
            Icons.info_outline,
            size: 14,
            color: scheme.onSurfaceVariant.withValues(alpha: 0.7),
          ),
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
              minimumSize: const Size(92, 42),
              shape: const StadiumBorder(),
            ),
            icon: const Icon(Icons.stop_rounded, size: 17),
            label: Text(l10n.stop),
          ),
          const SizedBox(width: 12),
          FilledButton.icon(
            onPressed: onSwitch,
            style: FilledButton.styleFrom(
              minimumSize: const Size(116, 42),
              shape: const StadiumBorder(),
            ),
            icon: const Icon(Icons.swap_horiz_rounded, size: 17),
            label: Text(l10n.switchActivity),
          ),
        ] else
          FilledButton.icon(
            onPressed: onStart,
            style: FilledButton.styleFrom(
              minimumSize: const Size(140, 46),
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

/// 缺口圆环 + 环内计时/会话信息。
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

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final dark = theme.brightness == Brightness.dark;
    final palette = dark
        ? const [_Palette.mint, _Palette.aqua]
        : const [_Palette.cyan, _Palette.emerald];
    final timeSize = size * 0.17;

    // 高亮沿弧传递：3s 一圈；由 1Hz tick 驱动的 1s 线性补间连续推进。
    final phase = recording ? (elapsed.inMilliseconds % 3000) / 3000.0 : 0.06;

    return Semantics(
      label: recording
          ? '${l10n.timerRunning} ${runningName ?? ''}'
          : l10n.notRecording,
      child: SizedBox(
        width: size,
        height: size,
        child: TweenAnimationBuilder<double>(
          tween: Tween<double>(end: phase),
          duration: Duration(milliseconds: recording ? 1000 : 300),
          curve: Curves.linear,
          builder: (context, animatedPhase, _) {
            return CustomPaint(
              painter: _RingPainter(
                phase: animatedPhase,
                running: recording,
                colors: palette,
              ),
              child: Center(
                child: Padding(
                  padding: EdgeInsets.symmetric(horizontal: size * 0.16),
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
                            letterSpacing: -1.4,
                            height: 1.0,
                            color: recording
                                ? scheme.onSurface
                                : scheme.onSurfaceVariant,
                          ),
                        ),
                      ),
                      SizedBox(height: size * 0.03),
                      Text(
                        recording
                            ? l10n.timerCurrentSession
                            : l10n.notRecording,
                        style: TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.w500,
                          letterSpacing: 0.6,
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                      AnimatedSwitcher(
                        duration: const Duration(milliseconds: 240),
                        child: recording && runningName != null
                            ? Padding(
                                key: const ValueKey('running'),
                                padding: EdgeInsets.only(top: size * 0.05),
                                child: Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    ActivityColorDot(
                                      runningColor == null
                                          ? palette.last
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
            );
          },
        ),
      ),
    );
  }
}

/// 环配色：白天蓝绿、夜间青绿（低饱和高亮度，避免夜间刺眼）。
abstract final class _Palette {
  static const Color cyan = Color(0xff06b6d4);
  static const Color emerald = Color(0xff10b981);
  static const Color aqua = Color(0xff22d3ee);
  static const Color mint = Color(0xff34d399);
}

class _RingPainter extends CustomPainter {
  _RingPainter({
    required this.phase,
    required this.running,
    required this.colors,
  });

  final double phase;
  final bool running;
  final List<Color> colors;

  /// 固定缺口：正下方 22% 周长。
  static const double _gap = 0.22 * 2 * math.pi;

  @override
  void paint(Canvas canvas, Size size) {
    final stroke = size.width * 0.034;
    final center = Offset(size.width / 2, size.height / 2);
    final radius = (size.shortestSide - stroke) / 2;
    final rect = Rect.fromCircle(center: center, radius: radius);

    // 缺口居中于正下方（90°）：从右下角起顺时针扫过，止于左下角。
    final start = math.pi / 2 + _gap / 2;
    final sweep = 2 * math.pi - _gap;

    // 底弧：两色低透明度渐变。
    final base = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = stroke
      ..strokeCap = StrokeCap.round
      ..shader = SweepGradient(
        transform: GradientRotation(start),
        colors: [
          colors[0].withValues(alpha: running ? 0.38 : 0.22),
          colors[1].withValues(alpha: running ? 0.38 : 0.22),
        ],
      ).createShader(rect);
    canvas.drawArc(rect, start, sweep, false, base);

    // 高潮：沿弧传递的彗星高亮（运行中才显著）。
    final waveAlpha = running ? 1.0 : 0.35;
    final angle = start + phase * sweep;
    final wave = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = stroke
      ..strokeCap = StrokeCap.round
      ..shader = SweepGradient(
        transform: GradientRotation(angle - math.pi),
        colors: [
          colors[1].withValues(alpha: 0),
          colors[1].withValues(alpha: 0.05 * waveAlpha),
          colors[0].withValues(alpha: 0.95 * waveAlpha),
          colors[1].withValues(alpha: 0.35 * waveAlpha),
          colors[0].withValues(alpha: 0),
        ],
        stops: const [0.0, 0.34, 0.47, 0.55, 0.72],
      ).createShader(rect);
    canvas.drawArc(rect, start, sweep, false, wave);

    if (running) {
      final glow = Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = stroke * 1.9
        ..strokeCap = StrokeCap.round
        ..color = colors[1].withValues(alpha: 0.16)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 9);
      canvas.drawArc(rect, start, sweep, false, glow);
    }
  }

  @override
  bool shouldRepaint(_RingPainter old) =>
      old.phase != phase || old.running != running || old.colors != colors;
}
