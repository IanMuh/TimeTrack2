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
import 'package:timetrack2/stores/activity_store.dart';
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
import 'package:timetrack2/viewmodels/activity.dart';
import 'package:timetrack2/viewmodels/time_entry.dart';
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
    activity = ActivityStore(
      activities: activities,
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
      activity: activity,
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
  late final ActivityStore activity;
  late final TrackingStore tracking;
  late final SyncBundleRepository syncBundleRepo;
  late final FileInteropService fileInterop;
  late final CommandDispatcher dispatcher;
  late final CommandParser parser;

  Future<void> close() async {
    tracking.dispose();
    activity.dispose();
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

  group('批次 5a：entry_update / activity_create', () {
    late _TestHarness h;

    setUp(() => h = _TestHarness());
    tearDown(() => h.close());

    Future<CommandResult> run(String text) async {
      final invocation = h.parser.parse(text).requireValue();
      return h.dispatcher.dispatch(invocation);
    }

    Future<String> seedEntry() async {
      await h.activities.createActivity(name: '学习', color: 0);
      final add = await run('add 学习 --start=10:00 --end=11:00 --note=旧备注');
      expect(add, isA<CommandSuccess>());
      final today = await h.entries.entriesForDay(DateTime.now());
      return today.first.id;
    }

    test('entry_update：部分更新字段 + 载荷透传', () async {
      final a2 = (await h.activities.createActivity(name: '阅读', color: 1))
          .requireValue();
      final id = await seedEntry();

      final result = await run(
          'entry_update $id --activity=阅读 --end=12:30 --note=新备注');
      expect(result, isA<CommandSuccess>());
      final payload = (result as CommandSuccess).data;
      expect(payload, isA<TimeEntry>());
      expect((payload as TimeEntry).endAt!.hour, 12);
      expect(payload.endAt!.minute, 30);

      final entry = (await h.entries.entryById(id))!;
      expect(entry.activityId, a2.id);
      // 换活动刷新快照（不变式 4）。
      expect(entry.activityNameSnapshot, '阅读');
      expect(entry.note, '新备注');
      // start 未提供 = 保持。
      expect(entry.startAt.hour, 10);
    });

    test('entry_update：时间相对条目所在日还原（历史条目跨零点切段）', () async {
      final id = await seedEntry();
      final before = (await h.entries.entryById(id))!;
      // 把起点挪到昨天 23:00（直接仓储改，模拟历史条目）。
      final yesterday = DateTime.now().subtract(const Duration(days: 1));
      await h.entries.updateEntryFields(
        entry: before,
        startAt: DateTime(yesterday.year, yesterday.month, yesterday.day, 23),
        endAt:
            DateTime(yesterday.year, yesterday.month, yesterday.day, 23, 30),
      );
      final historical = (await h.entries.entryById(id))!;

      final result = await run('entry_update $id --end=01:00');
      expect(result, isA<CommandSuccess>());
      // 跨天时段按本地日切段落库（不变式 3）——按**范围汇总**断言而非单行：
      // 显式 end 早于起点 → 视为次日凌晨（跨零点启发），总时长 120 分钟。
      final windowStart = historical.startAt;
      final windowEnd =
          DateTime(yesterday.year, yesterday.month, yesterday.day)
              .add(const Duration(days: 2));
      final segments = await h.entries.entriesForRange(windowStart, windowEnd);
      final total =
          segments.fold(Duration.zero, (d, e) => d + e.durationUntil(windowEnd));
      expect(total.inMinutes, 120);
      // start 未提供 = 保持原日期（首段沿用原 id、仍在原日）。
      final first = segments
          .reduce((a, b) => a.startAt.isBefore(b.startAt) ? a : b);
      expect(first.id, id);
      expect(first.startAt.day, historical.startAt.day,
          reason: 'start 未提供应保持原日期');
    });

    test('entry_update：跨零点延伸的邻日段独立存在，缩改不追溯删除', () async {
      final id = await seedEntry();
      final before = (await h.entries.entryById(id))!;
      final yesterday = DateTime.now().subtract(const Duration(days: 1));
      final yDay = DateTime(yesterday.year, yesterday.month, yesterday.day);
      // 先造成跨零点条目（昨日 23:00 → 今日 00:30）。
      await h.entries.updateEntryFields(
        entry: before,
        startAt:
            DateTime(yesterday.year, yesterday.month, yesterday.day, 23),
        endAt: yDay.add(const Duration(days: 1, minutes: 30)),
      );
      // 再缩回昨日单日（--start/--end 相对首段所在日解析）。
      final result = await run('entry_update $id --start=22:00 --end=23:00');
      expect(result, isA<CommandSuccess>());

      // 段模型：编辑只作用于被编辑行；此前跨零点延伸产生的今日 00:00–00:30
      // 段是独立条目（时间线可见、可单独编辑/删除），不被追溯清理——窗口
      // 内共两段 90 分钟；确定性派生 id 命中覆盖，不叠加重复行。
      final windowEnd = yDay.add(const Duration(days: 2));
      final segments = await h.entries.entriesForRange(yDay, windowEnd);
      expect(segments, hasLength(2));
      final total = segments.fold(
          Duration.zero, (d, e) => d + e.durationUntil(windowEnd));
      expect(total.inMinutes, 90);
      expect(segments.map((e) => e.id).toSet().length, segments.length,
          reason: '无重叠重复行');
      // 被编辑首段按新时段落库（原 id 保留给首段）。
      final edited = segments.where((e) => e.id == id).single;
      expect(edited.startAt.hour, 22);
      expect(edited.endAt!.hour, 23);
    });

    test('entry_update：undo 写回旧快照 / redo 写回新快照（单条记录）', () async {
      final id = await seedEntry();

      final edit = await run('entry_update $id --end=12:00 --note=改');
      expect(edit, isA<CommandSuccess>());
      expect((await h.entries.entryById(id))!.note, '改');

      // 单次 undo 即回到编辑前（旧 delete+add 语义需要两次）。
      final undo = await run('undo');
      expect(undo, isA<CommandSuccess>());
      final restored = (await h.entries.entryById(id))!;
      expect(restored.note, '旧备注');
      expect(restored.endAt!.hour, 11);
      expect(restored.endAt!.minute, 0);

      final redo = await run('redo');
      expect(redo, isA<CommandSuccess>());
      final redone = (await h.entries.entryById(id))!;
      expect(redone.note, '改');
      expect(redone.endAt!.hour, 12);
    });

    test('entry_update：无修改项/条目不存在 明确失败', () async {
      final id = await seedEntry();
      final noChange = await run('entry_update $id');
      expect(noChange, isA<CommandFailure>());

      final missing = await run('entry_update non-existent-id --note=x');
      expect(missing, isA<CommandFailure>());
      expect((missing as CommandFailure).reason, contains('不存在'));
    });

    test('entry_update：--end=now 绝对语义（跨天遗留条目精确结束在当前时刻）',
        () async {
      final id = await seedEntry();
      final before = (await h.entries.entryById(id))!;
      // 挪成 3 天前 22:00–23:00 的遗留条目：HH:MM 锚定条目所在日 + 单次
      // +1 天进位会把「结束到现在」算错近两天——now 特值不受此影响。
      final now = DateTime.now();
      final baseDay = DateTime(now.year, now.month, now.day)
          .subtract(const Duration(days: 3));
      await h.entries.updateEntryFields(
        entry: before,
        startAt: baseDay.add(const Duration(hours: 22)),
        endAt: baseDay.add(const Duration(hours: 23)),
      );

      final result = await run('entry_update $id --end=now');
      expect(result, isA<CommandSuccess>());
      // 段模型：跨 3 天延伸按本地日切段落库——最晚 endAt 即"现在"。
      final segments = await h.entries.entriesForRange(
          baseDay, baseDay.add(const Duration(days: 4)));
      final end = segments
          .map((e) => e.endAt)
          .whereType<DateTime>()
          .reduce((a, b) => a.isAfter(b) ? a : b);
      expect(end.difference(DateTime.now()).abs(),
          lessThan(const Duration(seconds: 5)),
          reason: '延伸到注入时钟的当前时刻（绝对语义）');
      expect(end.day, DateTime.now().day,
          reason: '落在今天，而非条目所在日的次日凌晨');
    });

    test('entry_update：--end 等于 --start 显式失败（不静默进位成 24 小时）',
        () async {
      final id = await seedEntry();
      final result = await run('entry_update $id --start=10:00 --end=10:00');
      expect(result, isA<CommandFailure>());
      expect((result as CommandFailure).reason, contains('结束时刻'));
    });

    test('entry_update：空串 --note 清空备注（编辑对话框清空保存路径）', () async {
      final id = await seedEntry();
      // 页面直发 CommandInvocation（不经 parser），空串必须按"清空"落库。
      final result = await h.dispatcher.dispatch(CommandInvocation(
        name: 'entry_update',
        args: [id],
        options: {'note': ''},
      ));
      expect(result, isA<CommandSuccess>());
      expect((await h.entries.entryById(id))!.note, isEmpty);
    });

    test('entry_update：跨零点编辑的 undo 软删派生段 / redo 复活（对称换血）',
        () async {
      final id = await seedEntry();
      final before = (await h.entries.entryById(id))!;
      final yesterday = DateTime.now().subtract(const Duration(days: 1));
      final yDay = DateTime(yesterday.year, yesterday.month, yesterday.day);
      await h.entries.updateEntryFields(
        entry: before,
        startAt: yDay.add(const Duration(hours: 23)),
        endAt: yDay.add(const Duration(hours: 23, minutes: 30)),
      );

      // 跨零点延伸：--end=00:30 产生今日派生段（首段原 id + 派生段）。
      final edit = await run('entry_update $id --end=00:30');
      expect(edit, isA<CommandSuccess>());
      final windowEnd = yDay.add(const Duration(days: 2));
      final segments = await h.entries.entriesForRange(yDay, windowEnd);
      expect(segments, hasLength(2));
      final derivedIds = segments.map((e) => e.id).toSet()..remove(id);
      expect(derivedIds, hasLength(1));
      final derivedId = derivedIds.single;

      // undo：派生段软删 + 原行复活（回到编辑前 23:00–23:30）。
      expect(await run('undo'), isA<CommandSuccess>());
      expect(await h.entries.entryById(derivedId), isNull,
          reason: 'undo 后派生段不再可见');
      final restored = await h.entries.entryByIdIncludingDeleted(id);
      expect(restored!.isDeleted, isFalse);
      expect(restored.endAt, yDay.add(const Duration(hours: 23, minutes: 30)));

      // redo：新段全集复活——派生段按确定性 id 复活，原行保持切段后时段。
      expect(await run('redo'), isA<CommandSuccess>());
      final revivedDerived = await h.entries.entryById(derivedId);
      expect(revivedDerived, isNotNull, reason: 'redo 复活派生段');
      expect(revivedDerived!.isDeleted, isFalse);
      final redone = await h.entries.entryById(id);
      expect(redone, isNotNull);
      expect(redone!.endAt, yDay.add(const Duration(days: 1)),
          reason: '首段切到当日零点');
    });

    test('activity_create：新建 + 载荷 + undo 软删 / redo 复活', () async {
      final result =
          await run('activity_create 阅读 --color=4294967040 --one_off=true');
      expect(result, isA<CommandSuccess>());
      final created = (result as CommandSuccess).data;
      expect(created, isA<Activity>());
      final activity = created as Activity;
      expect(activity.name, '阅读');
      expect(activity.isOneOff, isTrue);
      expect(activity.color, 4294967040);

      final undo = await run('undo');
      expect(undo, isA<CommandSuccess>());
      expect((await h.activities.activityById(activity.id))!.isDeleted, isTrue);

      final redo = await run('redo');
      expect(redo, isA<CommandSuccess>());
      expect((await h.activities.activityById(activity.id))!.isDeleted, isFalse);
    });

    test('activity_create：默认非 one-off；非法取值明确失败', () async {
      final ok = await run('activity_create 运动');
      expect(ok, isA<CommandSuccess>());
      final all = await h.activities.activities();
      expect(all.requireValue().map((a) => a.name), contains('运动'));

      final badColor = await run('activity_create A --color=red');
      expect(badColor, isA<CommandFailure>());
      expect((badColor as CommandFailure).reason, contains('颜色'));

      final badOneOff = await run('activity_create B --one_off=yes');
      expect(badOneOff, isA<CommandFailure>());
      expect((badOneOff as CommandFailure).reason, contains('one_off'));
    });
  });
}
