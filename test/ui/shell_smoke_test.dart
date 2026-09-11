import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:timetrack2/app.dart';
import 'package:timetrack2/components/app_theme.dart';

/// UI 层测试基座（阶段 4 批次 0）。
///
/// 契约 §1 三档断点（<600 紧凑 / 600–840 中宽 / ≥840 宽屏）驱动的"任意宽度
/// 无溢出"验收，从这里下沉为可运行断言；后续每批页面对齐设计稿后在本文件
/// 追加对应宽度矩阵（老项目 adaptive_layout_test 思路）。
void main() {
  testWidgets('三档宽度下应用根正常渲染且无布局异常', (tester) async {
    const sizes = [
      Size(390, 844), // 紧凑（<600）
      Size(700, 900), // 中宽（600–840）
      Size(1280, 900), // 宽屏（≥840）
    ];
    for (final size in sizes) {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1.0;
      await tester.pumpWidget(const TimeTrack2App());
      await tester.pumpAndSettle();
      expect(
        tester.takeException(),
        isNull,
        reason: '宽度 $size 出现渲染异常（溢出/断言）',
      );
      expect(find.text('TimeTrack2'), findsOneWidget);
    }
    addTearDown(tester.view.reset);
  });

  testWidgets('本地化默认中文注入（appSubtitle 中文占位正常显示）', (tester) async {
    tester.view.physicalSize = const Size(700, 900);
    tester.view.devicePixelRatio = 1.0;
    // 设计稿/铁律 6 默认中文占位：显式注入 zh locale 验证 ARB 注入。
    await tester.pumpWidget(const TimeTrack2App(locale: Locale('zh')));
    await tester.pumpAndSettle();
    expect(find.text('时间追踪'), findsOneWidget);
    addTearDown(tester.view.reset);
  });

  test('主题组装：深浅两套按设计令牌（indigo 主色/zinc 表面）', () {
    final light = buildTimeTrackTheme(Brightness.light);
    final dark = buildTimeTrackTheme(Brightness.dark);
    // 品牌主色 indigo-600，两主题一致（实心按钮）
    expect(light.colorScheme.primary, const Color(0xff4f46e5));
    expect(dark.colorScheme.primary, const Color(0xff4f46e5));
    // 浅色表面白 / 深色表面 zinc-900
    expect(light.colorScheme.surface, Colors.white);
    expect(dark.colorScheme.surface, const Color(0xff18181b));
    // 深色主题亮暗声明正确
    expect(dark.brightness, Brightness.dark);
    expect(light.brightness, Brightness.light);
  });
}
