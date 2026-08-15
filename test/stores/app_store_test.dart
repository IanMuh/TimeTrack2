import 'dart:async';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:timetrack2/api/supabase/sync_backend.dart';
import 'package:timetrack2/data/database/app_database.dart' hide ProfileSettings;
import 'package:timetrack2/stores/app_store.dart';
import 'package:timetrack2/viewmodels/commands/command_invocation.dart';
import 'package:timetrack2/utils/result.dart';

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

void main() {
  group('AppStore 组装与启动编排', () {
    test('create：组装全部 store 并加载缓存（内存库，跳过网络检查）', () async {
      final db = AppDatabase(NativeDatabase.memory());
      final store = await AppStore.create(
        database: db,
        backend: _FakeBackend(),
        runStartupChecks: false,
      );
      addTearDown(store.dispose);

      // 全部 store 可访问。
      expect(store.timer, isNotNull);
      expect(store.category, isNotNull);
      expect(store.settings, isNotNull);
      expect(store.today, isNotNull);
      expect(store.timeline, isNotNull);
      expect(store.stats, isNotNull);
      expect(store.sync, isNotNull);
      expect(store.update, isNotNull);
      expect(store.tracking, isNotNull);
      expect(store.dispatcher, isNotNull);
      expect(store.undo, isNotNull);

      // 启动编排副作用：4 个默认活动被 seed、设置已加载。
      final seedActivities =
          await store.activities.activities();
      expect(seedActivities.requireValue(), hasLength(4));
      expect(store.settings.current, isNotNull); // 默认配置已加载
      expect(store.category.all, isNotNull);
    });

    test('dispatcher 可用：switch 指令经 AppStore 通道执行（seed 活动）', () async {
      final db = AppDatabase(NativeDatabase.memory());
      final store = await AppStore.create(
        database: db,
        backend: _FakeBackend(),
        runStartupChecks: false,
      );
      addTearDown(store.dispose);

      // seed 的活动含"学习"。
      final result = await store.dispatcher.dispatch(
        _invocation('switch 学习'),
      );
      expect(result, isA<CommandSuccess>());
      final running = await store.timer.entries.runningEntry();
      expect(running, isNotNull);
      expect(running!.isAuto, isFalse); // 手动 switch
    });

    test('create 支持显式 now/windowsInstaller 注入', () async {
      final db = AppDatabase(NativeDatabase.memory());
      final fixed = DateTime(2026, 8, 14, 12);
      final store = await AppStore.create(
        database: db,
        backend: _FakeBackend(),
        now: () => fixed,
        runStartupChecks: false,
      );
      addTearDown(store.dispose);
      expect(store.today.today, isEmpty); // 今日窗口正常
    });
  });
}

/// 构造指令（跳过 parser——测试聚焦 AppStore 组装与 dispatcher 接线；
/// parser 解析已由 command_parser_test 覆盖）。
// ignore: avoid_classes_with_only_static_members
CommandInvocation _invocation(String name) => CommandInvocation(
  name: name.split(' ').first,
  args: name.split(' ').skip(1).toList(),
);
