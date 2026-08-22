import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:timetrack2/stores/theme_mode_store.dart';

/// ThemeModeStore UI 状态测试（阶段 4 批次 1）。
///
/// 纯内存状态类：默认浅色（契约 §9.7）、setMode 显式设置、toggle 三态循环
/// （浅色 → 深色 → 跟随系统 → 浅色）。持久化（ProfileSettings 加 theme 列）
/// 属批次 4——迁移后接线时在此追加"加载/回写"用例。
void main() {
  group('ThemeModeStore', () {
    test('默认 light（契约 §9.7：默认浅色，可切深色/跟随系统）', () {
      expect(ThemeModeStore().mode, ThemeMode.light);
    });

    test('setMode：显式设置并通知一次；同值幂等不重复通知', () {
      final store = ThemeModeStore();
      var notified = 0;
      store.addListener(() => notified++);

      store.setMode(ThemeMode.dark);
      expect(store.mode, ThemeMode.dark);
      expect(notified, 1);

      // 设置同值：状态不变，不通知（避免无意义 rebuild）。
      store.setMode(ThemeMode.dark);
      expect(notified, 1);

      store.setMode(ThemeMode.system);
      expect(store.mode, ThemeMode.system);
      expect(notified, 2);
    });

    test('toggle：三态循环 light→dark→system→light', () {
      final store = ThemeModeStore();
      expect(store.mode, ThemeMode.light);
      store.toggle();
      expect(store.mode, ThemeMode.dark);
      store.toggle();
      expect(store.mode, ThemeMode.system);
      store.toggle();
      expect(store.mode, ThemeMode.light);
    });
  });
}