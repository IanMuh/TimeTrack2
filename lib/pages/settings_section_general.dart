/// 设置分区实现 ①：通用 / 提醒 / 时间线（批次 4）。
///
/// 三区全部是 ProfileSettings 表单——变更经 [SettingsStore.save] 落库
/// （即时生效 + undo + LWW 时间戳推进），不另设本地草稿态。
library;

import 'package:flutter/material.dart';

import '../l10n/app_localizations.dart';
import '../utils/result.dart';
import '../stores/app_store.dart';
import '../utils/time_format.dart';
import '../viewmodels/profile_settings.dart';
import 'settings_widgets.dart';

/// 通用分区。
class GeneralSection extends StatelessWidget {
  const GeneralSection({super.key, required this.app});

  final AppStore app;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return ListenableBuilder(
      listenable: app.settings,
      builder: (context, _) {
        final s = app.settings.current;
        return SettingsSectionCard(
          key: const ValueKey('sec-general'),
          icon: Icons.tune_rounded,
          title: l10n.settingsSecGeneral,
          subtitle: l10n.settingsSecGeneralSub,
          children: [
            // 外观三选（浅/深/跟随系统——持久化驱动 app.dart 主题）。
            _Field(
              title: l10n.settingsAppearance,
              hint: l10n.settingsAppearanceHint,
              child: SettingsOptionCards<ThemeModeSetting>(
                options: [
                  SettingsOption(
                    value: ThemeModeSetting.light,
                    icon: Icons.light_mode_outlined,
                    label: l10n.settingsThemeLight,
                  ),
                  SettingsOption(
                    value: ThemeModeSetting.dark,
                    icon: Icons.dark_mode_outlined,
                    label: l10n.settingsThemeDark,
                  ),
                  SettingsOption(
                    value: ThemeModeSetting.system,
                    icon: Icons.monitor_outlined,
                    label: l10n.settingsThemeSystem,
                  ),
                ],
                groupValue: s?.themeMode ?? ThemeModeSetting.light,
                onChanged: (v) => _save(app, context, (cur) => cur.copyWith(themeMode: v)),
              ),
            ),
            SettingsDropdownRow<int>(
              title: l10n.settingsWeekStart,
              subtitle: l10n.settingsWeekStartHint,
              value: s?.weekStartDay ?? 1,
              items: [
                SettingsDropdownItem(value: 1, label: l10n.settingsWeekMonday),
                SettingsDropdownItem(value: 7, label: l10n.settingsWeekSunday),
                SettingsDropdownItem(value: 6, label: l10n.settingsWeekSaturday),
              ],
              onChanged: (v) => _save(app, context, (cur) => cur.copyWith(weekStartDay: v)),
            ),
            SettingsSegmentedRow(
              title: l10n.settingsTimeFormat,
              subtitle: l10n.settingsTimeFormatHint,
              segments: [l10n.settingsHour12, l10n.settingsHour24],
              selectedIndex: (s?.use24HourFormat ?? true) ? 1 : 0,
              onChanged: (i) => _save(
                app,
                context,
                (cur) => cur.copyWith(use24HourFormat: i == 1),
              ),
            ),
            SettingsDropdownRow<int>(
              title: l10n.settingsDefaultDuration,
              subtitle: l10n.settingsDefaultDurationHint,
              value: s?.defaultRecordMinutes ?? 25,
              items: [
                for (final m in ProfileSettings.defaultRecordMinutesChoices)
                  SettingsDropdownItem(
                    value: m,
                    label: l10n.settingsMinutesShort(m),
                  ),
              ],
              onChanged: (v) =>
                  _save(app, context, (cur) => cur.copyWith(defaultRecordMinutes: v)),
            ),
            SettingsSwitchRow(
              title: l10n.settingsQuickReminder,
              subtitle: l10n.settingsQuickReminderHint,
              value: s?.quickReminderEnabled ?? true,
              onChanged: (v) =>
                  _save(app, context, (cur) => cur.copyWith(quickReminderEnabled: v)),
            ),
          ],
        );
      },
    );
  }
}

/// 提醒分区。
class ReminderSection extends StatelessWidget {
  const ReminderSection({super.key, required this.app});

  final AppStore app;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return ListenableBuilder(
      listenable: app.settings,
      builder: (context, _) {
        final s = app.settings.current;
        final quickOn = s?.quickReminderEnabled ?? true;
        return SettingsSectionCard(
          key: const ValueKey('sec-reminder'),
          icon: Icons.notifications_outlined,
          title: l10n.settingsSecReminder,
          subtitle: l10n.settingsSecReminderSub,
          children: [
            // 触发时刻（分钟 → TimePicker）。
            _Field(
              title: l10n.settingsTriggerTime,
              hint: l10n.settingsTriggerTimeHint,
              enabled: quickOn,
              child: _TriggerTimeField(app: app, minutes: s?.reminderTimeOfDayMinutes ?? 540),
            ),
            SettingsSliderRow(
              title: l10n.settingsDurationThreshold,
              subtitle: l10n.settingsDurationThresholdHint,
              value: s?.reminderMinutes ?? 45,
              min: 15,
              max: 180,
              valueLabel: minutesLabel(l10n, s?.reminderMinutes ?? 45),
              marks: ['15', '60', '120', '180'],
              onChangeEnd: quickOn
                  ? (v) => _save(app, context, (cur) => cur.copyWith(reminderMinutes: v))
                  : (v) {},
            ),
            SettingsSliderRow(
              title: l10n.settingsRepeatInterval,
              subtitle: l10n.settingsRepeatIntervalHint,
              value: s?.reminderIntervalMinutes ?? 10,
              min: 5,
              max: 60,
              valueLabel: minutesLabel(l10n, s?.reminderIntervalMinutes ?? 10),
              marks: ['5', '15', '30', '60'],
              onChangeEnd: quickOn
                  ? (v) => _save(
                      app, context, (cur) => cur.copyWith(reminderIntervalMinutes: v))
                  : (v) {},
            ),
            _Field(
              title: l10n.settingsReminderMethod,
              hint: null,
              enabled: quickOn,
              child: SettingsOptionCards<ReminderMethod>(
                options: [
                  SettingsOption(
                    value: ReminderMethod.dialog,
                    icon: Icons.chat_bubble_outline,
                    label: l10n.settingsMethodDialog,
                    desc: l10n.settingsMethodDialogDesc,
                  ),
                  SettingsOption(
                    value: ReminderMethod.banner,
                    icon: Icons.web_asset_outlined,
                    label: l10n.settingsMethodBanner,
                    desc: l10n.settingsMethodBannerDesc,
                  ),
                  SettingsOption(
                    value: ReminderMethod.silent,
                    icon: Icons.notifications_off_outlined,
                    label: l10n.settingsMethodSilent,
                    desc: l10n.settingsMethodSilentDesc,
                  ),
                ],
                groupValue: s?.reminderMethod ?? ReminderMethod.dialog,
                onChanged: (v) =>
                    _save(app, context, (cur) => cur.copyWith(reminderMethod: v)),
              ),
            ),
          ],
        );
      },
    );
  }
}

/// 时间线分区。
class TimelineSection extends StatelessWidget {
  const TimelineSection({super.key, required this.app});

  final AppStore app;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return ListenableBuilder(
      listenable: app.settings,
      builder: (context, _) {
        final s = app.settings.current;
        final value = s?.mergeNeighborThresholdMinutes ?? 1;
        return SettingsSectionCard(
          key: const ValueKey('sec-timeline'),
          icon: Icons.merge_rounded,
          title: l10n.settingsSecTimeline,
          subtitle: l10n.settingsSecTimelineSub,
          paddedChildren: true,
          children: [
            Column(
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
                          Text(l10n.settingsMergeThreshold,
                              style: Theme.of(context).textTheme.bodyMedium),
                          const SizedBox(height: 2),
                          Text(
                            l10n.settingsMergeThresholdHint,
                            style: Theme.of(context)
                                .textTheme
                                .bodySmall
                                ?.copyWith(
                                  color:
                                      Theme.of(context).colorScheme.onSurfaceVariant,
                                ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 16),
                    Text(
                      minutesLabel(l10n, value),
                      style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                            color: Theme.of(context).colorScheme.primary,
                            fontWeight: FontWeight.w600,
                          ),
                    ),
                  ],
                ),
                Slider(
                  value: value.toDouble(),
                  min: 1,
                  max: 60,
                  divisions: 59,
                  label: minutesLabel(l10n, value),
                  onChanged: (_) {},
                  onChangeEnd: (v) => _save(
                    app,
                    context,
                    (cur) => cur.copyWith(mergeNeighborThresholdMinutes: v.round()),
                  ),
                ),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    for (final mark in ['1', '15', '30', '60'])
                      Text(
                        mark,
                        style: Theme.of(context).textTheme.labelSmall?.copyWith(
                              color:
                                  Theme.of(context).colorScheme.onSurfaceVariant,
                            ),
                      ),
                  ],
                ),
                const SizedBox(height: 12),
                SettingsInfoBanner(child: Text(l10n.settingsUnassignedNote)),
              ],
            ),
          ],
        );
      },
    );
  }
}

/// 表单字段外壳（标题 + 提示 + 控件 + 关闭态置灰）。
class _Field extends StatelessWidget {
  const _Field({
    required this.title,
    required this.child,
    this.hint,
    this.enabled = true,
  });

  final String title;
  final String? hint;
  final Widget child;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 14, 20, 6),
      child: Opacity(
        opacity: enabled ? 1 : 0.45,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(title, style: Theme.of(context).textTheme.bodyMedium),
            if (hint != null) ...[
              const SizedBox(height: 2),
              Text(
                hint!,
                style: Theme.of(context)
                    .textTheme
                    .bodySmall
                    ?.copyWith(color: scheme.onSurfaceVariant),
              ),
            ],
            const SizedBox(height: 10),
            child,
          ],
        ),
      ),
    );
  }
}

/// 触发时刻选择（分钟 ↔ TimeOfDay）。
class _TriggerTimeField extends StatelessWidget {
  const _TriggerTimeField({required this.app, required this.minutes});

  final AppStore app;
  final int minutes;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final time = TimeOfDay(
      hour: minutes ~/ 60,
      minute: minutes % 60,
    );
    // 跟随 24 小时制偏好（偏好已全局接线，此处曾固定 24h 渲染漏改）。
    final use24 = app.settings.current?.use24HourFormat ?? true;
    return InkWell(
      onTap: () async {
        final picked = await showTimePicker(context: context, initialTime: time);
        if (picked == null || !context.mounted) return;
        final value = picked.hour * 60 + picked.minute;
        await _save(
          app,
          context,
          (cur) => cur.copyWith(reminderTimeOfDayMinutes: value),
        );
      },
      borderRadius: BorderRadius.circular(8),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: scheme.outlineVariant.withValues(alpha: 0.6)),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              formatClock(time.hour, time.minute, use24: use24),
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    fontFeatures: const [FontFeature.tabularFigures()],
                  ),
            ),
            const SizedBox(width: 6),
            Icon(Icons.schedule, size: 16, color: scheme.onSurfaceVariant),
          ],
        ),
      ),
    );
  }
}

/// 统一保存入口：以 store 当前值为基准派生 next（防闭包过期值覆盖并发
/// 修改），失败经 SnackBar 呈现（设置保存极少失败，不弹对话框）。
Future<void> _save(
  AppStore app,
  BuildContext context,
  ProfileSettings Function(ProfileSettings current) transform,
) async {
  final store = app.settings;
  final current = store.current;
  if (current == null) return;
  final result = await store.save(transform(current));
  if (!context.mounted) return;
  if (result case AppFailure<ProfileSettings> failure) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(failure.message)));
  }
}
