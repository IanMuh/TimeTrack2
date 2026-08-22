import 'package:flutter/material.dart';

import '../l10n/app_localizations.dart';

/// 页面三态组件（各页"加载 / 空 / 错误"统一呈现，纯参数注入无业务）。
///
/// 三态的结构（图标 + 标题 + 说明 + 可选动作）在所有页面一致，页面仅注入
/// 文案与回调；错误态的重试与空态的主按钮语义由调用方（页/壳）决定。

/// 加载态：骨架卡片 + 加载文案。
class LoadingStateView extends StatelessWidget {
  const LoadingStateView({super.key, this.message});

  final String? message;

  @override
  Widget build(BuildContext context) {
    final muted = Theme.of(context).colorScheme.surfaceContainerHighest;
    final l10n = AppLocalizations.of(context)!;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final height in const [64.0, 48.0, 48.0]) ...[
          Container(
            height: height,
            decoration: BoxDecoration(
              color: muted,
              borderRadius: BorderRadius.circular(16),
            ),
          ),
          const SizedBox(height: 12),
        ],
        const SizedBox(height: 8),
        Center(
          child: Text(
            message ?? l10n.loading,
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ),
      ],
    );
  }
}

/// 空态：引导性提示 + 可选主按钮（如"开始记录吧"）。
class EmptyStateView extends StatelessWidget {
  const EmptyStateView({
    super.key,
    required this.icon,
    required this.title,
    this.message,
    this.actionLabel,
    this.onAction,
  });

  final IconData icon;
  final String title;
  final String? message;
  final String? actionLabel;
  final VoidCallback? onAction;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 48, horizontal: 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 40, color: theme.colorScheme.onSurfaceVariant),
            const SizedBox(height: 12),
            Text(
              title,
              style: theme.textTheme.titleMedium?.merge(
                const TextStyle(fontWeight: FontWeight.w600),
              ),
              textAlign: TextAlign.center,
            ),
            if (message != null) ...[
              const SizedBox(height: 6),
              Text(
                message!,
                style: theme.textTheme.bodySmall?.merge(
                  TextStyle(color: theme.colorScheme.onSurfaceVariant),
                ),
                textAlign: TextAlign.center,
              ),
            ],
            if (actionLabel != null && onAction != null) ...[
              const SizedBox(height: 20),
              FilledButton(onPressed: onAction, child: Text(actionLabel!)),
            ],
          ],
        ),
      ),
    );
  }
}

/// 错误态：页面级错误 + 重试（错误呈现为卡内样式，不弹全局提示）。
class ErrorStateView extends StatelessWidget {
  const ErrorStateView({
    super.key,
    required this.message,
    this.title,
    this.retryLabel,
    this.onRetry,
  });

  final String? title;
  final String message;
  final String? retryLabel;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l10n = AppLocalizations.of(context)!;
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 48, horizontal: 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.error_outline,
              size: 40,
              color: theme.colorScheme.error,
            ),
            const SizedBox(height: 12),
            Text(
              title ?? l10n.errorTitle,
              style: theme.textTheme.titleMedium?.merge(
                const TextStyle(fontWeight: FontWeight.w600),
              ),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 6),
            Text(
              message,
              style: theme.textTheme.bodySmall?.merge(
                TextStyle(color: theme.colorScheme.onSurfaceVariant),
              ),
              textAlign: TextAlign.center,
            ),
            if (onRetry != null) ...[
              const SizedBox(height: 20),
              OutlinedButton(
                onPressed: onRetry,
                child: Text(retryLabel ?? l10n.retry),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
