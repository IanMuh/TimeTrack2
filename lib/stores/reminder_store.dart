/// 提醒 store（批次 5c，弹窗体系 §5.2）：ClockStore tick 驱动的两类提醒。
///
/// 触发规则（设置项见 ProfileSettings）：
/// - **运行阈值提醒**「仍在进行？」：非未分配的运行条目连续记录达到
///   `reminderMinutes` 阈值后触发，按 `reminderIntervalMinutes` 间隔重复，
///   直至用户「停止」（经 TimerStore 写路径，计入手动会话保持）或确认/
///   稍后（顺延一个间隔）。切换条目后按新条目起点重新计阈值；
/// - **触发时刻提醒**（快速提醒）：`quickReminderEnabled` 开启时，每日
///   `reminderTimeOfDayMinutes` 时刻若未在记录则提醒开始记录——每日至多
///   一次（静音方式同样消耗当日标记，视为已提醒）。
///
/// 载体由 `reminderMethod` 决定：dialog（对话框，模态）/ banner（常驻
/// 横幅，由壳层渲染）/ silent（不产生任何 UI）。同一时刻至多一条待处置
/// 提醒（运行阈值优先于快速提醒）；待处置期间不再叠加触发。
///
/// 本 store 不持有 BuildContext、不直接弹 UI：壳层监听 [active] 渲染
/// （对话框按请求 id 去重，横幅随 active 增删）。
library;

import 'dart:async';

import 'package:flutter/foundation.dart';

import '../utils/date_time_ext.dart';
import '../viewmodels/profile_settings.dart' show ReminderMethod;
import '../viewmodels/time_entry.dart';
import 'clock_store.dart';
import 'settings_store.dart';
import 'timer_store.dart';

/// 一条待处置提醒（壳层渲染依据；[id] 为展示去重键）。
sealed class ReminderRequest {
  const ReminderRequest({required this.id});

  /// 展示去重键（同 id 不重复弹对话框）。
  final String id;

  /// 提醒载体（来自 ProfileSettings.reminderMethod 触发时刻快照）。
  ReminderMethod get method;
}

/// 运行阈值提醒「仍在进行？」。
class OngoingReminder extends ReminderRequest {
  const OngoingReminder({
    required this.entryId,
    required this.activityName,
    required this.activityColor,
    required this.elapsed,
    required this.method,
    required super.id,
  });

  final String entryId;
  final String activityName;
  final int? activityColor;
  final Duration elapsed;

  @override
  final ReminderMethod method;
}

/// 触发时刻提醒（到点提醒开始记录）。
class QuickStartReminder extends ReminderRequest {
  const QuickStartReminder({required this.method, required super.id});

  @override
  final ReminderMethod method;
}

/// 提醒 store。
class ReminderStore extends ChangeNotifier {
  ReminderStore({
    required this.clock,
    required this.settings,
    required this.timer,
    required this.isUnassignedActivity,
    DateTime Function()? now,
  }) : _now = now ?? DateTime.now {
    clock.addListener(_onClockTick);
  }

  final ClockStore clock;
  final SettingsStore settings;
  final TimerStore timer;

  /// 运行条目"未分配活动"判定（ActivityRepository.activityIdIsUnassigned，
  /// AppStore 装配注入——本 store 不直接依赖活动仓储）。
  final Future<bool> Function(String activityId) isUnassignedActivity;

  final DateTime Function() _now;

  bool _disposed = false;

  /// 当前待处置提醒；null = 无。
  ReminderRequest? _active;
  ReminderRequest? get active => _active;

  /// 运行条目是否"未分配"判定缓存（activityId → 判定结果；防每 tick 查库，
  /// 与 app_shell 同款模式）。
  final Map<String, bool> _unassignedCache = {};

  // 运行阈值提醒状态（按运行条目 id 绑定）。
  String? _thresholdEntryId;
  DateTime? _thresholdNextAt;

  /// 快速提醒已触发的当日（dayStart 粒度；null = 今日未触发）。
  DateTime? _quickFiredDay;

  @override
  void dispose() {
    _disposed = true;
    clock.removeListener(_onClockTick);
    super.dispose();
  }

  /// 时钟 tick 入口（异步判定收敛为 fire-and-forget，异常不逃逸出
  /// ClockStore 的监听器链——与 TrackingStore._onTick 同款防护）。
  void _onClockTick() {
    if (_disposed) return;
    unawaited(
      handleTick().catchError((Object e) {
        debugPrint('ReminderStore: tick 异常 ${e.runtimeType}: $e');
      }),
    );
  }

  /// 单次提醒检查（tick 驱动；测试可注入固定时刻后直调）。
  @visibleForTesting
  Future<void> handleTick() async {
    if (_disposed) return;
    if (_active != null) return; // 待处置中：不叠加触发
    final s = settings.current;
    if (s == null) return; // 设置未加载
    final now = _now();
    final recording = await _resolveRecording();
    if (_disposed) return;
    final method = s.reminderMethod;

    // ---- 1) 运行阈值提醒「仍在进行？」----
    if (recording) {
      final running = timer.runningEntry!;
      if (_thresholdEntryId != running.id || _thresholdNextAt == null) {
        // 新会话（切换/刚启动）：按该条目起点重计阈值。
        _thresholdEntryId = running.id;
        _thresholdNextAt =
            running.startAt.add(Duration(minutes: s.reminderMinutes));
      }
      if (!now.isBefore(_thresholdNextAt!)) {
        // 触发即顺延一个重复间隔（继续/稍后/关闭共用该节奏）。
        _thresholdNextAt =
            now.add(Duration(minutes: s.reminderIntervalMinutes));
        if (method != ReminderMethod.silent) {
          _active = OngoingReminder(
            entryId: running.id,
            activityName: running.activityNameSnapshot,
            activityColor: running.activityColorSnapshot,
            elapsed: now.difference(running.startAt),
            method: method,
            id: 'ongoing:${running.id}:${now.millisecondsSinceEpoch}',
          );
          notifyListeners();
          return;
        }
      }
    } else {
      _thresholdEntryId = null;
      _thresholdNextAt = null;
    }

    // ---- 2) 触发时刻提醒（到点提醒开始记录）----
    if (s.quickReminderEnabled && !recording) {
      final dayStart = now.startOfDay;
      final trigger =
          dayStart.add(Duration(minutes: s.reminderTimeOfDayMinutes));
      if (!now.isBefore(trigger) && _quickFiredDay != dayStart) {
        _quickFiredDay = dayStart; // 静音方式同样消耗当日标记
        if (method != ReminderMethod.silent) {
          _active = QuickStartReminder(
              method: method, id: 'quick:${dayStart.toIso8601String()}');
          notifyListeners();
        }
      }
    }
  }

  /// 当前是否"记录中"（存在非未分配的运行条目；未分配判定带缓存）。
  Future<bool> _resolveRecording() async {
    final TimeEntry? running = timer.runningEntry;
    if (running == null) return false;
    final activityId = running.activityId;
    if (!_unassignedCache.containsKey(activityId)) {
      _unassignedCache[activityId] =
          await isUnassignedActivity(activityId);
    }
    return !(_unassignedCache[activityId] ?? false);
  }

  /// 「继续」/「稍后提醒」/横幅「关闭」：清当前提醒并按重复间隔再约下一次。
  void acknowledgeOngoing() {
    if (_active is! OngoingReminder) return;
    final interval = Duration(
        minutes: settings.current?.reminderIntervalMinutes ?? 10);
    _thresholdNextAt = _now().add(interval);
    _active = null;
    notifyListeners();
  }

  /// 「停止」：结束当前运行（经 TimerStore 写路径——手动语义，计入会话
  /// 保持），清提醒与阈值状态。
  Future<void> stopOngoing() async {
    if (_active is! OngoingReminder) return;
    _active = null;
    _thresholdEntryId = null;
    _thresholdNextAt = null;
    notifyListeners();
    await timer.stopRunning();
  }

  /// 快速提醒处置（开始记录跳转由壳层负责；此处仅清除待处置态）。
  void dismissQuick() {
    if (_active is! QuickStartReminder) return;
    _active = null;
    notifyListeners();
  }
}
