/// 设置分区实现 ②：云同步（登录/登出/摘要/立即同步）+ AI 配置二期占位。
library;

import 'package:flutter/material.dart';

import '../l10n/app_localizations.dart';
import '../utils/result.dart';
import '../viewmodels/commands/command_invocation.dart';
import '../stores/app_store.dart';
import 'settings_widgets.dart';

/// 云同步分区。
class SyncSection extends StatelessWidget {
  const SyncSection({super.key, required this.app});

  final AppStore app;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return ListenableBuilder(
      listenable: app.sync,
      builder: (context, _) {
        final sync = app.sync;
        return SettingsSectionCard(
          key: const ValueKey('sec-sync'),
          icon: Icons.cloud_outlined,
          title: l10n.settingsSecSync,
          subtitle: l10n.settingsSecSyncSub,
          paddedChildren: true,
          children: [
            _SyncStatusCard(app: app),
            const SizedBox(height: 12),
            _SyncSummaryGrid(app: app),
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                FilledButton.icon(
                  onPressed: sync.isConfigured && !sync.syncing
                      ? () => _syncNow(context)
                      : null,
                  icon: sync.syncing
                      ? const SizedBox(
                          width: 14,
                          height: 14,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.sync, size: 16),
                  label: Text(l10n.settingsSyncNow),
                ),
                if (sync.userId != null)
                  OutlinedButton.icon(
                    onPressed: () => _signOut(context),
                    icon: const Icon(Icons.logout, size: 16),
                    label: Text(l10n.settingsSyncSignOut),
                  ),
                // 未配置/未登录：登录入口。
                if (sync.isConfigured && sync.userId == null)
                  OutlinedButton.icon(
                    onPressed: () => _openLoginDialog(context, app),
                    icon: const Icon(Icons.login, size: 16),
                    label: Text(l10n.settingsLoginTitle),
                  ),
              ],
            ),
          ],
        );
      },
    );
  }

  Future<void> _syncNow(BuildContext context) async {
    // 经指令通道（铁律 7）：'sync' 指令已注册——与深链/AI/未来快捷键同入口。
    final result =
        await app.dispatcher.dispatch(CommandInvocation(name: 'sync'));
    if (!context.mounted) return;
    final l10n = AppLocalizations.of(context)!;
    final messenger = ScaffoldMessenger.of(context);
    messenger.hideCurrentSnackBar();
    if (result case CommandFailure failure) {
      messenger.showSnackBar(
        SnackBar(content: Text(l10n.settingsSyncFailed(failure.reason))),
      );
    }
  }

  Future<void> _signOut(BuildContext context) async {
    final result = await app.sync.signOut();
    if (!context.mounted) return;
    final l10n = AppLocalizations.of(context)!;
    if (result.isSuccess) {
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(content: Text(l10n.settingsSignedOut)));
    }
  }
}

class _SyncStatusCard extends StatelessWidget {
  const _SyncStatusCard({required this.app});

  final AppStore app;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final scheme = Theme.of(context).colorScheme;
    final sync = app.sync;
    final configured = sync.isConfigured;
    final loggedIn = sync.userId != null;
    final online = configured && !sync.syncing;
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: scheme.outlineVariant.withValues(alpha: 0.6)),
      ),
      child: Row(
        children: [
          Container(
            width: 40,
            height: 40,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: scheme.primary.withValues(alpha: 0.1),
            ),
            child: Icon(
              configured ? Icons.cloud_outlined : Icons.cloud_off_outlined,
              size: 20,
              color: scheme.primary,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  configured
                      ? l10n.settingsSyncConfigured
                      : l10n.settingsSyncNotConfigured,
                  style: Theme.of(context)
                      .textTheme
                      .bodyMedium
                      ?.copyWith(fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: 2),
                Text(
                  !configured
                      ? l10n.settingsSyncNotConfiguredHint
                      : loggedIn
                          ? l10n.settingsSyncLoggedInAs(
                              sync.userId ?? '')
                          : l10n.settingsSyncNotLoggedIn,
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: scheme.onSurfaceVariant,
                      ),
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          _StatusDot(
            label: configured ? l10n.settingsSyncOnline : l10n.settingsSyncOffline,
            active: online,
          ),
        ],
      ),
    );
  }
}

class _StatusDot extends StatelessWidget {
  const _StatusDot({required this.label, required this.active});

  final String label;
  final bool active;

  @override
  Widget build(BuildContext context) {
    final color = active ? const Color(0xFF10B981) : const Color(0xFF9CA3AF);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(999),
        color: color.withValues(alpha: 0.12),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 6,
            height: 6,
            decoration: BoxDecoration(shape: BoxShape.circle, color: color),
          ),
          const SizedBox(width: 6),
          Text(
            label,
            style: Theme.of(context).textTheme.labelSmall?.copyWith(
                  color: color,
                  fontWeight: FontWeight.w600,
                ),
          ),
        ],
      ),
    );
  }
}

class _SyncSummaryGrid extends StatelessWidget {
  const _SyncSummaryGrid({required this.app});

  final AppStore app;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final sync = app.sync;
    final lastAt = sync.lastSyncAt;
    final lastText = lastAt == null
        ? l10n.settingsSyncNever
        : DateTime.now().difference(lastAt) < const Duration(minutes: 1)
            ? l10n.settingsSyncJustNow
            : '${lastAt.difference(DateTime.now()).inMinutes.abs()} min';
    final pulled = sync.lastPulled;
    final pushed = sync.lastPushed;
    return Row(
      children: [
        Expanded(
          child: _SummaryCell(
              label: l10n.settingsSyncLastAt, value: lastText),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: _SummaryCell(
            label: '↓',
            value: pulled == null ? '—' : l10n.settingsSyncPulled(pulled),
          ),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: _SummaryCell(
            label: '↑',
            value: pushed == null ? '—' : l10n.settingsSyncPushed(pushed),
          ),
        ),
      ],
    );
  }
}

class _SummaryCell extends StatelessWidget {
  const _SummaryCell({required this.label, required this.value});

  final String label;
  final String value;

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
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  fontWeight: FontWeight.w600,
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
            overflow: TextOverflow.ellipsis,
          ),
        ],
      ),
    );
  }
}

/// 登录对话框：magic link 邮箱 → 验证码 OTP（加载/失败态）。
Future<void> _openLoginDialog(BuildContext context, AppStore app) async {
  await showDialog<void>(
    context: context,
    builder: (dialogContext) => _LoginDialog(app: app),
  );
}

class _LoginDialog extends StatefulWidget {
  const _LoginDialog({required this.app});

  final AppStore app;

  @override
  State<_LoginDialog> createState() => _LoginDialogState();
}

class _LoginDialogState extends State<_LoginDialog> {
  final _emailController = TextEditingController();
  final _codeController = TextEditingController();
  bool _sending = false;
  bool _verifying = false;
  bool _codeSent = false;
  String? _error;

  @override
  void dispose() {
    _emailController.dispose();
    _codeController.dispose();
    super.dispose();
  }

  Future<void> _sendCode() async {
    final email = _emailController.text.trim();
    if (email.isEmpty || !email.contains('@')) {
      setState(() => _error = 'email');
      return;
    }
    setState(() {
      _sending = true;
      _error = null;
    });
    final result = await widget.app.sync.sendMagicLink(email);
    if (!mounted) return;
    setState(() {
      _sending = false;
      switch (result) {
        case AppSuccess<void>():
          _codeSent = true;
          _error = null;
        case AppFailure<void> failure:
          _error = failure.message;
      }
    });
  }

  Future<void> _verify() async {
    final email = _emailController.text.trim();
    final code = _codeController.text.trim();
    if (code.length != 6) {
      setState(() => _error = 'code');
      return;
    }
    setState(() {
      _verifying = true;
      _error = null;
    });
    final result = await widget.app.sync.verifyEmailOtp(email, code);
    if (!mounted) return;
    switch (result) {
      case AppSuccess<String>():
        if (mounted) Navigator.of(context).pop();
        return;
      case AppFailure<String> failure:
        setState(() {
          _verifying = false;
          _error = failure.message;
        });
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final scheme = Theme.of(context).colorScheme;
    return AlertDialog(
      title: Text(l10n.settingsLoginTitle),
      content: SizedBox(
        width: 380,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              l10n.settingsLoginSubtitle,
              style: Theme.of(context)
                  .textTheme
                  .bodySmall
                  ?.copyWith(color: scheme.onSurfaceVariant),
            ),
            const SizedBox(height: 16),
            TextField(
              key: const ValueKey('login-email'),
              controller: _emailController,
              keyboardType: TextInputType.emailAddress,
              decoration: InputDecoration(
                labelText: l10n.settingsLoginEmail,
                border: const OutlineInputBorder(),
                isDense: true,
              ),
              enabled: !_codeSent,
            ),
            if (!_codeSent) ...[
              const SizedBox(height: 14),
              SizedBox(
                width: double.infinity,
                child: FilledButton(
                  onPressed: _sending ? null : _sendCode,
                  child: _sending
                      ? const SizedBox(
                          width: 14,
                          height: 14,
                          child:
                              CircularProgressIndicator(strokeWidth: 2),
                        )
                      : Text(l10n.settingsLoginSendCode),
                ),
              ),
            ],
            if (_codeSent) ...[
              const SizedBox(height: 14),
              Text(
                l10n.settingsLoginCodeSent,
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: const Color(0xFF10B981),
                    ),
              ),
              const SizedBox(height: 10),
              TextField(
                key: const ValueKey('login-code'),
                controller: _codeController,
                keyboardType: TextInputType.number,
                maxLength: 6,
                decoration: InputDecoration(
                  labelText: l10n.settingsLoginCode,
                  border: const OutlineInputBorder(),
                  isDense: true,
                  counterText: '',
                ),
              ),
              const SizedBox(height: 14),
              SizedBox(
                width: double.infinity,
                child: FilledButton(
                  onPressed: _verifying ? null : _verify,
                  child: _verifying
                      ? const SizedBox(
                          width: 14,
                          height: 14,
                          child:
                              CircularProgressIndicator(strokeWidth: 2),
                        )
                      : Text(l10n.settingsLoginVerify),
                ),
              ),
            ],
            if (_error != null && _error != 'email' && _error != 'code') ...[
              const SizedBox(height: 12),
              Container(
                width: double.infinity,
                padding:
                    const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(8),
                  color: scheme.error.withValues(alpha: 0.08),
                ),
                child: Row(
                  children: [
                    Icon(Icons.error_outline,
                        size: 14, color: scheme.error),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        l10n.settingsLoginFailed(_error!),
                        style: Theme.of(context)
                            .textTheme
                            .bodySmall
                            ?.copyWith(color: scheme.error),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(l10n.settingsLoginCancel),
        ),
      ],
    );
  }
}

/// AI 配置分区（二期占位——契约 §4.5：一期仅预留入口位）。
class AiSection extends StatelessWidget {
  const AiSection({super.key});

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return SettingsSectionCard(
      key: const ValueKey('sec-ai'),
      icon: Icons.auto_awesome_outlined,
      title: l10n.settingsSecAi,
      subtitle: l10n.settingsSecAiSub,
      badge: l10n.settingsAiBadge,
      paddedChildren: true,
      children: [
        SettingsInfoBanner(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(Icons.schedule_outlined,
                  size: 16, color: Theme.of(context).colorScheme.onSurfaceVariant),
              const SizedBox(width: 8),
              Expanded(child: Text(l10n.settingsAiPhase2Note)),
            ],
          ),
        ),
      ],
    );
  }
}
