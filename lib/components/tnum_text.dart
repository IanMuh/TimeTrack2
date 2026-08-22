import 'package:flutter/material.dart';

/// 等宽表格数字文本（契约 §8：实时计时数字须稳定不跳动）。
///
/// 通过 tabular figures 特性让每位数字等宽——秒级推进时不因字符宽度抖动。
/// 所有计时/时长/统计数字应使用本组件（或保证 style 含 tabularFigures）。
class TnumText extends StatelessWidget {
  const TnumText(
    this.text, {
    super.key,
    this.style,
    this.maxLines,
    this.overflow,
  });

  final String text;
  final TextStyle? style;
  final int? maxLines;
  final TextOverflow? overflow;

  @override
  Widget build(BuildContext context) {
    final merged = (style ?? const TextStyle()).merge(
      const TextStyle(fontFeatures: [FontFeature.tabularFigures()]),
    );
    return Text(
      text,
      style: merged,
      maxLines: maxLines,
      overflow: overflow,
    );
  }
}

/// 时长 → `HH:MM:SS`（秒级计时显示用；小时不截断，补零到两位）。
String formatHms(Duration d) {
  final h = d.inHours;
  final m = d.inMinutes.remainder(60);
  final s = d.inSeconds.remainder(60);
  String two(int v) => v.toString().padLeft(2, '0');
  return '${h.toString().padLeft(2, '0')}:${two(m)}:${two(s)}';
}
