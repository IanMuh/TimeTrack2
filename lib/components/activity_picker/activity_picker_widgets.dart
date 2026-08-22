import 'package:flutter/material.dart';

import '../../l10n/app_localizations.dart';
import '../../viewmodels/activity.dart';
import '../../viewmodels/activity_category.dart';
import '../controls.dart';
import '../feedback.dart';
import 'activity_picker.dart';
import 'activity_picker_forms.dart';
import 'activity_picker_tree.dart';

/// 选择器内部实现（桌面弹窗 / 移动抽屉两形态的宿主与子件）。
///
/// 无业务状态：数据来自 [ActivityPickerModel] 快照，动作经
/// [ActivityPickerEvents] 回调出去；成功/失败反馈按壳层 Snackbar 约定。

/// 伪节点 id：全部 / 未分类。
const allNode = '__all__';
const unassignedNode = '__unassigned__';

class ActivityPickerHost extends StatefulWidget {
  const ActivityPickerHost({
    super.key,
    required this.model,
    required this.events,
    required this.currentActivityId,
    required this.asSheet,
  });

  final ActivityPickerModel model;
  final ActivityPickerEvents events;
  final String? currentActivityId;
  final bool asSheet;

  @override
  State<ActivityPickerHost> createState() => _ActivityPickerHostState();
}

class _ActivityPickerHostState extends State<ActivityPickerHost> {
  final TextEditingController _search = TextEditingController();
  String _query = '';
  String? _selectedCategoryId; // null = 全部
  final Set<String> _expanded = {};
  List<String?> _breadcrumb = const [null];

  ActivityPickerModel get model => widget.model;
  AppLocalizations get l10n => AppLocalizations.of(context)!;

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  // ---------------------------------------------------------------------------
  // 过滤
  // ---------------------------------------------------------------------------

  bool _inCategorySet(Set<String> categoryIds, String categoryId) {
    final set = model.descendantsOf[categoryId] ?? const <String>{};
    return categoryIds.contains(categoryId) || categoryIds.any(set.contains);
  }

  List<Activity> _filteredActivities() {
    final all = model.activities;
    if (_query.isNotEmpty) {
      final q = _query.trim().toLowerCase();
      return all.where((a) => a.name.toLowerCase().contains(q)).toList();
    }
    final selected = _selectedCategoryId;
    if (selected == null || selected == allNode) return all;
    if (selected == unassignedNode) {
      return all
          .where((a) => model.primaryCategoryIdByActivity[a.id] == null)
          .toList();
    }
    return all.where((a) {
      final primary = model.primaryCategoryIdByActivity[a.id];
      final secondaries = model.categoryIdsByActivity[a.id] ?? const {};
      return _inCategorySet({?primary}, selected) ||
          _inCategorySet(secondaries, selected);
    }).toList();
  }

  List<({String id, String label, Color? dot})> _rootChips() {
    return [
      (id: allNode, label: l10n.timerAll, dot: null),
      (
        id: unassignedNode,
        label: l10n.unassignedActivity,
        dot: const Color(0xffa1a1aa),
      ),
      for (final c in model.childrenByParent[null] ?? const [])
        (id: c.id, label: c.name, dot: Color(c.color)),
    ];
  }

  // ---------------------------------------------------------------------------
  // 分类管理
  // ---------------------------------------------------------------------------

  Future<void> _showCategoryMenu(
    ActivityCategory node,
    Offset globalPosition,
  ) async {
    final action = await showMenu<String>(
      context: context,
      position: RelativeRect.fromLTRB(
        globalPosition.dx,
        globalPosition.dy,
        globalPosition.dx,
        globalPosition.dy,
      ),
      items: [
        PopupMenuItem(value: 'edit', child: Text(l10n.edit)),
        PopupMenuItem(value: 'delete', child: Text(l10n.delete)),
      ],
    );
    if (action == null || !mounted) return;
    if (action == 'edit') {
      final ok = await showEditCategoryForm(context, node, model, widget.events);
      if (ok == true && mounted) {
        showAppSnackBar(context, message: l10n.categoryUpdated);
      }
    } else {
      await _confirmDeleteCategory(node);
    }
  }

  Future<void> _confirmDeleteCategory(ActivityCategory node) async {
    final descendants = model.descendantsOf[node.id]?.length ?? 0;
    final affected = _affectedActivityCount(node);
    final ok = await showAppConfirmationDialog(
      context,
      title: l10n.deleteCategoryTitle,
      message: l10n.categoryDeleteHint
          .replaceAll('N', '$descendants')
          .replaceAll('M', '$affected'),
      confirmLabel: l10n.delete,
      isDestructive: true,
    );
    if (ok != true) return;
    final onDelete = widget.events.onDeleteCategory;
    if (onDelete == null) return;
    final success = await onDelete(node);
    if (!mounted) return;
    showAppSnackBar(
      context,
      message: success ? l10n.categoryDeleted : l10n.deleteFailed,
      isError: !success,
    );
  }

  int _affectedActivityCount(ActivityCategory node) {
    return model.activities.where((a) {
      final primary = model.primaryCategoryIdByActivity[a.id];
      final secondaries = model.categoryIdsByActivity[a.id] ?? const {};
      return _inCategorySet({?primary}, node.id) ||
          _inCategorySet(secondaries, node.id);
    }).length;
  }

  // ---------------------------------------------------------------------------
  // 动作
  // ---------------------------------------------------------------------------

  void _select(Activity activity) {
    Navigator.of(context).pop();
    widget.events.onSelectActivity(activity);
  }

  Future<void> _showNewActivity() async {
    final initialMain = _selectedCategoryId != null &&
            _selectedCategoryId != allNode &&
            _selectedCategoryId != unassignedNode
        ? _selectedCategoryId
        : null;
    final ok = await showNewActivityForm(
      context,
      model,
      widget.events,
      initialMainCategoryId: initialMain,
    );
    if (ok == true && mounted) {
      showAppSnackBar(context, message: l10n.activityCreated);
    }
  }

  Future<void> _showNewCategory() async {
    final initialParent = _selectedCategoryId != null &&
            _selectedCategoryId != allNode &&
            _selectedCategoryId != unassignedNode
        ? _selectedCategoryId
        : null;
    final ok = await showNewCategoryForm(
      context,
      model,
      widget.events,
      initialParentId: initialParent,
    );
    if (ok == true && mounted) {
      showAppSnackBar(context, message: l10n.categoryCreated);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      children: [
        SafeArea(
          top: widget.asSheet,
          bottom: false,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
            child: TextField(
              controller: _search,
              decoration: InputDecoration(
                hintText: l10n.searchActivities,
                prefixIcon: const Icon(Icons.search, size: 18),
                suffixIcon: _query.isEmpty
                    ? null
                    : IconButton(
                        icon: const Icon(Icons.close, size: 14),
                        onPressed: () {
                          _search.clear();
                          setState(() => _query = '');
                        },
                      ),
              ),
              onChanged: (v) => setState(() => _query = v),
            ),
          ),
        ),
        Expanded(
          child:
              widget.asSheet ? _buildSheetBody() : _buildDialogBody(theme),
        ),
        SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
            child: Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: widget.events.onCreateCategory == null
                        ? null
                        : _showNewCategory,
                    icon:
                        const Icon(Icons.create_new_folder_outlined, size: 16),
                    label: Text(l10n.newCategory),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: FilledButton.icon(
                    onPressed: widget.events.onCreateActivity == null
                        ? null
                        : _showNewActivity,
                    icon: const Icon(Icons.add, size: 16),
                    label: Text(l10n.newActivity),
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildDialogBody(ThemeData theme) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          width: 232,
          decoration: BoxDecoration(
            color: theme.colorScheme.surfaceContainer,
          ),
          child: ListView(
            padding: const EdgeInsets.symmetric(vertical: 4),
            children: [
              FakeNodeTile(
                label: l10n.timerAll,
                selected:
                    _selectedCategoryId == null || _selectedCategoryId == allNode,
                onTap: () => setState(() => _selectedCategoryId = allNode),
              ),
              FakeNodeTile(
                label: l10n.unassignedActivity,
                dot: const Color(0xffa1a1aa),
                selected: _selectedCategoryId == unassignedNode,
                onTap: () =>
                    setState(() => _selectedCategoryId = unassignedNode),
              ),
              const Divider(height: 8),
              ..._categoryNodes(0),
            ],
          ),
        ),
        Expanded(child: _buildActivityList()),
      ],
    );
  }

  List<Widget> _categoryNodes(int depth) {
    final out = <Widget>[];
    _visitNodes(depth, null, out);
    return out;
  }

  void _visitNodes(int depth, String? parentId, List<Widget> out) {
    for (final c in model.childrenByParent[parentId] ?? const []) {
      out.add(CategoryNodeTile(
        node: c,
        depth: depth,
        expanded: _expanded.contains(c.id),
        selected: _selectedCategoryId == c.id,
        ancestorPath: model.ancestorChain[c.id]?.join(' / '),
        onTap: () => setState(() => _selectedCategoryId = c.id),
        onToggle: () => setState(() {
          _expanded.contains(c.id) ? _expanded.remove(c.id) : _expanded.add(c.id);
        }),
        onMenu: _showCategoryMenu,
      ));
      if (_expanded.contains(c.id)) _visitNodes(depth + 1, c.id, out);
    }
  }

  Widget _buildSheetBody() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          height: 40,
          child: ListView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 16),
            children: [
              if (_breadcrumb.length > 1)
                Padding(
                  padding: const EdgeInsets.only(right: 6),
                  child: AppChip(
                    label: l10n.back,
                    onTap: () => setState(
                        () => _breadcrumb = _breadcrumb.sublist(0, _breadcrumb.length - 1)),
                  ),
                ),
              for (final chip in _sheetChips())
                Padding(
                  padding: const EdgeInsets.only(right: 6),
                  child: AppChip(
                    label: chip.label,
                    dotColor: chip.dot,
                    selected: _selectedCategoryId == chip.id,
                    onTap: () => setState(() {
                      _selectedCategoryId = chip.id;
                      if (chip.id != allNode && chip.id != unassignedNode) {
                        _breadcrumb = [..._breadcrumb, chip.id];
                      } else {
                        _breadcrumb = [null];
                      }
                    }),
                  ),
                ),
            ],
          ),
        ),
        Expanded(child: _buildActivityList()),
      ],
    );
  }

  List<({String id, String label, Color? dot})> _sheetChips() {
    final current = _breadcrumb.isNotEmpty ? _breadcrumb.last : null;
    if (current == null || current == allNode) return _rootChips();
    return (model.childrenByParent[current] ?? const [])
        .map((c) => (id: c.id, label: c.name, dot: Color(c.color)))
        .toList();
  }

  Widget _buildActivityList() {
    final theme = Theme.of(context);
    final activities = _filteredActivities();
    if (activities.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.space_dashboard_outlined,
                size: 36,
                color: theme.colorScheme.onSurfaceVariant,
              ),
              const SizedBox(height: 8),
              Text(
                l10n.categoryEmptyActivities,
                style: theme.textTheme.bodySmall,
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 12),
              OutlinedButton.icon(
                onPressed:
                    widget.events.onCreateActivity == null ? null : _showNewActivity,
                icon: const Icon(Icons.add, size: 16),
                label: Text(l10n.newActivity),
              ),
            ],
          ),
        ),
      );
    }
    return ListView.separated(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      itemCount: activities.length,
      separatorBuilder: (_, _) => const Divider(height: 1),
      itemBuilder: (context, index) {
        final activity = activities[index];
        return ActivityRow(
          activity: activity,
          current: widget.currentActivityId == activity.id,
          onTap: () => _select(activity),
          onEdit: widget.events.onEditActivity == null
              ? null
              : () => showEditActivityForm(context, activity, model, widget.events),
        );
      },
    );
  }
}
