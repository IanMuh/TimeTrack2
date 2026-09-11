/// 设置分区实现 ⑤：版本更新（状态机全态卡，契约 §7）+ 关于。
library;

import 'package:flutter/material.dart';

import '../l10n/app_localizations.dart';
import '../stores/app_store.dart';
import '../stores/update_store.dart';
import '../viewmodels/commands/command_invocation.dart';
import 'settings_widgets.dart';

/// 版本更新分区。
class UpdateSection extends StatelessWidget {
  const UpdateSection({super.key, required this.app});

  final AppStore app;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return ListenableBuilder(
      listenable: app.update,
      builder: (context, _) {
        final status = app.update.status;
        return SettingsSectionCard(
          key: const ValueKey('sec-update'),
          icon: Icons.system_update_alt_outlined,
          title: l10n.settingsSecUpdate,
          subtitle: l10n.settingsSecUpdateSub,
          paddedChildren: true,
          children: [
            // 版本信息行。
            Row(
              children: [
                Expanded(
                  child: _VersionCell(
                    label: l10n.settingsUpdateCurrent,
                    value: 'v${app.currentVersion}',
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: _VersionCell(
                    label: l10n.settingsUpdateLatest,
                    value: status.latestVersion.isEmpty
                        ? '—'
                        : 'v${status.latestVersion}',
                    accent: true,
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: _VersionCell(
                    label: l10n.settingsUpdateState,
                    value: _stateLabel(l10n, status.state),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 14),
            _UpdateStateCard(app: app),
            const SizedBox(height: 12),
            SettingsInfoBanner(
              compact: true,
              child: Text(l10n.settingsUpdateInstallNote),
            ),
          ],
        );
      },
    );
  }

  String _stateLabel(AppLocalizations l10n, UpdateState state) {
    return switch (state) {
      UpdateState.idle => l10n.settingsUpdateIdle,
      UpdateState.checking => l10n.settingsUpdateChecking,
      UpdateState.upToDate => l10n.settingsUpdateUpToDate,
      UpdateState.available => l10n.settingsUpdateAvailable,
      UpdateState.downloading => l10n.settingsUpdateDownloading,
      UpdateState.paused => l10n.settingsUpdateDownloading,
      UpdateState.verifying => l10n.settingsUpdateVerifying,
      UpdateState.installing => l10n.settingsUpdateInstalling,
      UpdateState.restartRequired => l10n.settingsUpdateRestartRequired,
      UpdateState.failed => l10n.settingsUpdateFailed,
    };
  }
}

class _VersionCell extends StatelessWidget {
  const _VersionCell({
    required this.label,
    required this.value,
    this.accent = false,
  });

  final String label;
  final String value;
  final bool accent;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: scheme.outlineVariant.withValues(alpha: 0.6)),
      ),
      child: Column(
        children: [
          Text(
            label,
            style: Theme.of(context)
                .textTheme
                .labelSmall
                ?.copyWith(color: scheme.onSurfaceVariant),
            overflow: TextOverflow.ellipsis,
          ),
          const SizedBox(height: 2),
          Text(
            value,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  fontWeight: FontWeight.w600,
                  color: accent ? scheme.primary : null,
                ),
          ),
        ],
      ),
    );
  }
}

/// 状态机主卡：按当前状态渲染主操作区（idle/available/downloading/
/// verifying/installing/restartRequired/failed/upToDate/checking）。
class _UpdateStateCard extends StatelessWidget {
  const _UpdateStateCard({required this.app});

  final AppStore app;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final scheme = Theme.of(context).colorScheme;
    final update = app.update;
    final status = update.status;
    final busy = switch (status.state) {
      UpdateState.checking ||
      UpdateState.downloading ||
      UpdateState.verifying ||
      UpdateState.installing =>
        true,
      _ => false,
    };
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: scheme.outlineVariant.withValues(alpha: 0.6)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 主操作按钮区（按状态）。
          switch (status.state) {
            UpdateState.idle ||
            UpdateState.upToDate ||
            UpdateState.failed ||
            UpdateState.available =>
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  OutlinedButton.icon(
                    key: const ValueKey('update-check'),
                    onPressed: busy ? null : _check,
                    icon: const Icon(Icons.refresh, size: 16),
                    label: Text(l10n.settingsUpdateCheck),
                  ),
                  if (status.state == UpdateState.available) ...[
                    FilledButton.icon(
                      key: const ValueKey('update-download'),
                      onPressed: _download,
                      icon: const Icon(Icons.download, size: 16),
                      label: Text(l10n.settingsUpdateDownload),
                    ),
                    OutlinedButton(
                      onPressed: () => _ignoreVersion(context),
                      child: Text(l10n.settingsUpdateIgnoreVersion),
                    ),
                    OutlinedButton(
                      onPressed: () {},
                      child: Text(l10n.settingsUpdateLater),
                    ),
                  ],
                  if (status.state == UpdateState.failed)
                    Text(
                      status.errorMessage ?? '',
                      style: Theme.of(context)
                          .textTheme
                          .bodySmall
                          ?.copyWith(color: scheme.error),
                    ),
                ],
              ),
            UpdateState.checking => Row(
                children: [
                  const SizedBox(
                    width: 14,
                    height: 14,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                  const SizedBox(width: 10),
                  Text(l10n.settingsUpdateChecking),
                ],
              ),
            UpdateState.downloading => _ProgressBlock(status: status),
            UpdateState.paused => _ProgressBlock(status: status),
            UpdateState.verifying => Row(
                children: [
                  const SizedBox(
                    width: 14,
                    height: 14,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                  const SizedBox(width: 10),
                  Text(l10n.settingsUpdateVerifying),
                ],
              ),
            UpdateState.installing => Row(
                children: [
                  const SizedBox(
                    width: 14,
                    height: 14,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                  const SizedBox(width: 10),
                  Text(l10n.settingsUpdateInstalling),
                ],
              ),
            UpdateState.restartRequired => Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Icon(Icons.restart_alt,
                          size: 16, color: Colors.amber.shade700),
                      const SizedBox(width: 8),
                      Text(l10n.settingsUpdateRestartRequired),
                    ],
                  ),
                  const SizedBox(height: 4),
                  Text(
                    l10n.settingsUpdateRestartBody,
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: scheme.onSurfaceVariant,
                        ),
                  ),
                ],
              ),
          },
          if (status.state == UpdateState.downloading ||
              status.state == UpdateState.paused) ...[
            const SizedBox(height: 6),
            Text(
              l10n.settingsUpdateVerifyNote,
              style: Theme.of(context).textTheme.labelSmall?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
            ),
          ],
        ],
      ),
    );
  }

  /// 经指令通道（铁律 7）：'update_check' 指令已注册——与深链/AI/壳层
  /// 同入口；结果经 update store 监听驱动 UI，无需在此处理。
  Future<void> _check() async {
    await app.dispatcher
        .dispatch(CommandInvocation(name: 'update_check'));
  }

  /// 下载 + 内联校验（verifying → install 可用）。无同名注册指令，暂直调
  ///（挂账：update_download 指令化——连同 signOut/ignoreVersion 收口）。
  Future<void> _download() async => app.update.download();

  Future<void> _ignoreVersion(BuildContext context) async {
    final l10n = AppLocalizations.of(context)!;
    await app.update.ignoreCurrentVersion();
    if (!context.mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(l10n.settingsUpdateIgnoredDone)));
  }
}

/// 下载进度块（received/total + 进度条；total 未知时不确定动画）。
class _ProgressBlock extends StatelessWidget {
  const _ProgressBlock({required this.status});

  final UpdateStatus status;

  static String mb(int bytes) =>
      '${(bytes / 1024 / 1024).toStringAsFixed(1)} MB';

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final scheme = Theme.of(context).colorScheme;
    final total = status.totalBytes;
    final received = status.receivedBytes;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(
              status.latestVersion.isEmpty
                  ? l10n.settingsUpdateDownloading
                  : 'v${status.latestVersion}',
              style: Theme.of(context)
                  .textTheme
                  .bodyMedium
                  ?.copyWith(fontWeight: FontWeight.w600),
            ),
            if (total != null)
              Text(
                '${mb(received)} / ${mb(total)}',
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: scheme.onSurfaceVariant,
                      fontFeatures: const [FontFeature.tabularFigures()],
                    ),
              )
            else
              Text(
                mb(received),
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: scheme.onSurfaceVariant,
                      fontFeatures: const [FontFeature.tabularFigures()],
                    ),
              ),
          ],
        ),
        const SizedBox(height: 8),
        total == null
            ? const LinearProgressIndicator(minHeight: 6)
            : ClipRRect(
                borderRadius: BorderRadius.circular(999),
                child: LinearProgressIndicator(
                  minHeight: 6,
                  value: total <= 0 ? null : received / total,
                ),
              ),
      ],
    );
  }
}

/// 关于分区。
class AboutSection extends StatelessWidget {
  const AboutSection({super.key, required this.app});

  final AppStore app;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final scheme = Theme.of(context).colorScheme;
    return SettingsSectionCard(
      key: const ValueKey('sec-about'),
      icon: Icons.info_outline,
      title: l10n.settingsSecAbout,
      subtitle: l10n.settingsSecAboutSub,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 12),
          child: Row(
            children: [
              Container(
                width: 48,
                height: 48,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(14),
                  color: scheme.primary,
                ),
                child: const Icon(Icons.schedule_outlined,
                    color: Colors.white, size: 26),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('TimeTrack',
                        style: Theme.of(context)
                            .textTheme
                            .titleSmall
                            ?.copyWith(fontWeight: FontWeight.w700)),
                    const SizedBox(height: 2),
                    Text(
                      l10n.settingsAboutTagline,
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                            color: scheme.onSurfaceVariant,
                          ),
                    ),
                  ],
                ),
              ),
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(999),
                  color: scheme.surfaceContainerHighest.withValues(alpha: 0.5),
                ),
                child: Text(
                  'v${app.currentVersion}',
                  style: Theme.of(context).textTheme.labelSmall?.copyWith(
                        fontFeatures: const [FontFeature.tabularFigures()],
                        fontWeight: FontWeight.w600,
                      ),
                ),
              ),
            ],
          ),
        ),
        SettingsRow(
          title: l10n.settingsAboutVersion,
          subtitle: 'v${app.currentVersion}',
          trailing: OutlinedButton(
            onPressed: () {
              // 跳更新卡（滚动锚点由设置页骨架处理）；检查经指令通道。
              app.dispatcher
                  .dispatch(CommandInvocation(name: 'update_check'));
            },
            child: Text(l10n.settingsAboutCheckUpdate),
          ),
        ),
        SettingsRow(
          title: l10n.settingsAboutOpenSource,
          subtitle: l10n.settingsAboutOpenSourceHint,
          trailing: const Icon(Icons.open_in_new,
              size: 16, color: Color(0xFF6366F1)),
        ),
        SettingsRow(
          title: l10n.settingsAboutLicense,
          subtitle: l10n.settingsAboutLicenseHint,
          trailing: const Text('MIT'),
        ),
      ],
    );
  }
}
