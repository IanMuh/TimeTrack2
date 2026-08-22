import 'package:flutter/material.dart';

import '../l10n/app_localizations.dart';

/// 计时页（批次 1 占位：标题 + 占位文案；批次 2 替换为真实实现）。
///
/// 占位不代表空壳实现任何业务——本页不触 store、不含业务状态。
class TimerPage extends StatelessWidget {
  const TimerPage({super.key});

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final textTheme = Theme.of(context).textTheme;
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Text(l10n.navTimer, style: textTheme.headlineSmall),
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