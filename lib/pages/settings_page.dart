/// 设置页（UI 重建 PR-D：路由化主从，`docs/UI重建方案.md` §6）。
///
/// - `/settings`（[SettingsIndexPage]）：窄屏分区列表页（行 56：图标 +
///   标题 + 副标题 + chevron），点行 `push` 子路由、系统返回可回；宽屏
///   在路由层 redirect 直达 `/settings/general`（见 `routes/app_router.dart`）。
/// - `/settings/:section`（[SettingsSectionPage]）：宽屏 = 左 240 扁平
///   导航（10 项不分组）+ 右只渲染选中分区（正文 760）；窄屏 = 返回头 +
///   单分区卡。切分区不丢壳层保活（子路由挂在 settings 分支内）。
/// - 只构建当前分区；未提交的表单输入不跨分区保留（现有分区均为显式
///   保存交互，方案文档已确认接受）。
///
/// 分区实现仍是 `settings_section_*.dart`（通用/提醒/时间线 | 云同步/AI |
/// 后台记录 | 备份/设备互通 | 更新/关于），本文件只做骨架与装配。
library;

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../components/page_frame.dart';
import '../constants/layout.dart';
import '../l10n/app_localizations.dart';
import 'settings_section_background.dart';
import 'settings_section_device.dart';
import 'settings_section_general.dart';
import 'settings_section_sync.dart';
import 'settings_section_update.dart';

/// 分区规格：[id] = 路由段（`/settings/<id>`，深链稳定标识）；icon 与
/// 文案键用于列表行/左导航（分区卡自身同样带 icon/标题/副标题，取同源
/// ARB 键保持一致）。
class SettingsSectionSpec {
  const SettingsSectionSpec({
    required this.id,
    required this.icon,
    required this.builder,
  });

  final String id;
  final IconData icon;
  final WidgetBuilder builder;
}

/// 十分区（顺序 = 契约表格顺序；与路由子项一一对应生成）。
final List<SettingsSectionSpec> kSettingsSections = [
  SettingsSectionSpec(
    id: 'general',
    icon: Icons.tune_rounded,
    builder: (_) => GeneralSection(),
  ),
  SettingsSectionSpec(
    id: 'backup',
    icon: Icons.backup_outlined,
    builder: (_) => BackupSection(),
  ),
  SettingsSectionSpec(
    id: 'reminder',
    icon: Icons.notifications_outlined,
    builder: (_) => ReminderSection(),
  ),
  SettingsSectionSpec(
    id: 'timeline',
    icon: Icons.merge_rounded,
    builder: (_) => TimelineSection(),
  ),
  SettingsSectionSpec(
    id: 'sync',
    icon: Icons.cloud_outlined,
    builder: (_) => SyncSection(),
  ),
  SettingsSectionSpec(
    id: 'ai',
    icon: Icons.auto_awesome_outlined,
    builder: (_) => const AiSection(),
  ),
  SettingsSectionSpec(
    id: 'background',
    icon: Icons.insights_outlined,
    builder: (_) => BackgroundSection(),
  ),
  SettingsSectionSpec(
    id: 'device',
    icon: Icons.devices_outlined,
    builder: (_) => DeviceSection(),
  ),
  SettingsSectionSpec(
    id: 'update',
    icon: Icons.system_update_alt_outlined,
    builder: (_) => UpdateSection(),
  ),
  SettingsSectionSpec(
    id: 'about',
    icon: Icons.info_outline,
    builder: (_) => AboutSection(),
  ),
];

/// 路由段 → 分区规格（深链直达用；未知段回退 general）。
SettingsSectionSpec settingsSectionById(String id) {
  for (final spec in kSettingsSections) {
    if (spec.id == id) return spec;
  }
  return kSettingsSections.first;
}

String settingsSectionTitle(AppLocalizations l10n, SettingsSectionSpec spec) {
  return switch (spec.id) {
    'general' => l10n.settingsSecGeneral,
    'backup' => l10n.settingsSecBackup,
    'reminder' => l10n.settingsSecReminder,
    'timeline' => l10n.settingsSecTimeline,
    'sync' => l10n.settingsSecSync,
    'ai' => l10n.settingsSecAi,
    'background' => l10n.settingsSecBackground,
    'device' => l10n.settingsSecDevice,
    'update' => l10n.settingsSecUpdate,
    'about' => l10n.settingsSecAbout,
    _ => spec.id,
  };
}

String settingsSectionSubtitle(AppLocalizations l10n, SettingsSectionSpec spec) {
  return switch (spec.id) {
    'general' => l10n.settingsSecGeneralSub,
    'backup' => l10n.settingsSecBackupSub,
    'reminder' => l10n.settingsSecReminderSub,
    'timeline' => l10n.settingsSecTimelineSub,
    'sync' => l10n.settingsSecSyncSub,
    'ai' => l10n.settingsSecAiSub,
    'background' => l10n.settingsSecBackgroundSub,
    'device' => l10n.settingsSecDeviceSub,
    'update' => l10n.settingsSecUpdateSub,
    'about' => l10n.settingsSecAboutSub,
    _ => '',
  };
}

/// 分区列表页（`/settings` 本体）：窄屏主形态；宽屏正常不可达（路由
/// redirect 拦到 `/settings/general`）。不做 build 期宽屏补跳——分支挂载
/// 时本页可能在宽屏下离屏构建，补跳会把子路由深链劫持回 general。
class SettingsIndexPage extends StatelessWidget {
  const SettingsIndexPage({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l10n = AppLocalizations.of(context)!;
    return PageFrame(
      maxWidth: AppContentWidth.form,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 20, 24, 4),
            child: Text(l10n.navSettings, style: theme.textTheme.headlineSmall),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 24),
            child: Text(
              l10n.settingsInstantHint,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
          const SizedBox(height: 12),
          Expanded(
            child: SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 32),
              child: _SectionListCard(),
            ),
          ),
        ],
      ),
    );
  }
}

/// 分区列表卡（单卡容器 + 行间细分隔，样式对齐 SettingsSectionCard）。
class _SectionListCard extends StatelessWidget {
  const _SectionListCard();

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      decoration: BoxDecoration(
        color: scheme.surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: scheme.outlineVariant.withValues(alpha: 0.5),
        ),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        children: [
          for (var i = 0; i < kSettingsSections.length; i++) ...[
            if (i > 0)
              Divider(
                height: 1,
                color: scheme.outlineVariant.withValues(alpha: 0.4),
              ),
            _IndexRow(spec: kSettingsSections[i]),
          ],
        ],
      ),
    );
  }
}

/// 分区列表行（56：图标块 + 标题/副标题 + chevron）；点行 push 子路由
/// （系统返回/手势可回）。
class _IndexRow extends StatelessWidget {
  const _IndexRow({required this.spec});

  final SettingsSectionSpec spec;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l10n = AppLocalizations.of(context)!;
    final scheme = theme.colorScheme;
    return InkWell(
      onTap: () => context.push('/settings/${spec.id}'),
      child: SizedBox(
        height: 56,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Row(
            children: [
              Container(
                width: 32,
                height: 32,
                decoration: BoxDecoration(
                  color: scheme.primary.withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Icon(spec.icon, size: 16, color: scheme.primary),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Text(
                      settingsSectionTitle(l10n, spec),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                    Text(
                      settingsSectionSubtitle(l10n, spec),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
              Icon(
                Icons.chevron_right_rounded,
                size: 18,
                color: scheme.onSurfaceVariant,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 分区页（`/settings/:section`）。
///
/// - 宽屏 ≥840：左 240 扁平导航（选中态由路由段驱动，切换 `go` 同栈
///   替换不堆栈）+ 右只渲染选中分区（正文 760）。
/// - 窄屏：返回头（pop 不可达时兜底回列表页）+ 单分区卡。
class SettingsSectionPage extends StatelessWidget {
  const SettingsSectionPage({super.key, required this.sectionId});

  final String sectionId;

  @override
  Widget build(BuildContext context) {
    final spec = settingsSectionById(sectionId);
    final section = spec.builder(context);
    final wide = MediaQuery.sizeOf(context).width >= AppBreakpoints.expanded;
    if (!wide) {
      return PageFrame(
        maxWidth: AppContentWidth.form,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _NarrowHeader(),
            Expanded(
              child: SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
                child: section,
              ),
            ),
          ],
        ),
      );
    }
    return PageFrame(
      maxWidth: AppContentWidth.settings,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SizedBox(
            width: 240,
            child: SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(24, 20, 8, 32),
              child: _SectionNav(selectedId: spec.id),
            ),
          ),
          Expanded(
            child: SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(8, 20, 24, 48),
              child: ConstrainedBox(
                constraints: const BoxConstraints(
                  maxWidth: AppContentWidth.form,
                ),
                child: section,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// 窄屏返回头：返回键（pop 不可达——如宽屏 redirect 直落后拉窄——兜底
/// 回列表页）+ 页标题。
class _NarrowHeader extends StatelessWidget {
  const _NarrowHeader();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l10n = AppLocalizations.of(context)!;
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 24, 4),
      child: Row(
        children: [
          IconButton(
            icon: const Icon(Icons.arrow_back_rounded, size: 20),
            tooltip: l10n.settingsBackToSections,
            onPressed: () {
              if (context.canPop()) {
                context.pop();
              } else {
                context.go('/settings');
              }
            },
          ),
          const SizedBox(width: 4),
          Text(l10n.navSettings, style: theme.textTheme.titleLarge),
        ],
      ),
    );
  }
}

/// 宽屏左侧分区导航（10 项扁平列表；选中态 = primary 10% 底，样式对齐
/// 壳层侧导航项）。
class _SectionNav extends StatelessWidget {
  const _SectionNav({required this.selectedId});

  final String selectedId;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l10n = AppLocalizations.of(context)!;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
          child: Text(l10n.navSettings, style: theme.textTheme.headlineSmall),
        ),
        for (final spec in kSettingsSections)
          _NavItem(
            spec: spec,
            selected: spec.id == selectedId,
            onTap: () => context.go('/settings/${spec.id}'),
          ),
      ],
    );
  }
}

class _NavItem extends StatelessWidget {
  const _NavItem({
    required this.spec,
    required this.selected,
    required this.onTap,
  });

  final SettingsSectionSpec spec;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final scheme = Theme.of(context).colorScheme;
    final foreground = selected ? scheme.primary : scheme.onSurfaceVariant;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Material(
        color: selected
            ? scheme.primary.withValues(alpha: 0.10)
            : Colors.transparent,
        borderRadius: BorderRadius.circular(8),
        child: InkWell(
          borderRadius: BorderRadius.circular(8),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
            child: Row(
              children: [
                Icon(spec.icon, size: 18, color: foreground),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    settingsSectionTitle(l10n, spec),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
                      color: foreground,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
