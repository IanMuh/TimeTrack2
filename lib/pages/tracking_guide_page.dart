/// 后台记录授权引导页（批次 6b，契约 §6.3）：Android 首次进入后台记录
/// 分区且未授予"使用情况访问"时的全屏说明页。
///
/// 内容：为何需要 + 隐私承诺（不读屏幕内容）+ 去系统设置开启 / 暂不开启。
/// 「不反复纠缠」语义由 [AndroidTrackingBridge.guideDismissedThisSession]
/// 会话标志承载——本会话内选择"暂不开启"后不再自动弹出，可稍后在
/// 设置 → 后台记录 手动再启。
library;

import 'dart:async';

import 'package:flutter/material.dart';

import '../api/platform/android_tracking.dart';
import '../l10n/app_localizations.dart';

/// 全屏引导页。
class TrackingGuidePage extends StatelessWidget {
  const TrackingGuidePage({super.key, required this.bridge});

  final AndroidTrackingBridge bridge;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      key: const ValueKey('usage-guide-page'),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const SizedBox(height: 48),
              Container(
                width: 64,
                height: 64,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: scheme.primary.withValues(alpha: 0.1),
                ),
                alignment: Alignment.center,
                child: Icon(Icons.visibility_outlined,
                    size: 32, color: scheme.primary),
              ),
              const SizedBox(height: 20),
              Text(
                l10n.settingsSecBackground,
                textAlign: TextAlign.center,
                style: Theme.of(context)
                    .textTheme
                    .headlineSmall
                    ?.copyWith(fontWeight: FontWeight.w600),
              ),
              const SizedBox(height: 6),
              Text(
                l10n.usageAccessGuide,
                textAlign: TextAlign.center,
                style: Theme.of(context)
                    .textTheme
                    .bodyMedium
                    ?.copyWith(color: scheme.onSurfaceVariant),
              ),
              const SizedBox(height: 28),
              _SectionHeading(text: l10n.bgGuideWhy),
              const SizedBox(height: 6),
              Text(l10n.bgGuideWhyBody),
              const SizedBox(height: 18),
              Container(
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(12),
                  color:
                      scheme.primaryContainer.withValues(alpha: 0.35),
                ),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(Icons.lock_outline,
                        size: 18, color: scheme.primary),
                    const SizedBox(width: 10),
                    Expanded(child: Text(l10n.bgGuidePrivacy)),
                  ],
                ),
              ),
              const Spacer(),
              FilledButton.icon(
                key: const ValueKey('guide-open-settings'),
                onPressed: () {
                  bridge.openUsageAccessSettings();
                  // 顺手请求通知权限（前台服务常驻通知可见性，API 33+）。
                  unawaited(bridge.requestNotificationPermission());
                },
                icon: const Icon(Icons.settings_outlined, size: 18),
                label: Text(l10n.usageAccessButton),
              ),
              const SizedBox(height: 8),
              Text(
                l10n.bgGuideNote,
                textAlign: TextAlign.center,
                style: Theme.of(context)
                    .textTheme
                    .bodySmall
                    ?.copyWith(color: scheme.onSurfaceVariant),
              ),
              const SizedBox(height: 10),
              TextButton(
                key: const ValueKey('guide-later'),
                onPressed: () => Navigator.of(context).pop(),
                child: Text(l10n.usageAccessLater),
              ),
              const SizedBox(height: 16),
            ],
          ),
        ),
      ),
    );
  }
}

class _SectionHeading extends StatelessWidget {
  const _SectionHeading({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    return Text(
      text,
      style: Theme.of(context)
          .textTheme
          .titleSmall
          ?.copyWith(fontWeight: FontWeight.w600),
    );
  }
}
