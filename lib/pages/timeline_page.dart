import 'package:flutter/material.dart';

import '../l10n/app_localizations.dart';

/// 时间线页（批次 1 占位：标题 + 占位文案；批次 3 替换为真实实现）。
class TimelinePage extends StatelessWidget {
  const TimelinePage({super.key});

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final textTheme = Theme.of(context).textTheme;
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Text(l10n.navTimeline, style: textTheme.headlineSmall),
          const SizedBox(height: 8),
          Text(
            l10n.pagePlaceholder,
            style: textTheme.bodySmall?.copyWith(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }
}