import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:timetrack2/api/supabase/sync_backend.dart';
import 'package:timetrack2/app.dart';
import 'package:timetrack2/components/controls.dart' show AppChip;
import 'package:timetrack2/data/database/app_database.dart' hide ProfileSettings;
import 'package:timetrack2/pages/timer_page.dart';
import 'package:timetrack2/stores/app_store.dart';
import 'package:timetrack2/utils/result.dart';
import 'package:timetrack2/viewmodels/commands/command_invocation.dart';

/// 计时页 / 今日页集成测试（内存库 + fake 后端 + 指令通道驱动真实数据）。
///
/// 范式对齐 test/stores/app_store_test.dart 与 app_shell_test.dart：
/// runStartupChecks=false；store 在测试体内 dispose（ClockStore 周期
/// Timer 必须测试体内取消——flutter_test 收尾检查早于 addTearDown）。
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

Future<void> _pumpApp(WidgetTester tester, AppStore store) async {
  tester.view.physicalSize = const Size(1280, 900);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    TimeTrack2App(appStore: store, locale: const Locale('zh')),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('计时页：未运行态焦点卡 + 快捷区分类行 + 三态正常', (tester) async {
    final store = await _createStore();
    await _pumpApp(tester, store);
    expect(tester.takeException(), isNull);
    // 焦点卡 + 全局计时条两处"未在记录"。
    expect(find.text('未在记录'), findsNWidgets(2));
    // 快捷区：分类 chip 行 + 全部入口。
    expect(find.text('全部'), findsOneWidget);
    // 今日累计与会话数角标在焦点卡。
    expect(find.text('今日累计'), findsOneWidget);
    expect(find.text('会话数'), findsOneWidget);
    store.dispose();
  });

  testWidgets('计时页：切换活动 → 焦点卡运行态；再击确认中间态；停止回落', (tester) async {
    final store = await _createStore();
    await _pumpApp(tester, store);
    await store.dispatcher
        .dispatch(CommandInvocation(name: 'switch', args: const ['学习']));
    await tester.pumpAndSettle();
    // 焦点卡 + 计时条 + 快捷卡三处"学习"。
    expect(find.text('学习'), findsNWidgets(3));
    expect(find.text('今日累计'), findsOneWidget);

    // 再击确认中间态：点"通勤"卡（种子活动之一）→ 提示条出现；再击 → 切换。
    await tester.tap(find.text('通勤'));
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('再击确认切换'), findsOneWidget);
    // 2.5s 未确认自动取消（中间态回退）。
    await tester.pump(const Duration(seconds: 3));
    expect(find.text('再击确认切换'), findsNothing);
    // 双击直接切换（契约 4.1 已定交互）。
    final card = tester.getCenter(find.text('通勤'));
    await tester.tapAt(card);
    await tester.pump(const Duration(milliseconds: 100));
    await tester.tapAt(card);
    await tester.pumpAndSettle();
    expect(store.timer.runningEntry?.activityNameSnapshot, '通勤');

    // 页面级停止（作用域到 TimerPage）→ 回落未记录。
    await tester.tap(find.descendant(
      of: find.byType(TimerPage),
      matching: find.text('停止'),
    ));
    await tester.pumpAndSettle();
    expect(find.text('未在记录'), findsNWidgets(2));
    store.dispose();
  });

  testWidgets('计时页：分类 chip 过滤快捷活动；临时活动即开即记', (tester) async {
    final store = await _createStore();
    // 建分类"工作"并把 学习 归入（经分类仓储 + link）。
    final created = await store.category
        .createCategory(name: '代码开发', color: 0xff6366f1, parentId: null);
    expect(created.isSuccess, isTrue);
    final learn = (await store.activities.activities()).requireValue()
        .firstWhere((a) => a.name == '学习');
    await store.category.setActivityCategories(
      activityId: learn.id,
      primaryCategoryId: created.requireValue().id,
      secondaryCategoryIds: const [],
    );

    await _pumpApp(tester, store);
    // chip 行含"代码开发"；点击过滤：学习在、通勤不在。
    await tester.tap(find.text('代码开发'));
    await tester.pump();
    expect(find.text('学习'), findsWidgets);
    expect(find.text('通勤'), findsNothing);

    // 临时活动：一键创建（一次性活动）+ 切换。
    await tester.tap(find.text('临时活动'));
    await tester.pumpAndSettle();
    expect(store.timer.runningEntry?.activityNameSnapshot, '临时活动');
    expect(store.timer.runningEntry?.activityId != null, isTrue);
    store.dispose();
  });

  testWidgets('今日页：补记条目后 4 指标正确；宽屏预览可见', (tester) async {
    final store = await _createStore();
    // 经指令通道补记：学习 09:00–10:00。
    await store.dispatcher.dispatch(CommandInvocation(
      name: 'add',
      args: const ['学习'],
      options: const {'start': '09:00', 'end': '10:00'},
    ));
    await _pumpApp(tester, store);
    // 切到今日页。
    await tester.tap(find.byIcon(Icons.calendar_today_outlined));
    await tester.pumpAndSettle();
    // 4 指标标签 + 汇总值。
    expect(find.text('总时长'), findsOneWidget);
    expect(find.text('会话数'), findsOneWidget);
    expect(find.text('专注时长'), findsOneWidget);
    expect(find.text('休息时长'), findsOneWidget);
    expect(find.text('01:00:00'), findsWidgets, reason: '总时长 1 小时');
    // 宽屏时间线预览可见。
    expect(find.text('时间线预览'), findsOneWidget);
    expect(find.text('查看完整时间线'), findsOneWidget);
    store.dispose();
  });

  testWidgets('今日页：日期步进 → 空日态；紧凑档隐藏预览', (tester) async {
    final store = await _createStore();
    await store.dispatcher.dispatch(CommandInvocation(
      name: 'add',
      args: const ['学习'],
      options: const {'start': '09:00', 'end': '10:00'},
    ));
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      TimeTrack2App(appStore: store, locale: const Locale('zh')),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byIcon(Icons.calendar_today_outlined));
    await tester.pumpAndSettle();
    // 紧凑档无预览卡。
    expect(find.text('时间线预览'), findsNothing);

    // 步进到明天 → 空日态。
    await tester.tap(find.byIcon(Icons.chevron_right_rounded));
    await tester.pumpAndSettle();
    expect(find.text('该日暂无记录'), findsOneWidget);
    expect(find.text('回到今天'), findsOneWidget);
    store.dispose();
  });

  testWidgets('今日页：分类筛选联动未分类组', (tester) async {
    final store = await _createStore();
    await store.dispatcher.dispatch(CommandInvocation(
      name: 'add',
      args: const ['学习'],
      options: const {'start': '09:00', 'end': '10:00'},
    ));
    await _pumpApp(tester, store);
    await tester.tap(find.byIcon(Icons.calendar_today_outlined));
    await tester.pumpAndSettle();
    // 未分类筛选 chip：学习无分类 → 命中"未分类"时仍在；先清空全部再选未分类。
    await tester.tap(find.text('清除筛选'));
    await tester.pump();
    // 未分配筛选 chip 翻转为选中态（学习无分类归属该组）。
    final chip = tester.widget<AppChip>(find.byType(AppChip).last);
    expect(chip.selected, isFalse);
    await tester.tap(find.byType(AppChip).last);
    await tester.pump();
    expect(tester.widget<AppChip>(find.byType(AppChip).last).selected, isTrue);
    store.dispose();
  });
}
