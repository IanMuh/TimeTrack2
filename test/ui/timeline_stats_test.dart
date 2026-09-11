import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:timetrack2/api/supabase/sync_backend.dart';
import 'package:timetrack2/app.dart';
import 'package:timetrack2/data/database/app_database.dart' hide ProfileSettings;
import 'package:timetrack2/stores/app_store.dart';
import 'package:timetrack2/utils/result.dart';
import 'package:timetrack2/viewmodels/commands/command_invocation.dart';

/// 时间线页 / 统计页集成测试（内存库 + 指令通道造数据）。
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

/// 套件时钟：真实**当日凌晨** 00:30——早于快速提醒触发时刻（09:00），
/// 防其模态在 pumpAndSettle 中弹出挡交互；又与 add 指令的 HH:MM 解析
/// （dispatcher 取真实今日）保持同一自然日，时间线/统计范围一致。
final DateTime _harnessNow = () {
  final r = DateTime.now();
  return DateTime(r.year, r.month, r.day, 0, 30);
}();

Future<AppStore> _createStore() {
  return AppStore.create(
    database: AppDatabase(NativeDatabase.memory()),
    backend: _FakeBackend(),
    runStartupChecks: false,
    now: () => _harnessNow,
  );
}

Future<void> _addToday(AppStore store, String start, String end) async {
  await store.dispatcher.dispatch(CommandInvocation(
    name: 'add',
    args: const ['学习'],
    options: {'start': start, 'end': end},
  ));
}

Future<void> _pump(WidgetTester tester, AppStore store) async {
  tester.view.physicalSize = const Size(1280, 900);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    TimeTrack2App(appStore: store, locale: const Locale('zh')),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('时间线：条目渲染 + 汇总数字 + 编辑器打开', (tester) async {
    final store = await _createStore();
    await _addToday(store, '09:00', '10:30');
    await _addToday(store, '11:00', '11:45');
    await _pump(tester, store);
    await tester.tap(find.byIcon(Icons.view_timeline_outlined));
    await tester.pumpAndSettle();
    // 汇总带：总时长 2:15。
    expect(find.text('总时长'), findsOneWidget);
    expect(find.text('2:15'), findsOneWidget);
    expect(find.text('会话数'), findsOneWidget);
    // 竖向时间轴节点卡（学习 ×2）。
    expect(find.text('学习'), findsNWidgets(4)); // 轴卡×2 + 列表行×2
    // 点击列表行开编辑器（新增/编辑对话框）。
    await tester.tap(find.text('学习').first);
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsOneWidget);
    expect(find.text('开始'), findsOneWidget);
    expect(find.text('结束'), findsOneWidget);
    store.dispose();
  });

  testWidgets('时间线：未来日期横幅 + 日志视图', (tester) async {
    final store = await _createStore();
    await _addToday(store, '09:00', '10:00');
    await _pump(tester, store);
    await tester.tap(find.byIcon(Icons.view_timeline_outlined));
    await tester.pumpAndSettle();
    // 步进到明天 → 空态 + 未来横幅。
    await tester.tap(find.byIcon(Icons.chevron_right_rounded).first);
    await tester.pumpAndSettle();
    expect(find.text('该日暂无记录'), findsOneWidget);
    expect(find.textContaining('未来日期暂无记录'), findsOneWidget);
    // 切日志视图：dispatch 已产生操作日志（switch/stop/add…）。
    await tester.tap(find.text('日志'));
    await tester.pumpAndSettle();
    expect(find.textContaining('暂无操作日志'), findsNothing);
    store.dispose();
  });

  testWidgets('统计：造数后渲染行与图表卡；昨天空态；AI 引导不报错', (tester) async {
    final store = await _createStore();
    await _addToday(store, '09:00', '10:00');
    await _addToday(store, '13:00', '15:30');
    await _pump(tester, store);
    await tester.tap(find.byIcon(Icons.pie_chart_outline));
    await tester.pumpAndSettle();
    // 维度 tab + 图表卡标题。
    expect(find.text('主分类 · 树聚合'), findsOneWidget);
    expect(find.text('活动'), findsAtLeastNWidgets(1));
    expect(find.text('每日分布'), findsOneWidget);
    expect(find.text('占比分布'), findsOneWidget);
    expect(find.text('每日明细'), findsOneWidget);
    // 排除自动开关存在。
    expect(find.text('排除自动条目'), findsOneWidget);
    // AI 入口：点击出引导（不抛错）。
    await tester.tap(find.text('AI 总结'));
    await tester.pumpAndSettle();
    expect(find.textContaining('尚未配置'), findsOneWidget);
    await tester.tap(find.text('暂不'));
    await tester.pumpAndSettle();
    // 范围切"昨天" → 空态引导。
    await tester.tap(find.text('昨天'));
    await tester.pumpAndSettle();
    expect(find.text('开始记录吧'), findsNWidgets(2)); // 空态标题 + 主按钮
    store.dispose();
  });

  testWidgets('统计：维度切换到活动 + 树筛选卡折叠（紧凑）', (tester) async {
    final store = await _createStore();
    await _addToday(store, '09:00', '10:00');
    await _pump(tester, store);
    await tester.tap(find.byIcon(Icons.pie_chart_outline));
    await tester.pumpAndSettle();
    // 维度切"活动"。
    await tester.tap(find.text('活动').last);
    await tester.pumpAndSettle();
    expect(find.text('学习'), findsAtLeastNWidgets(1));
    store.dispose();
  });

  testWidgets('统计：排除自动开关极性——默认计入自动，勾选后聚合/明细同口径剔除',
      (tester) async {
    final store = await _createStore();
    // 手动 00:00-00:10（学习）+ 自动 00:10-00:20（经计时写路径 isAuto 落库）。
    await _addToday(store, '00:00', '00:10');
    final auto = (await store.activities
            .createActivity(name: '自动备份', color: 1))
        .requireValue();
    final xuexi = (await store.activities.activities())
        .requireValue()
        .firstWhere((a) => a.name == '学习');
    final dayStart =
        DateTime(_harnessNow.year, _harnessNow.month, _harnessNow.day);
    await store.timer.switchToActivity(auto.id,
        isAuto: true, at: dayStart.add(const Duration(minutes: 10)));
    await store.timer.stopRunning(at: dayStart.add(const Duration(minutes: 20)));

    await _pump(tester, store);
    await tester.tap(find.byIcon(Icons.pie_chart_outline));
    await tester.pumpAndSettle();
    await tester.tap(find.text('活动').last); // 维度 → 活动（行 id = activity:<id>）
    await tester.pumpAndSettle();

    // 默认（开关关 = 计入）：学习 10 分钟在列，自动条目也在列。
    final included = store.stats.snapshot!;
    expect(
      included.rows
          .where((r) => r.id == 'activity:${xuexi.id}')
          .single
          .totalDuration,
      const Duration(minutes: 10),
    );
    expect(
      included.rows.where((r) => r.id == 'activity:${auto.id}'),
      isNotEmpty,
      reason: '开关默认关 = 自动条目计入聚合（极性回归锁）',
    );

    // 勾选「排除自动条目」→ 自动剔除，明细/图表/聚合行同口径。
    await tester.tap(find.text('排除自动条目'));
    await tester.pumpAndSettle();
    final excluded = store.stats.snapshot!;
    expect(excluded.rows.where((r) => r.id == 'activity:${auto.id}'), isEmpty);
    expect(
      excluded.rows
          .where((r) => r.id == 'activity:${xuexi.id}')
          .single
          .totalDuration,
      const Duration(minutes: 10),
    );
    store.dispose();
  });

  testWidgets('可疑条目：未分配遗留运行段不弹对话框（未记录态非可疑）',
      (tester) async {
    final store = await _createStore();
    // 上次会话 00:00 记录、00:10 停止 → 留下 00:10 起的未分配运行段
    //（早于会话起点 00:30）。修复前会误弹「发现遗留运行条目」。
    final a = (await store.activities.createActivity(name: '临时', color: 1))
        .requireValue();
    final dayStart =
        DateTime(_harnessNow.year, _harnessNow.month, _harnessNow.day);
    await store.timer.switchToActivity(a.id, at: dayStart);
    await store.timer.stopRunning(at: dayStart.add(const Duration(minutes: 10)));

    await _pump(tester, store);
    expect(find.byType(AlertDialog), findsNothing,
        reason: '未记录态的跨会话运行段不属可疑，不弹决策对话框');
    store.dispose();
  });

  testWidgets('可疑条目：真实活动遗留运行段弹决策框，「结束到现在」落当前时刻',
      (tester) async {
    final store = await _createStore();
    // 阈值调大防运行阈值提醒（运行条目 00:00 起，会话起点 00:30 已达 30 分钟）。
    await store.settings.reload();
    await store.settings
        .save(store.settings.current!.copyWith(reminderMinutes: 600));
    final a = (await store.activities.createActivity(name: '遗留任务', color: 2))
        .requireValue();
    final dayStart =
        DateTime(_harnessNow.year, _harnessNow.month, _harnessNow.day);
    await store.timer.switchToActivity(a.id, at: dayStart);

    await _pump(tester, store);
    expect(find.text('发现遗留运行条目'), findsOneWidget);
    // 「结束到现在」= entry_update --end=now（绝对语义）。
    await tester.tap(find.text('结束到现在'));
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsNothing);
    expect(store.timer.runningEntry, isNull,
        reason: '遗留条目已结束（end=now 落库成功；若指令失败条目仍在运行）');
    store.dispose();
  });
}
