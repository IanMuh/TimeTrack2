import 'package:flutter/material.dart';

/// 活动色点（无业务状态：色值由调用方注入，从
/// `constants/theme_tokens.dart` 的 ActivityPalette 取）。
///
/// 大量用于列表/卡片/时间轴轨道：色点带一层主题表面色描边（ring），
/// 深浅色下从卡片底浮起。
class ActivityColorDot extends StatelessWidget {
  const ActivityColorDot(
    this.color, {
    super.key,
    this.size = 12,
    this.ringWidth = 2,
  });

  final Color color;
  final double size;
  final double ringWidth;

  @override
  Widget build(BuildContext context) {
    final ring = Theme.of(context).colorScheme.surface;
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: color,
        shape: BoxShape.circle,
        border: Border.all(color: ring, width: ringWidth),
      ),
    );
  }
}

/// 活动色占比条（统计/分组占比；ratio ∈ [0,1]）。
class ActivityColorBar extends StatelessWidget {
  const ActivityColorBar(
    this.color, {
    super.key,
    required this.ratio,
    this.height = 6,
  });

  final Color color;
  final double ratio;
  final double height;

  @override
  Widget build(BuildContext context) {
    final track = Theme.of(context).colorScheme.surfaceContainerHighest;
    return ClipRRect(
      borderRadius: BorderRadius.circular(height),
      child: SizedBox(
        height: height,
        child: Stack(
          fit: StackFit.expand,
          children: [
            ColoredBox(color: track),
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
