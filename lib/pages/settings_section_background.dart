/// 设置分区实现 ③：后台记录（平台卡 + 总开关 + 规则列表/表单，契约 §6.2）。
///
/// 规则 CRUD 经指令通道（tracking_rule_create/update/delete）——铁律 7；
/// 总开关写 ProfileSettings（SettingsStore）；平台卡按平台分派：
/// - Android（批次 6b）：「使用情况访问」授权状态卡 + 跳系统设置 +
///   未授权禁总开关 + 进分区全屏引导（§6.3，本会话不重复纠缠）；
/// - Windows/其他：常驻说明 + 检测器状态（批次 6a 前为 Noop → "待接入"）。
library;

import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/material.dart';

import '../api/platform/windows_foreground_detector.dart'
    show WindowsForegroundDetector;
import '../components/activity_picker/activity_picker.dart';
import '../l10n/app_localizations.dart';
import '../stores/app_store.dart';
import '../stores/tracking_store.dart' show NoopForegroundDetector;
import '../utils/result.dart';
import '../viewmodels/activity.dart';
import '../viewmodels/commands/command_invocation.dart';
import '../viewmodels/profile_settings.dart';
import '../viewmodels/tracking_rule.dart';
import 'settings_widgets.dart';
import 'tracking_guide_page.dart';

/// 后台记录分区。
class BackgroundSection extends StatefulWidget {
  const BackgroundSection({super.key, required this.app});

  final AppStore app;

  @override
  State<BackgroundSection> createState() => _BackgroundSectionState();
}

class _BackgroundSectionState extends State<BackgroundSection> {
  List<Activity> _activities = const [];

  /// 「使用情况访问」授权状态（null = 未查询/非 Android）。
  bool? _usageGranted;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final result = await widget.app.activities.activities(includeDeleted: false);
    await widget.app.tracking.reloadRules();
    if (!mounted) return;
    if (result.isSuccess) {
      setState(() => _activities = result.requireValue());
    }
    await _refreshUsageGranted();
    unawaited(_maybeShowGuide());
  }

  /// 查询「使用情况访问」授权态（非 Android 短路为 null）。
  Future<void> _refreshUsageGranted() async {
    if (!Platform.isAndroid) return;
    final granted = await widget.app.androidTracking.isUsageGranted();
    if (!mounted) return;
    setState(() => _usageGranted = granted);
  }

  /// §6.3 引导触发：进分区时未授权且本会话未纠缠过 → 全屏引导。
  Future<void> _maybeShowGuide() async {
    if (!mounted || !Platform.isAndroid) return;
    if (widget.app.androidTracking.guideDismissedThisSession) return;
    if (_usageGranted == true) {
      // 已授权：标记会话内不再引导。
      widget.app.androidTracking.guideDismissedThisSession = true;
      return;
    }
    await Navigator.of(context, rootNavigator: true).push(
      MaterialPageRoute<void>(
        fullscreenDialog: true,
        builder: (_) => TrackingGuidePage(bridge: widget.app.androidTracking),
      ),
    );
    // 从系统设置返回后复查授权态。
    widget.app.androidTracking.guideDismissedThisSession = true;
    await _refreshUsageGranted();
  }

  Future<void> _openUsageSettings() async {
    await widget.app.androidTracking.openUsageAccessSettings();
    await _refreshUsageGranted();
  }

  Activity? _activityOf(String id) {
    for (final a in _activities) {
      if (a.id == id) return a;
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final app = widget.app;
    return ListenableBuilder(
      listenable: Listenable.merge([app.tracking, app.settings, app.timer]),
      builder: (context, _) {
        final settings = app.settings.current;
        final rules = app.tracking.ruleList;
        // §6.2：Android 未授权时总开关禁用（引导用户先去系统设置授权）。
        final androidNeedsPermission =
            Platform.isAndroid && _usageGranted == false;
        return SettingsSectionCard(
          key: const ValueKey('sec-background'),
          icon: Icons.insights_outlined,
          title: l10n.settingsSecBackground,
          subtitle: l10n.settingsSecBackgroundSub,
          paddedChildren: true,
          children: [
            _PlatformCard(
              app: app,
              usageGranted: Platform.isAndroid ? (_usageGranted ?? false) : null,
              onOpenUsageSettings:
                  Platform.isAndroid ? _openUsageSettings : null,
            ),
            // 手动会话保持可见化（批次 6b 用户反馈）：手动点过活动卡后自动
            // 切换挂起——给出状态与一键恢复，防"功能坏了"的误判。
            if (app.timer.manualSessionHold) ...[
              const SizedBox(height: 14),
              SettingsInfoBanner(
                child: Row(
                  children: [
                    Icon(Icons.pause_circle_outline,
                        size: 16, color: SettingsSky.dark),
                    const SizedBox(width: 8),
                    Expanded(child: Text(l10n.bgManualHoldBanner)),
                    TextButton(
                      // 经指令通道（铁律 7）：manual_hold_clear 指令化落点。
                      onPressed: () => widget.app.dispatcher
                          .dispatch(CommandInvocation(name: 'manual_hold_clear')),
                      child: Text(l10n.bgManualHoldResume),
                    ),
                  ],
                ),
              ),
            ],
            const SizedBox(height: 14),
            // 总开关。
            Container(
              padding: const EdgeInsets.only(top: 14),
              decoration: BoxDecoration(
                border: Border(
                  top: BorderSide(
                    color: Theme.of(context)
                        .colorScheme
                        .outlineVariant
                        .withValues(alpha: 0.4),
                  ),
                ),
              ),
              child: SettingsSwitchRow(
                title: l10n.settingsBgMasterSwitch,
                subtitle: androidNeedsPermission
                    ? l10n.usageAccessGuide
                    : l10n.settingsBgMasterHint,
                value: androidNeedsPermission
                    ? false
                    : settings?.backgroundTrackingEnabled ?? false,
                onChanged: androidNeedsPermission ? null : (v) => _saveMaster(v),
              ),
            ),
            const SizedBox(height: 14),
            Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(l10n.settingsBgRules,
                          style: Theme.of(context).textTheme.bodyMedium),
                      const SizedBox(height: 2),
                      Text(
                        l10n.settingsBgRulesCount(rules.length),
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                              color: Theme.of(context).colorScheme.onSurfaceVariant,
                            ),
                      ),
                    ],
                  ),
                ),
                FilledButton.icon(
                  onPressed: () => _openForm(context, null),
                  icon: const Icon(Icons.add, size: 16),
                  label: Text(l10n.settingsBgNewRule),
                ),
              ],
            ),
            const SizedBox(height: 10),
            if (rules.isEmpty)
              SettingsInfoBanner(child: Text(l10n.settingsBgEmptyRules))
            else
              Container(
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(
                    color: Theme.of(context)
                        .colorScheme
                        .outlineVariant
                        .withValues(alpha: 0.6),
                  ),
                ),
                clipBehavior: Clip.antiAlias,
                child: Column(
                  children: [
                    for (var i = 0; i < rules.length; i++) ...[
                      if (i > 0)
                        Divider(
                          height: 1,
                          color: Theme.of(context)
                              .colorScheme
                              .outlineVariant
                              .withValues(alpha: 0.25),
                        ),
                      _RuleRow(
                        rule: rules[i],
                        activity: _activityOf(rules[i].activityId),
                        onEdit: () => _openForm(context, rules[i]),
                        onDelete: () => _deleteRule(rules[i]),
                        onToggleSync: (v) => _updateRule(
                          rules[i],
                          options: {'sync': v ? 'true' : 'false'},
                        ),
                        onToggleEnabled: (v) => _updateRule(
                          rules[i],
                          options: {'enabled': v ? 'true' : 'false'},
                        ),
                      ),
                    ],
                  ],
                ),
              ),
          ],
        );
      },
    );
  }

  Future<void> _saveMaster(bool value) async {
    final store = widget.app.settings;
    final current = store.current;
    if (current == null) return;
    // Android 开启时先补通知权限请求（API 33+；前台服务常驻通知可见性）。
    // 引导页跳系统设置期间弹窗无法展示，故在用户主动开启的时机补问。
    if (value && Platform.isAndroid &&
        !widget.app.androidTracking.notificationPermissionAsked) {
      await widget.app.androidTracking.requestNotificationPermission();
      if (!mounted) return;
    }
    final result = await store.save(current.copyWith(backgroundTrackingEnabled: value));
    // 保存失败必须可见（与通用分区 _save 的失败反馈一致——开关渲染由
    // store 通知回滚，无反馈会呈现"点了没反应"）。
    if (!mounted) return;
    if (result case AppFailure<ProfileSettings> failure) {
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(content: Text(failure.message)));
    }
  }

  Future<void> _updateRule(TrackingRule rule, {Map<String, String> options = const {}}) async {
    await widget.app.dispatcher
        .dispatch(CommandInvocation(name: 'tracking_rule_update', args: [rule.id], options: options));
    if (mounted) setState(() {});
  }

  Future<void> _deleteRule(TrackingRule rule) async {
    final l10n = AppLocalizations.of(context)!;
    await widget.app.dispatcher.dispatch(
        CommandInvocation(name: 'tracking_rule_delete', args: [rule.id]));
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(l10n.settingsBgRuleDeleted)));
  }

  Future<void> _openForm(BuildContext context, TrackingRule? existing) async {
    final saved = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => RuleFormDialog(
        app: widget.app,
        activities: _activities,
        existing: existing,
      ),
    );
    if (saved == true && mounted) {
      await widget.app.tracking.reloadRules();
      if (!mounted) return;
      final l10n = AppLocalizations.of(this.context)!;
      ScaffoldMessenger.of(this.context)
        ..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(content: Text(l10n.settingsBgRuleSaved)));
    }
  }
}

/// 平台卡：Android = 「使用情况访问」授权状态卡（§6.2）；Windows/其他 =
/// 常驻说明 + 检测器状态。
class _PlatformCard extends StatelessWidget {
  const _PlatformCard({
    required this.app,
    this.usageGranted,
    this.onOpenUsageSettings,
  });

  final AppStore app;

  /// Android：授权态（null = 非 Android）。
  final bool? usageGranted;
  final VoidCallback? onOpenUsageSettings;

  @override
  Widget build(BuildContext context) {
    if (usageGranted != null) {
      return _androidCard(context);
    }
    return _windowsCard(context);
  }

  Widget _androidCard(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final scheme = Theme.of(context).colorScheme;
    final granted = usageGranted == true;
    return SettingsInfoBanner(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                granted
                    ? Icons.verified_user_outlined
                    : Icons.privacy_tip_outlined,
                size: 16,
                color: granted ? scheme.primary : scheme.error,
              ),
              const SizedBox(width: 8),
              Text(
                l10n.usageAccess,
                style: Theme.of(context)
                    .textTheme
                    .bodySmall
                    ?.copyWith(fontWeight: FontWeight.w600),
              ),
              const Spacer(),
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(999),
                  color: granted
                      ? scheme.primary.withValues(alpha: 0.1)
                      : scheme.error.withValues(alpha: 0.08),
                ),
                child: Text(
                  granted ? l10n.usageAccessGranted : l10n.usageAccessNotGranted,
                  style: TextStyle(
                    fontSize: 11,
                    color: granted ? scheme.primary : scheme.error,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Text(l10n.settingsBgDetectorState(granted
              ? l10n.settingsBgDetectorRunning
              : l10n.usageAccessNotGranted)),
          if (!granted) ...[
            const SizedBox(height: 8),
            FilledButton.tonalIcon(
              key: const ValueKey('open-usage-settings'),
              onPressed: onOpenUsageSettings,
              icon: const Icon(Icons.settings_outlined, size: 16),
              label: Text(l10n.usageAccessButton),
            ),
          ],
        ],
      ),
    );
  }

  Widget _windowsCard(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final scheme = Theme.of(context).colorScheme;
    final detectorReady = app.tracking.detector is! NoopForegroundDetector;
    final lastNote = app.tracking.lastMatchNote;
    return SettingsInfoBanner(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.monitor_heart_outlined,
                  size: 16, color: SettingsSky.dark),
              const SizedBox(width: 8),
              Text(
                l10n.settingsBgWindowsTitle,
                style: Theme.of(context)
                    .textTheme
                    .bodySmall
                    ?.copyWith(fontWeight: FontWeight.w600),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Text(l10n.settingsBgWindowsBody),
          const SizedBox(height: 6),
          Text(
            l10n.settingsBgDetectorState(detectorReady
                ? l10n.settingsBgDetectorRunning
                : l10n.settingsBgDetectorPending),
          ),
          if (lastNote != null) ...[
            const SizedBox(height: 2),
            Text(
              l10n.settingsBgLastMatch(lastNote),
              style: TextStyle(color: scheme.onSurfaceVariant),
            ),
          ],
        ],
      ),
    );
  }
}

/// 单条规则行。
class _RuleRow extends StatelessWidget {
  const _RuleRow({
    required this.rule,
    required this.activity,
    required this.onEdit,
    required this.onDelete,
    required this.onToggleSync,
    required this.onToggleEnabled,
  });

  final TrackingRule rule;
  final Activity? activity;
  final VoidCallback onEdit;
  final VoidCallback onDelete;
  final ValueChanged<bool> onToggleSync;
  final ValueChanged<bool> onToggleEnabled;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final scheme = Theme.of(context).colorScheme;
    final kindLabel =
        rule.matchKind == TrackingRuleMatchKind.title
            ? l10n.settingsBgKindTitle
            : l10n.settingsBgKindProcess;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      child: Wrap(
        spacing: 8,
        runSpacing: 6,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(6),
              color: scheme.surfaceContainerHighest.withValues(alpha: 0.5),
            ),
            child: Text(
              rule.pattern,
              style: Theme.of(context).textTheme.labelMedium?.copyWith(
                    fontFamily: 'monospace',
                    fontFeatures: const [FontFeature.tabularFigures()],
                  ),
            ),
          ),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(999),
              color: SettingsSky.base.withValues(alpha: 0.1),
            ),
            child: Text(
              kindLabel,
              style: Theme.of(context).textTheme.labelSmall?.copyWith(
                    color: SettingsSky.dark,
                  ),
            ),
          ),
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 8,
                height: 8,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: Color(activity?.color ?? 0xFF6366F1),
                ),
              ),
              const SizedBox(width: 6),
              Text(
                activity?.name ?? '—',
                style: Theme.of(context).textTheme.bodyMedium,
              ),
            ],
          ),
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              _MiniToggle(
                label: l10n.settingsBgSyncToggle,
                value: rule.syncEnabled,
                onChanged: onToggleSync,
              ),
              const SizedBox(width: 8),
              _MiniToggle(
                label: l10n.settingsBgEnabledToggle,
                value: rule.enabled,
                onChanged: onToggleEnabled,
              ),
              IconButton(
                tooltip: l10n.settingsBgEdit,
                icon: const Icon(Icons.edit_outlined, size: 14),
                onPressed: onEdit,
                visualDensity: VisualDensity.compact,
              ),
              IconButton(
                tooltip: l10n.settingsBgDelete,
                icon: Icon(Icons.delete_outline,
                    size: 14, color: scheme.error),
                onPressed: onDelete,
                visualDensity: VisualDensity.compact,
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _MiniToggle extends StatelessWidget {
  const _MiniToggle({
    required this.label,
    required this.value,
    required this.onChanged,
  });

  final String label;
  final bool value;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return InkWell(
      onTap: () => onChanged(!value),
      borderRadius: BorderRadius.circular(999),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(999),
          color: value
              ? scheme.primary.withValues(alpha: 0.1)
              : scheme.surfaceContainerHighest.withValues(alpha: 0.4),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              value ? Icons.cloud_done_outlined : Icons.cloud_off_outlined,
              size: 12,
              color: value ? scheme.primary : scheme.onSurfaceVariant,
            ),
            const SizedBox(width: 4),
            Text(
              label,
              style: Theme.of(context).textTheme.labelSmall?.copyWith(
                    color: value ? scheme.primary : scheme.onSurfaceVariant,
                  ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 规则表单对话框（新建/编辑共用）。
class RuleFormDialog extends StatefulWidget {
  const RuleFormDialog({
    super.key,
    required this.app,
    required this.activities,
    this.existing,
  });

  final AppStore app;
  final List<Activity> activities;
  final TrackingRule? existing;

  @override
  State<RuleFormDialog> createState() => _RuleFormDialogState();
}

class _RuleFormDialogState extends State<RuleFormDialog> {
  late final TextEditingController _pattern;
  late TrackingRuleMatchKind _kind;
  late String? _activityId;
  late bool _sync;

  @override
  void initState() {
    super.initState();
    final rule = widget.existing;
    _pattern = TextEditingController(text: rule?.pattern ?? '');
    _kind = rule?.matchKind ?? TrackingRuleMatchKind.process;
    _activityId = rule?.activityId;
    _sync = rule?.syncEnabled ?? true;
  }

  @override
  void dispose() {
    _pattern.dispose();
    super.dispose();
  }

  /// 捕获当前前台（批次 6b）：进程名/包名或窗口标题填入模式框，并联动
  /// 匹配类型。检测器不可用/无前台时提示。
  void _captureForeground({required bool isTitle}) {
    final detector = widget.app.foregroundDetector;
    String value;
    if (detector is WindowsForegroundDetector) {
      // 捕获瞬间本应用必然在前台——读"最近非本应用"快照（跟踪轮询
      // 持续刷新），实时查询只会得到 TimeTrack2 自身。
      final snap = detector.captureExternal();
      value = (isTitle ? snap.windowTitle : snap.processName) ?? '';
    } else {
      // Android 检测器已在 native 查询侧过滤本应用包名。
      value = (isTitle ? detector.windowTitle : detector.processName) ?? '';
    }
    final l10n = AppLocalizations.of(context)!;
    if (value.isEmpty) {
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(content: Text(l10n.settingsBgCaptureFailed)));
      return;
    }
    setState(() {
      _pattern.text = value;
      _kind = isTitle ? TrackingRuleMatchKind.title : TrackingRuleMatchKind.process;
    });
  }

  Future<void> _pickActivity() async {    final app = widget.app;
    final category = app.category;
    final primary = <String, String?>{};
    final all = <String, Set<String>>{};
    for (final link in category.links) {
      all.putIfAbsent(link.activityId, () => {}).add(link.categoryId);
      if (link.isPrimary) primary[link.activityId] = link.categoryId;
    }
    for (final a in widget.activities) {
      primary.putIfAbsent(a.id, () => null);
      all.putIfAbsent(a.id, () => {});
    }
    final model = ActivityPickerModel(
      activities: widget.activities,
      categories: category.all,
      descendantsOf: category.descendantsOf,
      childrenByParent: category.childrenByParent,
      ancestorChain: category.ancestorChains,
      primaryCategoryIdByActivity: primary,
      categoryIdsByActivity: all,
    );
    final events = ActivityPickerEvents(
      onSelectActivity: (activity) =>
          setState(() => _activityId = activity.id),
    );
    // 契约 §5.1：移动（<600）= 底部抽屉形态——桌面双栏弹窗左栏固定 232px，
    // 紧凑视口下活动列表只剩几十像素（与计时页同款分支）。
    if (MediaQuery.sizeOf(context).width >= 600) {
      await showActivityCategoryPickerDialog(
        context,
        model: model,
        currentActivityId: _activityId,
        events: events,
      );
    } else {
      await showActivityCategoryPickerSheet(
        context,
        model: model,
        currentActivityId: _activityId,
        events: events,
      );
    }
  }

  Future<void> _save() async {
    final l10n = AppLocalizations.of(context)!;
    final pattern = _pattern.text.trim();
    if (pattern.isEmpty || _activityId == null) {
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(content: Text(l10n.settingsBgFormInvalid)));
      return;
    }
    final activity = widget.activities
        .where((a) => a.id == _activityId)
        .firstOrNull;
    if (activity == null) return;
    final dispatcher = widget.app.dispatcher;
    if (widget.existing == null) {
      await dispatcher.dispatch(CommandInvocation(
        name: 'tracking_rule_create',
        args: [pattern],
        options: {
          'kind': _kind == TrackingRuleMatchKind.title ? 'title' : 'process',
          'activity': activity.name,
          'sync': _sync ? 'true' : 'false',
        },
      ));
    } else {
      await dispatcher.dispatch(CommandInvocation(
        name: 'tracking_rule_update',
        args: [widget.existing!.id],
        options: {
          'pattern': pattern,
          'kind': _kind == TrackingRuleMatchKind.title ? 'title' : 'process',
          'activity': activity.name,
          'sync': _sync ? 'true' : 'false',
        },
      ));
    }
    if (mounted) Navigator.of(context).pop(true);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final scheme = Theme.of(context).colorScheme;
    final activity = widget.activities
        .where((a) => a.id == _activityId)
        .firstOrNull;
    return AlertDialog(
      title: Text(widget.existing == null
          ? l10n.settingsBgRuleFormTitleNew
          : l10n.settingsBgRuleFormTitleEdit),
      content: SizedBox(
        width: 420,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            TextField(
              key: const ValueKey('rule-pattern'),
              controller: _pattern,
              decoration: InputDecoration(
                labelText: l10n.settingsBgPattern,
                helperText: l10n.settingsBgPatternHint,
                border: const OutlineInputBorder(),
                isDense: true,
              ),
            ),
            const SizedBox(height: 8),
            // 捕获当前前台（批次 6b）：免去手动查包名/进程名的门槛。
            Wrap(
              spacing: 8,
              children: [
                if (Platform.isAndroid)
                  ActionChip(
                    key: const ValueKey('capture-current'),
                    avatar: const Icon(Icons.center_focus_strong, size: 16),
                    label: Text(l10n.bgCaptureCurrentApp),
                    onPressed: () => _captureForeground(isTitle: false),
                  )
                else ...[
                  ActionChip(
                    avatar: const Icon(Icons.center_focus_strong, size: 16),
                    label: Text(l10n.bgCaptureProcess),
                    onPressed: () => _captureForeground(isTitle: false),
                  ),
                  ActionChip(
                    avatar: const Icon(Icons.center_focus_strong, size: 16),
                    label: Text(l10n.bgCaptureTitle),
                    onPressed: () => _captureForeground(isTitle: true),
                  ),
                ],
              ],
            ),
            const SizedBox(height: 16),
            Text(l10n.settingsBgMatchKind,
                style: Theme.of(context).textTheme.labelMedium),
            const SizedBox(height: 6),
            Row(
              children: [
                _KindRadio(
                  label: l10n.settingsBgKindProcess,
                  groupValue: _kind,
                  value: TrackingRuleMatchKind.process,
                  onChanged: (v) => setState(() => _kind = v),
                ),
                const SizedBox(width: 24),
                _KindRadio(
                  label: l10n.settingsBgKindTitle,
                  groupValue: _kind,
                  value: TrackingRuleMatchKind.title,
                  onChanged: (v) => setState(() => _kind = v),
                ),
              ],
            ),
            const SizedBox(height: 16),
            Text(l10n.settingsBgTargetActivity,
                style: Theme.of(context).textTheme.labelMedium),
            const SizedBox(height: 6),
            InkWell(
              key: const ValueKey('rule-activity'),
              onTap: _pickActivity,
              borderRadius: BorderRadius.circular(8),
              child: Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(
                      color: scheme.outlineVariant.withValues(alpha: 0.6)),
                ),
                child: Row(
                  children: [
                    if (activity != null) ...[
                      Container(
                        width: 8,
                        height: 8,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: Color(activity.color),
                        ),
                      ),
                      const SizedBox(width: 8),
                    ],
                    Expanded(
                      child: Text(activity?.name ?? l10n.settingsBgPickActivity),
                    ),
                    Icon(Icons.expand_more,
                        size: 16, color: scheme.onSurfaceVariant),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 16),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              dense: true,
              title: Text(l10n.settingsBgSyncThisRule),
              value: _sync,
              onChanged: (v) => setState(() => _sync = v),
            ),
            const SizedBox(height: 8),
            SettingsInfoBanner(
              compact: true,
              child: Text(l10n.settingsBgPriorityNote),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: Text(l10n.settingsBgCancel),
        ),
        FilledButton(
          key: const ValueKey('rule-save'),
          onPressed: _save,
          child: Text(l10n.settingsBgSave),
        ),
      ],
    );
  }
}

class _KindRadio extends StatelessWidget {
  const _KindRadio({
    required this.label,
    required this.groupValue,
    required this.value,
    required this.onChanged,
  });

  final String label;
  final TrackingRuleMatchKind groupValue;
  final TrackingRuleMatchKind value;
  final ValueChanged<TrackingRuleMatchKind> onChanged;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final selected = groupValue == value;
    return InkWell(
      onTap: () => onChanged(value),
      borderRadius: BorderRadius.circular(8),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 16,
            height: 16,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              border: Border.all(
                color: selected ? scheme.primary : scheme.outlineVariant,
                width: 2,
              ),
            ),
            alignment: Alignment.center,
            child: selected
                ? Container(
                    width: 7,
                    height: 7,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: scheme.primary,
                    ),
                  )
                : null,
          ),
          const SizedBox(width: 8),
          Text(label, style: Theme.of(context).textTheme.bodyMedium),
        ],
      ),
    );
  }
}
