/// 设置页基础组件（批次 4）：分区卡 / 设置行 / 开关 / 滑杆 / 三选卡 /
/// 下拉 / 分段 / 危险区 / 提示条。
///
/// 约定（契约 §8 + DESIGN_LANG）：组件无业务状态（参数注入）；样式对齐
/// 设计稿——rounded-2xl 分区卡 + indigo 徽标头 + divide 行列表。
library;

import 'package:flutter/material.dart';

import '../l10n/app_localizations.dart';

/// 分区卡（十分区统一容器）。
class SettingsSectionCard extends StatelessWidget {
  const SettingsSectionCard({
    super.key,
    required this.icon,
    required this.title,
    required this.subtitle,
    this.badge,
    this.children = const <Widget>[],
    this.paddedChildren = false,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final String? badge;
  final List<Widget> children;

  /// true = children 不按行分隔排布（内边距容器，如云同步/更新卡）。
  final bool paddedChildren;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Card(
      margin: EdgeInsets.zero,
      elevation: 0,
      color: scheme.surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: BorderSide(color: scheme.outlineVariant.withValues(alpha: 0.5)),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 16, 20, 14),
            child: Row(
              children: [
                Container(
                  width: 32,
                  height: 32,
                  decoration: BoxDecoration(
                    color: scheme.primary.withValues(alpha: 0.1),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Icon(icon, size: 16, color: scheme.primary),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Flexible(
                            child: Text(
                              title,
                              style: Theme.of(context).textTheme.titleSmall,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                          if (badge != null) ...[
                            const SizedBox(width: 8),
                            _Badge(label: badge!),
                          ],
                        ],
                      ),
                      const SizedBox(height: 2),
                      Text(
                        subtitle,
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                              color: scheme.onSurfaceVariant,
                            ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          Divider(height: 1, color: scheme.outlineVariant.withValues(alpha: 0.4)),
          if (paddedChildren)
            Padding(padding: const EdgeInsets.all(20), child: Column(children: children))
          else
            ...children.map((child) => _Separated(child: child)),
        ],
      ),
    );
  }
}

/// 行间隔分隔线包裹（除首行外顶部分隔）。
class _Separated extends StatelessWidget {
  const _Separated({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Divider(
          height: 1,
          color: Theme.of(context).colorScheme.outlineVariant.withValues(alpha: 0.25),
        ),
        child,
      ],
    );
  }
}

/// 设计语言 sky（信息提示色，Tailwind sky-500/600——Material 无 sky）。
class SettingsSky {
  SettingsSky._();
  static const Color base = Color(0xFF0EA5E9);
  static const Color dark = Color(0xFF0284C7);
}

class _Badge extends StatelessWidget {
  const _Badge({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: Colors.amber.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        label,
        style: Theme.of(context).textTheme.labelSmall?.copyWith(
              color: Colors.amber.shade800,
              fontWeight: FontWeight.w600,
            ),
      ),
    );
  }
}

/// 标准设置行：标题 + 副题 + 右侧控件。
class SettingsRow extends StatelessWidget {
  const SettingsRow({
    super.key,
    required this.title,
    this.subtitle,
    required this.trailing,
    this.padding = const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
  });

  final String title;
  final String? subtitle;
  final Widget trailing;
  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: padding,
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: Theme.of(context).textTheme.bodyMedium),
                if (subtitle != null) ...[
                  const SizedBox(height: 2),
                  Text(
                    subtitle!,
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: scheme.onSurfaceVariant,
                        ),
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(width: 16),
          trailing,
        ],
      ),
    );
  }
}

/// 开关行。
class SettingsSwitchRow extends StatelessWidget {
  const SettingsSwitchRow({
    super.key,
    required this.title,
    this.subtitle,
    required this.value,
    required this.onChanged,
    this.enabled = true,
  });

  final String title;
  final String? subtitle;
  final bool value;
  final ValueChanged<bool>? onChanged;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    return SettingsRow(
      title: title,
      subtitle: subtitle,
      trailing: Switch(
        value: value,
        onChanged: enabled ? onChanged : null,
      ),
    );
  }
}

/// 滑杆行（拖动结束才落库——onChangeEnd；拖动中仅视觉反馈由 Slider 自身完成）。
class SettingsSliderRow extends StatelessWidget {
  const SettingsSliderRow({
    super.key,
    required this.title,
    this.subtitle,
    required this.value,
    required this.min,
    required this.max,
    this.divisions,
    required this.valueLabel,
    required this.onChangeEnd,
    this.marks = const <String>[],
  });

  final String title;
  final String? subtitle;
  final int value;
  final int min;
  final int max;
  final int? divisions;
  final String valueLabel;
  final ValueChanged<int> onChangeEnd;

  /// 刻度说明（如 15/60/120/180 分钟，均分展示）。
  final List<String> marks;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.baseline,
            textBaseline: TextBaseline.alphabetic,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(title, style: Theme.of(context).textTheme.bodyMedium),
                    if (subtitle != null) ...[
                      const SizedBox(height: 2),
                      Text(
                        subtitle!,
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                              color: scheme.onSurfaceVariant,
                            ),
                      ),
                    ],
                  ],
                ),
              ),
              const SizedBox(width: 16),
              Text(
                valueLabel,
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                      color: scheme.primary,
                      fontWeight: FontWeight.w600,
                      fontFeatures: const [FontFeature.tabularFigures()],
                    ),
              ),
            ],
          ),
          Slider(
            value: value.toDouble(),
            min: min.toDouble(),
            max: max.toDouble(),
            divisions: divisions ?? (max - min),
            label: valueLabel,
            onChanged: (_) {},
            onChangeEnd: (v) => onChangeEnd(v.round()),
          ),
          if (marks.isNotEmpty)
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                for (final mark in marks)
                  Text(
                    mark,
                    style: Theme.of(context).textTheme.labelSmall?.copyWith(
                          color: scheme.onSurfaceVariant,
                          fontFeatures: const [FontFeature.tabularFigures()],
                        ),
                  ),
              ],
            ),
        ],
      ),
    );
  }
}

/// 三选卡组（外观 / 提醒方式等 2-3 选一场景）。
class SettingsOptionCards<T> extends StatelessWidget {
  const SettingsOptionCards({
    super.key,
    required this.options,
    required this.groupValue,
    required this.onChanged,
  });

  final List<SettingsOption<T>> options;
  final T groupValue;
  final ValueChanged<T> onChanged;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (var i = 0; i < options.length; i++) ...[
            if (i > 0) const SizedBox(height: 8),
            _OptionCard(
              option: options[i],
              selected: options[i].value == groupValue,
              onTap: () => onChanged(options[i].value),
              accent: scheme.primary,
            ),
          ],
        ],
      ),
    );
  }
}

class SettingsOption<T> {
  const SettingsOption({
    required this.value,
    required this.icon,
    required this.label,
    this.desc,
  });

  final T value;
  final IconData icon;
  final String label;
  final String? desc;
}

class _OptionCard extends StatelessWidget {
  const _OptionCard({
    required this.option,
    required this.selected,
    required this.onTap,
    required this.accent,
  });

  final SettingsOption<dynamic> option;
  final bool selected;
  final VoidCallback onTap;
  final Color accent;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 120),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: selected ? accent : scheme.outlineVariant.withValues(alpha: 0.6),
            width: selected ? 1.4 : 1,
          ),
          color: selected ? accent.withValues(alpha: 0.06) : null,
        ),
        child: Row(
          children: [
            Icon(
              option.icon,
              size: 18,
              color: selected ? accent : scheme.onSurfaceVariant,
            ),
            const SizedBox(width: 10),
            Expanded(child: Text(option.label, style: Theme.of(context).textTheme.bodyMedium)),
            if (option.desc != null) ...[
              const SizedBox(width: 8),
              Text(
                option.desc!,
                style: Theme.of(context).textTheme.labelSmall?.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
              ),
            ],
            const SizedBox(width: 8),
            AnimatedContainer(
              duration: const Duration(milliseconds: 120),
              width: 18,
              height: 18,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: selected ? accent : Colors.transparent,
                border: Border.all(
                  color: selected ? accent : scheme.outlineVariant,
                ),
              ),
              child: selected
                  ? const Icon(Icons.check, size: 12, color: Colors.white)
                  : null,
            ),
          ],
        ),
      ),
    );
  }
}

/// 下拉选择行（PopupMenu 实现，样式对齐设计稿 select）。
class SettingsDropdownRow<T> extends StatelessWidget {
  const SettingsDropdownRow({
    super.key,
    required this.title,
    this.subtitle,
    required this.value,
    required this.items,
    required this.onChanged,
  });

  final String title;
  final String? subtitle;
  final T value;
  final List<SettingsDropdownItem<T>> items;
  final ValueChanged<T> onChanged;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final current = items.firstWhere(
      (i) => i.value == value,
      orElse: () => items.first,
    );
    return SettingsRow(
      title: title,
      subtitle: subtitle,
      trailing: PopupMenuButton<T>(
        initialValue: value,
        onSelected: onChanged,
        itemBuilder: (context) => [
          for (final item in items)
            PopupMenuItem(value: item.value, child: Text(item.label)),
        ],
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: scheme.outlineVariant.withValues(alpha: 0.6)),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(current.label, style: Theme.of(context).textTheme.bodyMedium),
              const SizedBox(width: 6),
              Icon(Icons.expand_more, size: 16, color: scheme.onSurfaceVariant),
            ],
          ),
        ),
      ),
    );
  }
}

class SettingsDropdownItem<T> {
  const SettingsDropdownItem({required this.value, required this.label});

  final T value;
  final String label;
}

/// 分段二选一（12/24 时制）。
class SettingsSegmentedRow extends StatelessWidget {
  const SettingsSegmentedRow({
    super.key,
    required this.title,
    this.subtitle,
    required this.segments,
    required this.selectedIndex,
    required this.onChanged,
  });

  final String title;
  final String? subtitle;
  final List<String> segments;
  final int selectedIndex;
  final ValueChanged<int> onChanged;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return SettingsRow(
      title: title,
      subtitle: subtitle,
      trailing: Container(
        padding: const EdgeInsets.all(3),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: scheme.outlineVariant.withValues(alpha: 0.6)),
          color: scheme.surfaceContainerHighest.withValues(alpha: 0.4),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (var i = 0; i < segments.length; i++)
              GestureDetector(
                onTap: () => onChanged(i),
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 120),
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(6),
                    color: i == selectedIndex ? scheme.primary : null,
                  ),
                  child: Text(
                    segments[i],
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: i == selectedIndex
                              ? scheme.onPrimary
                              : scheme.onSurfaceVariant,
                          fontWeight:
                              i == selectedIndex ? FontWeight.w600 : null,
                        ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// 危险区卡（红色，清除全部数据等不可逆操作）。
class SettingsDangerCard extends StatelessWidget {
  const SettingsDangerCard({
    super.key,
    required this.title,
    required this.message,
    required this.actionLabel,
    required this.onAction,
  });

  final String title;
  final String message;
  final String actionLabel;
  final VoidCallback onAction;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final error = scheme.error;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
      child: Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: error.withValues(alpha: 0.35)),
          color: error.withValues(alpha: 0.05),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.warning_amber_rounded, size: 16, color: error),
                const SizedBox(width: 8),
                Text(
                  title,
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                        color: error,
                        fontWeight: FontWeight.w600,
                      ),
                ),
              ],
            ),
            const SizedBox(height: 6),
            Text(
              message,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: error.withValues(alpha: 0.85),
                  ),
            ),
            const SizedBox(height: 12),
            FilledButton.icon(
              onPressed: onAction,
              icon: const Icon(Icons.delete_outline, size: 16),
              label: Text(actionLabel),
              style: FilledButton.styleFrom(
                backgroundColor: error,
                foregroundColor: scheme.onError,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 信息提示条（时间线未分配合并说明 / 匹配优先级说明等）。
class SettingsInfoBanner extends StatelessWidget {
  const SettingsInfoBanner({super.key, required this.child, this.compact = false});

  final Widget child;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      width: double.infinity,
      padding: EdgeInsets.all(compact ? 10 : 12),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(10),
        color: SettingsSky.base.withValues(alpha: 0.08),
        border: Border.all(color: SettingsSky.base.withValues(alpha: 0.25)),
      ),
      child: DefaultTextStyle(
        style: Theme.of(context).textTheme.bodySmall!.copyWith(
              color: scheme.onSurface,
              height: 1.4,
            ),
        child: child,
      ),
    );
  }
}

/// 操作按钮行（导出/导入等成对按钮）。
class SettingsActions extends StatelessWidget {
  const SettingsActions({super.key, required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
      child: Wrap(spacing: 8, runSpacing: 8, children: children),
    );
  }
}

/// 出境/隐私类披露条（amber 左边框样式，AI 二期沿用）。
class SettingsAmberNotice extends StatelessWidget {
  const SettingsAmberNotice({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        borderRadius: const BorderRadius.horizontal(right: Radius.circular(10)),
        border: Border(
          left: BorderSide(color: Colors.amber.shade600, width: 3),
          top: BorderSide(color: Colors.amber.withValues(alpha: 0.3)),
          right: BorderSide(color: Colors.amber.withValues(alpha: 0.3)),
          bottom: BorderSide(color: Colors.amber.withValues(alpha: 0.3)),
        ),
        color: Colors.amber.withValues(alpha: 0.07),
      ),
      child: DefaultTextStyle(
        style: Theme.of(context).textTheme.bodySmall!,
        child: child,
      ),
    );
  }
}

/// 辅助：分钟数 → 本地化"X 分钟"标签（滑杆值显示）。
String minutesLabel(AppLocalizations l10n, int minutes) {
  return l10n.settingsMinutesShort(minutes);
}
