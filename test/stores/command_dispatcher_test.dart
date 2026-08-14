import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:timetrack2/constants/commands/command_definitions.dart';
import 'package:timetrack2/data/database/app_database.dart' hide ProfileSettings;
import 'package:timetrack2/data/interop/file_interop_service.dart';
import 'package:timetrack2/data/repositories/action_log_repository.dart';
import 'package:timetrack2/data/repositories/activity_repository.dart';
import 'package:timetrack2/data/repositories/category_repository.dart';
import 'package:timetrack2/data/repositories/settings_repository.dart';
import 'package:timetrack2/data/repositories/time_entry_repository.dart';
import 'package:timetrack2/data/repositories/tracking_rule_repository.dart';
import 'package:timetrack2/data/sync/sync_bundle_repository.dart';
import 'package:timetrack2/stores/category_store.dart';
import 'package:timetrack2/stores/clock_store.dart';
import 'package:timetrack2/stores/command_dispatcher.dart';
import 'package:timetrack2/stores/data_revision.dart';
import 'package:timetrack2/stores/timer_store.dart';
import 'package:timetrack2/stores/tracking_store.dart';
import 'package:timetrack2/stores/command_contracts.dart';
import 'package:timetrack2/stores/undo_store.dart';
import 'package:timetrack2/utils/command_parser.dart';
import 'package:timetrack2/utils/result.dart';
import 'package:timetrack2/viewmodels/commands/command_invocation.dart';
import 'package:timetrack2/viewmodels/tracking_rule.dart';

class _TestHarness {
  _TestHarness() {
    db = AppDatabase(NativeDatabase.memory());
    activities = ActivityRepository(database: db);
    categories = CategoryRepository(database: db);
    settings = SettingsRepository(database: db);
    entries = TimeEntryRepository(
      database: db,
      activityRepository: activities,
      settingsRepository: settings,
    );
    rules = TrackingRuleRepository(database: db);
    undo = UndoStore();
    revision = DataRevision();
    clock = ClockStore(autoStart: false);
    timer = TimerStore(
      entries: entries,
      undo: undo,
      clock: clock,
      dataRevision: revision,
    );
    category = CategoryStore(
      categories: categories,
      undo: undo,
      dataRevision: revision,
    );
    tracking = TrackingStore(
      rules: rules,
      timer: timer,
      dataRevision: revision,
      clock: clock,
      pollInterval: const Duration(seconds: 5),
    );
    syncBundleRepo = SyncBundleRepository(
      database: db,
      activities: activities,
      categories: categories,
      timeEntries: entries,
      actionLogs: ActionLogRepository(database: db),
      settings: settings,
    );
    fileInterop = FileInteropService(syncBundleRepository: syncBundleRepo);
    dispatcher = CommandDispatcher(
      undo: undo,
      timer: timer,
      sync: _NoopSync(),
      update: _NoopUpdate(),
      category: category,
      tracking: tracking,
      activities: activities,
      fileInterop: fileInterop,
      database: db,
    );
    parser = CommandParser(definitions: commandDefinitions);
  }

  late final AppDatabase db;
  late final ActivityRepository activities;
  late final CategoryRepository categories;
  late final SettingsRepository settings;
  late final TimeEntryRepository entries;
  late final TrackingRuleRepository rules;
  late final UndoStore undo;
  late final DataRevision revision;
  late final ClockStore clock;
  late final TimerStore timer;
  late final CategoryStore category;
  late final TrackingStore tracking;
  late final SyncBundleRepository syncBundleRepo;
  late final FileInteropService fileInterop;
  late final CommandDispatcher dispatcher;
  late final CommandParser parser;

  Future<void> close() async {
    tracking.dispose();
    category.dispose();
    timer.dispose();
    clock.dispose();
    revision.dispose();
    undo.dispose();
    await db.close();
  }
}

/// Dispatcher 的 sync/update 用最小 stub（本测试不覆盖它们）。
class _NoopSync implements SyncNowProvider {
  @override
  Future<AppResult<dynamic>> syncNow() async =>
      const AppFailure('sync stub 未配置');
}

class _NoopUpdate implements UpdateActions {
  @override
  Future<AppResult<dynamic>> check() async => const AppFailure('update stub 未配置');
  @override
  Future<AppResult<dynamic>> install() async => const AppFailure('update stub 未配置');
}

void main() {
  group('CommandDispatcher 路由', () {
    late _TestHarness h;

    setUp(() => h = _TestHarness());
    tearDown(() => h.close());

    Future<CommandResult> run(String text) async {
      final invocation = h.parser.parse(text).requireValue();
      return h.dispatcher.dispatch(invocation);
    }

    test('switch 指令：活动名→id 切换', () async {
      final a = (await h.activities.createActivity(name: '学习', color: 0))
          .requireValue();
      final result = await run('switch 学习');
      expect(result, isA<CommandSuccess>());
      expect((await h.entries.runningEntry())!.activityId, a.id);
    });

    test('switch 不存在的活动：明确失败', () async {
      final result = await run('switch 不存在活动');
      expect(result, isA<CommandFailure>());
      expect((result as CommandFailure).reason, contains('活动不存在'));
    });

    test('重名活动：歧义失败', () async {
      await h.activities.createActivity(name: 'A', color: 0);
      await h.activities.createActivity(name: 'A', color: 1);
      final result = await run('switch A');
      expect(result, isA<CommandFailure>());
      expect((result as CommandFailure).reason, contains('重名'));
    });

    test('add 指令：补记时间段（--start/--end）', () async {
      final a = (await h.activities.createActivity(name: '开会', color: 0))
          .requireValue();
      final result = await run('add 开会 --start=10:00 --end=11:00 --note=周会');
      expect(result, isA<CommandSuccess>());
      final today = await h.entries.entriesForDay(DateTime.now());
      expect(today, hasLength(1));
      expect(today.first.note, '周会');
      expect(today.first.activityId, a.id);
    });

    test('category_create 指令：新建分类', () async {
      final result = await run('category_create 工作');
      expect(result, isA<CommandSuccess>());
      expect((await h.categories.categories()).requireValue(), hasLength(1));
    });

    test('tracking_rule_create 指令：新建映射规则', () async {
      final a = (await h.activities.createActivity(name: '编码', color: 0))
          .requireValue();
      final result = await run(
          'tracking_rule_create code.exe --activity=编码 --kind=process');
      expect(result, isA<CommandSuccess>());
      final rules = (await h.rules.allRules()).requireValue();
      expect(rules, hasLength(1));
      expect(rules.first.activityId, a.id);
      expect(rules.first.matchKind, TrackingRuleMatchKind.process);
    });

    test('未知指令：parser 层明确失败（不进 dispatcher）', () async {
      // 指令定义即注册表：未知指令在 parser.parse 就拒绝（携带可用指令
      // 列表），不会到达 dispatcher 的 default 分支。
      final parseResult = h.parser.parse('foo bar');
      expect(parseResult, isA<AppFailure<CommandInvocation>>());
      expect((parseResult as AppFailure<CommandInvocation>).message,
          contains('未知指令'));
    });

    test('undo 指令：撤销 switch', () async {
      await h.activities.createActivity(name: '学习', color: 0);
      final firstSwitch = await run('switch 学习');
      expect(firstSwitch, isA<CommandSuccess>());
      // switch 前无运行条目 → 无 undo 记录 → undo 失败。
      final undoFail = await run('undo');
      expect(undoFail, isA<CommandFailure>());

      // 第二次 switch 后 undo：可撤销（恢复未结束态）。
      final secondSwitch = await run('switch 学习');
      expect(secondSwitch, isA<CommandSuccess>());
      final undoOk = await run('undo');
      expect(undoOk, isA<CommandSuccess>());
    });
  });
}
