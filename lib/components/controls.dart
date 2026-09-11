import 'package:flutter/material.dart';

/// 自绘受控控件（全部无业务状态：值/回调由调用方持有）。
///
/// 设计稿要求 toggle/滑块/chip/复选框可辨识、禁用态不静默；本文件提供
/// 统一质感的实现，页面直接使用，不各自发明控件外观。

/// 开关：w-40/h-24 胶囊轨道 + 白色圆钮，选中主色、禁用半透明。
class AppToggle extends StatelessWidget {
  const AppToggle({
    super.key,
    required this.value,
    required this.onChanged,
    this.label,
    this.disabled = false,
  });

  final bool value;
  final ValueChanged<bool>? onChanged;
  final String? label;
  final bool disabled;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final trackColor = value ? scheme.primary : scheme.outlineVariant;
    final toggle = Opacity(
      opacity: disabled ? 0.5 : 1,
      child: GestureDetector(
        onTap: disabled || onChanged == null ? null : () => onChanged!(!value),
        child: Container(
          width: 40,
          height: 24,
          padding: const EdgeInsets.all(2),
          decoration: BoxDecoration(
            color: trackColor,
            borderRadius: BorderRadius.circular(999),
          ),
          child: AnimatedAlign(
            duration: const Duration(milliseconds: 150),
            alignment: value ? Alignment.centerRight : Alignment.centerLeft,
            child: Container(
              width: 20,
              height: 20,
              decoration: BoxDecoration(
                color: Colors.white,
                shape: BoxShape.circle,
                boxShadow: const [
                  BoxShadow(
                    color: Color(0x33000000),
                    blurRadius: 2,
                    offset: Offset(0, 1),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
    if (label == null) return toggle;
    return GestureDetector(
      onTap: disabled || onChanged == null ? null : () => onChanged!(!value),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          toggle,
          const SizedBox(width: 10),
          Text(
            label!,
            style: TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.w500,
              color: disabled
                  ? scheme.onSurfaceVariant
                  : scheme.onSurface,
            ),
          ),
        ],
      ),
    );
  }
}

/// 滑块（自绘：轨道 + 实心进展 + 白色圆钮，拖拽/点按均可定位）。
class AppSlider extends StatelessWidget {
  const AppSlider({
    super.key,
    required this.value,
    required this.min,
    required this.max,
    required this.onChanged,
    this.valueText,
    this.disabled = false,
  });

  final double value;
  final double min;
  final double max;
  final ValueChanged<double> onChanged;
  final String? valueText;
  final bool disabled;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final span = max - min;
    final fraction = span == 0 ? 0.0 : ((value - min) / span).clamp(0.0, 1.0);

    void handle(double dx, double width) {
      if (disabled || width <= 0) return;
      final f = (dx / width).clamp(0.0, 1.0);
      onChanged(min + f * span);
    }

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          height: 28,
          child: LayoutBuilder(
            builder: (context, constraints) {
              final width = constraints.maxWidth;
              return GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTapDown: (d) => handle(d.localPosition.dx, width),
                onHorizontalDragUpdate: (d) =>
                    handle(d.localPosition.dx, width),
                child: Opacity(
                  opacity: disabled ? 0.5 : 1,
                  child: Stack(
                    alignment: Alignment.centerLeft,
                    children: [
                      // 轨道
                      Container(
                        height: 6,
                        decoration: BoxDecoration(
                          color: scheme.outlineVariant.withValues(alpha: 0.6),
                          borderRadius: BorderRadius.circular(3),
                        ),
                      ),
                      // 进展段 + 圆钮（按占比定位；圆钮在段右缘，向渲染侧
                      // 平移半个身位使其圆心对齐进度点——Transform 不参与
                      // 布局约束，避免负 margin 断言）。
                      FractionallySizedBox(
                        widthFactor: fraction,
                        child: Container(
                          height: 6,
                          decoration: BoxDecoration(
                            color: scheme.primary,
                            borderRadius: BorderRadius.circular(3),
                          ),
                          alignment: Alignment.centerRight,
                          child: Transform.translate(
                            offset: const Offset(8, 0),
                            child: Container(
                              width: 16,
                              height: 16,
                              decoration: BoxDecoration(
                                color: Colors.white,
                                shape: BoxShape.circle,
                                border: Border.all(
                                  color: scheme.outlineVariant,
                                  width: 1,
                                ),
                                boxShadow: const [
                                  BoxShadow(
                                    color: Color(0x33000000),
                                    blurRadius: 3,
                                    offset: Offset(0, 1),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              );
            },
          ),
        ),
        if (valueText != null)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text(
              valueText!,
              style: TextStyle(
                fontSize: 12,
                color: scheme.onSurfaceVariant,
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
            ),
          ),
      ],
    );
  }
}

/// 胶囊筛选 chip：可选色点与计数徽标，选中态 = 主色浅染 + 主色文字。
class AppChip extends StatelessWidget {
  const AppChip({
    super.key,
    required this.label,
    this.selected = false,
    this.dotColor,
    this.count,
    this.onTap,
  });

  final String label;
  final bool selected;
  final Color? dotColor;
  final int? count;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 120),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        decoration: BoxDecoration(
          color: selected
              ? scheme.primary.withValues(alpha: 0.12)
              : scheme.surface,
          borderRadius: BorderRadius.circular(999),
          border: Border.all(
            color: selected ? scheme.primary : scheme.outlineVariant,
            width: 1,
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (dotColor != null) ...[
              Container(
                width: 8,
                height: 8,
                decoration: BoxDecoration(
                  color: dotColor,
                  shape: BoxShape.circle,
                ),
              ),
              const SizedBox(width: 6),
            ],
            Text(
              label,
              style: TextStyle(
                fontSize: 13,
                fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
                color: selected
                    ? scheme.primary
                    : scheme.onSurface,
              ),
            ),
            if (count != null) ...[
              const SizedBox(width: 6),
              _CountBadge(count: count!, selected: selected),
            ],
          ],
        ),
      ),
    );
  }
}

class _CountBadge extends StatelessWidget {
  const _CountBadge({required this.count, required this.selected});

  final int count;
  final bool selected;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
      decoration: BoxDecoration(
        color: selected
            ? scheme.primary
            : scheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        '$count',
        style: TextStyle(
          fontSize: 11,
          fontWeight: FontWeight.w600,
          color: selected ? Colors.white : scheme.onSurfaceVariant,
          fontFeatures: const [FontFeature.tabularFigures()],
        ),
      ),
    );
  }
}

/// 自绘复选框：圆角方框 + 勾选填充（受控）。
class AppCheckbox extends StatelessWidget {
  const AppCheckbox({
    super.key,
    required this.checked,
    this.onChanged,
    this.disabled = false,
    this.size = 20,
  });

  final bool checked;
  final ValueChanged<bool>? onChanged;
  final bool disabled;
  final double size;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Opacity(
      opacity: disabled ? 0.5 : 1,
      child: GestureDetector(
        onTap: disabled || onChanged == null
            ? null
            : () => onChanged!(!checked),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 120),
          width: size,
          height: size,
          decoration: BoxDecoration(
            color: checked ? scheme.primary : Colors.transparent,
            borderRadius: BorderRadius.circular(6),
            border: Border.all(
              color: checked ? scheme.primary : scheme.outlineVariant,
              width: 1.5,
            ),
          ),
          child: checked
              ? Icon(
                  Icons.check_rounded,
                  size: size - 6,
                  color: Colors.white,
                )
              : null,
        ),
      ),
    );
  }
}
