import 'package:flutter/material.dart';

import '../l10n/app_localizations.dart';

/// 全局计时条（契约 §3.3：常驻底部，贯穿所有页面）。
///
/// **无业务状态**（契约 §8）：不 import 任何 store，全部数据/回调由宿主
/// （AppShell）注入：
/// - [isRecording] false（未运行）时弱化呈现"未在记录"占位；
/// - [isRecording] true：活动色点 + 活动名 + 等宽（tabular figures）实时计时，
///   右侧"停止 / 切换活动"按钮；活动名整块可点回计时页（[onOpenTimer]）；
/// - **紧凑档（[compact]）**：活动名不省略（FittedBox 等比收缩而非截断）、
///   计时不省略，按钮收窄（契约 §3.3）。
///
/// 切换活动选择器在批次 2 提供（当前"切换活动"禁用 + tooltip 说明原因），
/// 避免半成品选择器；停止已接线到指令通道（宿主回调）。
class GlobalTimerBar extends StatelessWidget {
  const GlobalTimerBar({
    super.key,
    this.isRecording = false,
    this.activityName,
    this.activityColor,
    this.elapsed = Duration.zero,
    this.compact = false,
    this.onStop,
    this.onSwitch,
    this.onOpenTimer,
  });

  /// 是否正在记录（宿主判定：运行条目非未分配活动）。
  final bool isRecording;

  /// 运行中活动名（isRecording 时必填）。
  final String? activityName;

  /// 运行中活动色（isRecording 时必填；快照色）。
  final Color? activityColor;

  /// 距 startedAt 的实时时长（宿主用时钟 clamp 计算）。
  final Duration elapsed;

  /// 紧凑档（<840）：按钮收窄；活动名/计时不省略。
  final bool compact;

  /// 停止当前会话（宿主经指令通道分发）。
  final VoidCallback? onStop;

  /// 切换活动（批次 2 选择器接入前禁用）。
  final VoidCallback? onSwitch;

  /// 回到计时页（契约 §3.3 入口）。
  final VoidCallback? onOpenTimer;

  static const _barHeight = 56.0; // h-14（design/DESIGN_LANG.md）

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    return Material(
      color: scheme.surface,
      child: Container(
        height: _barHeight,
        width: double.infinity,
        decoration: BoxDecoration(
          border: Border(top: BorderSide(color: scheme.outline)),
        ),
        padding: EdgeInsets.symmetric(horizontal: compact ? 12 : 20),
        child: compact
            ? (isRecording ? _buildRunning(context) : _buildIdle(context))
            : Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 1024),
                  child: isRecording
                      ? _buildRunning(context)
                      : _buildIdle(context),
                ),
              ),
      ),
    );
  }

  /// 未运行占位：弱化呈现"未在记录"（灰点 + 灰字，无操作按钮）。
  Widget _buildIdle(BuildContext context) {
    final theme = Theme.of(context);
    return Row(
      children: [
        _dot(theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.6)),
        const SizedBox(width: 8),
        Text(
          AppLocalizations.of(context)!.notRecording,
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
      ],
    );
  }

  Widget _buildRunning(BuildContext context) {
    final theme = Theme.of(context);
    final l10n = AppLocalizations.of(context)!;
    final name = activityName ?? '';
    final color = activityColor ?? const Color(0xff64748b);

    final nameBlock = InkWell(
      onTap: onOpenTimer,
      borderRadius: BorderRadius.circular(6),
      child: Tooltip(
        message: l10n.timerBarGoToTimer,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 4),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              _dot(color),
              const SizedBox(width: 8),
              // 紧凑档不省略活动名：FittedBox 等比收缩而非截断（契约 §3.3）。
              Flexible(
                child: FittedBox(
                  fit: BoxFit.scaleDown,
                  alignment: Alignment.centerLeft,
                  child: Text(
                    name,
                    maxLines: 1,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      fontWeight: FontWeight.w500,
                      color: theme.colorScheme.onSurface,
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );

    // 等宽（tabular figures）实时计时：数字不跳动（契约 §8）。
    final timeText = Text(
      _formatElapsed(elapsed),
      style: theme.textTheme.bodyMedium?.copyWith(
        fontWeight: FontWeight.w600,
        letterSpacing: -0.2,
        fontFeatures: const [FontFeature.tabularFigures()],
        color: theme.colorScheme.onSurface,
      ),
    );

    // 停止按钮：危险语义（error 色描边）。
    final stopButton = Tooltip(
      message: l10n.stopCurrentActivity,
      child: OutlinedButton(
        onPressed: onStop,
        style: OutlinedButton.styleFrom(
          foregroundColor: theme.colorScheme.error,
          side: BorderSide(
            color: theme.colorScheme.error.withValues(alpha: 0.45),
          ),
          visualDensity: VisualDensity.compact,
          minimumSize: Size(0, compact ? 30 : 34),
          padding: EdgeInsets.symmetric(horizontal: compact ? 10 : 14),
          textStyle: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
        ),
        child: Text(l10n.stop),
      ),
    );

    // 切换活动：批次 2 接入选择器；当前禁用 + tooltip 说明原因（不呈现
    // 半成品选择器）。Tooltip 包禁用按钮仍可触发（自身持有手势）。
    // 紧凑档用图标按钮：文字按钮（en "Switch activity" ≈105px）会把活动
    // 名 FittedBox 压到不可读（契约 §3.3"活动名与计时不得省略"）。
    final switchButton = Tooltip(
      message: l10n.timerBarSwitchUnavailable,
      child: compact
          ? IconButton(
              onPressed: null,
              visualDensity: VisualDensity.compact,
              icon: const Icon(Icons.cached_rounded, size: 18),
            )
          : FilledButton(
              onPressed: null,
              style: FilledButton.styleFrom(
                visualDensity: VisualDensity.compact,
                minimumSize: const Size(0, 34),
                padding: const EdgeInsets.symmetric(horizontal: 14),
                textStyle:
                    const TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(8)),
              ),
              child: Text(l10n.timerBarSwitch),
            ),
    );

    return Row(
      children: [
        // 活动名整块最大可用宽度：不挤占计时与按钮。
        Expanded(child: nameBlock),
        const SizedBox(width: 12),
        timeText,
        const SizedBox(width: 12),
        stopButton,
        const SizedBox(width: 8),
        switchButton,
      ],
    );
  }

  Widget _dot(Color color) {
    return Container(
      width: 10,
      height: 10,
      decoration: BoxDecoration(color: color, shape: BoxShape.circle),
    );
  }

  /// HH:MM:SS（100+ 小时自然溢出为 3 位小时数）；等宽由调用处 fontFeatures 保证。
  static String _formatElapsed(Duration d) {
    String two(int v) => v.toString().padLeft(2, '0');
    return '${two(d.inHours)}:${two(d.inMinutes % 60)}:${two(d.inSeconds % 60)}';
  }
}