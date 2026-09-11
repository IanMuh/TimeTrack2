import 'package:flutter/material.dart';

import '../l10n/app_localizations.dart';
import '../utils/time_format.dart';
import '../viewmodels/time_entry.dart';
import 'controls.dart' show AppToggle;
import 'feedback.dart';

/// 条目编辑对话框草稿（提交数据；页面转指令通道）。
class EntryEditDraft {
  const EntryEditDraft({
    required this.activityId,
    required this.activityName,
    required this.start,
    this.end,
    required this.keepRunning,
    required this.note,
    this.entryId,
    this.endIsNow = false,
  });

  final String? entryId; // null = 新增
  final String activityId;
  final String activityName;
  final DateTime start;

  /// null + keepRunning=true = 运行中。
  final DateTime? end;

  /// 未选结束时刻的"结束到现在"语义（宿主据此传指令特值 `now`——绝对
  /// 时刻，跨天条目不受 HH:MM 按条目所在日还原影响）。
  final bool endIsNow;
  final bool keepRunning;
  final String note;
}

/// 条目编辑对话框（契约 §4.3：新增/编辑共用；无业务状态——数据/回调注入，
/// 指令分发由宿主页面完成）。
///
/// 校验（4 类，保存时逐条检查显示在表单顶部）：
/// - 结束 ≤ 开始 / 运行条目落在将来 → 红，阻断；
/// - 与既有条目重叠 → amber，允许继续（checkbox 确认）；
/// - 跨 0 点区间 → sky 提示"保存后将拆分"（数据层负责拆分）。
Future<void> showEntryEditorDialog(
  BuildContext context, {
  required TimeEntry? entry, // null = 新增
  required String? currentActivityId,
  required String currentActivityName,
  required int currentActivityColor,
  required VoidCallback onPickActivity, // 打开合并选择器（宿主装配）
  required List<TimeEntry> existing, // 重叠检测用（同日既有条目）
  required Future<bool> Function(EntryEditDraft draft) onSubmit,
  required Future<bool> Function(String entryId) onDelete,
  Future<bool> Function(String entryId, String direction)? onMerge,
  Future<bool> Function(String entryId, DateTime at)? onSplit,
  Future<bool> Function(String entryId)? onExtendToNow,
  bool use24 = true,
}) {
  return showDialog<void>(
    context: context,
    builder: (_) => _EntryEditorDialog(
      entry: entry,
      currentActivityId: currentActivityId,
      currentActivityName: currentActivityName,
      currentActivityColor: currentActivityColor,
      onPickActivity: onPickActivity,
      existing: existing,
      onSubmit: onSubmit,
      onDelete: onDelete,
      onMerge: onMerge,
      onSplit: onSplit,
      onExtendToNow: onExtendToNow,
      use24: use24,
    ),
  );
}

class _EntryEditorDialog extends StatefulWidget {
  const _EntryEditorDialog({
    this.use24 = true,
    required this.entry,
    required this.currentActivityId,
    required this.currentActivityName,
    required this.currentActivityColor,
    required this.onPickActivity,
    required this.existing,
    required this.onSubmit,
    required this.onDelete,
    this.onMerge,
    this.onSplit,
    this.onExtendToNow,
  });

  final TimeEntry? entry;

  /// 24 小时制（用户偏好，时刻字段显示形态）。
  final bool use24;
  final String? currentActivityId;
  final String currentActivityName;
  final int currentActivityColor;
  final VoidCallback onPickActivity;
  final List<TimeEntry> existing;
  final Future<bool> Function(EntryEditDraft) onSubmit;
  final Future<bool> Function(String) onDelete;
  final Future<bool> Function(String, String)? onMerge;
  final Future<bool> Function(String, DateTime)? onSplit;
  final Future<bool> Function(String)? onExtendToNow;

  @override
  State<_EntryEditorDialog> createState() => _EntryEditorDialogState();
}

class _EntryEditorDialogState extends State<_EntryEditorDialog> {
  late DateTime _start;
  DateTime? _end;
  late bool _keepRunning;
  late final TextEditingController _note;
  bool _overlapConfirmed = false;
  bool _submitting = false;

  @override
  void initState() {
    super.initState();
    _start = widget.entry?.startAt ?? _roundTo5(DateTime.now());
    _end = widget.entry?.endAt;
    _keepRunning = widget.entry?.isRunning ?? false;
    _note = TextEditingController(text: widget.entry?.note ?? '');
  }

  static DateTime _roundTo5(DateTime t) => DateTime(
        t.year,
        t.month,
        t.day,
        t.hour,
        (t.minute / 5).floor() * 5,
      );

  @override
  void dispose() {
    _note.dispose();
    super.dispose();
  }

  // ---------------------------------------------------------------------------
  // 校验（4 类）
  // ---------------------------------------------------------------------------

  String? get _blockError {
    final l10n = AppLocalizations.of(context)!;
    if (!_keepRunning && _end != null && !_end!.isAfter(_start)) {
      return l10n.entryErrEndBeforeStart;
    }
    if (_keepRunning && _start.isAfter(DateTime.now())) {
      return l10n.entryErrRunningInFuture;
    }
    return null;
  }

  bool get _hasOverlap {
    final id = widget.entry?.id;
    for (final e in widget.existing) {
      if (e.id == id) continue;
      final s = e.startAt;
      final en = e.endAt ?? DateTime.now();
      final myEnd = _keepRunning ? DateTime.now() : (_end ?? DateTime.now());
      if (_start.isBefore(en) && s.isBefore(myEnd)) return true;
    }
    return false;
  }

  bool get _crossesMidnight =>
      !_keepRunning &&
      _end != null &&
      _start.day != _end!.day;

  // ---------------------------------------------------------------------------
  // 提交
  // ---------------------------------------------------------------------------

  Future<void> _submit() async {
    final l10n = AppLocalizations.of(context)!;
    if (_blockError != null) return;
    if (_hasOverlap && !_overlapConfirmed) return;
    setState(() => _submitting = true);
    final ok = await widget.onSubmit(EntryEditDraft(
      entryId: widget.entry?.id,
      activityId: widget.currentActivityId ?? '',
      activityName: widget.currentActivityName,
      start: _start,
      // keepRunning=true → end 保持 null（运行中）；关闭「保持运行中」但
      // 未选结束时刻 → endIsNow（宿主传 `now` 特值），不在此截断成 HH:MM。
      end: _keepRunning ? null : _end,
      endIsNow: !_keepRunning && _end == null,
      keepRunning: _keepRunning,
      note: _note.text,
    ));
    if (!mounted) return;
    setState(() => _submitting = false);
    if (ok) {
      Navigator.of(context).pop();
    } else {
      showAppSnackBar(context, message: l10n.createFailed, isError: true);
    }
  }

  Future<void> _confirmDelete() async {
    final entry = widget.entry;
    if (entry == null) return;
    final l10n = AppLocalizations.of(context)!;
    final ok = await showAppConfirmationDialog(
      context,
      title: l10n.entryDeleteTitle,
      message: l10n.entryDeleteHint,
      confirmLabel: l10n.delete,
      isDestructive: true,
    );
    if (ok != true) return;
    final deleted = await widget.onDelete(entry.id);
    if (!mounted) return;
    if (deleted) Navigator.of(context).pop();
  }

  // ---------------------------------------------------------------------------
  // 构建
  // ---------------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final isEdit = widget.entry != null;
    return AlertDialog(
      title: Text(isEdit ? l10n.entryEditorEdit : l10n.entryEditorNew),
      content: SizedBox(
        width: 480,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // 活动选择（更换按钮打开合并选择器——宿主回调）。
              InkWell(
                onTap: widget.onPickActivity,
                borderRadius: BorderRadius.circular(8),
                child: Container(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 12, vertical: 10),
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: scheme.outlineVariant),
                  ),
                  child: Row(
                    children: [
                      Container(
                        width: 10,
                        height: 10,
                        decoration: BoxDecoration(
                          color: Color(widget.currentActivityColor),
                          shape: BoxShape.circle,
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          widget.currentActivityName,
                          style: const TextStyle(
                              fontSize: 14, fontWeight: FontWeight.w500),
                        ),
                      ),
                      Text(l10n.entryChangeActivity,
                          style: TextStyle(
                              fontSize: 12, color: scheme.primary)),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 14),
              Row(
                children: [
                  Expanded(
                    child: _DateTimeField(
                      label: l10n.entryStartAt,
                      value: _start,
                      use24: widget.use24,
                      onChanged: (v) => setState(() => _start = v),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: _DateTimeField(
                      label: l10n.entryEndAt,
                      value: _end ?? DateTime.now(),
                      enabled: !_keepRunning,
                      onChanged: (v) => setState(() => _end = v),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 10),
              if (isEdit)
                AppToggle(
                  value: _keepRunning,
                  label: l10n.entryKeepRunning,
                  onChanged: (v) => setState(() => _keepRunning = v),
                ),
              const SizedBox(height: 14),
              TextFormField(
                controller: _note,
                maxLines: 3,
                decoration: InputDecoration(
                  hintText: l10n.entryNoteHint,
                ),
              ),
              // —— 校验区（4 类）——
              if (_blockError != null) ...[
                const SizedBox(height: 10),
                _ValidateBanner(
                  color: scheme.error,
                  icon: Icons.error_outline,
                  text: _blockError!,
                ),
              ] else if (_hasOverlap && !_overlapConfirmed) ...[
                const SizedBox(height: 10),
                _ValidateBanner(
                  color: const Color(0xfff59e0b),
                  icon: Icons.warning_amber_rounded,
                  text: l10n.entryWarnOverlap,
                  actionLabel: l10n.entryOverlapContinue,
                  onAction: () => setState(() => _overlapConfirmed = true),
                ),
              ] else if (_crossesMidnight) ...[
                const SizedBox(height: 10),
                _ValidateBanner(
                  color: const Color(0xff0ea5e9),
                  icon: Icons.info_outline,
                  text: l10n.entryHintSplit,
                ),
              ],
              // —— 仅编辑态：相邻合并 / 拆分 / 延伸 ——
              if (isEdit) ...[
                const Divider(height: 28),
                Text(l10n.entryEditOps,
                    style: theme.textTheme.labelMedium),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    if (widget.onMerge != null)
                      OutlinedButton(
                        onPressed: () => widget.onMerge!(
                            widget.entry!.id, 'previous'),
                        child: Text(l10n.entryMergePrev),
                      ),
                    if (widget.onMerge != null)
                      OutlinedButton(
                        onPressed: () =>
                            widget.onMerge!(widget.entry!.id, 'next'),
                        child: Text(l10n.entryMergeNext),
                      ),
                    if (widget.onSplit != null)
                      OutlinedButton(
                        onPressed: _splitDialog,
                        child: Text(l10n.entrySplit),
                      ),
                    if (widget.onExtendToNow != null && !_keepRunning)
                      OutlinedButton(
                        onPressed: () =>
                            widget.onExtendToNow!(widget.entry!.id),
                        child: Text(l10n.entryExtendNow),
                      ),
                  ],
                ),
              ],
            ],
          ),
        ),
      ),
      actions: [
        if (isEdit)
          TextButton(
            onPressed: _confirmDelete,
            style: TextButton.styleFrom(foregroundColor: scheme.error),
            child: Text(l10n.delete),
          ),
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(l10n.cancel),
        ),
        FilledButton(
          onPressed: (_blockError != null ||
                  (_hasOverlap && !_overlapConfirmed) ||
                  _submitting ||
                  widget.currentActivityId == null)
              ? null
              : _submit,
          child: Text(l10n.save),
        ),
      ],
    );
  }

  Future<void> _splitDialog() async {
    final picked = await showTimePicker(
      context: context,
      initialTime:
          TimeOfDay(hour: _start.hour, minute: _start.minute),
    );
    if (picked == null || widget.onSplit == null) return;
    final at = DateTime(
      _start.year,
      _start.month,
      _start.day,
      picked.hour,
      picked.minute,
    );
    final ok = await widget.onSplit!(widget.entry!.id, at);
    if (ok && mounted) Navigator.of(context).pop();
  }
}

/// 日期+时间组合输入（简化：日期 showDatePicker + 时间 showTimePicker）。
class _DateTimeField extends StatelessWidget {
  const _DateTimeField({
    this.use24 = true,
    required this.label,
    required this.value,
    required this.onChanged,
    this.enabled = true,
  });

  final String label;
  final DateTime value;
  final ValueChanged<DateTime> onChanged;
  final bool enabled;

  /// 24 小时制（显示形态）。
  final bool use24;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: enabled ? () => _pick(context) : null,
      child: InputDecorator(
        decoration: InputDecoration(
          labelText: label,
          enabled: enabled,
        ),
        child: Text(
          '${value.month}/${value.day} '
          '${formatClockOf(value, use24: use24)}',
          style: TextStyle(
            fontSize: 13,
            color: enabled ? null : Theme.of(context).disabledColor,
            fontFeatures: const [FontFeature.tabularFigures()],
          ),
        ),
      ),
    );
  }

  Future<void> _pick(BuildContext context) async {
    final d = await showDatePicker(
      context: context,
      initialDate: value,
      firstDate: DateTime(2020),
      lastDate: DateTime.now().add(const Duration(days: 365)),
      helpText: AppLocalizations.of(context)!.todayPickDate,
    );
    if (d == null || !context.mounted) return;
    final t = await showTimePicker(
      context: context,
      initialTime: TimeOfDay(hour: value.hour, minute: value.minute),
    );
    if (t == null) return;
    onChanged(DateTime(d.year, d.month, d.day, t.hour, t.minute));
  }
}

class _ValidateBanner extends StatelessWidget {
  const _ValidateBanner({
    required this.color,
    required this.icon,
    required this.text,
    this.actionLabel,
    this.onAction,
  });

  final Color color;
  final IconData icon;
  final String text;
  final String? actionLabel;
  final VoidCallback? onAction;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: color.withValues(alpha: 0.3)),
      ),
      child: Row(
        children: [
          Icon(icon, size: 14, color: color),
          const SizedBox(width: 8),
          Expanded(
            child: Text(text,
                style: TextStyle(fontSize: 12, color: color)),
          ),
          if (actionLabel != null && onAction != null)
            TextButton(
              onPressed: onAction,
              style: TextButton.styleFrom(
                visualDensity: VisualDensity.compact,
              ),
              child: Text(actionLabel!),
            ),
        ],
      ),
    );
  }
}
