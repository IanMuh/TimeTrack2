/// 主题模式 UI 状态（阶段 4 批次 1）：浅 / 深 / 跟随系统。
///
/// 这是**纯 UI 状态类**（不属于领域 store）：只管理当前 [ThemeMode]，不触库、
/// 不记 undo、不进同步（主题是设备本地偏好，不进跨设备数据语义）。
///
/// **持久化延迟到批次 4**：ProfileSettings 当前无 theme 列，落库需要 drift
/// 表结构变更（schema 迁移）——设置页批次会一并加列并在此接线（默认浅色
/// 与契约 §9.7 一致），本批次仅内存态。
library;

import 'package:flutter/material.dart' show ChangeNotifier, ThemeMode;

/// 主题模式状态。
class ThemeModeStore extends ChangeNotifier {
  ThemeMode _mode = ThemeMode.light;

  /// 当前主题模式（默认浅色，契约 §9.7）。
  ThemeMode get mode => _mode;

  /// 显式设置主题模式。
  void setMode(ThemeMode mode) {
    if (mode == _mode) return;
    _mode = mode;
    notifyListeners();
  }

  /// 三态循环切换：浅色 → 深色 → 跟随系统 → 浅色。
  void toggle() {
    _mode = switch (_mode) {
      ThemeMode.light => ThemeMode.dark,
      ThemeMode.dark => ThemeMode.system,
      ThemeMode.system => ThemeMode.light,
    };
    notifyListeners();
  }
}