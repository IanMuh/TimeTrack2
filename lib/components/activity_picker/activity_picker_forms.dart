import 'package:flutter/material.dart';

import '../../l10n/app_localizations.dart';
import '../../viewmodels/activity.dart';
import '../../viewmodels/activity_category.dart';
import '../../constants/theme_tokens.dart' show ActivityPalette;
import '../controls.dart';
import 'activity_picker.dart';

/// 内嵌表单：新建活动 / 编辑活动 / 新建分类 / 编辑分类。
///
/// 全部经 events 回调出去（`Future<bool>` 语义），成功返回 true（表单自动
/// 关闭，由调用方弹成功 Snackbar），失败显示行内错误并保持表单打开。

/// 8 色选色圈行（选中主色环 + 勾选）。
class ColorPickRow extends StatelessWidget {
  const ColorPickRow({
    super.key,
    required this.selected,
    required this.onSelected,
  });

  final int selected;
  final ValueChanged<int> onSelected;

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: 10,
      runSpacing: 8,
      children: [
        for (final c in ActivityPalette.all)
          GestureDetector(
            onTap: () => onSelected(ActivityPalette.of(c, dark: false)),
            child: Container(
              width: 26,
              height: 26,
              decoration: BoxDecoration(
                color: Color(ActivityPalette.of(c, dark: false)),
                shape: BoxShape.circle,
                border: selected == ActivityPalette.of(c, dark: false)
                    ? Border.all(
                        color: Theme.of(context).colorScheme.onSurface,
                        width: 2,
                      )
                    : null,
              ),
              child: selected == ActivityPalette.of(c, dark: false)
                  ? const Icon(Icons.check_rounded, size: 16, color: Colors.white)
                  : null,
            ),
          ),
      ],
    );
  }
}

/// 分类扁平路径标签（下拉项文本）。
String _categoryPathLabel(ActivityPickerModel model, String? categoryId) {
  if (categoryId == null) return '';
  final chain = model.ancestorChain[categoryId] ?? const [];
  return chain.join(' / ');
}

/// 下拉：根分类（null）+ 全部分类（路径标签）。
class _CategoryDropdown extends StatelessWidget {
  const _CategoryDropdown({
    required this.model,
    required this.value,
    required this.onChanged,
    required this.label,
    this.excludeIds = const {},
  });

  final ActivityPickerModel model;
  final String? value;
  final ValueChanged<String?> onChanged;
  final String label;
  final Set<String> excludeIds;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final items = [
      DropdownMenuItem<String?>(
        value: null,
        child: Text('— ${l10n.rootCategory} —', style: const TextStyle(fontSize: 13)),
      ),
      for (final c in model.categories)
        if (!excludeIds.contains(c.id))
          DropdownMenuItem<String?>(
            value: c.id,
            child: Text(
              _categoryPathLabel(model, c.id),
              style: const TextStyle(fontSize: 13),
              overflow: TextOverflow.ellipsis,
            ),
          ),
    ];
    return DropdownButtonFormField<String?>(
      initialValue: value,
      isExpanded: true,
      decoration: InputDecoration(labelText: label),
      items: items,
      onChanged: onChanged,
    );
  }
}

/// 新建活动表单（返回 true=成功；false/null=失败/取消）。
Future<bool?> showNewActivityForm(
  BuildContext context,
  ActivityPickerModel model,
  ActivityPickerEvents events, {
  String? initialMainCategoryId,
}) {
  return _showActivityForm(
    context,
    model,
    events,
    activity: null,
    initialMainCategoryId: initialMainCategoryId,
  );
}

/// 编辑活动表单（回填当前活动值；提交走 [ActivityPickerEvents.onEditActivity]）。
Future<bool?> showEditActivityForm(
  BuildContext context,
  Activity activity,
  ActivityPickerModel model,
  ActivityPickerEvents events,
) {
  return _showActivityForm(context, model, events, activity: activity);
}

Future<bool?> _showActivityForm(
  BuildContext context,
  ActivityPickerModel model,
  ActivityPickerEvents events, {
  Activity? activity,
  String? initialMainCategoryId,
  bool? initialOneOff,
}) {
  return showDialog<bool>(
    context: context,
    builder: (dialogContext) {
      return _ActivityFormDialog(
        model: model,
        events: events,
        activity: activity,
        initialMainCategoryId: initialMainCategoryId,
        initialOneOff: initialOneOff,
      );
    },
  );
}

class _ActivityFormDialog extends StatefulWidget {
  const _ActivityFormDialog({
    required this.model,
    required this.events,
    required this.activity,
    this.initialMainCategoryId,
    this.initialOneOff,
  });

  final ActivityPickerModel model;
  final ActivityPickerEvents events;
  final Activity? activity;
  final String? initialMainCategoryId;
  final bool? initialOneOff;

  @override
  State<_ActivityFormDialog> createState() => _ActivityFormDialogState();
}

class _ActivityFormDialogState extends State<_ActivityFormDialog> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _name = TextEditingController(
    text: widget.activity?.name ?? '',
  );
  late int _color = widget.activity?.color ?? ActivityPalette.of(ActivityPalette.all.first, dark: false);
  late bool _oneOff = widget.initialOneOff ?? widget.activity?.isOneOff ?? false;
  late String? _mainCategoryId = widget.initialMainCategoryId ??
      widget.model.primaryCategoryIdByActivity[widget.activity?.id];
  late final Set<String> _secondary = {
    ...?widget.model.categoryIdsByActivity[widget.activity?.id],
  };
  String? _error;

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (!(_formKey.currentState?.validate() ?? false)) return;
    final events = widget.events;
    final activity = widget.activity;
    final bool ok;
    if (activity == null) {
      final onCreate = events.onCreateActivity;
      if (onCreate == null) return;
      ok = await onCreate(ActivityDraft(
        name: _name.text,
        color: _color,
        oneOff: _oneOff,
        mainCategoryId: _mainCategoryId,
        secondaryCategoryIds: _secondary.toList(),
      ));
    } else {
      final onEdit = events.onEditActivity;
      if (onEdit == null) return;
      final updated = activity.copyWith(
        name: _name.text,
        color: _color,
        isOneOff: _oneOff,
      );
      ok = await onEdit(updated);
    }
    if (!mounted) return;
    if (ok) {
      Navigator.of(context).pop(true);
    } else {
      setState(() => _error = AppLocalizations.of(context)!.createFailed);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final theme = Theme.of(context);
    return AlertDialog(
      title: Text(widget.activity == null ? l10n.newActivity : l10n.edit),
      content: SizedBox(
        width: 360,
        child: SingleChildScrollView(
          child: Form(
            key: _formKey,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                TextFormField(
                  controller: _name,
                  autofocus: true,
                  decoration: InputDecoration(labelText: l10n.name),
                  validator: (v) =>
                      (v == null || v.trim().isEmpty) ? l10n.activityNameRequired : null,
                ),
                const SizedBox(height: 14),
                Text(l10n.color, style: theme.textTheme.labelMedium),
                const SizedBox(height: 8),
                ColorPickRow(selected: _color, onSelected: (v) => setState(() => _color = v)),
                const SizedBox(height: 14),
                // 持续 / 临时二选一
                Row(
                  children: [
                    AppChip(
                      label: l10n.ongoing,
                      selected: !_oneOff,
                      onTap: () => setState(() => _oneOff = false),
                    ),
                    const SizedBox(width: 8),
                    AppChip(
                      label: l10n.oneOff,
                      selected: _oneOff,
                      onTap: () => setState(() => _oneOff = true),
                    ),
                  ],
                ),
                const SizedBox(height: 14),
                _CategoryDropdown(
                  model: widget.model,
                  value: _mainCategoryId,
                  label: l10n.primaryCategory,
                  onChanged: (v) => setState(() => _mainCategoryId = v),
                ),
                const SizedBox(height: 14),
                Text('${l10n.secondaryCategories}（${_secondary.length}）',
                    style: theme.textTheme.labelMedium),
                const SizedBox(height: 6),
                Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: [
                    for (final c in widget.model.categories)
                      if (c.id != _mainCategoryId)
                        AppChip(
                          label: c.name,
                          selected: _secondary.contains(c.id),
                          onTap: () => setState(() {
                            _secondary.contains(c.id)
                                ? _secondary.remove(c.id)
                                : _secondary.add(c.id);
                          }),
                        ),
                  ],
                ),
                if (_error != null) ...[
                  const SizedBox(height: 10),
                  Text(_error!,
                      style: TextStyle(color: theme.colorScheme.error, fontSize: 12)),
                ],
              ],
            ),
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: Text(l10n.cancel),
        ),
        FilledButton(onPressed: _submit, child: Text(widget.activity == null ? l10n.create : l10n.save)),
      ],
    );
  }
}

/// 新建分类表单（父分类 null = 根）。
Future<bool?> showNewCategoryForm(
  BuildContext context,
  ActivityPickerModel model,
  ActivityPickerEvents events, {
  String? initialParentId,
}) {
  return _showCategoryForm(
    context,
    model,
    events,
    category: null,
    initialParentId: initialParentId,
  );
}

/// 编辑分类表单（父分类下拉排除自身与子孙——防成环）。
Future<bool?> showEditCategoryForm(
  BuildContext context,
  ActivityCategory category,
  ActivityPickerModel model,
  ActivityPickerEvents events,
) {
  return _showCategoryForm(context, model, events, category: category);
}

Future<bool?> _showCategoryForm(
  BuildContext context,
  ActivityPickerModel model,
  ActivityPickerEvents events, {
  ActivityCategory? category,
  String? initialParentId,
}) {
  return showDialog<bool>(
    context: context,
    builder: (_) => _CategoryFormDialog(
      model: model,
      events: events,
      category: category,
      initialParentId: initialParentId,
    ),
  );
}

class _CategoryFormDialog extends StatefulWidget {
  const _CategoryFormDialog({
    required this.model,
    required this.events,
    required this.category,
    this.initialParentId,
  });

  final ActivityPickerModel model;
  final ActivityPickerEvents events;
  final ActivityCategory? category;
  final String? initialParentId;

  @override
  State<_CategoryFormDialog> createState() => _CategoryFormDialogState();
}

class _CategoryFormDialogState extends State<_CategoryFormDialog> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _name =
      TextEditingController(text: widget.category?.name ?? '');
  late int _color = widget.category?.color ??
      ActivityPalette.of(ActivityPalette.all.first, dark: false);
  late String? _parentId =
      widget.initialParentId ?? widget.category?.parentId;
  String? _error;

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (!(_formKey.currentState?.validate() ?? false)) return;
    final category = widget.category;
    final bool ok;
    if (category == null) {
      final onCreate = widget.events.onCreateCategory;
      if (onCreate == null) return;
      ok = await onCreate(CategoryDraft(
        name: _name.text,
        color: _color,
        parentId: _parentId,
      ));
    } else {
      final onEdit = widget.events.onEditCategory;
      if (onEdit == null) return;
      final updated = ActivityCategory(
        id: category.id,
        userId: category.userId,
        name: _name.text,
        color: _color,
        updatedAt: category.updatedAt,
        deletedAt: category.deletedAt,
        parentId: _parentId,
      );
      ok = await onEdit(updated);
    }
    if (!mounted) return;
    if (ok) {
      Navigator.of(context).pop(true);
    } else {
      setState(() => _error = AppLocalizations.of(context)!.createFailed);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final theme = Theme.of(context);
    // 编辑时父分类可选集合排除自身与子孙（防成环，契约无环不变量）。
    final descendants = widget.category == null
        ? const <String>{}
        : (widget.model.descendantsOf[widget.category!.id] ??
            <String>{widget.category!.id});
    return AlertDialog(
      title: Text(widget.category == null ? l10n.newCategory : l10n.edit),
      content: SizedBox(
        width: 320,
        child: SingleChildScrollView(
          child: Form(
            key: _formKey,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                TextFormField(
                  controller: _name,
                  autofocus: true,
                  decoration: InputDecoration(labelText: l10n.name),
                  validator: (v) => (v == null || v.trim().isEmpty)
                      ? l10n.activityNameRequired
                      : null,
                ),
                const SizedBox(height: 14),
                Text(l10n.color, style: theme.textTheme.labelMedium),
                const SizedBox(height: 8),
                ColorPickRow(selected: _color, onSelected: (v) => setState(() => _color = v)),
                const SizedBox(height: 14),
                _CategoryDropdown(
                  model: widget.model,
                  value: _parentId,
                  label: l10n.parentCategory,
                  excludeIds: descendants,
                  onChanged: (v) => setState(() => _parentId = v),
                ),
                if (_error != null) ...[
                  const SizedBox(height: 10),
                  Text(_error!,
                      style: TextStyle(color: theme.colorScheme.error, fontSize: 12)),
                ],
              ],
            ),
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: Text(l10n.cancel),
        ),
        FilledButton(
          onPressed: _submit,
          child: Text(widget.category == null ? l10n.create : l10n.save),
        ),
      ],
    );
  }
}
