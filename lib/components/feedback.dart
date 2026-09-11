import 'package:flutter/material.dart';

import '../l10n/app_localizations.dart';

/// 全局反馈载体（契约 §5.2 决策规则的"载体"实现；语义分配到壳/页调用方）。
///
/// - 不可逆/二选一决策 → [showAppConfirmationDialog]（对话框）
/// - 纯通知 → [showAppSnackBar]（浮动、单条、可带动作）
/// - 常驻提醒 → [AppBanner]（横幅）

/// 浮动 Snackbar：单条通知，可带动作（如"撤销"）与错误态前缀图标。
void showAppSnackBar(
  BuildContext context, {
  required String message,
  String? actionLabel,
  VoidCallback? onAction,
  bool isError = false,
}) {
  final messenger = ScaffoldMessenger.of(context);
  messenger.clearSnackBars();
  messenger.showSnackBar(
    SnackBar(
      behavior: SnackBarBehavior.floating,
      elevation: 4,
      content: Row(
        children: [
          if (isError) ...[
            // Snackbar 固定深底，错误图标用亮红（red-300）保对比。
            const Icon(Icons.error_outline, size: 18, color: Color(0xfffca5a5)),
            const SizedBox(width: 8),
          ],
          Expanded(child: Text(message)),
        ],
      ),
      action: actionLabel != null && onAction != null
          ? SnackBarAction(label: actionLabel, onPressed: onAction)
          : null,
    ),
  );
}

/// 常驻提醒横幅（三类型：info / warning / error），可关闭。
class AppBanner extends StatelessWidget {
  const AppBanner({
    super.key,
    required this.type,
    required this.title,
    this.message,
    this.actionLabel,
    this.onAction,
    this.onDismiss,
  });

  final AppBannerType type;
  final String title;
  final String? message;
  final String? actionLabel;
  final VoidCallback? onAction;
  final VoidCallback? onDismiss;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final scheme = Theme.of(context).colorScheme;
    final color = switch (type) {
      AppBannerType.info => const Color(0xff0ea5e9), // sky-500
      AppBannerType.warning => const Color(0xfff59e0b), // amber-500
      AppBannerType.error => scheme.error,
    };
    final icon = switch (type) {
      AppBannerType.info => Icons.info_outline,
      AppBannerType.warning => Icons.warning_amber_rounded,
      AppBannerType.error => Icons.error_outline,
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: color.withValues(alpha: Theme.of(context).brightness == Brightness.dark ? 0.14 : 0.08),
        borderRadius: BorderRadius.circular(12),
        border: Border(left: BorderSide(color: color, width: 4)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 18, color: color),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: scheme.onSurface,
                  ),
                ),
                if (message != null) ...[
                  const SizedBox(height: 2),
                  Text(
                    message!,
                    style: TextStyle(
                      fontSize: 12.5,
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                ],
                if (actionLabel != null && onAction != null) ...[
                  const SizedBox(height: 6),
                  TextButton(
                    onPressed: onAction,
                    style: TextButton.styleFrom(
                      padding: EdgeInsets.zero,
                      minimumSize: const Size(48, 32),
                    ),
                    child: Text(actionLabel!),
                  ),
                ],
              ],
            ),
          ),
          if (onDismiss != null)
            IconButton(
              tooltip: l10n.close,
              iconSize: 16,
              visualDensity: VisualDensity.compact,
              color: scheme.onSurfaceVariant,
              onPressed: onDismiss,
              icon: const Icon(Icons.close),
            ),
        ],
      ),
    );
  }
}

enum AppBannerType { info, warning, error }

/// 确认对话框（不可逆/二选一决策的载体）：返回 true 表示确认。
///
/// 桌面居中、移动同为居中（契约 §5.2 允许对话框居中；移动抽屉形态留给
/// 底部操作类大决策在页面侧自行实现）。
Future<bool?> showAppConfirmationDialog(
  BuildContext context, {
  required String title,
  required String message,
  String? confirmLabel,
  String? cancelLabel,
  bool isDestructive = false,
}) async {
  final l10n = AppLocalizations.of(context)!;
  final scheme = Theme.of(context).colorScheme;
  return showDialog<bool>(
    context: context,
    builder: (context) {
      return AlertDialog(
        title: Text(title),
        content: Text(message),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: Text(cancelLabel ?? l10n.cancel),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(true),
            style: isDestructive
                ? TextButton.styleFrom(
                    foregroundColor: scheme.error,
                  )
                : null,
            child: Text(confirmLabel ?? l10n.ok),
          ),
        ],
      );
    },
  );
}
