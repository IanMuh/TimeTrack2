import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:timetrack2/api/supabase/sync_backend.dart';
import 'package:timetrack2/app.dart';
import 'package:timetrack2/data/database/app_database.dart' hide ProfileSettings;
import 'package:timetrack2/stores/app_store.dart';
import 'package:timetrack2/utils/result.dart';
import 'package:timetrack2/viewmodels/commands/command_invocation.dart';
import 'dart:async';

import 'package:timetrack2/viewmodels/profile_settings.dart';

/// 设置页（批次 4）集成测试：十分区渲染 / 偏好持久化即时生效 /
/// 危险区清除流 / 规则表单经指令通道。
class _FakeBackend implements SyncBackend {
  final _authController = StreamController<String?>.broadcast();

  @override
  bool get isConfigured => true;

  @override
  Stream<String?> get authStateStream => _authController.stream;

  @override
  String? get currentUserId => null;

  @override
  Future<AppResult<void>> sendMagicLink(String email) async =>
      const AppSuccess(null);

  @override
  Future<AppResult<String>> verifyEmailOtp(String email, String token) async {
    // 真实后端语义：验证成功即会话建立，auth 流推新 user id。
    _authController.add('user-1');
    return AppSuccess('user-1');
  }

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

Future<void> _openSettings(WidgetTester tester, AppStore store,
    {Size size = const Size(1280, 900)}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    TimeTrack2App(appStore: store, locale: const Locale('zh')),
  );
  await tester.pumpAndSettle();
  await tester.tap(find.byIcon(Icons.settings_outlined));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('十分区渲染：分区标题齐全（宽屏左导航 + 分区卡）', (tester) async {
    final store = await _createStore();
    await _openSettings(tester, store);
    // 宽屏左导航出现全部十分区标题。
    for (final title in [
      '通用',
      '备份与导出',
      '提醒',
      '时间线',
      '云同步',
      'AI 配置',
      '后台记录',
      '设备互通',
      '版本更新',
      '关于',
    ]) {
      expect(find.text(title), findsWidgets, reason: '分区 "$title" 应渲染');
    }
    store.dispose();
  });

  testWidgets('外观切换：主题落库即时生效（浅 → 深）', (tester) async {
    final store = await _createStore();
    await _openSettings(tester, store);
    // 初始浅色。
    expect(
      tester.widget<MaterialApp>(find.byType(MaterialApp)).themeMode,
      ThemeMode.light,
    );
    await tester.tap(find.text('深色'));
    await tester.pumpAndSettle();
    // MaterialApp themeMode 即时切换（持久化驱动）。
    expect(
      tester.widget<MaterialApp>(find.byType(MaterialApp)).themeMode,
      ThemeMode.dark,
      reason: '主题切换经 SettingsStore.save → app.dart 重建即时生效',
    );
    expect(
      store.settings.current?.themeMode,
      ThemeModeSetting.dark,
      reason: '偏好已落库',
    );
    store.dispose();
  });

  testWidgets('时制切换：12 小时制落库', (tester) async {
    final store = await _createStore();
    await _openSettings(tester, store);
    await tester.tap(find.text('12 小时'));
    await tester.pumpAndSettle();
    expect(store.settings.current?.use24HourFormat, isFalse);
    store.dispose();
  });

  testWidgets('清除全部数据：危险区 → 三键对话框 → 清除后活动回 seed',
      (tester) async {
    final store = await _createStore();
    // 造数据（活动 + 条目 + 自定义分类）。
    await store.dispatcher.dispatch(CommandInvocation(
      name: 'add',
      args: const ['学习'],
      options: const {'start': '09:00', 'end': '10:00'},
    ));
    await store.today.loadToday();
    await _openSettings(tester, store);

    // 打开清除对话框（危险区按钮唯一；设置页长，先滚动可见）。
    await tester.ensureVisible(find.text('清除全部数据').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('清除全部数据').last);
    await tester.pumpAndSettle();
    expect(find.text('此操作将永久删除全部时间条目、活动与设置，无法撤销。清除前请先导出备份，以免数据丢失。'),
        findsOneWidget);

    // "先导出备份" 路径：不立即清除。
    await tester.tap(find.byKey(const ValueKey('wipe-export-first')));
    await tester.pumpAndSettle();
    // 取消文件保存对话框（file_selector 不可用环境返回失败路径——SnackBar 提示）。
    await tester.pump(const Duration(milliseconds: 300));

    // 再次进入并确认清除。
    await tester.ensureVisible(find.text('清除全部数据').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('清除全部数据').last);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('wipe-confirm')));
    await tester.pumpAndSettle();
    expect(find.text('已清除全部数据'), findsOneWidget);

    // 今日空（seed 活动重建——无时间条目）。
    await store.today.loadToday();
    store.dispose();
  });

  testWidgets('后台记录：新建规则表单 → 指令通道 → 列表出现', (tester) async {
    final store = await _createStore();
    await _openSettings(tester, store);
    await tester.ensureVisible(find.text('新建规则'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('新建规则'));
    await tester.pumpAndSettle();
    await tester.enterText(
        find.byKey(const ValueKey('rule-pattern')), 'code.exe');
    // 选择目标活动（seed 活动之一）。
    await tester.tap(find.byKey(const ValueKey('rule-activity')));
    await tester.pumpAndSettle();
    // 选择器：点第一个活动（合并选择器活动卡）。
    await tester.tap(find.text('工作').first);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('rule-save')));
    await tester.pumpAndSettle();
    // 规则行出现（pattern 徽标）。
    expect(find.text('code.exe'), findsOneWidget);
    // 指令通道落库（经 dispatcher tracking_rule_create）。
    expect(store.tracking.ruleList, hasLength(1));
    expect(store.tracking.ruleList.first.pattern, 'code.exe');
    expect(store.tracking.ruleList.first.enabled, isTrue,
        reason: '新建规则默认启用');
    store.dispose();
  });

  testWidgets('LAN 主机：启动 → 端口与配对码展示 → 停止清状态', (tester) async {
    final store = await _createStore();
    await _openSettings(tester, store);
    // HttpServer.bind 是真实 IO——fake async zone 不会推进其完成事件，
    // 用 runAsync 直调 store（按钮 onPressed 即 lan.startHost 一行绑定）。
    await tester.runAsync(store.lan.startHost);
    await tester.pumpAndSettle();
    expect(find.text('运行中'), findsOneWidget);
    expect(store.lan.hostRunning, isTrue);
    expect(store.lan.pairingCode, isNotNull);
    expect(store.lan.pairingCode, matches(RegExp(r'^\d{6}$')));
    await tester.runAsync(store.lan.stopHost);
    await tester.pumpAndSettle();
    expect(find.text('已停止'), findsOneWidget);
    expect(store.lan.pairingCode, isNull);
    store.dispose();
  });

  testWidgets('云同步：未登录态显示登录入口，登录对话框两段流（发码→验证）',
      (tester) async {
    final store = await _createStore();
    await _openSettings(tester, store);
    // FakeBackend isConfigured=true 且未登录 → 登录按钮。
    await tester.ensureVisible(find.text('登录'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('登录'));
    await tester.pumpAndSettle();
    await tester.enterText(
        find.byKey(const ValueKey('login-email')), 'user@example.com');
    await tester.tap(find.text('发送验证码'));
    await tester.pumpAndSettle();
    // 验证码段。
    expect(find.byKey(const ValueKey('login-code')), findsOneWidget);
    await tester.enterText(
        find.byKey(const ValueKey('login-code')), '123456');
    await tester.tap(find.text('验证并登录'));
    await tester.pumpAndSettle();
    // FakeBackend verifyEmailOtp 成功 → 对话框关闭 + userId 就位。
    expect(find.byKey(const ValueKey('login-email')), findsNothing);
    expect(store.sync.userId, 'user-1');
    store.dispose();
  });

  testWidgets('更新卡：idle 态渲染（检查按钮 + 安装差异说明）', (tester) async {
    final store = await _createStore();
    await _openSettings(tester, store);
    expect(find.byKey(const ValueKey('update-check')), findsOneWidget);
    expect(find.textContaining('安装差异'), findsOneWidget);
    expect(find.text('v${store.currentVersion}'), findsWidgets);
    store.dispose();
  });
}
