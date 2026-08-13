import 'package:drift/drift.dart' show InsertMode, Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:timetrack2/api/supabase/cloud_sync_engine.dart';
import 'package:timetrack2/api/supabase/sync_backend.dart';
import 'package:timetrack2/api/supabase/sync_status_store.dart';
import 'package:timetrack2/data/database/app_database.dart';
import 'package:timetrack2/data/repositories/action_log_repository.dart';
import 'package:timetrack2/data/repositories/activity_repository.dart';
import 'package:timetrack2/data/repositories/category_repository.dart';
import 'package:timetrack2/data/repositories/settings_repository.dart';
import 'package:timetrack2/data/repositories/time_entry_repository.dart';
import 'package:timetrack2/data/repositories/tracking_rule_repository.dart';
import 'package:timetrack2/viewmodels/action_log.dart';
import 'package:timetrack2/viewmodels/activity.dart';
import 'package:timetrack2/viewmodels/activity_category.dart';
import 'package:timetrack2/viewmodels/profile_settings.dart' as settings_vm;
import 'package:timetrack2/viewmodels/time_entry.dart';
import 'package:timetrack2/viewmodels/tracking_rule.dart';

import 'memory_remote.dart';

/// 云同步测试环境：内存库 + 内存远端 + 引擎。
class CloudHarness {
  CloudHarness._(this.db, this.activities, this.categories, this.settings,
      this.actionLogs, this.entries, this.statusStore, this.remote, this.engine,
      this.trackingRules);

  static CloudHarness create({int pageSize = 999}) {
    final remote = MemoryRemote();
    return _build(remote: remote, pageSize: pageSize);
  }

  /// 宽松模式 harness：远端允许无主行（[MemoryRemote.allowUnownedRows]）——
  /// 模拟"远端遗留无归属行"的历史数据场景（见 [MemoryRemote.seedUnowned]）。
  static CloudHarness createLoose({int pageSize = 999}) {
    final remote = MemoryRemote()..allowUnownedRows = true;
    return _build(remote: remote, pageSize: pageSize);
  }

  static CloudHarness _build({
    required MemoryRemote remote,
    required int pageSize,
  }) {
    final db = AppDatabase(NativeDatabase.memory());
    final activities = ActivityRepository(database: db);
    final categories = CategoryRepository(database: db);
    final settings = SettingsRepository(database: db);
    final actionLogs = ActionLogRepository(database: db);
    final entries = TimeEntryRepository(
      database: db,
      activityRepository: activities,
      settingsRepository: settings,
    );
    final statusStore = SyncStatusStore(database: db);
    final trackingRules = TrackingRuleRepository(database: db);
    final engine = CloudSyncEngine(
      database: db,
      gateway: remote,
      statusStore: statusStore,
      activities: activities,
      categories: categories,
      timeEntries: entries,
      actionLogs: actionLogs,
      settings: settings,
      trackingRules: trackingRules,
      pageSize: pageSize,
    );
    return CloudHarness._(db, activities, categories, settings, actionLogs,
        entries, statusStore, remote, engine, trackingRules);
  }

  final AppDatabase db;
  final ActivityRepository activities;
  final CategoryRepository categories;
  final SettingsRepository settings;
  final ActionLogRepository actionLogs;
  final TimeEntryRepository entries;
  final SyncStatusStore statusStore;
  final MemoryRemote remote;
  final CloudSyncEngine engine;
  final TrackingRuleRepository trackingRules;

  /// 引擎单用户测试的约定用户：与 memory_remote 的 seed 默认归属同源
  ///（seed 未显式带 user_id 的行注入该值；两处共享单一事实来源防漂移）。
  static const userId = MemoryRemote.defaultSeedUserId;

  Future<void> close() => db.close();
}

void main() {
  group('CloudSyncEngine 拉取（先拉）', () {
    test('从未同步 → 全量拉取（since=null），远端行落本地', () async {
      final h = CloudHarness.create();
      try {
        final remoteActivity = Activity(
          id: 'remote-a',
          name: '远端活动',
          color: 0xff123456,
          isFavorite: true,
          updatedAt: DateTime(2026, 8, 11, 10),
        );
        h.remote.seed(RemoteTables.activities, remoteActivity.toMap());

        final report = (await h.engine.syncNow(userId: CloudHarness.userId))
            .requireValue();
        expect(report.wasFullSync, isTrue, reason: '从未同步 → 全量');
        expect(report.pulledRows, 1);

        final local = (await h.activities.activities()).requireValue();
        expect(local.map((a) => a.id), contains('remote-a'));
        expect(local.firstWhere((a) => a.id == 'remote-a').name, '远端活动');
      } finally {
        await h.close();
      }
    });

    test('拉取分页：pageSize=2 时逐页拉全，页集合不重叠且并集覆盖全部', () async {
      final h = CloudHarness.create(pageSize: 2);
      try {
        final allIds = <String>{};
        for (var i = 0; i < 5; i++) {
          final id = 'a$i';
          allIds.add(id);
          h.remote.seed(
            RemoteTables.activities,
            Activity(
              id: id,
              name: '活动$i',
              color: 0,
              isFavorite: false,
              updatedAt: DateTime(2026, 8, 10, 0, 0, i),
            ).toMap(),
          );
        }
        final report =
            (await h.engine.syncNow(userId: CloudHarness.userId)).requireValue();
        expect(report.pulledRows, 5);
        expect((await h.activities.activities()).requireValue(), hasLength(5));

        // 精确断言：5 行 pageSize=2 → 恰好 3 次 activities 拉取，页偏移逐页推进。
        // **锁定意图（r53 注明）**：该精确计数锁定的是**引擎"短页终止"停止
        // 条件**（拉到 hasMore=false 即停，不多拉空页/死循环）——不是 mock
        // 内部切片实现；mock 的偏移分页语义本就是网关契约的镜像（与真网关
        // range 分页对齐），计数随 mock 语义调整而变红属预期（同步调整即可）。
        final pullCalls =
            h.remote.pullLog.where((c) => c.table == 'activities').toList();
        expect(pullCalls, hasLength(3), reason: '5 行 pageSize=2 需 3 页');
        expect(pullCalls.map((c) => c.page).toList(), [0, 1, 2],
            reason: '页偏移必须逐页推进（防重复拉取同一页）');

        // 各页返回行集合互不重叠、并集等于全部远端行（防分页错位漏拉/重拉）。
        final seen = <String>{};
        for (var i = 0; i < pullCalls.length; i++) {
          final pageRows = await h.remote.fetchRowsSince(
            table: RemoteTables.activities,
            userId: CloudHarness.userId,
            pageSize: 2,
            page: i,
          );
          final ids = pageRows.rows.map((r) => r['id']! as String).toList();
          for (final id in ids) {
            expect(seen.add(id), isTrue, reason: '页 $i 与前面页重叠：$id');
          }
        }
        expect(seen, allIds, reason: '各页并集必须等于全部远端行');
      } finally {
        await h.close();
      }
    });

    test('拉取 LWW：远端更新的行覆盖本地，本地更新的行不被覆盖', () async {
      final h = CloudHarness.create();
      try {
        final localActivity = (await h.activities.createActivity(
          name: '本地活动',
          color: 0xff000000,
        ))
            .requireValue();

        // 远端旧行（updatedAt 早于本地）→ 不覆盖
        final staleRemote = localActivity.copyWith(
          name: '远端旧名',
          updatedAt: localActivity.updatedAt.subtract(const Duration(hours: 1)),
        );
        h.remote.seed(RemoteTables.activities, staleRemote.toMap());
        await h.engine.syncNow(userId: CloudHarness.userId);
        var after =
            (await h.activities.activities()).requireValue().firstWhere(
                  (a) => a.id == localActivity.id,
                );
        expect(after.name, '本地活动', reason: '旧远端不覆盖新本地');

        // 远端新行（updatedAt 晚于本地，且落在 markSuccess 合理性容差内）→ 覆盖
        final newRemote = localActivity.copyWith(
          name: '远端新名',
          updatedAt: localActivity.updatedAt.add(const Duration(minutes: 1)),
        );
        h.remote.seed(RemoteTables.activities, newRemote.toMap());
        (await h.engine.syncNow(userId: CloudHarness.userId)).requireValue();
        after = (await h.activities.activities()).requireValue().firstWhere(
              (a) => a.id == localActivity.id,
            );
        expect(after.name, '远端新名', reason: '新远端覆盖旧本地');
      } finally {
        await h.close();
      }
    });

    test('删除传播：远端墓碑（deleted_at）→ 本地行被软删', () async {
      final h = CloudHarness.create();
      try {
        final localActivity = (await h.activities.createActivity(
          name: '待删',
          color: 0xff112233,
        ))
            .requireValue();

        // 远端墓碑：updatedAt 晚于本地 + deleted_at 非空
        final tombstone = localActivity.copyWith(
          deletedAt: localActivity.updatedAt.add(const Duration(minutes: 1)),
          updatedAt: localActivity.updatedAt.add(const Duration(minutes: 1)),
        );
        h.remote.seed(RemoteTables.activities, tombstone.toMap());
        await h.engine.syncNow(userId: CloudHarness.userId);

        final active = (await h.activities.activities()).requireValue();
        expect(active.map((a) => a.id), isNot(contains(localActivity.id)),
            reason: '远端墓碑随 LWW 传播删除本地行');
        // 软删不变量：行仍存在（含删查询可见）且 deletedAt 已置位（防实现
        // 退化为硬删而测试误通过）。
        final withDeleted =
            (await h.activities.activities(includeDeleted: true)).requireValue();
        final tombstoned =
            withDeleted.firstWhere((a) => a.id == localActivity.id);
        expect(tombstoned.isDeleted, isTrue, reason: '墓碑行保留且标记软删');
        expect(tombstoned.deletedAt, isNotNull);
      } finally {
        await h.close();
      }
    });

    test('删除冲突平局：相等时间戳下远端墓碑仍胜出（删除永远赢，r52 补锁）', () async {
      // **平局决胜分支锁定**：replaceIfRemoteNewer 的决胜规则含
      // `updatedAt 相等 && 远端删除 && 本地存活` 分支（删除永远赢）——但删除
      // 传播用例都用 +1min 严格更新触发，从未用**相等时间戳**触发该分支；
      // 多设备时钟偏差/离线编辑下平局真实存在，须显式锁定（防实现把平局
      // 改为"远端不覆盖"后删除静默失效而测试仍通过）。
      final h = CloudHarness.create();
      try {
        final t0 = DateTime(2026, 8, 11, 10).toUtc();
        final localActivity = (await h.activities.createActivity(
          name: '本地存活',
          color: 0xff112233,
        ))
            .requireValue();
        // 本地 updatedAt 与远端墓碑**完全相同**（force 覆盖：本地行时间与
        // 远端墓碑时间对齐——平局场景）。
        final tombstone = localActivity.copyWith(
          deletedAt: t0,
          updatedAt: t0,
        );
        // 本地行时间也对齐 t0（写库覆盖）。
        await h.db.into(h.db.activities).insert(
              ActivitiesCompanion.insert(
                id: localActivity.id,
                userId: const Value(CloudHarness.userId),
                name: '本地存活',
                color: 0xff112233,
                isFavorite: const Value(false),
                updatedAt: t0.toIso8601String(),
                deletedAt: const Value(null),
              ),
              mode: InsertMode.insertOrReplace,
            );
        h.remote.seed(RemoteTables.activities, tombstone.toMap());
        await h.engine.syncNow(userId: CloudHarness.userId);

        final withDeleted =
            (await h.activities.activities(includeDeleted: true)).requireValue();
        final row = withDeleted.firstWhere((a) => a.id == localActivity.id);
        expect(row.isDeleted, isTrue,
            reason: '相等时间戳下远端删除墓碑胜出（平局决胜分支生效）');
      } finally {
        await h.close();
      }
    });

    test('相等时间戳 + 远端存活 → 本地删除保留（复活需严格更晚，r52 补锁）', () async {
      // **平局决胜语义（deliberate LWW，r53 标题修正）**：多设备场景"本地
      // 墓碑 + 远端存活行"且时间戳**相等**时——pull 按"远端非删除 + 时间不
      // 早于本地"不应用（删除保留）；push 按"远端严格更晚才跳过"的防旧规则
      // **照常写回本地墓碑**（`isAfter` 对相等为 false，不跳过）——远端存活
      // 行被本地删除**撤销**（复活语义）。这是行级 LWW 的有意行为（删除与
      // 存活同权重、时间戳决胜；删除方须**严格更晚**才赢），不是缺陷——
      // 显式锁定防误改。
      final h = CloudHarness.create();
      try {
        final t0 = DateTime(2026, 8, 11, 10).toUtc();
        // 远端存活行：时间戳 t0（与本地墓碑相等——平局）。
        final remoteLive = Activity(
          id: 'revive-1',
          name: '远端存活',
          color: 0xffaabbcc,
          isFavorite: false,
          userId: CloudHarness.userId,
          updatedAt: t0,
        );
        h.remote.seed(RemoteTables.activities, remoteLive.toMap());
        // 本地墓碑：同样时间戳 t0。
        await h.db.into(h.db.activities).insert(
              ActivitiesCompanion.insert(
                id: 'revive-1',
                userId: const Value(CloudHarness.userId),
                name: '本地已删',
                color: 0xffaabbcc,
                isFavorite: const Value(false),
                updatedAt: t0.toIso8601String(),
                deletedAt: Value(t0.toIso8601String()),
              ),
              mode: InsertMode.insertOrReplace,
            );
        await h.engine.syncNow(userId: CloudHarness.userId);
        // 平局 + 远端存活：本地删除保留；push 相等时间戳照常写回墓碑（防旧
        // 仅对"远端严格更晚"生效）——"复活"语义：删除方需严格更晚才赢。
        final withDeleted =
            (await h.activities.activities(includeDeleted: true)).requireValue();
        final row = withDeleted.firstWhere((a) => a.id == 'revive-1');
        expect(row.isDeleted, isTrue,
            reason: '平局 + 远端存活不撤销本地删除（删除方时间不严格更晚）');
      } finally {
        await h.close();
      }
    });

    test('分类/条目/日志冒烟：远端行拉回本地并 LWW 应用', () async {
      final h = CloudHarness.create();
      try {
        // 远端分类（含 parent_id）
        final remoteCategory = ActivityCategory(
          id: 'cat-1',
          name: '远端分类',
          color: 0xff0f766e,
          updatedAt: DateTime(2026, 8, 11, 10),
        );
        h.remote.seed(RemoteTables.categories, remoteCategory.toMap());

        // 远端活动 + 关联（拉回顺序：活动 → 分类 → 关联，FK 依赖方向）
        final remoteActivity = Activity(
          id: 'act-1',
          name: '远端活动',
          color: 0xff2563eb,
          isFavorite: true,
          updatedAt: DateTime(2026, 8, 11, 10),
        );
        h.remote.seed(RemoteTables.activities, remoteActivity.toMap());
        final remoteLink = ActivityCategoryLink(
          id: 'link-1',
          activityId: 'act-1',
          categoryId: 'cat-1',
          updatedAt: DateTime(2026, 8, 11, 10),
        );
        h.remote.seed(RemoteTables.links, remoteLink.toMap());

        // 远端条目 + 日志
        final remoteEntry = TimeEntry(
          id: 'entry-1',
          activityId: 'act-1',
          activityNameSnapshot: '远端活动',
          activityColorSnapshot: 0xff2563eb,
          startAt: DateTime(2026, 8, 11, 9),
          endAt: DateTime(2026, 8, 11, 10),
          deviceId: 'devX',
          updatedAt: DateTime(2026, 8, 11, 10),
        );
        h.remote.seed(RemoteTables.timeEntries, remoteEntry.toMap());
        final remoteLog = ActionLog(
          id: 'log-1',
          actionType: ActionType.switch_,
          occurredAt: DateTime(2026, 8, 11, 9),
          deviceId: 'devX',
          updatedAt: DateTime(2026, 8, 11, 10),
        );
        h.remote.seed(RemoteTables.actionLogs, remoteLog.toMap());

        await h.engine.syncNow(userId: CloudHarness.userId);

        // 全部落本地
        final cats = (await h.categories.categories()).requireValue();
        expect(cats.map((c) => c.id), contains('cat-1'));
        final links = (await h.categories.links()).requireValue();
        expect(links.map((l) => l.id), contains('link-1'));
        final entries = await h.entries.allEntries();
        expect(entries.map((e) => e.id), contains('entry-1'));
        final logs = (await h.actionLogs.allLogs()).requireValue();
        expect(logs.map((l) => l.id), contains('log-1'));
      } finally {
        await h.close();
      }
    });
  });

  group('CloudSyncEngine 推送（后推）', () {
    test('防旧推送：本地旧值不覆盖远端更新的行（LWW 决胜）', () async {
      final h = CloudHarness.create();
      try {
        final localActivity = (await h.activities.createActivity(
          name: '本地新活动',
          color: 0xffaabbcc,
        ))
            .requireValue();

        // 远端已有该 id、updatedAt 更新、且字段完整（远端新名）。
        // +1min（落在 markSuccess 合理性容差内，且晚于本地创建时间）。
        final remoteNewer = localActivity.copyWith(
          name: '远端新名',
          updatedAt: localActivity.updatedAt.add(const Duration(minutes: 1)),
        );
        h.remote.seed(RemoteTables.activities, remoteNewer.toMap());

        (await h.engine.syncNow(userId: CloudHarness.userId)).requireValue();
        // 防旧推送的本质：无论推送是否执行（相等时间戳写回也属 LWW 幂等），
        // 远端行内容与 updated_at 都不被本地旧值破坏——验证远端保持更新值。
        final remoteRow = h.remote.tables[RemoteTables.activities]![
            localActivity.id]!;
        expect(remoteRow['name'], '远端新名',
            reason: '远端更新 ⇒ 本地不覆盖（防旧推送）');
        // 远端仍保留其更新的 updated_at（未被本地旧时间戳回退）
        final remoteUpdatedAt =
            DateTime.parse(remoteRow['updated_at']! as String);
        expect(
          remoteUpdatedAt.isAfter(localActivity.updatedAt),
          isTrue,
          reason: '远端 updated_at 保持更新值',
        );
      } finally {
        await h.close();
      }
    });

    test('推送删除传播：本地软删活动 → 远端行带墓碑（含远端无该行）', () async {
      final h = CloudHarness.create();
      try {
        // 场景 A：远端已有该行（存活）→ 本地软删 → 推送后远端墓碑
        final localActivity = (await h.activities.createActivity(
          name: '待删A',
          color: 0xff112233,
        ))
            .requireValue();
        h.remote.seed(RemoteTables.activities, localActivity.toMap());
        await h.engine.syncNow(userId: CloudHarness.userId);
        expect(
          h.remote.tables[RemoteTables.activities]![localActivity.id]!['deleted_at'],
          isNull,
          reason: '初始远端存活',
        );

        await h.activities.deleteActivity(localActivity);
        await h.engine.syncNow(userId: CloudHarness.userId);
        final tombstone =
            h.remote.tables[RemoteTables.activities]![localActivity.id]!;
        expect(tombstone['deleted_at'], isNotNull,
            reason: '本地软删墓碑推送到远端');
        expect(
          DateTime.parse(tombstone['updated_at']! as String)
              .isAfter(localActivity.updatedAt),
          isTrue,
          reason: '墓碑推进 updated_at（删除永远赢）',
        );

        // 场景 B：远端无该行 → 本地软删墓碑也应推送（不因远端缺失而漏推）
        final second = (await h.activities.createActivity(
          name: '待删B',
          color: 0xff445566,
        ))
            .requireValue();
        await h.activities.deleteActivity(second);
        await h.engine.syncNow(userId: CloudHarness.userId);
        final remoteTombstone =
            h.remote.tables[RemoteTables.activities]![second.id];
        expect(remoteTombstone, isNotNull, reason: '远端无行时墓碑也要推送');
        expect(remoteTombstone!['deleted_at'], isNotNull);
      } finally {
        await h.close();
      }
    });

    test('推送跳过分支：拉取后远端被并发更新 → 本地旧值不写回（remoteAt.isAfter 触发）', () async {
      final h = CloudHarness.create();
      try {
        // 首次全量同步：本地 A 推送到远端（远端无该行 → 无跳过）。
        final a = (await h.activities.createActivity(
          name: '并发活动',
          color: 0xffaabbcc,
        ))
            .requireValue();
        (await h.engine.syncNow(userId: CloudHarness.userId)).requireValue();
        expect(h.remote.lastPushedIds, contains(a.id),
            reason: '首次推送落库');

        // 第二次同步：拉取阶段远端无新值（本地已是远端副本，相等不覆盖）。
        // 推送检查（fetchRemoteUpdatedAt）时模拟远端被并发更新（时间戳 +1min
        // 更晚）→ remoteAt.isAfter(local) 成立 → 该行被跳过、不写回。
        h.remote.updatedAtBias[a.id] = const Duration(minutes: 1);
        h.remote.lastPushedIds.clear();
        (await h.engine.syncNow(userId: CloudHarness.userId)).requireValue();
        expect(h.remote.lastPushedIds, isNot(contains(a.id)),
            reason: '远端严格更新 ⇒ 推送跳过（本地旧值不覆盖远端新值）');
      } finally {
        await h.close();
      }
    });

    test('本地更新推送：远端内容与 updated_at 均推进为本地新值，下一轮不重复推送', () async {
      final h = CloudHarness.create();
      try {
        // 首次全量同步：本地 A 推送到远端。
        final a = (await h.activities.createActivity(
          name: '原始名',
          color: 0xffaabbcc,
        ))
            .requireValue();
        (await h.engine.syncNow(userId: CloudHarness.userId)).requireValue();
        final pushedBefore =
            h.remote.tables[RemoteTables.activities]![a.id]!;
        final remoteBefore =
            DateTime.parse(pushedBefore['updated_at']! as String);

        // 本地更新活动（改名）→ 推送后远端内容/updated_at 均为本地新值。
        final updated = (await h.activities.updateActivity(
          activity: a,
          name: '新名',
          color: 0xff112233,
        ))
            .requireValue();
        (await h.engine.syncNow(userId: CloudHarness.userId)).requireValue();
        final pushedAfter =
            h.remote.tables[RemoteTables.activities]![a.id]!;
        expect(pushedAfter['name'], '新名', reason: '远端内容被本地更新覆盖');
        final remoteAfter =
            DateTime.parse(pushedAfter['updated_at']! as String);
        expect(remoteAfter.isAfter(remoteBefore), isTrue,
            reason: '远端 updated_at 推进为本地新值');
        expect(remoteAfter.isAtSameMomentAs(updated.updatedAt), isTrue);

        // 下一轮：`>= since` 包含式游标 + 相等时间戳写回（已接受的设计取舍，
        // LWW 幂等）——重复推送不改变远端值，收敛稳定。
        final nameBefore = pushedAfter['name'];
        final atBefore =
            DateTime.parse(pushedAfter['updated_at']! as String);
        h.remote.lastPushedIds.clear();
        (await h.engine.syncNow(userId: CloudHarness.userId)).requireValue();
        final stable =
            h.remote.tables[RemoteTables.activities]![a.id]!;
        expect(stable['name'], nameBefore,
            reason: '重复推送不改变远端内容（LWW 幂等收敛）');
        expect(
          DateTime.parse(stable['updated_at']! as String)
              .isAtSameMomentAs(atBefore),
          isTrue,
          reason: '重复推送不改变远端 updated_at',
        );
      } finally {
        await h.close();
      }
    });

    test('推送补填 user_id；远端无该行则推送', () async {
      final h = CloudHarness.create();
      try {
        final localActivity = (await h.activities.createActivity(
          name: '待推送',
          color: 0xff010203,
        ))
            .requireValue();

        final report =
            (await h.engine.syncNow(userId: CloudHarness.userId)).requireValue();
        expect(report.pushedRows, greaterThanOrEqualTo(1));

        final remoteRow = h.remote.tables[RemoteTables.activities]![
            localActivity.id]!;
        expect(remoteRow['user_id'], CloudHarness.userId,
            reason: '推送补填 user_id');
        expect(remoteRow['name'], '待推送');
      } finally {
        await h.close();
      }
    });
  });

  group('CloudSyncEngine 游标与顺序', () {
    test('先拉后推：所有拉取在第一个推送之前', () async {
      final h = CloudHarness.create();
      try {
        final a = (await h.activities.createActivity(
          name: '活动',
          color: 0,
        ))
            .requireValue();
        h.remote.seed(RemoteTables.activities, a.copyWith(
          name: '远端名',
          updatedAt: a.updatedAt.add(const Duration(minutes: 1)),
        ).toMap());

        await h.engine.syncNow(userId: CloudHarness.userId);
        expectPullBeforePush(h.remote.callLog);
      } finally {
        await h.close();
      }
    });

    test('成功后推进游标并清错误；失败不清游标且记录错误', () async {
      final h = CloudHarness.create();
      try {
        // 首轮 seed 远端行：空全量同步不推进游标（防墙钟竞态漏推），
        // 有实际拉取才建立游标。
        h.remote.seed(
          RemoteTables.activities,
          Activity(
            id: 'first-seed',
            name: '初始行',
            color: 0,
            isFavorite: false,
            updatedAt: DateTime(2026, 8, 11, 10),
          ).toMap(),
        );
        // 成功一次 → 游标推进
        await h.engine.syncNow(userId: CloudHarness.userId);
        var status = (await h.statusStore.read(userId: CloudHarness.userId)).requireValue();
        expect(status.hasSynced, isTrue, reason: '成功即视为已同步（游标非空）');
        expect(status.lastSuccessfulSyncAt, isNotNull);
        expect(status.lastError, isNull);
        expect(status.lastTarget, SyncTarget.supabase);
        final cursorAfterFirst = status.lastSuccessfulSyncAt!;

        // 失败 → 错误记录、游标保持
        h.remote.nextError = Exception('网络中断');
        final failed = await h.engine.syncNow(userId: CloudHarness.userId);
        expect(failed.isSuccess, isFalse);
        status = (await h.statusStore.read(userId: CloudHarness.userId)).requireValue();
        expect(status.lastError, isNotNull, reason: '失败记录原因');
        expect(status.hasSynced, isTrue, reason: '失败不清游标');
        expect(status.lastSuccessfulSyncAt, cursorAfterFirst,
            reason: '失败不清游标');

        // 恢复：远端新增一行（updatedAt 晚于游标）→ 游标推进到该行时间
        final newRemote = Activity(
          id: 'new-remote',
          name: '恢复后的新行',
          color: 0,
          isFavorite: false,
          updatedAt: cursorAfterFirst.add(const Duration(minutes: 5)),
        );
        h.remote.seed(RemoteTables.activities, newRemote.toMap());
        await h.engine.syncNow(userId: CloudHarness.userId);
        status = (await h.statusStore.read(userId: CloudHarness.userId)).requireValue();
        expect(status.lastError, isNull, reason: '成功后清除错误');
        expect(
          status.lastSuccessfulSyncAt!.isAfter(cursorAfterFirst),
          isTrue,
          reason: '游标推进到本次拉取的最大行 updated_at',
        );
        expect(
          status.lastSuccessfulSyncAt!.isAtSameMomentAs(
            newRemote.updatedAt,
          ),
          isTrue,
          reason: '游标 = 最大行时间（非墙钟）',
        );
      } finally {
        await h.close();
      }
    });

    test('拉取中途失败：部分行已落库但游标不推进，重试按原游标重拉补齐', () async {
      final h = CloudHarness.create(pageSize: 2);
      try {
        // 首轮 seed 远端行：空全量同步不推进游标（防墙钟竞态漏推），
        // 有实际拉取才建立游标。
        h.remote.seed(
          RemoteTables.activities,
          Activity(
            id: 'base-seed',
            name: '基准行',
            color: 0,
            isFavorite: false,
            updatedAt: DateTime(2026, 8, 11, 10),
          ).toMap(),
        );
        // 首次全量同步（1 行），推进游标
        await h.engine.syncNow(userId: CloudHarness.userId);
        final cursor = (await h.statusStore.read(userId: CloudHarness.userId))
            .requireValue()
            .lastSuccessfulSyncAt!;

        // 远端新增 3 行（分 2 页）；第二次同步第 2 页拉取失败
        for (var i = 0; i < 3; i++) {
          h.remote.seed(
            RemoteTables.activities,
            Activity(
              id: 'mid-fail-$i',
              name: '中途行$i',
              color: 0,
              isFavorite: false,
              updatedAt: cursor.add(Duration(minutes: i + 1)),
            ).toMap(),
          );
        }
        h.remote.resetCallCount();
        h.remote.pullLog.clear(); // 清首次同步的拉取日志，本次断言从 0 计
        // 语义化失败钩子：activities 第 2 页拉取失败（不依赖裸调用序号）。
        h.remote.failOnCall = 'pull:activities#1';
        final failed = await h.engine.syncNow(userId: CloudHarness.userId);
        expect(failed.isSuccess, isFalse, reason: '中途失败应返回失败');
        // pullLog 在抛错前记录：断言失败确实发生在 activities 第 2 页
        //（防引擎调用顺序变化导致失败点静默移位）。
        expect(h.remote.pullLog, hasLength(greaterThanOrEqualTo(2)));
        expect(h.remote.pullLog[1].table, 'activities');
        expect(h.remote.pullLog[1].page, 1);

        var status = (await h.statusStore.read(userId: CloudHarness.userId)).requireValue();
        expect(status.lastSuccessfulSyncAt!.isAtSameMomentAs(cursor), isTrue,
            reason: '中途失败不清游标');
        expect(status.lastError, isNotNull);

        // 第 1 页行已部分落库（LWW 幂等：不丢已应用行）；第 2 页行不得落库
        //（失败点必须钉死在 activities 第 2 页）。
        final partial = (await h.activities.activities()).requireValue();
        expect(partial.map((a) => a.id), contains('mid-fail-0'));
        expect(partial.map((a) => a.id), isNot(contains('mid-fail-2')),
            reason: '失败必须发生在 activities 第 2 页（第 2 页行不得落库）');

        // 重试（不设失败）→ 从原游标重拉，补齐全部 3 行 + 游标推进
        await h.engine.syncNow(userId: CloudHarness.userId);
        final after = (await h.activities.activities()).requireValue();
        for (var i = 0; i < 3; i++) {
          expect(after.map((a) => a.id), contains('mid-fail-$i'),
              reason: '重试后补齐中途未拉到的行');
        }
        status = (await h.statusStore.read(userId: CloudHarness.userId)).requireValue();
        expect(status.lastError, isNull, reason: '重试成功后清错误');
        expect(status.lastSuccessfulSyncAt!.isAfter(cursor), isTrue,
            reason: '重试成功后游标推进');
      } finally {
        await h.close();
      }
    });

    test('推送阶段失败：游标不推进、错误记录、重试补推本地未推送行', () async {
      final h = CloudHarness.create();
      try {
        // 首轮 seed 远端行建立游标
        h.remote.seed(
          RemoteTables.activities,
          Activity(
            id: 'push-base',
            name: '基准行',
            color: 0,
            isFavorite: false,
            updatedAt: DateTime(2026, 8, 11, 10),
          ).toMap(),
        );
        await h.engine.syncNow(userId: CloudHarness.userId);
        final cursor = (await h.statusStore.read(userId: CloudHarness.userId))
            .requireValue()
            .lastSuccessfulSyncAt!;

        // 本地新建活动（晚于游标，将进入推送窗口）
        final newActivity = (await h.activities.createActivity(
          name: '待推送',
          color: 0xff112233,
        ))
            .requireValue();

        // 第二次同步：在 push:activities 时失败（推送阶段）——语义化钩子，
        // 不依赖"6 次 pull + 1 次 updated_at"的精确序号。
        h.remote.resetCallCount();
        h.remote.pullLog.clear();
        h.remote.failOnCall = 'push:activities';
        final failed = await h.engine.syncNow(userId: CloudHarness.userId);
        expect(failed.isSuccess, isFalse, reason: '推送阶段失败应返回失败');
        // 失败确实发生在推送阶段（updated_at 查询已执行、push 未完成）。
        expect(h.remote.callLog, contains('updated_at:activities'));

        var status = (await h.statusStore.read(userId: CloudHarness.userId))
            .requireValue();
        expect(status.lastSuccessfulSyncAt!.isAtSameMomentAs(cursor), isTrue,
            reason: '推送失败不清游标');
        expect(status.lastError, isNotNull);

        // 重试（不设失败）→ 从原游标重推，本地新行完整补推
        await h.engine.syncNow(userId: CloudHarness.userId);
        final remoteRow =
            h.remote.tables[RemoteTables.activities]?[newActivity.id];
        expect(remoteRow, isNotNull, reason: '重试后本地新行补推到远端');
        expect(remoteRow!['name'], '待推送');
        status = (await h.statusStore.read(userId: CloudHarness.userId))
            .requireValue();
        expect(status.lastError, isNull, reason: '重试成功后清错误');
        expect(status.lastSuccessfulSyncAt!.isAfter(cursor), isTrue,
            reason: '重试成功后游标推进');
      } finally {
        await h.close();
      }
    });

    test('增量拉取：since 透传，旧行不重拉、新行拉回', () async {
      final h = CloudHarness.create();
      try {
        // 首轮 seed 远端行：空全量同步不推进游标（防墙钟竞态漏推）。
        h.remote.seed(
          RemoteTables.activities,
          Activity(
            id: 'incr-base',
            name: '基准行',
            color: 0,
            isFavorite: false,
            updatedAt: DateTime(2026, 8, 11, 10),
          ).toMap(),
        );
        // 首次全量同步（1 行），推进游标
        await h.engine.syncNow(userId: CloudHarness.userId);
        final cursor = (await h.statusStore.read(userId: CloudHarness.userId))
            .requireValue()
            .lastSuccessfulSyncAt!;
        h.remote.pullLog.clear();

        // 远端新增：旧行（早于游标）+ 新行（晚于游标）
        final oldRow = Activity(
          id: 'old-row',
          name: '旧行（早于游标）',
          color: 0,
          isFavorite: false,
          updatedAt: cursor.subtract(const Duration(minutes: 1)),
        );
        final newRow = Activity(
          id: 'new-row',
          name: '新行（晚于游标）',
          color: 0,
          isFavorite: false,
          updatedAt: cursor.add(const Duration(minutes: 1)),
        );
        h.remote.seed(RemoteTables.activities, oldRow.toMap());
        h.remote.seed(RemoteTables.activities, newRow.toMap());

        await h.engine.syncNow(userId: CloudHarness.userId);
        // since 透传：第二次拉取携带上次成功游标（非 null）
        final pulls =
            h.remote.pullLog.where((c) => c.table == 'activities').toList();
        expect(pulls, isNotEmpty);
        for (final pull in pulls) {
          expect(pull.since, isNotNull, reason: '增量拉取必须携带 since 游标');
          expect(
            pull.since!.isAtSameMomentAs(cursor),
            isTrue,
            reason: 'since = 上次成功游标',
          );
        }
        // 增量语义：只拉回新行（updated_at >= since）
        final local = (await h.activities.activities()).requireValue();
        expect(local.map((a) => a.id), isNot(contains('old-row')),
            reason: '早于游标的行不重拉');
        expect(local.map((a) => a.id), contains('new-row'),
            reason: '晚于游标的行被拉回');
      } finally {
        await h.close();
      }
    });

    test('profile_settings：本地有记录才推送，远端记录拉取合并', () async {
      final h = CloudHarness.create();
      try {
        // 本地无配置 → 不推送 profile_settings
        await h.engine.syncNow(userId: CloudHarness.userId);
        expect(
          h.remote.callLog.contains('push:profile_settings'),
          isFalse,
          reason: '无本地配置记录不推默认值',
        );

        // 本地保存配置 → 推送
        await h.settings.save(
          (await h.settings.settings()).requireValue().copyWith(
                reminderMinutes: 30,
              ),
        );
        await h.engine.syncNow(userId: CloudHarness.userId);
        final remoteSettings =
            h.remote.tables[RemoteTables.profileSettings];
        expect(remoteSettings, isNotNull);
        expect(
          remoteSettings!.values.single['reminder_minutes'],
          30,
          reason: '本地配置推送到远端',
        );

        // 远端更新的配置 → 拉回合并（LWW；远端行需带 user_id；updatedAt 落在
        // markSuccess 合理性容差内：晚于本地保存时刻 +2min，但早于 now+5min）。
        final remoteUpdated = (await h.settings.settings())
            .requireValue()
            .copyWith(
              userId: CloudHarness.userId,
              reminderMinutes: 55,
              updatedAt: DateTime.now().add(const Duration(minutes: 2)),
            );
        h.remote.seed(
          RemoteTables.profileSettings,
          remoteUpdated.toMap(),
        );
        (await h.engine.syncNow(userId: CloudHarness.userId)).requireValue();
        expect(
          (await h.settings.settings()).requireValue().reminderMinutes,
          55,
          reason: '远端更新的配置 LWW 覆盖本地',
        );
      } finally {
        await h.close();
      }
    });

    test('profile_settings 归属冲突跳过（r53）：他人遗留 + 本地更晚 → 不计拉取', () async {
      // **skipWhen 语义回归守护**：r52 把归属冲突跳过从 apply 内提前返回
      // 移入 skipWhen（不计 count/maxSeen，防游标吞掉增量窗口）——若无
      // 用例锁定，回归为"apply 内返回"（旧的计数/推进游标语义）时测试仍
      // 全绿。本用例锁定：跳过行不计入 pulledRows、他人遗留配置不被覆盖。
      final h = CloudHarness.create();
      try {
        // 本地：他人归属的遗留配置（save 会以 now 推进 updatedAt → 本地更晚）。
        await h.settings.save(
          (await h.settings.settings()).requireValue().copyWith(
                userId: 'other-user',
                reminderMinutes: 10,
              ),
        );
        // 远端：当前用户的配置行（时间戳为过去 → 本地更晚 → 触发跳过）。
        final remoteSettings = settings_vm.ProfileSettings(
          userId: CloudHarness.userId,
          reminderMinutes: 55,
          timezone: (await h.settings.settings()).requireValue().timezone,
          updatedAt:
              DateTime.now().toUtc().subtract(const Duration(hours: 1)),
        );
        h.remote.seed(RemoteTables.profileSettings, remoteSettings.toMap());

        final report =
            (await h.engine.syncNow(userId: CloudHarness.userId)).requireValue();
        // 跳过：本地他人遗留配置未被当前用户远端行覆盖（防上一用户未同步
        // 修改被静默销毁）。
        final local = (await h.settings.settings()).requireValue();
        expect(local.userId, 'other-user', reason: '他人遗留配置未被覆盖');
        expect(local.reminderMinutes, 10, reason: '本地更新值保留');
        // 跳过行不计入 pulledRows（skipWhen 契约：不计 count/maxSeen）。
        expect(report.pulledRows, 0,
            reason: '归属冲突跳过行不计入拉取行数');
      } finally {
        await h.close();
      }
    });

    test('并发 syncNow 互斥：在途调用被拒绝，游标不回退', () async {
      final h = CloudHarness.create();
      try {
        // 远端先有一行，让首次同步有实际工作。
        h.remote.seed(
          RemoteTables.activities,
          Activity(
            id: 'seed',
            name: '远端行',
            color: 0,
            isFavorite: false,
            updatedAt: DateTime(2026, 8, 11, 10),
          ).toMap(),
        );

        final results = await Future.wait([
          h.engine.syncNow(userId: CloudHarness.userId),
          h.engine.syncNow(userId: CloudHarness.userId),
        ]);
        // in-flight 锁在 syncNow 首个 await 前同步置位：确定性恰好一个成功、
        // 另一个被拒绝（防 Future.wait 顺序求值假设失效时双双成功漏检）。
        final successes =
            results.where((r) => r.isSuccess).length;
        expect(successes, 1, reason: '并发 syncNow 应恰好一个成功');
        final rejected = results.where((r) => !r.isSuccess).toList();
        expect(rejected, hasLength(1), reason: '另一个必须被 in-flight 锁拒绝');
        expect(
          rejected.single.when(onSuccess: (_) => '', onFailure: (m) => m),
          contains('进行中'),
          reason: '拒绝消息应明确为"同步进行中"',
        );

        // 游标不因并发回退：胜出调用游标 = seed 行时刻（2026-08-11 10:00，
        // maxSeen=10:00 < startedAt 不截断），且无错误污染（被拒调用不写状态）。
        final status = (await h.statusStore.read(userId: CloudHarness.userId))
            .requireValue();
        expect(status.lastSuccessfulSyncAt, isNotNull,
            reason: '并发结束后游标有效');
        expect(
          status.lastSuccessfulSyncAt!.isAtSameMomentAs(DateTime(2026, 8, 11, 10)),
          isTrue,
          reason: '胜出调用游标 = 远端 seed 行时刻',
        );
        expect(status.lastError, isNull,
            reason: '被拒调用不得污染 lastError');
      } finally {
        await h.close();
      }
    });

    test('增量边界：updated_at == since 的行不得漏拉（>= since 语义）', () async {
      final h = CloudHarness.create();
      try {
        // 首轮 seed 远端行：空全量同步不推进游标（防墙钟竞态漏推）。
        h.remote.seed(
          RemoteTables.activities,
          Activity(
            id: 'boundary-base',
            name: '基准行',
            color: 0,
            isFavorite: false,
            updatedAt: DateTime(2026, 8, 11, 10),
          ).toMap(),
        );
        // 首次全量（1 行），游标 = 该行时刻
        await h.engine.syncNow(userId: CloudHarness.userId);
        final cursor = (await h.statusStore.read(userId: CloudHarness.userId))
            .requireValue()
            .lastSuccessfulSyncAt!;
        h.remote.pullLog.clear();

        // 边界行：updated_at 恰好 == 游标（含 6 位微秒对齐）
        final boundary = Activity(
          id: 'boundary-row',
          name: '游标边界行',
          color: 0,
          isFavorite: false,
          updatedAt: cursor,
        );
        h.remote.seed(RemoteTables.activities, boundary.toMap());

        await h.engine.syncNow(userId: CloudHarness.userId);
        // 边界行被拉取（>= since）且 LWW 落库——不得漏拉
        final local = (await h.activities.activities()).requireValue();
        expect(local.map((a) => a.id), contains('boundary-row'),
            reason: 'updated_at == since 的行必须被拉取（不得漏拉）');

        // 边界行 updated_at 恰好 == 游标时游标不前进：下一轮按 >= 语义会再次
        // 拉取该行（属预期——gte 闭区间 + LWW 幂等，无数据丢失/重复入库）。
        final cursor2 = (await h.statusStore.read(userId: CloudHarness.userId))
            .requireValue()
            .lastSuccessfulSyncAt!;
        expect(cursor2.isAtSameMomentAs(cursor), isTrue,
            reason: '游标=本次最大行时间（边界行不推进）');
        await h.engine.syncNow(userId: CloudHarness.userId);
        final local2 = (await h.activities.activities()).requireValue();
        expect(
          local2.where((a) => a.id == 'boundary-row'),
          hasLength(1),
          reason: '重复拉取 LWW 幂等，不产生重复行',
        );
      } finally {
        await h.close();
      }
    });
  });

  group('CloudSyncEngine 跨用户隔离', () {
    test('远端其他用户的行不拉回本地', () async {
      final h = CloudHarness.create();
      try {
        final otherRow = Activity(
          id: 'other-user-row',
          name: '他人活动',
          color: 0,
          isFavorite: false,
          userId: 'other-user',
          updatedAt: DateTime(2026, 8, 11, 10),
        );
        h.remote.seed(RemoteTables.activities, otherRow.toMap());

        await h.engine.syncNow(userId: CloudHarness.userId);
        final local = (await h.activities.activities()).requireValue();
        expect(local.map((a) => a.id), isNot(contains('other-user-row')),
            reason: '远端其他用户的行不得拉回本地（user_id 过滤）');
      } finally {
        await h.close();
      }
    });

    test('本地其他用户的遗留行不推送、不改归属', () async {
      final h = CloudHarness.create();
      try {
        // 直接插入带其他用户归属的遗留行（共享设备上前一登录用户的数据）。
        final otherRow = Activity(
          id: 'legacy-other',
          name: '遗留他人行',
          color: 0,
          isFavorite: false,
          userId: 'other-user',
          updatedAt: DateTime(2026, 8, 11, 10),
        );
        await h.db.into(h.db.activities).insert(
              ActivitiesCompanion.insert(
                id: otherRow.id,
                userId: const Value('other-user'),
                name: otherRow.name,
                color: otherRow.color,
                isFavorite: const Value(false),
                updatedAt: otherRow.updatedAt.toUtc().toIso8601String(),
              ),
            );

        await h.engine.syncNow(userId: CloudHarness.userId);
        // 远端不得出现该行（归属过滤 + RLS 语义）
        expect(
          h.remote.tables[RemoteTables.activities]?.containsKey('legacy-other') ??
              false,
          isFalse,
          reason: '本地他人遗留行不得被推送（防跨用户数据污染）',
        );
        // 本地该行归属不被改写
        final localRow = await (h.db.select(h.db.activities)
              ..where((t) => t.id.equals('legacy-other')))
            .getSingle();
        expect(localRow.userId, 'other-user', reason: '_withUserId 不改写他人归属');
      } finally {
        await h.close();
      }
    });
  });

  group('CloudSyncEngine 推送（其余表冒烟）', () {
    test('时间条目与日志推送：本地新行补填 user_id 后上云', () async {
      final h = CloudHarness.create();
      try {
        final activity = (await h.activities.createActivity(
          name: '活动',
          color: 0xff2563eb,
        ))
            .requireValue();
        await h.entries.createManualEntry(
          activityId: activity.id,
          startAt: DateTime(2026, 8, 11, 9),
          endAt: DateTime(2026, 8, 11, 10),
          note: '推送条目',
        );
        await h.actionLogs.insert(
          actionType: ActionType.switch_,
          occurredAt: DateTime(2026, 8, 11, 9),
          deviceId: 'devX',
        );

        await h.engine.syncNow(userId: CloudHarness.userId);

        final remoteEntries =
            h.remote.tables[RemoteTables.timeEntries];
        expect(remoteEntries, isNotNull, reason: '时间条目应推送到远端');
        final remoteEntry =
            remoteEntries!.values.firstWhere((r) => r['note'] == '推送条目');
        expect(remoteEntry['user_id'], CloudHarness.userId,
            reason: '条目推送补填 user_id');

        final remoteLogs = h.remote.tables[RemoteTables.actionLogs];
        expect(remoteLogs, isNotNull, reason: '日志应推送到远端');
        expect(remoteLogs!.values, isNotEmpty);
        for (final row in remoteLogs.values) {
          expect(row['user_id'], CloudHarness.userId,
              reason: '日志推送补填 user_id');
        }
      } finally {
        await h.close();
      }
    });
  });

  group('CloudSyncEngine 推送（分类/规则）', () {
    test('tracking_rules：sync_enabled=true 规则推送/拉取，false 仅存本地（模块 2c-foreground）', () async {
      final h = CloudHarness.create();
      try {
        // 规则 activity_id 引用 activities（本地 FK ON）——先落本地活动，
        // 否则本地 saveRule 因 FK 悬挂失败。**不做远端 seed**：远端活动由
        // 首轮同步的 activities 推送建立（引擎表顺序 activities → … →
        // tracking_rules 与 FK 依赖方向一致）；云端引用完整性由
        // validate_tracking_rule_ref 触发器兜底（mock 不模拟触发器，顺序
        // 契约由本用例的活动先推送 + 引擎表序隐式保证）。
        await h.db.into(h.db.activities).insert(
              ActivitiesCompanion.insert(
                id: 'rule-activity',
                userId: const Value(null),
                name: '规则活动',
                color: 0xff2563eb,
                isFavorite: const Value(false),
                // 固定 UTC 时刻（与远端活动同刻，防首轮 LWW 冲突随机器时区
                // 胜负不定——DateTime.utc 与 toMap 归一化一致）。
                updatedAt: '2026-08-12T10:00:00.000000Z',
              ),
            );
        // 本地同步规则（sync_enabled=true）+ 本地-only 规则（sync_enabled=false）
        final t0 = DateTime.utc(2026, 8, 12, 4);
        await h.trackingRules.saveRule(
          TrackingRule(
            id: 'r-sync',
            pattern: 'chrome.exe',
            matchKind: TrackingRuleMatchKind.process,
            activityId: 'rule-activity',
            syncEnabled: true,
            updatedAt: t0,
          ),
        );
        await h.trackingRules.saveRule(
          TrackingRule(
            id: 'r-local',
            pattern: 'secret-app.exe',
            matchKind: TrackingRuleMatchKind.process,
            activityId: 'rule-activity',
            syncEnabled: false,
            updatedAt: t0.add(const Duration(minutes: 1)),
          ),
        );

        await h.engine.syncNow(userId: CloudHarness.userId);

        // 推送：sync_enabled=true 的规则上云并补填 user_id；false 的规则不进远端
        final remoteRules = h.remote.tables[RemoteTables.trackingRules];
        expect(remoteRules, isNotNull, reason: 'tracking_rules 应推送到远端');
        expect(remoteRules!.containsKey('r-sync'), isTrue,
            reason: 'sync_enabled=true 规则上云');
        expect(remoteRules['r-sync']!['user_id'], CloudHarness.userId,
            reason: '规则推送补填 user_id');
        expect(remoteRules['r-sync']!['sync_enabled'], true,
            reason: 'sync_enabled 字段保真');
        // **字段级往返一致性（r8）**：防推送时字段截断/改写/归一化错误
        //（如 match_kind 序列化丢失、activity_id 缺失）被忽略。
        final pushedRule = remoteRules['r-sync']!;
        expect(pushedRule['pattern'], 'chrome.exe',
            reason: 'pattern 推送保真');
        expect(pushedRule['match_kind'], 'process',
            reason: 'match_kind 推送保真（storageValue）');
        expect(pushedRule['activity_id'], 'rule-activity',
            reason: 'activity_id 推送保真');
        expect(
          pushedRule['updated_at'],
          t0.toUtc().toIso8601String(),
          reason: 'updated_at 推送保真（toMap 归一化与本地一致）',
        );
        expect(remoteRules.containsKey('r-local'), isFalse,
            reason: 'sync_enabled=false 规则不进远端（本地偏好不泄漏到云）');

        // 拉取：远端规则 → 本地 LWW 应用（含补填归属 + 快照）。
        // updatedAt 须**晚于**第一次同步推进的游标（增量窗口 >= since），
        // 且落在 markSuccess 合理性容差内（now+2min < now+5min）——与
        // profile_settings 拉回用例同模式。
        final remoteRule = TrackingRule(
          id: 'r-remote',
          pattern: 'code.exe',
          matchKind: TrackingRuleMatchKind.process,
          activityId: 'rule-activity',
          syncEnabled: true,
          userId: CloudHarness.userId,
          updatedAt: DateTime.now().toUtc().add(const Duration(minutes: 2)),
        );
        h.remote.seed(RemoteTables.trackingRules, remoteRule.toMap());
        await h.engine.syncNow(userId: CloudHarness.userId);
        final localRule = await h.trackingRules.ruleById('r-remote');
        expect(localRule, isNotNull, reason: '远端规则拉回本地');
        expect(localRule!.pattern, 'code.exe');
        expect(localRule.syncEnabled, isTrue);
        // 本地-only 规则仍保留（拉取不覆盖本地 sync_enabled=false 的规则）
        final localOnly = await h.trackingRules.ruleById('r-local');
        expect(localOnly, isNotNull, reason: '本地-only 规则不被远端影响');
        expect(localOnly!.syncEnabled, isFalse);

        // **同 id 远端残留副本不覆盖本地-only 规则（r1）**：用户曾同步过该
        // 规则（远端残留副本）、随后本地关闭同步，另一设备仍编辑该规则（远端
        // updated_at 更晚）——拉取不得把本地已关闭的规则覆盖回 sync_enabled=
        // true（防本地偏好被远端静默改回同步后重新上云）。
        final remoteStale = TrackingRule(
          id: 'r-local', // 与本地-only 规则同 id
          pattern: 'secret-app.exe',
          matchKind: TrackingRuleMatchKind.process,
          activityId: 'rule-activity',
          syncEnabled: true,
          userId: CloudHarness.userId,
          updatedAt: DateTime.now().toUtc().add(const Duration(minutes: 2)),
        );
        h.remote.seed(RemoteTables.trackingRules, remoteStale.toMap());
        await h.engine.syncNow(userId: CloudHarness.userId);
        final preserved = await h.trackingRules.ruleById('r-local');
        expect(preserved, isNotNull, reason: '同 id 远端残留不得删除本地-only 规则');
        expect(preserved!.syncEnabled, isFalse,
            reason: '远端更晚副本不得把本地-only 规则覆盖回同步（本地偏好保留）');
      } finally {
        await h.close();
      }
    });

    test('分类推送：本地新分类（含 parentId）推送且补填 user_id', () async {
      final h = CloudHarness.create();
      try {
        final parent = (await h.categories.createCategory(
          name: '父分类',
          color: 0xff0f766e,
        ))
            .requireValue();
        await h.categories.createCategory(
          name: '子分类',
          color: 0xff123456,
          parentId: parent.id,
        );

        await h.engine.syncNow(userId: CloudHarness.userId);

        final remoteCats =
            h.remote.tables[RemoteTables.categories];
        expect(remoteCats, isNotNull, reason: '分类应推送到远端');
        expect(remoteCats!.values, hasLength(2));
        for (final row in remoteCats.values) {
          expect(row['user_id'], CloudHarness.userId,
              reason: '分类推送补填 user_id');
        }
        final child =
            remoteCats.values.firstWhere((r) => r['name'] == '子分类');
        expect(child['parent_id'], parent.id, reason: 'parent_id 随行推送');
      } finally {
        await h.close();
      }
    });
  });

  group('远端无主行：宽松模式认领 / 严格模式隔离', () {
    /// 无主行统一用**远离当前时刻的固定 UTC 常量**（2020 年——LWW 关键字段
    /// 时区语义明确，且不会受运行环境时钟影响：贴近当前时间的绝对日期在
    /// CI 沙箱快照/系统时钟异常下会成为未来时间戳、偏离游标推进设计意图）。
    final unownedAt = DateTime.utc(2020, 1, 1, 10);

    test('无主行在宽松模式下可见并被拉回本地，推送后远端归属当前用户（网关层语义）', () async {
      final h = CloudHarness.createLoose();
      try {
        // 远端遗留无归属行（user_id 为 null，模拟历史数据）——seedUnowned
        // 是宽松模式下构造真无主行的唯一入口（seed 恒注入默认归属；严格
        // 模式用 injectUnownedRow，见下方用例——两者同一数据构造路径）。
        h.remote.seedUnowned(
          RemoteTables.activities,
          Activity(
            id: 'unowned-a',
            name: '无主活动',
            color: 0xffabcdef,
            isFavorite: false,
            updatedAt: unownedAt,
          ).toMap(),
        );

        (await h.engine.syncNow(userId: CloudHarness.userId)).requireValue();
        final local = (await h.activities.activities()).requireValue();
        expect(local.map((a) => a.id), contains('unowned-a'),
            reason: '宽松模式下拉取应含无主行');

        // **认领路径真正守护**：远端行归属由 MemoryRemote.upsertRows
        // 无条件注入（无法区分"引擎 _withUserId 生效"与"网关注入兜底"）——
        // 改用 `lastPushedRawRows`（注入前原始负载）断言引擎**实际发送**的
        // 行已携带当前用户归属，认领路径失效时测试变红。
        // **本地永不收敛（如实声明）**：首轮拉回的无主行以 user_id=null 落
        // 本地库；_withUserId 只补填**出站**行副本、不写回本地——第二轮
        // 同步时远端行时间戳相等、LWW 平局跳过，本地行 user_id 永远保持
        // null，该行在**每一轮**同步都被重复推送（非收敛稳态，属引擎设计
        // 语义；共享设备换号后会与已认领远端行产生归属冲突，归阶段 3 多
        // 用户数据隔离/清除入口处理）。
        final pushedRaw = (h.remote.lastPushedRawRowsByTable[
                RemoteTables.activities] ??
            const <Map<String, Object?>>[])
            .where((r) => r['id'] == 'unowned-a');
        expect(pushedRaw, isNotEmpty, reason: '无主行被推送');
        expect(pushedRaw.first['user_id'], CloudHarness.userId,
            reason: '引擎 _withUserId 补填的推送行归属当前用户（认领路径生效）');
        // **按表视图（r50）**：`lastPushedRawRowsByTable` 记录"每表最近一次
        // 成功 upsert 的原始负载"——本断言不依赖 activities 是最后一个非空
        // 推送表的顺序假设（未来给其他表补 seed 行也不会清掉本表记录）。
        final remoteRow =
            h.remote.tables[RemoteTables.activities]?['unowned-a'];
        expect(remoteRow, isNotNull, reason: '推送后远端行存在');
        expect(remoteRow!['user_id'], CloudHarness.userId,
            reason: '远端行归属为当前用户（推送语义）');

        // 重复同步：本地表 id 主键唯一，行不产生重复（LWW 幂等——本地
        // user_id 仍为 null，属上文声明的非收敛稳态）。
        // **本轮确有一次新推送（r51 交叉验证）**：按表视图在本轮未推该表时
        // 保留上一轮记录（跨轮次残留边界）——`pushedAgain` 非空无法单独证明
        // 本轮重复推送；用 callLog 的 `push:activities` 计数交叉验证本轮
        // 确实发生了一次新的 activities 推送（对比第二轮 syncNow 前后计数）。
        final pushCountBefore = h.remote.callLog
            .where((c) => c == 'push:${RemoteTables.activities}')
            .length;
        (await h.engine.syncNow(userId: CloudHarness.userId)).requireValue();
        final pushCountAfter = h.remote.callLog
            .where((c) => c == 'push:${RemoteTables.activities}')
            .length;
        expect(pushCountAfter, pushCountBefore + 1,
            reason: '第二轮同步必须新发起一次 activities 推送（非收敛稳态：'
                '每轮都重复推送，非仅残留旧记录）');
        final local2 = (await h.activities.activities()).requireValue();
        expect(local2.where((a) => a.id == 'unowned-a'), hasLength(1),
            reason: '重复同步不产生重复行（主键唯一）');
        // **非收敛契约守护（r48，r50 注明演化边界）**：注释声明的"本地永不
        // 收敛、每一轮都被重复推送"稳态由断言锁定——若引擎未来改为推送后
        // 收敛本地归属（回写 user_id，阶段 3 评估方向），下方断言变红属
        // **预期**：届时按新语义更新"实现细节断言"（本地 user_id/重复推送），
        // 保留"特性级断言"（无主行可见、被拉回、远端认领、无重复行）。
        expect(
          local2.singleWhere((a) => a.id == 'unowned-a').userId,
          isNull,
          reason: '本地行 user_id 仍为 null（当前非收敛稳态；阶段 3 收敛实现须同步本断言）',
        );
        final pushedAgain = (h.remote.lastPushedRawRowsByTable[
                RemoteTables.activities] ??
            const <Map<String, Object?>>[])
            .where((r) => r['id'] == 'unowned-a');
        expect(pushedAgain, isNotEmpty,
            reason: '本轮推送的 activities 负载含 unowned-a（配合上方 push 计数）');
        expect(pushedAgain.first['user_id'], CloudHarness.userId,
            reason: '重复推送行归属仍为当前用户');
      } finally {
        await h.close();
      }
    });

    test('严格模式（默认）下 syncNow 对远端无主行隔离（不拉回本地）', () async {
      final h = CloudHarness.create();
      try {
        // **语义说明（r22 修正）**：严格模式下无主行的隔离在**网关层**完成
        //（MemoryRemote 的 fetchRowsSince 过滤 user_id==null 行，与真网关
        // eq('user_id') 对 NULL 不匹配一致）——此用例验证的是严格模式端到端
        // 不拉取无主行（含网关层过滤）；引擎 _pullTable 的防御性过滤只跳过
        // **非 null 他人** user_id 行（无主行设计上允许本地认领，见引擎
        // 注释）。
        // 用 injectUnownedRow（与 seedUnowned 同一数据构造路径：行校验 +
        // 深拷贝）注入无主行——seed 恒注入默认归属、seedUnowned 在严格模式
        // 抛错，无法构造此场景。
        h.remote.injectUnownedRow(
          RemoteTables.activities,
          Activity(
            id: 'unowned-strict',
            name: '无主活动',
            color: 0xffabcdef,
            isFavorite: false,
            updatedAt: unownedAt, // 与宽松模式组共用 UTC 常量
          ).toMap(),
        );
        // **正向对照**：同轮 seed 一条正常有主行——防过滤/拉取逻辑
        // 被误改得过宽（所有行都被过滤时仅断言"无主行不出现"仍会通过，
        // 有主行对照能区分"正确隔离"与"过度过滤"）。
        h.remote.seed(
          RemoteTables.activities,
          Activity(
            id: 'owned-strict',
            name: '有主活动',
            color: 0xff123456,
            isFavorite: false,
            updatedAt: unownedAt,
          ).toMap(),
        );

        (await h.engine.syncNow(userId: CloudHarness.userId)).requireValue();
        final local = (await h.activities.activities()).requireValue();
        expect(local.map((a) => a.id), isNot(contains('unowned-strict')),
            reason: '严格模式下无主行不得被拉回本地（与真网关 eq 对 NULL 不匹配一致）');
        expect(local.map((a) => a.id), contains('owned-strict'),
            reason: '严格模式只隔离无主行，有主行正常拉取（正向对照）');
        // **完整语义守护**：严格模式"只隔离、不触碰"——同步后远端无主行
        // 必须保持 user_id 为 null（防未来引擎改动出现"未拉回却直接认领/
        // 改写远端无主行"的路径）。
        final remoteRow =
            h.remote.tables[RemoteTables.activities]?['unowned-strict'];
        expect(remoteRow, isNotNull, reason: '远端无主行仍存在');
        expect(remoteRow!['user_id'], isNull,
            reason: '严格模式下同步不得认领/改写远端无主行');
      } finally {
        await h.close();
      }
    });
  });
}
