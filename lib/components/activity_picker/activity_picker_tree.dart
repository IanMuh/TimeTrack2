import 'package:flutter/material.dart';

import '../../l10n/app_localizations.dart';
import '../../viewmodels/activity.dart';
import '../../viewmodels/activity_category.dart';
import '../activity_color_dot.dart';

/// 分类树节点行、伪节点行与活动行（选择器内部子件）。

/// 分类树节点（桌面侧栏）：缩进 + 展开箭头 + 色点 + 名；深 > 3 层以祖先链
/// 路径呈现（不再继续缩进——契约 §5.1 层级展示规则）。
class CategoryNodeTile extends StatefulWidget {
  const CategoryNodeTile({
    super.key,
    required this.node,
    required this.depth,
    required this.expanded,
    required this.selected,
    required this.ancestorPath,
    required this.onTap,
    required this.onToggle,
    required this.onMenu,
  });

  final ActivityCategory node;
  final int depth;
  final bool expanded;
  final bool selected;
  final String? ancestorPath;
  final VoidCallback onTap;
  final VoidCallback onToggle;
  final void Function(ActivityCategory, Offset globalPosition) onMenu;

  static const _maxFlatDepth = 3;

  @override
  State<CategoryNodeTile> createState() => _CategoryNodeTileState();
}

class _CategoryNodeTileState extends State<CategoryNodeTile> {
  Offset _lastPosition = Offset.zero;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final node = widget.node;
    final depth = widget.depth;
    final expanded = widget.expanded;
    final selected = widget.selected;
    final isFlat = depth >= CategoryNodeTile._maxFlatDepth;
    final foreground = selected ? scheme.primary : scheme.onSurface;

    return InkWell(
      onTap: widget.onTap,
      onLongPress: () => widget.onMenu(node, _lastPosition),
      onSecondaryTapDown: (d) => widget.onMenu(node, d.globalPosition),
      onTapDown: (d) => _lastPosition = d.globalPosition,
      child: Padding(
        padding: EdgeInsets.only(
          left: 8 + (isFlat ? CategoryNodeTile._maxFlatDepth * 14.0 : depth * 14.0),
          top: 6,
          bottom: 6,
          right: 8,
        ),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
          decoration: BoxDecoration(
            color: selected
                ? scheme.primary.withValues(alpha: 0.10)
                : Colors.transparent,
            borderRadius: BorderRadius.circular(6),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  InkWell(
                    onTap: widget.onToggle,
                    child: Padding(
                      padding: const EdgeInsets.only(right: 2),
                      child: Icon(
                        expanded
                            ? Icons.keyboard_arrow_down_rounded
                            : Icons.keyboard_arrow_right_rounded,
                        size: 16,
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                  ActivityColorDot(Color(node.color), size: 10),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      node.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
                        color: foreground,
                      ),
                    ),
                  ),
                ],
              ),
              if (isFlat && widget.ancestorPath != null)
                Padding(
                  padding: const EdgeInsets.only(left: 26, top: 2),
                  child: Text(
                    widget.ancestorPath!,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 11, color: scheme.onSurfaceVariant),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 伪节点（全部 / 未分类）平铺小行。
class FakeNodeTile extends StatelessWidget {
  const FakeNodeTile({
    super.key,
    required this.label,
    required this.selected,
    required this.onTap,
    this.dot,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;
  final Color? dot;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(10, 8, 10, 8),
        child: Row(
          children: [
            SizedBox(width: 16, child: dot == null ? null : ActivityColorDot(dot!, size: 10)),
            const SizedBox(width: 8),
            Text(
              label,
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: selected ? scheme.primary : scheme.onSurface,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 活动行：色点 + 名 + 临时/当前徽标；长按 = 编辑。
class ActivityRow extends StatelessWidget {
  const ActivityRow({
    super.key,
    required this.activity,
    required this.current,
    required this.onTap,
    this.onEdit,
  });

  final Activity activity;
  final bool current;
  final VoidCallback onTap;
  final VoidCallback? onEdit;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final l10n = AppLocalizations.of(context)!;
    return InkWell(
      onTap: onTap,
      onLongPress: onEdit,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 10),
        child: Row(
          children: [
            ActivityColorDot(Color(activity.color), size: 12),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                activity.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodyMedium?.copyWith(
                  fontWeight: FontWeight.w500,
                ),
              ),
            ),
            if (activity.isOneOff) const SizedBox(width: 6),
            if (activity.isOneOff)
              _Badge(
                label: l10n.oneOff,
                color: scheme.primary.withValues(alpha: 0.12),
                textColor: scheme.primary,
              ),
            if (current) ...[
              const SizedBox(width: 6),
              _Badge(
                label: l10n.currentActivity,
                color: scheme.tertiaryContainer,
                textColor: scheme.onTertiaryContainer,
              ),
            ],
            if (onEdit != null)
              Padding(
                padding: const EdgeInsets.only(left: 8),
                child: Icon(Icons.edit_outlined,
                    size: 14, color: scheme.onSurfaceVariant),
              ),
          ],
        ),
      ),
    );
  }
}

class _Badge extends StatelessWidget {
  const _Badge({required this.label, required this.color, required this.textColor});

  final String label;
  final Color color;
  final Color textColor;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
      decoration: BoxDecoration(
        color: color,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        label,
        style: TextStyle(
          fontSize: 11,
          fontWeight: FontWeight.w600,
          color: textColor,
        ),
      ),
    );
  }
}
