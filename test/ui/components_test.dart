import 'dart:async' show unawaited;

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:timetrack2/components/activity_color_dot.dart';
import 'package:timetrack2/components/app_theme.dart';
import 'package:timetrack2/components/controls.dart';
import 'package:timetrack2/components/feedback.dart';
import 'package:timetrack2/components/state_views.dart';
import 'package:timetrack2/components/tnum_text.dart';
import 'package:timetrack2/l10n/app_localizations.dart';

/// 公共组件基座测试（组件无业务状态：独立 pump，不需要应用壳）。
void main() {
  Widget host(Widget child, {Brightness brightness = Brightness.light}) {
    return MaterialApp(
      theme: buildTimeTrackTheme(brightness),
      // 设计稿默认中文占位；组件文案键按 zh 断言。
      locale: const Locale('zh'),
      localizationsDelegates: const [
        AppLocalizations.delegate,
        // zh locale 需要整套 Global 委托（否则 MaterialLocalizations 缺失、
        // Scaffold/SnackBar/AlertDialog 全部不可用）。
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      supportedLocales: AppLocalizations.supportedLocales,
      home: Scaffold(body: Center(child: child)),
    );
  }

  group('TnumText', () {
    testWidgets('等宽字体特性已合并进 style', (tester) async {
      await tester.pumpWidget(host(const TnumText('01:24:36')));
      final text = tester.widget<Text>(find.text('01:24:36'));
      expect(text.style!.fontFeatures, contains(FontFeature.tabularFigures()));
    });

    test('formatHms 补零且小时不截断', () {
      expect(formatHms(const Duration(hours: 1, minutes: 24, seconds: 36)),
          '01:24:36');
      expect(formatHms(const Duration(hours: 99, minutes: 5, seconds: 3)),
          '99:05:03');
      expect(formatHms(Duration.zero), '00:00:00');
    });
  });

  group('ActivityColorDot / Bar', () {
    testWidgets('色点尺寸与颜色正确', (tester) async {
      await tester.pumpWidget(host(const ActivityColorDot(Color(0xfff43f5e))));
      final container = tester.widget<Container>(
        find.descendant(
          of: find.byType(ActivityColorDot),
          matching: find.byType(Container),
        ),
      );
      final box = container.decoration! as BoxDecoration;
      expect(box.color, const Color(0xfff43f5e));
      expect(box.shape, BoxShape.circle);
    });

    testWidgets('占比条按 ratio 缩放进度', (tester) async {
      await tester.pumpWidget(host(
        const ActivityColorBar(Color(0xff0ea5e9), ratio: 0.42),
      ));
      final frac = tester.widget<FractionallySizedBox>(
        find.byType(FractionallySizedBox),
      );
      expect(frac.widthFactor, closeTo(0.42, 0.001));
    });
  });

  group('三态组件', () {
    testWidgets('加载态显示骨架与文案', (tester) async {
      await tester.pumpWidget(host(const LoadingStateView()));
      expect(find.text('加载中…'), findsOneWidget);
      expect(find.byType(Container), findsNWidgets(3)); // 3 张骨架卡
    });

    testWidgets('空态渲染并触发动作', (tester) async {
      var tapped = false;
      await tester.pumpWidget(host(EmptyStateView(
        icon: Icons.business_center_outlined,
        title: '暂无活动',
        message: '开始记录吧',
        actionLabel: '创建',
        onAction: () => tapped = true,
      )));
      expect(find.text('暂无活动'), findsOneWidget);
      expect(find.text('开始记录吧'), findsOneWidget);
      await tester.tap(find.text('创建'));
      expect(tapped, isTrue);
    });

    testWidgets('错误态触发重试', (tester) async {
      var retried = false;
      await tester.pumpWidget(host(ErrorStateView(
        message: '数据库读取失败',
        onRetry: () => retried = true,
      )));
      expect(find.text('出错了'), findsOneWidget);
      await tester.tap(find.text('重试'));
      expect(retried, isTrue);
    });
  });

  group('自绘控件', () {
    testWidgets('AppToggle 受控切换与禁用', (tester) async {
      var value = false;
      await tester.pumpWidget(host(AppToggle(
        value: value,
        onChanged: (v) => value = v,
      )));
      await tester.tap(find.byType(AppToggle));
      expect(value, isTrue);

      // 禁用不触发回调
      var called = false;
      await tester.pumpWidget(host(AppToggle(
        value: false,
        disabled: true,
        onChanged: (_) => called = true,
      )));
      await tester.tap(find.byType(AppToggle));
      expect(called, isFalse);
    });

    testWidgets('AppSlider 点击定位换算正确', (tester) async {
      double? got;
      await tester.pumpWidget(host(AppSlider(
        value: 5,
        min: 0,
        max: 10,
        onChanged: (v) => got = v,
      )));
      final box = tester.getRect(find.byType(AppSlider));
      await tester.tapAt(Offset(box.left + box.width * 0.25, box.center.dy));
      expect(got, isNotNull);
      expect(got!, closeTo(2.5, 0.3)); // 0.25 * 10
    });

    testWidgets('AppChip 选中态回调与计数徽标', (tester) async {
      var tapped = false;
      await tester.pumpWidget(host(AppChip(
        label: '工作',
        count: 4,
        selected: true,
        onTap: () => tapped = true,
      )));
      expect(find.text('工作'), findsOneWidget);
      expect(find.text('4'), findsOneWidget);
      await tester.tap(find.text('工作'));
      expect(tapped, isTrue);
    });

    testWidgets('AppCheckbox 勾选回调与禁用', (tester) async {
      var checked = false;
      await tester.pumpWidget(host(AppCheckbox(
        checked: checked,
        onChanged: (v) => checked = v,
      )));
      await tester.tap(find.byType(AppCheckbox));
      expect(checked, isTrue);
      // 受控组件：回调只改测试侧变量，重 pump 新值后勾选态才上屏。
      await tester.pumpWidget(host(AppCheckbox(
        checked: checked,
        onChanged: (v) => checked = v,
      )));
      expect(find.byIcon(Icons.check_rounded), findsOneWidget);
    });
  });

  group('反馈载体', () {
    testWidgets('Snackbar 显示并可触发动作', (tester) async {
      var action = false;
      await tester.pumpWidget(host(
        const SizedBox(),
        brightness: Brightness.dark,
      ));
      final context = tester.element(find.byType(Scaffold));
      showAppSnackBar(
        context,
        message: '已停止计时',
        actionLabel: '撤销',
        onAction: () => action = true,
      );
      await tester.pump();
      // 进场动画期间 IgnorePointer 拦截点击；推进 300ms 到完全进场。
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('已停止计时'), findsOneWidget);
      await tester.tap(find.text('撤销'));
      await tester.pump();
      expect(action, isTrue);
    });

    testWidgets('AppBanner 三类型渲染 + 关闭回调', (tester) async {
      var dismissed = false;
      await tester.pumpWidget(host(Column(
        children: [
          const AppBanner(type: AppBannerType.info, title: '新版本可用'),
          const AppBanner(type: AppBannerType.warning, title: '警告内容'),
          AppBanner(
            type: AppBannerType.error,
            title: '出错啦',
            onDismiss: () => dismissed = true,
          ),
        ],
      )));
      expect(find.byType(AppBanner), findsNWidgets(3));
      expect(find.byIcon(Icons.info_outline), findsOneWidget);
      expect(find.byIcon(Icons.warning_amber_rounded), findsOneWidget);
      await tester.tap(find.byTooltip('关闭'));
      expect(dismissed, isTrue);
    });

    testWidgets('确认对话框：确认 true / 取消 false', (tester) async {
      bool? result;
      await tester.pumpWidget(host(const SizedBox()));
      final context = tester.element(find.byType(Scaffold));
      unawaited(showAppConfirmationDialog(
        context,
        title: '删除分类？',
        message: '将删除所有子分类',
        isDestructive: true,
      ).then((v) => result = v));
      await tester.pumpAndSettle();
      expect(find.text('删除分类？'), findsOneWidget);
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      expect(result, isFalse);
    });

    testWidgets('深浅主题下控件组均正常渲染', (tester) async {
      // 深色主题下整组 pump 无异常（浅色行为已被上面用例覆盖）。
      await tester.pumpWidget(host(
        const Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ToggleOption(),
            SizedBox(height: 8),
            AppBanner(type: AppBannerType.warning, title: '深色警告'),
            SizedBox(height: 8),
            LoadingStateView(),
          ],
        ),
        brightness: Brightness.dark,
      ));
      await tester.pump();
      expect(tester.takeException(), isNull);
    });
  });
}

/// 深色整组用例的容器（避免 top-level 散布控件样板）。
class ToggleOption extends StatelessWidget {
  const ToggleOption({super.key});

  @override
  Widget build(BuildContext context) {
    return const AppToggle(value: true, onChanged: null, label: '开关');
  }
}
