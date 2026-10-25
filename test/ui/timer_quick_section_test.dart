import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:timetrack2/components/app_theme.dart';
import 'package:timetrack2/l10n/app_localizations.dart';
import 'package:timetrack2/pages/timer_quick_section.dart';
import 'package:timetrack2/viewmodels/activity.dart';
import 'package:timetrack2/viewmodels/activity_category.dart';

/// 计时页快捷活动区（PR-B）：紧凑分组列表 + 搜索 + 三档列数。
void main() {
  final now = DateTime.utc(2026, 10, 24);
  final study = ActivityCategory(
    id: 'c1',
    name: '学习',
    color: 0xff6366f1,
    updatedAt: now,
  );

  Activity activity(String id, String name, {int color = 0xff6366f1}) {
    return Activity(
      id: id,
      name: name,
      color: color,
      isFavorite: false,
      updatedAt: now,
    );
  }

  final activities = [
    activity('a1', '阅读'),
    activity('a2', '写作'),
    activity('a3', '背单词'),
  ];

  Widget host(Widget child, double width) {
    return MaterialApp(
      theme: buildTimeTrackTheme(Brightness.light),
      locale: const Locale('zh'),
      localizationsDelegates: const [
        AppLocalizations.delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      supportedLocales: AppLocalizations.supportedLocales,
      home: Scaffold(body: SingleChildScrollView(child: child)),
    );
  }

  Widget section({
    String? runningId,
    String? pendingId,
    ValueChanged<String>? onSearch,
  }) {
    return Builder(
      builder: (context) {
        return TimerQuickSection(
          l10n: AppLocalizations.of(context)!,
          categoryFilterId: null,
          rootCategories: [study],
          childrenByParent: {
            null: [study],
          },
          ancestorChain: {
            'c1': ['学习'],
          },
          descendantsOf: {
            'c1': {'c1'},
          },
          activities: activities,
          categoryIdsByActivity: {
            'a1': {'c1'},
            'a2': {'c1'},
            'a3': {'c1'},
          },
          runningActivityId: runningId,
          pendingActivityId: pendingId,
          todayByActivity: {'a1': const Duration(hours: 1, minutes: 5)},
          onFilter: (_) {},
          onActivityTap: (_) {},
          onActivityDoubleTap: (_) {},
          onActivityLongPress: (_) {},
          onTemporary: () {},
          onNewActivity: () {},
        );
      },
    );
  }

  Future<void> pumpAt(WidgetTester tester, double width, Widget child) async {
    tester.view.physicalSize = Size(width, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(host(child, width));
    await tester.pumpAndSettle();
  }

  for (final width in [480.0, 800.0, 1280.0]) {
    testWidgets('三档宽度（$width）分组列表渲染无溢出', (tester) async {
      await pumpAt(tester, width, section());
      expect(tester.takeException(), isNull);
      expect(find.text('学习'), findsWidgets);
      for (final a in activities) {
        expect(find.text(a.name), findsOneWidget);
      }
    });
  }

  testWidgets('>=1200 时行按列流动，单分类也铺满宽度', (tester) async {
    await pumpAt(tester, 1280, section());
    final xs = [
      for (final name in ['阅读', '写作', '背单词'])
        tester.getTopLeft(find.text(name)).dx,
    ];
    // 三列：三个条目分别落在不同列（x 各不相同），而不是全部挤在左侧单列。
    expect(xs.toSet().length, 3);

    await pumpAt(tester, 480, section());
    final compact = [
      for (final name in ['阅读', '写作', '背单词'])
        tester.getTopLeft(find.text(name)).dx,
    ];
    expect(compact.toSet().length, 1);
  });

  testWidgets('搜索按名称过滤并显示空态', (tester) async {
    await pumpAt(tester, 800, section());
    await tester.enterText(find.byType(TextField), '阅');
    await tester.pumpAndSettle();
    expect(find.text('阅读'), findsOneWidget);
    expect(find.text('写作'), findsNothing);
    expect(find.text('背单词'), findsNothing);

    await tester.enterText(find.byType(TextField), '不存在');
    await tester.pumpAndSettle();
    expect(find.text('没有匹配的活动'), findsOneWidget);
  });

  testWidgets('运行中行显示今日时长；待确认行显示再击提示', (tester) async {
    await pumpAt(tester, 800, section(runningId: 'a1'));
    expect(find.text('1:05'), findsOneWidget);

    await pumpAt(tester, 800, section(pendingId: 'a2'));
    expect(find.text('再击确认切换'), findsOneWidget);
  });
}
