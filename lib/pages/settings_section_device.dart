/// 设置分区实现 ④：备份与导出（含清除全部数据危险区）+ 设备互通
///（LAN 主机/客户端/文件互通，契约 §4.5）。
///
/// 导出/导入走指令通道（export/import——铁律 7，dispatcher 内处理设备 id
/// 与 file_selector 对话框）；清除数据走 DataWipeService（UI 强制先备份
/// 提示 + 清后驱动全 store reload）。
library;

import 'package:flutter/material.dart';

import '../l10n/app_localizations.dart';
import '../stores/app_store.dart';
import '../stores/lan_store.dart';
import '../utils/result.dart';
import '../viewmodels/commands/command_invocation.dart';
import 'settings_widgets.dart';

/// 备份与导出分区。
class BackupSection extends StatelessWidget {
  const BackupSection({super.key, required this.app});

  final AppStore app;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return SettingsSectionCard(
      key: const ValueKey('sec-backup'),
      icon: Icons.backup_outlined,
      title: l10n.settingsSecBackup,
      subtitle: l10n.settingsSecBackupSub,
      children: [
        SettingsRow(
          title: l10n.settingsExport,
          subtitle: l10n.settingsExportHint,
          trailing: OutlinedButton.icon(
            key: const ValueKey('backup-export'),
            onPressed: () => _export(context),
            icon: const Icon(Icons.download, size: 16),
            label: Text(l10n.settingsExportBtn),
          ),
        ),
        SettingsRow(
          title: l10n.settingsImport,
          subtitle: l10n.settingsImportHint,
          trailing: OutlinedButton.icon(
            key: const ValueKey('backup-import'),
            onPressed: () => _import(context),
            icon: const Icon(Icons.upload, size: 16),
            label: Text(l10n.settingsImportBtn),
          ),
        ),
        SettingsDangerCard(
          title: l10n.settingsDangerTitle,
          message: l10n.settingsDangerMessage,
          actionLabel: l10n.settingsDangerBtn,
          onAction: () => _confirmWipe(context),
        ),
      ],
    );
  }

  Future<void> _export(BuildContext context) async {
    final l10n = AppLocalizations.of(context)!;
    final result = await app.dispatcher
        .dispatch(CommandInvocation(name: 'export'));
    if (!context.mounted) return;
    final messenger = ScaffoldMessenger.of(context)..hideCurrentSnackBar();
    switch (result) {
      case CommandSuccess success:
        messenger.showSnackBar(
          SnackBar(
            content:
                Text(l10n.settingsExportDone(success.message ?? '')),
          ),
        );
      case CommandFailure failure:
        // 用户取消文件对话框等非错误路径不弹失败条。
        if (!failure.reason.contains('未选择')) {
          messenger.showSnackBar(
            SnackBar(content: Text(l10n.settingsOpFailed(failure.reason))),
          );
        }
    }
  }

  Future<void> _import(BuildContext context) async {
    final l10n = AppLocalizations.of(context)!;
    final result = await app.dispatcher
        .dispatch(CommandInvocation(name: 'import'));
    if (!context.mounted) return;
    final messenger = ScaffoldMessenger.of(context)..hideCurrentSnackBar();
    switch (result) {
      case CommandSuccess success:
        final count = int.tryParse(
                RegExp(r'\d+').stringMatch(success.message ?? '') ?? '') ??
            0;
        messenger.showSnackBar(
          SnackBar(content: Text(l10n.settingsImportDone(count))),
        );
      case CommandFailure failure:
        if (!failure.reason.contains('未选择')) {
          messenger.showSnackBar(
            SnackBar(content: Text(l10n.settingsOpFailed(failure.reason))),
          );
        }
    }
  }

  /// 清除前强制提示先导出备份（契约硬约束）。
  Future<void> _confirmWipe(BuildContext context) async {
    final l10n = AppLocalizations.of(context)!;
    final action = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        key: const ValueKey('wipe-dialog'),
        icon: Icon(Icons.warning_amber_rounded,
            color: Theme.of(context).colorScheme.error),
        title: Text(l10n.settingsWipeDialogTitle),
        content: Text(l10n.settingsWipeDialogBody),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop('cancel'),
            child: Text(l10n.settingsWipeCancel),
          ),
          OutlinedButton(
            key: const ValueKey('wipe-export-first'),
            onPressed: () => Navigator.of(dialogContext).pop('export'),
            child: Text(l10n.settingsWipeExportFirst),
          ),
          FilledButton(
            key: const ValueKey('wipe-confirm'),
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(dialogContext).colorScheme.error,
            ),
            onPressed: () => Navigator.of(dialogContext).pop('wipe'),
            child: Text(l10n.settingsWipeConfirm),
          ),
        ],
      ),
    );
    if (!context.mounted) return;
    switch (action) {
      case 'export':
        await _export(context);
      case 'wipe':
        await _wipe(context);
      default:
        break;
    }
  }

  Future<void> _wipe(BuildContext context) async {
    final l10n = AppLocalizations.of(context)!;
    final result = await app.wipe.wipeAll();
    if (!context.mounted) return;
    final messenger = ScaffoldMessenger.of(context)..hideCurrentSnackBar();
    if (result case AppFailure<int> _) {
      messenger.showSnackBar(
        SnackBar(content: Text(l10n.settingsWipeFailed)),
      );
      return;
    }
    // 全量重载：数据已空，各 store 缓存必须失效（含 seed 默认活动重建）。
    await app.activities.seedActivities();
    await app.category.reload();
    await app.settings.reload();
    await app.today.loadToday();
    await app.timer.refresh();
    await app.tracking.reloadRules();
    await app.lan.reloadPeer(); // sync_peers 已清空，内存配对态同步失效
    // 时间线/统计页监听 dataRevision 自动失效缓存（bump 即全页一致）。
    app.dataRevision.bump();
    // 撤销/重做历史指向已物理删除的数据——清空防"可撤销"语义失真。
    app.undo.clear();
    if (!context.mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(l10n.settingsWipeDone)));
  }
}

/// 设备互通分区。
class DeviceSection extends StatefulWidget {
  const DeviceSection({super.key, required this.app});

  final AppStore app;

  @override
  State<DeviceSection> createState() => _DeviceSectionState();
}

class _DeviceSectionState extends State<DeviceSection> {
  final _hostController = TextEditingController();
  final _codeController = TextEditingController();

  @override
  void initState() {
    super.initState();
    widget.app.lan.reloadPeer();
  }

  @override
  void dispose() {
    _hostController.dispose();
    _codeController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final app = widget.app;
    return ListenableBuilder(
      listenable: app.lan,
      builder: (context, _) {
        final lan = app.lan;
        return SettingsSectionCard(
          key: const ValueKey('sec-device'),
          icon: Icons.devices_outlined,
          title: l10n.settingsSecDevice,
          subtitle: l10n.settingsSecDeviceSub,
          paddedChildren: true,
          children: [
            _LanHostCard(lan: lan),
            const SizedBox(height: 14),
            _LanClientCard(
              lan: lan,
              hostController: _hostController,
              codeController: _codeController,
            ),
            const SizedBox(height: 14),
            // 文件互通（同备份区导出/导入——经同一指令通道）。
            Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(l10n.settingsLanFileInterop,
                          style: Theme.of(context).textTheme.bodyMedium),
                      const SizedBox(height: 2),
                      Text(
                        l10n.settingsLanFileInteropHint,
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                              color:
                                  Theme.of(context).colorScheme.onSurfaceVariant,
                            ),
                      ),
                    ],
                  ),
                ),
                OutlinedButton.icon(
                  onPressed: () => _export(context),
                  icon: const Icon(Icons.file_download_outlined, size: 16),
                  label: Text(l10n.settingsExportBtn),
                ),
                const SizedBox(width: 8),
                OutlinedButton.icon(
                  onPressed: () => _import(context),
                  icon: const Icon(Icons.file_upload_outlined, size: 16),
                  label: Text(l10n.settingsImportBtn),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Icon(Icons.info_outline,
                    size: 14,
                    color: Theme.of(context).colorScheme.onSurfaceVariant),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    l10n.settingsLanManualOnly,
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color:
                              Theme.of(context).colorScheme.onSurfaceVariant,
                        ),
                  ),
                ),
              ],
            ),
            if (lan.lastError != null) ...[
              const SizedBox(height: 8),
              Text(
                lan.lastError!,
                style: TextStyle(
                  color: Theme.of(context).colorScheme.error,
                  fontSize: 12,
                ),
              ),
            ],
          ],
        );
      },
    );
  }

  Future<void> _export(BuildContext context) async {
    final l10n = AppLocalizations.of(context)!;
    final result = await widget.app.dispatcher
        .dispatch(CommandInvocation(name: 'export'));
    if (!context.mounted) return;
    if (result case CommandSuccess success) {
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(
          SnackBar(content: Text(l10n.settingsExportDone(success.message ?? ''))),
        );
    }
  }

  Future<void> _import(BuildContext context) async {
    final l10n = AppLocalizations.of(context)!;
    final result = await widget.app.dispatcher
        .dispatch(CommandInvocation(name: 'import'));
    if (!context.mounted) return;
    if (result case CommandSuccess success) {
      final count =
          int.tryParse(RegExp(r'\d+').stringMatch(success.message ?? '') ?? '') ?? 0;
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(content: Text(l10n.settingsImportDone(count))));
    }
  }
}

/// LAN 主机卡。
class _LanHostCard extends StatelessWidget {
  const _LanHostCard({required this.lan});

  final LanStore lan;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final scheme = Theme.of(context).colorScheme;
    final running = lan.hostRunning;
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: scheme.outlineVariant.withValues(alpha: 0.6)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 32,
                height: 32,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(8),
                  color: scheme.primary.withValues(alpha: 0.1),
                ),
                child: Icon(Icons.dns_outlined,
                    size: 16, color: scheme.primary),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(l10n.settingsLanHost,
                        style: Theme.of(context)
                            .textTheme
                            .bodyMedium
                            ?.copyWith(fontWeight: FontWeight.w600)),
                    const SizedBox(height: 2),
                    Text(
                      l10n.settingsLanHostHint,
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
                  color: running
                      ? const Color(0xFF10B981).withValues(alpha: 0.12)
                      : scheme.surfaceContainerHighest.withValues(alpha: 0.5),
                ),
                child: Text(
                  running ? l10n.settingsLanRunning : l10n.settingsLanStopped,
                  style: Theme.of(context).textTheme.labelSmall?.copyWith(
                        color: running
                            ? const Color(0xFF059669)
                            : scheme.onSurfaceVariant,
                        fontWeight: FontWeight.w600,
                      ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              if (!running)
                FilledButton.icon(
                  key: const ValueKey('lan-start'),
                  onPressed: lan.hostBusy ? null : lan.startHost,
                  icon: lan.hostBusy
                      ? const SizedBox(
                          width: 14,
                          height: 14,
                          child:
                              CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.play_arrow, size: 16),
                  label: Text(l10n.settingsLanStart),
                )
              else ...[
                OutlinedButton.icon(
                  key: const ValueKey('lan-stop'),
                  onPressed: lan.hostBusy ? null : lan.stopHost,
                  icon: const Icon(Icons.stop, size: 16),
                  label: Text(l10n.settingsLanStop),
                ),
              ],
            ],
          ),
          if (running) ...[
            const SizedBox(height: 12),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(8),
                color: scheme.surfaceContainerHighest.withValues(alpha: 0.35),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Icon(Icons.link, size: 14, color: SettingsSky.dark),
                      const SizedBox(width: 6),
                      Text('${l10n.settingsLanPort} ${lan.hostPort}'),
                      const SizedBox(width: 16),
                      Icon(Icons.key_outlined,
                          size: 14, color: Colors.amber.shade700),
                      const SizedBox(width: 6),
                      Text(
                        lan.pairingCode ?? '—',
                        style: const TextStyle(
                          fontFeatures: [FontFeature.tabularFigures()],
                          letterSpacing: 2,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 4),
                  Text(
                    l10n.settingsLanCodeOnce,
                    style: Theme.of(context).textTheme.labelSmall?.copyWith(
                          color: scheme.onSurfaceVariant,
                        ),
                  ),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// LAN 客户端卡。
class _LanClientCard extends StatelessWidget {
  const _LanClientCard({
    required this.lan,
    required this.hostController,
    required this.codeController,
  });

  final LanStore lan;
  final TextEditingController hostController;
  final TextEditingController codeController;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final scheme = Theme.of(context).colorScheme;
    final peer = lan.clientPeer;
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: scheme.outlineVariant.withValues(alpha: 0.6)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 32,
                height: 32,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(8),
                  color: scheme.primary.withValues(alpha: 0.1),
                ),
                child: Icon(Icons.smartphone_outlined,
                    size: 16, color: scheme.primary),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(l10n.settingsLanClient,
                        style: Theme.of(context)
                            .textTheme
                            .bodyMedium
                            ?.copyWith(fontWeight: FontWeight.w600)),
                    const SizedBox(height: 2),
                    Text(
                      peer != null
                          ? l10n.settingsLanPairedAs(peer.displayName)
                          : l10n.settingsLanClientHint,
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                            color: scheme.onSurfaceVariant,
                          ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              SizedBox(
                width: 260,
                child: TextField(
                  key: const ValueKey('lan-host-input'),
                  controller: hostController,
                  decoration: InputDecoration(
                    isDense: true,
                    border: const OutlineInputBorder(),
                    labelText: l10n.settingsLanHostInput,
                  ),
                ),
              ),
              SizedBox(
                width: 150,
                child: TextField(
                  key: const ValueKey('lan-code-input'),
                  controller: codeController,
                  keyboardType: TextInputType.number,
                  maxLength: 6,
                  decoration: InputDecoration(
                    isDense: true,
                    border: const OutlineInputBorder(),
                    labelText: l10n.settingsLanCodeInput,
                    counterText: '',
                  ),
                ),
              ),
              FilledButton(
                key: const ValueKey('lan-pair'),
                onPressed: lan.clientBusy ? null : _pair,
                child: lan.clientBusy
                    ? const SizedBox(
                        width: 14,
                        height: 14,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : Text(l10n.settingsLanPair),
              ),
              if (peer != null)
                OutlinedButton(
                  onPressed: lan.clientBusy ? null : lan.syncClient,
                  child: Text(l10n.settingsLanSyncNow),
                ),
            ],
          ),
        ],
      ),
    );
  }

  Future<void> _pair() async {
    await lan.pairClient(host: hostController.text, code: codeController.text);
  }
}
