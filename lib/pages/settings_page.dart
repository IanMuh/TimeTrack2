/// 设置页（批次 4）：十分区组织——紧凑档锚点条 + 单栏；宽屏（≥840）左
/// 锚点导航 + 右分区卡列（契约 §4.5：形态自由、分区化、即时生效）。
///
/// 分区实现拆分在 settings_section_*.dart（通用/提醒/时间线 | 云同步/AI |
/// 后台记录 | 备份/设备互通 | 更新/关于），本文件只做骨架与装配。
library;

import 'package:flutter/material.dart';

import '../l10n/app_localizations.dart';
import '../stores/app_store.dart';
import 'settings_section_background.dart';
import 'settings_section_device.dart';
import 'settings_section_general.dart';
import 'settings_section_sync.dart';
import 'settings_section_update.dart';

class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key, required this.app});

  final AppStore app;

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  // 分区列表（含 GlobalKey）在 State 生命周期内只建一次：GlobalKey 每次
  // build 新实例会让 Flutter 判定元素无法复用 → 十个分区随任意重建整棵
  // 重挂载，分区内部输入态（如 LAN 配对码输入框）全部丢失。
  List<SettingsSectionSpec> _sections = const [];

  @override
  void initState() {
    super.initState();
    _rebuildSections();
  }

  @override
  void didUpdateWidget(SettingsPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.app != oldWidget.app) _rebuildSections();
  }

  void _rebuildSections() => _sections = buildSettingsSections(widget.app);

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final wide = MediaQuery.sizeOf(context).width >= 840;
    final sections = _sections;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(24, 20, 24, 4),
          child: Text(
            l10n.navSettings,
            style: Theme.of(context).textTheme.headlineSmall,
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 24),
          child: Text(
            l10n.settingsInstantHint,
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
          ),
        ),
        const SizedBox(height: 12),
        Expanded(
          child: wide
              ? _WideLayout(sections: sections)
              : _CompactLayout(sections: sections),
        ),
      ],
    );
  }
}

/// 分区条目（标题 + 卡构建器 + 滚动 key）。
class SettingsSectionSpec {
  const SettingsSectionSpec({
    required this.key,
    required this.title,
    required this.builder,
  });

  final GlobalKey key;
  final String title;
  final WidgetBuilder builder;
}

/// 组装十分区（顺序 = 契约表格顺序）。
List<SettingsSectionSpec> buildSettingsSections(AppStore app) {
  return [
    SettingsSectionSpec(
      key: GlobalKey(debugLabel: 'sec-general'),
      title: 'settingsSecGeneral',
      builder: (_) => GeneralSection(app: app),
    ),
    SettingsSectionSpec(
      key: GlobalKey(debugLabel: 'sec-backup'),
      title: 'settingsSecBackup',
      builder: (_) => BackupSection(app: app),
    ),
    SettingsSectionSpec(
      key: GlobalKey(debugLabel: 'sec-reminder'),
      title: 'settingsSecReminder',
      builder: (_) => ReminderSection(app: app),
    ),
    SettingsSectionSpec(
      key: GlobalKey(debugLabel: 'sec-timeline'),
      title: 'settingsSecTimeline',
      builder: (_) => TimelineSection(app: app),
    ),
    SettingsSectionSpec(
      key: GlobalKey(debugLabel: 'sec-sync'),
      title: 'settingsSecSync',
      builder: (_) => SyncSection(app: app),
    ),
    SettingsSectionSpec(
      key: GlobalKey(debugLabel: 'sec-ai'),
      title: 'settingsSecAi',
      builder: (_) => const AiSection(),
    ),
    SettingsSectionSpec(
      key: GlobalKey(debugLabel: 'sec-background'),
      title: 'settingsSecBackground',
      builder: (_) => BackgroundSection(app: app),
    ),
    SettingsSectionSpec(
      key: GlobalKey(debugLabel: 'sec-device'),
      title: 'settingsSecDevice',
      builder: (_) => DeviceSection(app: app),
    ),
    SettingsSectionSpec(
      key: GlobalKey(debugLabel: 'sec-update'),
      title: 'settingsSecUpdate',
      builder: (_) => UpdateSection(app: app),
    ),
    SettingsSectionSpec(
      key: GlobalKey(debugLabel: 'sec-about'),
      title: 'settingsSecAbout',
      builder: (_) => AboutSection(app: app),
    ),
  ];
}

/// 紧凑档：顶部锚点条（横向滚动）+ 单栏分区列表。
class _CompactLayout extends StatelessWidget {
  const _CompactLayout({required this.sections});

  final List<SettingsSectionSpec> sections;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final scheme = Theme.of(context).colorScheme;
    final controller = PrimaryScrollController.maybeOf(context);
    return Column(
      children: [
        // 锚点条。
        SizedBox(
          height: 44,
          child: ListView.builder(
            scrollDirection: Axis.horizontal,
            itemCount: sections.length,
            padding: const EdgeInsets.symmetric(horizontal: 16),
            itemBuilder: (context, index) {
              final section = sections[index];
              return Padding(
                padding: const EdgeInsets.only(right: 8),
                child: ActionChip(
                  label: Text(_sectionLabel(l10n, section.title)),
                  onPressed: () => Scrollable.ensureVisible(
                    section.key.currentContext ?? context,
                    duration: const Duration(milliseconds: 300),
                    alignment: 0.1,
                  ),
                ),
              );
            },
          ),
        ),
        Divider(height: 1, color: scheme.outlineVariant.withValues(alpha: 0.4)),
        // 分区列表。
        Expanded(
          child: SingleChildScrollView(
            controller: controller,
            primary: controller == null,
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
            child: Column(
              children: [
                for (var i = 0; i < sections.length; i++) ...[
                  if (i > 0) const SizedBox(height: 14),
                  KeyedSubtree(
                    key: sections[i].key,
                    child: sections[i].builder(context),
                  ),
                ],
              ],
            ),
          ),
        ),
      ],
    );
  }
}

/// 宽屏档：左 200px 锚点导航 + 右分区卡列。
class _WideLayout extends StatelessWidget {
  const _WideLayout({required this.sections});

  final List<SettingsSectionSpec> sections;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 208,
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(24, 4, 8, 32),
            child: Column(
              children: [
                for (final section in sections)
                  Align(
                    alignment: Alignment.centerLeft,
                    child: TextButton(
                      onPressed: () => Scrollable.ensureVisible(
                        section.key.currentContext ?? context,
                        duration: const Duration(milliseconds: 300),
                        alignment: 0.05,
                      ),
                      child: Text(_sectionLabel(l10n, section.title)),
                    ),
                  ),
              ],
            ),
          ),
        ),
        Expanded(
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(8, 4, 24, 48),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 760),
              child: Column(
                children: [
                  for (var i = 0; i < sections.length; i++) ...[
                    if (i > 0) const SizedBox(height: 16),
                    KeyedSubtree(
                      key: sections[i].key,
                      child: sections[i].builder(context),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }
}

String _sectionLabel(AppLocalizations l10n, String key) {
  return switch (key) {
    'settingsSecGeneral' => l10n.settingsSecGeneral,
    'settingsSecBackup' => l10n.settingsSecBackup,
    'settingsSecReminder' => l10n.settingsSecReminder,
    'settingsSecTimeline' => l10n.settingsSecTimeline,
    'settingsSecSync' => l10n.settingsSecSync,
    'settingsSecAi' => l10n.settingsSecAi,
    'settingsSecBackground' => l10n.settingsSecBackground,
    'settingsSecDevice' => l10n.settingsSecDevice,
    'settingsSecUpdate' => l10n.settingsSecUpdate,
    'settingsSecAbout' => l10n.settingsSecAbout,
    _ => key,
  };
}
