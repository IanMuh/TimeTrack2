import 'package:flutter/widgets.dart';

/// 页面内容框架：水平居中并限制最大宽度。
///
/// 壳层不再统一约束内容宽度（旧实现全壳 `max-w-5xl`=1024 居中），
/// 由每个页面按语义声明自己的上限：计时/统计可放宽到 1440，
/// 今日 1120，设置 1280（设置正文内部仍按 760 排版）。
class PageFrame extends StatelessWidget {
  const PageFrame({super.key, required this.maxWidth, required this.child});

  /// 内容最大宽度（逻辑像素）。传 [double.infinity] 表示不限制。
  final double maxWidth;

  final Widget child;

  @override
  Widget build(BuildContext context) {
    if (maxWidth.isInfinite) return child;
    return Center(
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: maxWidth),
        child: child,
      ),
    );
  }
}
