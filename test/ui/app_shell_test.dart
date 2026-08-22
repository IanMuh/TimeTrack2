import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:timetrack2/api/supabase/sync_backend.dart';
import 'package:timetrack2/app.dart';
import 'package:timetrack2/components/global_timer_bar.dart';
import 'package:timetrack2/data/database/app_database.dart' hide ProfileSettings;
import 'package:timetrack2/pages/settings_page.dart';
import 'package:timetrack2/pages/stats_page.dart';
import 'package:timetrack2/pages/timeline_page.dart';
import 'package:timetrack2/pages/timer_page.dart';
import 'package:timetrack2/pages/today_page.dart';
import 'package:timetrack2/stores/app_store.dart';
import 'package:timetrack2/utils/result.dart';
import 'package:timetrack2/viewmodels/commands/command_invocation.dart';

/// 应用壳测试（阶段 4 批次 1）。
///
/// 测试范式对齐 `test/stores/app_store_test.dart`：内存库 + fake 后端 +
/// runStartupChecks=false 构造 [AppStore]，注入 [TimeTrack2App]（显式 zh
/// locale，确定性验证 ARB 文案）。
///
/// **store 释放纪律**：flutter_test 在测试体收尾（_verifyInvariants）时断言
/// 无 pending timer——[ClockStore] 的周期 Timer 必须在**测试体内**取消
/// （addTearDown 的时点晚于该检查，不可依赖）；ChangeNotifier.dispose 二次
/// 调用会断言，故不可既加 addTearDown 又在体内 dispose。
///
/// 覆盖：
/// 1. 三档宽度矩阵（390/700/1280）壳渲染无溢出（takeException null）；
/// 2. 底部导航 / 侧导航五页均可切换，进入各占位页标题存在；
/// 3. 壳保活：切到今日再切回计时，页面 Element 同一实例（State 保留）。
class _FakeBackend implements SyncBackend {
  @override
  bool get isConfigured => true;

  @override
  late final Stream<String?> authStateStream = Stream<String?>.multi(
    (controller) => controller.add(null),
    isBroadcast: true,
  );

  @override
  String? get currentUserId => null;

  @override
  Future<AppResult<void>> sendMagicLink(String email) async =>
      const AppSuccess(null);

  @override
  Future<AppResult<String>> verifyEmailOtp(String email, String token) async =>
      AppSuccess('user-1');

  @override
  Future<AppResult<SyncReport>> syncNow() async => const AppSuccess(SyncReport(
        target: SyncTarget.supabase,
        wasFullSync: false,
        pulledRows: 0,
        pushedRows: 0,
      ));

  @override
  Future<AppResult<void>> signOut() async => const AppSuccess(null);
}

Future<AppStore> _createStore() {
  return AppStore.create(
    database: AppDatabase(NativeDatabase.memory()),
    backend: _FakeBackend(),
    runStartupChecks: false,
  );
}

/// 当前展示页标题（页面内独立标题，避免与导航栏同名文案混淆）。
Finder _pageTitle(Type pageType, String title) =>
    find.descendant(of: find.byType(pageType), matching: find.text(title));

Finder _todayMarker() => find.descendant(
      of: find.byType(TodayPage),
      matching: find.textContaining(RegExp('总时长|今日暂无记录')),
    );

/// 计时页无固定标题字（焦点卡/快捷区），命中任一稳定标记。
Finder _timerMarker() => find.descendant(
      of: find.byType(TimerPage),
      matching: find.textContaining(RegExp('未在记录|今日累计|暂无活动')),
    );

/// 壳内唯一的 IndexedStack（go_router StatefulShellRoute.indexedStack 的
/// 分支容器）：currentIndex 即当前分支。
int _shellIndex(WidgetTester tester) =>
    tester.widget<IndexedStack>(find.byType(IndexedStack)).index!;

void main() {
  group('应用壳：三档宽度矩阵渲染', () {
    const sizes = [
      Size(390, 844), // 紧凑（<600）
      Size(700, 900), // 中宽（600–840）
      Size(1280, 900), // 宽屏（≥840）
    ];

    for (final size in sizes) {
      testWidgets('宽度 $size：壳渲染无溢出，计时条常驻未记录占位', (tester) async {
        final store = await _createStore();
        tester.view.physicalSize = size;
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.reset);
        await tester.pumpWidget(
          TimeTrack2App(appStore: store, locale: const Locale('zh')),
        );
        await tester.pumpAndSettle();
        expect(
          tester.takeException(),
          isNull,
          reason: '宽度 $size 出现渲染异常（溢出/断言）',
        );
        // 全局计时条常驻 + 计时页焦点卡（批次 2 起两处"未在记录"占位态）。
        expect(find.text('未在记录'), findsNWidgets(2));
        // 释放 store（取消 ClockStore 周期 Timer，见文件头纪律）。
        store.dispose();
      });
    }
  });

  group('应用壳：五页导航切换', () {
    testWidgets('底部导航（紧凑 390）：五页可切换且各页标题存在', (tester) async {
      final store = await _createStore();
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        TimeTrack2App(appStore: store, locale: const Locale('zh')),
      );
      await tester.pumpAndSettle();

      NavigationBar navBar() =>
          tester.widget<NavigationBar>(find.byType(NavigationBar));
      expect(navBar().selectedIndex, 0, reason: '初始着陆计时页');

      Future<void> switchTo(
        int index,
        IconData icon,
        Type pageType,
        String title,
      ) async {
        await tester.tap(find.byIcon(icon));
        await tester.pumpAndSettle();
        expect(navBar().selectedIndex, index, reason: '底部导航选中态应切换');
        expect(
          title.isEmpty
              ? (pageType == TodayPage ? _todayMarker() : _timerMarker())
              : _pageTitle(pageType, title),
          findsAtLeastNWidgets(1),
          reason: '进入 $title 页后页面内容应存在',
        );
      }

      // 计时页为默认着陆页（当前分支 0），无需切页；占位标记已验证如上。

      await switchTo(1, Icons.calendar_today_outlined, TodayPage, '');
      await switchTo(2, Icons.view_timeline_outlined, TimelinePage, '时间线');
      await switchTo(3, Icons.pie_chart_outline, StatsPage, '统计');
      await switchTo(4, Icons.settings_outlined, SettingsPage, '设置');
      await switchTo(0, Icons.timer_outlined, TimerPage, '');
      store.dispose();
    });

    testWidgets('侧导航（宽屏 1280）：五页可切换且各页标题存在', (tester) async {
      final store = await _createStore();
      tester.view.physicalSize = const Size(1280, 900);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        TimeTrack2App(appStore: store, locale: const Locale('zh')),
      );
      await tester.pumpAndSettle();

      // 宽屏：侧导航存在、无底部导航；品牌在壳上可见（契约 §3.2）。
      expect(find.byType(NavigationBar), findsNothing);
      expect(find.text('TimeTrack'), findsOneWidget);
      expect(_shellIndex(tester), 0, reason: '初始着陆计时页');

      Future<void> switchTo(
        int index,
        IconData icon,
        Type pageType,
        String title,
      ) async {
        await tester.tap(find.byIcon(icon));
        await tester.pumpAndSettle();
        expect(_shellIndex(tester), index, reason: '侧导航选中态应切换');
        expect(
          title.isEmpty
              ? (pageType == TodayPage ? _todayMarker() : _timerMarker())
              : _pageTitle(pageType, title),
          findsAtLeastNWidgets(1),
          reason: '进入 $title 页后页面内容应存在',
        );
      }

      // 计时页为默认着陆页（当前分支 0），无需切页；占位标记已验证如上。

      await switchTo(1, Icons.calendar_today_outlined, TodayPage, '');
      await switchTo(2, Icons.view_timeline_outlined, TimelinePage, '时间线');
      await switchTo(3, Icons.pie_chart_outline, StatsPage, '统计');
      await switchTo(4, Icons.settings_outlined, SettingsPage, '设置');
      await switchTo(0, Icons.timer_outlined, TimerPage, '');
      store.dispose();
    });
  });

  group('应用壳：全局计时条数据流', () {
    testWidgets('switch 后显示运行条目；点停止经指令通道回落未记录占位（紧凑档无溢出）', (tester) async {
      final store = await _createStore();
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        TimeTrack2App(appStore: store, locale: const Locale('zh')),
      );
      await tester.pumpAndSettle();

      // 未记录占位：计时条 + 计时页焦点卡两处。
      expect(find.text('未在记录'), findsNWidgets(2));

      // 经指令通道切换活动（seed 含"学习"）；计时条为运行态。
      await store.dispatcher.dispatch(
        CommandInvocation(name: 'switch', args: const ['学习']),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull, reason: '紧凑档运行态计时条溢出');
      expect(find.text('未在记录'), findsNothing);
      expect(find.text('学习'), findsNWidgets(5), reason: '计时条+焦点卡+快捷卡+今日面板(最近/占比)显示');
      expect(
        find.textContaining('00:00:'),
        findsAtLeastNWidgets(2),
        reason: '计时数字等宽格式（计时条/焦点卡/卡片角标，tabular figures 由样式提供）',
      );
      // 停止按钮可点；切换按钮禁用（批次 2 提供选择器）——按下不产生动作。
      // 计时条上的切换按钮仍禁用（选择器批次 2 接入页面级；条内按钮批次 5 统一）。
      expect(
        tester
            .widget<FilledButton>(find.descendant(
              of: find.byType(GlobalTimerBar),
              matching: find.widgetWithText(FilledButton, '切换活动'),
            ))
            .onPressed,
        isNull,
        reason: '计时条切换按钮仍禁用（tooltip 说明原因）',
      );

      // 点"停止"→ 壳层经指令通道分发 → Snackbar 反馈 + 计时条回落未记录。
      await tester.tap(find.descendant(
          of: find.byType(GlobalTimerBar),
          matching: find.text('停止'),
        ));
      await tester.pumpAndSettle();
      expect(find.text('未在记录'), findsNWidgets(2), reason: '停止后回落未记录占位（两处）');
      expect(
        find.text('已停止当前活动'),
        findsOneWidget,
        reason: '操作反馈 Snackbar 由壳层统一弹（经 dispatcher 结果）',
      );
      // 冲掉 Snackbar 的自动关闭 Timer（防测试收尾 pending timer）。
      await tester.pump(const Duration(seconds: 5));
      await tester.pumpAndSettle();
      store.dispose();
    });
  });

  group('应用壳：页面保活', () {
    testWidgets('五页访问后全部保活共存；切回计时页 Element 同一实例', (tester) async {
      final store = await _createStore();
      tester.view.physicalSize = const Size(1280, 900);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        TimeTrack2App(appStore: store, locale: const Locale('zh')),
      );
      await tester.pumpAndSettle();

      final timerElement = tester.element(
        find.byType(TimerPage, skipOffstage: false),
      );

      // 依次访问 5 页（StatefulShellRoute 分支懒挂载：访问过的分支才入壳，
      // 挂载后保活）。
      const visits = [
        (1, Icons.calendar_today_outlined, TodayPage, '今日'),
        (2, Icons.view_timeline_outlined, TimelinePage, '时间线'),
        (3, Icons.pie_chart_outline, StatsPage, '统计'),
        (4, Icons.settings_outlined, SettingsPage, '设置'),
      ];
      for (final (index, icon, pageType, title) in visits) {
        await tester.tap(find.byIcon(icon));
        await tester.pumpAndSettle();
        expect(_shellIndex(tester), index, reason: '$title 页应成为当前页');
        expect(
          pageType == TodayPage ? _todayMarker() : _pageTitle(pageType, title),
          findsOneWidget,
        );
      }

      // 五页全部保活共存于 route 树（IndexedStack 分支）。
      for (final pageType in [
        TimerPage,
        TodayPage,
        TimelinePage,
        StatsPage,
        SettingsPage,
      ]) {
        expect(
          find.byType(pageType, skipOffstage: false),
          findsOneWidget,
          reason: '$pageType 应保活共存于 route 树',
        );
      }

      // 切回计时：页面 Element 同一实例（未重建，State 保留）。
      await tester.tap(find.byIcon(Icons.timer_outlined));
      await tester.pumpAndSettle();
      expect(_shellIndex(tester), 0);
      expect(_timerMarker(), findsAtLeastNWidgets(1));
      expect(
        tester.element(find.byType(TimerPage, skipOffstage: false)),
        same(timerElement),
        reason: '切页后计时页 Element 应为同一实例（未重建）',
      );
      store.dispose();
    });
  });
}