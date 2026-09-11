import 'package:flutter/material.dart';

import '../../viewmodels/activity.dart';
import '../../viewmodels/activity_category.dart';
import 'activity_picker_widgets.dart';

/// 活动-分类合并选择器（契约 §5.1 核心交互，跨页复用：计时页切换、编辑
/// 对话框、后台规则目标选择共用）。
///
/// **组件无业务状态**（契约 §8）：模型与事件全部由调用方（页/壳）从 store
/// 装配注入，本组件只做展示与交互，不 import 任何 store。
///
/// 两形态（契约 §5.1 已定）：
/// - 桌面 = [showActivityCategoryPickerDialog]：居中弹窗，左分类树（展开/
///   缩进/多级/祖先链路径）+ 右活动集 + 顶部跨分类搜索 + 底部双新建入口；
/// - 移动 = [showActivityCategoryPickerSheet]：底部抽屉：搜索 → 分类筛选行
///   （含"全部"）→ 活动集合。
///
/// 数据语义（契约 §5.1）：选分类即过滤活动，选活动即完成选择；分类为层级树
/// （[ActivityCategory.parentId] 自引用，深 > 3 层以祖先链路径呈现）；
/// 每个活动有 1 主分类 + 多副分类（ActivityCategoryLink 模型）；活动可无分类。

/// 选择器展示模型（调用方 store 装配的纯数据快照；父类含根（parentId=null））。
class ActivityPickerModel {
  const ActivityPickerModel({
    required this.activities,
    required this.categories,
    required this.descendantsOf,
    required this.childrenByParent,
    required this.ancestorChain,
    required this.primaryCategoryIdByActivity,
    required this.categoryIdsByActivity,
  });

  /// 全部活动（含"未分配"单例；一次性活动带 [Activity.isOneOff] 由 UI 呈现
  /// "临时"徽标）。
  final List<Activity> activities;

  /// 全部分类（含各层；UI 按 [childrenByParent] 组装树）。
  final List<ActivityCategory> categories;

  /// 分类 id → 子孙分类 id 集合（递归含全部后代，不含自身）。
  final Map<String, Set<String>> descendantsOf;

  /// 父分类 id（根 = null）→ 直接子分类列表（保持 sortOrder 顺序）。
  final Map<String?, List<ActivityCategory>> childrenByParent;

  /// 分类 id → 祖先链路径（从根到**自身**的名字，如 `工作 / 项目A /
  /// 前端`）；单根分类仅含自身；供深 > 3 层的扁平路径呈现与筛选标签。
  final Map<String, List<String>> ancestorChain;

  /// 活动 id → 主分类 id（可能为 null=无分类，归入"未分类"）。
  final Map<String, String?> primaryCategoryIdByActivity;

  /// 活动 id → 副分类 id 集合（不含主分类时重复）。
  final Map<String, Set<String>> categoryIdsByActivity;
}

/// 新建活动草稿（选择器内嵌表单产出，事件回调交给调用方走指令/仓储）。
class ActivityDraft {
  const ActivityDraft({
    required this.name,
    required this.color,
    required this.oneOff,
    this.mainCategoryId,
    this.secondaryCategoryIds = const [],
  });

  final String name;
  final int color;

  /// 一次性活动（"临时"语义，自动清理）。
  final bool oneOff;

  final String? mainCategoryId;
  final List<String> secondaryCategoryIds;
}

/// 新建分类草稿（含父分类 id，null = 根分类）。
class CategoryDraft {
  const CategoryDraft({
    required this.name,
    required this.color,
    this.parentId,
  });

  final String name;
  final int color;
  final String? parentId;
}

/// 选择器事件（回调返回 bool=成功；成功与失败反馈由选择器用 Snackbar 提示，
/// 成功时表单自动关闭；**刷新约定**：选择器持有的是数据快照，draft 创建
/// 成功后选择器不自动刷新——调用方（页）在事件里创建真实数据后，若需立即
/// 渲染新数据，应关闭选择器再用新快照重开）。
class ActivityPickerEvents {
  const ActivityPickerEvents({
    required this.onSelectActivity,
    this.onCreateActivity,
    this.onCreateCategory,
    this.onEditActivity,
    this.onEditCategory,
    this.onDeleteCategory,
  });

  /// 选中活动即完成选择（计时页=切换指令；编辑对话框=回填字段）。
  final void Function(Activity activity) onSelectActivity;

  /// 现场新建活动；返回 true=成功。
  final Future<bool> Function(ActivityDraft draft)? onCreateActivity;

  /// 现场新建分类；返回 true=成功。
  final Future<bool> Function(CategoryDraft draft)? onCreateCategory;

  /// 编辑活动；返回 true=成功。
  final Future<bool> Function(Activity activity)? onEditActivity;

  /// 编辑分类；返回 true=成功。
  final Future<bool> Function(ActivityCategory category)? onEditCategory;

  /// 递归删除分类（UI 先确认——提示将递归软删子孙分类及活动关联、可单条
  /// 撤销；确认后触发，返回 true=成功）。
  final Future<bool> Function(ActivityCategory category)? onDeleteCategory;
}

/// 桌面形态：弹窗选择器。
Future<void> showActivityCategoryPickerDialog(
  BuildContext context, {
  required ActivityPickerModel model,
  required ActivityPickerEvents events,
  String? currentActivityId,
}) {
  return showActivityCategoryPicker(
    context,
    model: model,
    events: events,
    currentActivityId: currentActivityId,
    asSheet: false,
  );
}

/// 移动形态：底部抽屉选择器（搜索 → 分类筛选行（含"全部"）→ 活动集）。
Future<void> showActivityCategoryPickerSheet(
  BuildContext context, {
  required ActivityPickerModel model,
  required ActivityPickerEvents events,
  String? currentActivityId,
}) {
  return showActivityCategoryPicker(
    context,
    model: model,
    events: events,
    currentActivityId: currentActivityId,
    asSheet: true,
  );
}

/// 选择器主体（形态二合一；[asSheet] true = 移动底部抽屉，false = 桌面弹窗）。
Future<void> showActivityCategoryPicker(
  BuildContext context, {
  required ActivityPickerModel model,
  required ActivityPickerEvents events,
  String? currentActivityId,
  bool asSheet = false,
}) {
  final host = Builder(
    builder: (pickerContext) => ActivityPickerHost(
      model: model,
      events: events,
      currentActivityId: currentActivityId,
      asSheet: asSheet,
    ),
  );
  if (asSheet) {
    return showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      backgroundColor: Theme.of(context).colorScheme.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (_) => SizedBox(
        height: MediaQuery.of(context).size.height * 0.86,
        child: host,
      ),
    );
  }
  return showDialog<void>(
    context: context,
    barrierColor: const Color(0x66000000),
    builder: (_) => Dialog(
      insetPadding: const EdgeInsets.all(24),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      clipBehavior: Clip.antiAlias,
      child: host,
    ),
  );
}
