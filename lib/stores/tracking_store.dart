/// 后台自动记录 store（模块 3c③，2c' 新功能落位）。
///
/// 职责：
/// - **规则 CRUD**：saveRule/deleteRule（syncEnabled 语义沿用——false 仅
///   本地不推送）；规则变更 → dataRevision bump；
/// - **纯 Dart 匹配器**：进程名（精确/`*` 通配）+ 窗口标题（包含/正则）→
///   命中 [TrackingRuleMatchKind] 规则 → 自动 switch（经 TimerStore 写路径，
///   isAuto=true 透传）；
/// - **ForegroundDetector 抽象**：`{processName, windowTitle}`——平台实现
///   （Windows FFI 轮询 / Android usage_stats）归阶段 4，此处注入 fake 驱动；
/// - **tick 轮询**：TimerStore 时钟 tick 驱动，限频（防每 tick 重复命中同一
///   活动）；命中后记录 lastMatchedRule 供 UI 展示。
///
/// 匹配优先级：同进程命中多条规则时按规则插入序取**最先**（activeRules 已
/// 按 updatedAt 排序）。
library;

import 'package:flutter/foundation.dart';

import '../data/repositories/tracking_rule_repository.dart';
import '../utils/result.dart';
import '../viewmodels/tracking_rule.dart';
import 'clock_store.dart';
import 'data_revision.dart';
import 'timer_store.dart';

/// 前台检测器（平台实现归阶段 4；测试注入 fake）。
abstract interface class ForegroundDetector {
  /// 当前前台进程名（如 `chrome.exe`；不可用返回 null）。
  String? get processName;

  /// 当前前台窗口标题（可空）。
  String? get windowTitle;
}

/// 后台自动记录 store。
class TrackingStore extends ChangeNotifier {
  TrackingStore({
    required this.rules,
    required this.timer,
    required this.dataRevision,
    required this.clock,
    ForegroundDetector? detector,
    this.pollInterval = const Duration(seconds: 5),
    DateTime Function()? now,
  })  : detector = detector ?? _NoopDetector(),
        _now = now ?? DateTime.now {
    clock.addListener(_onTick);
  }

  final TrackingRuleRepository rules;
  final TimerStore timer;
  final DataRevision dataRevision;
  final ClockStore clock;
  final ForegroundDetector detector;

  /// 轮询间隔（节流：tick 每秒但仅间隔达标才检测）。
  final Duration pollInterval;
  final DateTime Function() _now;

  bool _disposed = false;
  DateTime _lastPoll = DateTime.fromMillisecondsSinceEpoch(0);
  String? _lastMatchedActivityId;
  String? _lastMatchNote;

  /// 最近一次自动命中切换的活动 id（UI 展示）。
  String? get lastMatchedActivityId => _lastMatchedActivityId;

  /// 最近一次自动命中的规则模式（UI 展示"由 X 自动记录"）。
  String? get lastMatchNote => _lastMatchNote;

  void _onTick() {
    if (_disposed) return;
    final now = _now();
    if (now.difference(_lastPoll) < pollInterval) return; // 限频
    _lastPoll = now;
    poll();
  }

  /// 检测前台并自动切换（供 tick 驱动与手动调用；fake 测试直接调）。
  Future<void> poll() async {
    if (_disposed) return;
    final process = detector.processName;
    if (process == null || process.isEmpty) return; // 无前台进程：不动作
    final title = detector.windowTitle;
    final rulesResult = await rules.activeRules();
    if (rulesResult case AppFailure<List<TrackingRule>> _) {
      return; // 规则加载失败：保持现状（下一轮重试）
    }
    final matched = _match(process, title, rulesResult.requireValue());
    if (matched == null) return;
    final current = await timer.entries.runningEntry();
    if (current != null && current.activityId == matched.activityId) {
      return; // 已在该活动：不重复切换
    }
    final result = await timer.switchToActivity(matched.activityId, isAuto: true);
    if (result.isSuccess) {
      _lastMatchedActivityId = matched.activityId;
      _lastMatchNote = matched.pattern;
      notifyListeners();
    }
  }

  /// 纯 Dart 匹配器（可独立单测）：
  /// - process 类：进程名精确或 `*` 段通配匹配；
  /// - title 类：窗口标题正则匹配（pattern 即标题正则，**不要求进程名
  ///   命中**——标题规则按窗口标题归活动，区分同应用内不同文档/页面）；
  /// - 同进程命中多条取**最先**（规则列表顺序 = activeRules updatedAt 序）。
  static TrackingRule? _match(
    String process,
    String? title,
    List<TrackingRule> candidates,
  ) {
    for (final rule in candidates) {
      if (rule.matchKind == TrackingRuleMatchKind.unknown) continue;
      if (rule.matchKind == TrackingRuleMatchKind.process) {
        if (_processMatches(process, rule.pattern)) return rule;
        continue;
      }
      // title 类：仅标题正则匹配。
      final windowTitle = title;
      if (windowTitle == null || windowTitle.isEmpty) continue;
      try {
        if (RegExp(rule.pattern).hasMatch(windowTitle)) {
          return rule;
        }
      } on FormatException {
        continue; // 非法正则规则：跳过（不因单条规则崩溃）
      }
    }
    return null;
  }

  static bool _processMatches(String process, String pattern) {
    if (pattern == '*') return true; // 全通配
    if (pattern.contains('*')) {
      // 段通配：`code*.exe` → 前缀匹配；`*` 前后段。
      final prefix = pattern.substring(0, pattern.indexOf('*'));
      return process.startsWith(prefix);
    }
    return process == pattern; // 精确
  }

  // ---------------------------------------------------------------------------
  // 规则 CRUD
  // ---------------------------------------------------------------------------

  /// 保存规则（新建/更新；updatedAt 由仓储推进）。
  Future<AppResult<TrackingRule>> saveRule(TrackingRule rule) async {
    final result = await rules.saveRule(rule);
    if (result.isSuccess) {
      dataRevision.bump();
      notifyListeners();
    }
    return result;
  }

  /// 删除规则（软删）。
  Future<AppResult<void>> deleteRule(TrackingRule rule) async {
    final result = await rules.deleteRule(rule);
    if (result.isSuccess) {
      dataRevision.bump();
      notifyListeners();
    }
    return result;
  }

  @override
  void dispose() {
    _disposed = true;
    clock.removeListener(_onTick);
    super.dispose();
  }
}

/// 无平台实现时的空检测器（阶段 4 前自动记录不动作）。
class _NoopDetector implements ForegroundDetector {
  @override
  String? get processName => null;
  @override
  String? get windowTitle => null;
}
