import 'dart:io';

import 'package:drift/drift.dart' hide isNotNull, isNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:timetrack2/constants/app_constants.dart';
import 'package:timetrack2/constants/storage_keys.dart';
import 'package:timetrack2/data/cleanup/cleanup_service.dart';
import 'package:timetrack2/data/database/app_database.dart';
import 'package:timetrack2/data/repositories/repository_mappings.dart';

/// 模块 2f：保留期清理 + VACUUM。
///
/// 覆盖：超期物理删除/未超期保留/从未同步跳过（sync 守卫）/分类父被删时
/// 存活子升级根分类（parentId 置 NULL）/VACUUM 阈值驱动/retentionDays
/// 覆盖值与回退/last_cleanup_at 写入。
void main() {
  late AppDatabase db;
  late CleanupService service;

  // utcString 是 RepositoryMappings mixin 实例方法（测试侧混入宿主调用）。
  final mapping = _MappingHost();

  setUp(() {
    db = AppDatabase(NativeDatabase.memory());
    service = CleanupService(
      database: db,
      vacuumThreshold: 5, // 注入小阈值（默认 1000 全库重写测试成本过高）
    );
  });

  tearDown(() async {
    // **幂等保护（r4）**：'retentionDays DB 异常回退' 用例手动 close 了共享
    // db——tearDown 再次 close 须安全（drift close 幂等，包 try 防非幂等实现
    // 把错误归因到用例之外）。
    try {
      await db.close();
    } catch (_) {
      // 已关闭：忽略。
    }
  });

  /// 写入 metadata 键。
  Future<void> putMeta(String key, String value) {
    return db
        .into(db.appMetadata)
        .insert(
          AppMetadataCompanion.insert(key: key, value: value),
          mode: InsertMode.insertOrReplace,
        );
  }

  /// 时间基准：现在（UTC 字符串）。
  String nowStr() => mapping.utcString(DateTime.now());

  /// 造软删行：deletedAt 距 now 的天数偏移。
  Future<void> seedSoftDeleted(
    String table,
    String id,
    Duration deletedAge, {
    String? userId,
  }) async {
    final deletedAt = mapping.utcString(DateTime.now().subtract(deletedAge));
    // FK 依赖：子表行引用 activities/activityCategories——先造对应父行（存活，
    // 否则本用例的物理删除断言会受父行存在性干扰）。父行 userId 与被删行一致
    //（r9 分区谓词下同 userId 才匹配）。
    if (table == 'timeEntries' || table == 'trackingRules') {
      await db
          .into(db.activities)
          .insert(
            ActivitiesCompanion.insert(
              id: 'act-$id',
              name: 'parent-$id',
              color: 1,
              updatedAt: deletedAt,
              userId: Value(userId),
            ),
            mode: InsertMode.insertOrIgnore,
          );
    }
    if (table == 'activityCategoryLinks') {
      await db
          .into(db.activities)
          .insert(
            ActivitiesCompanion.insert(
              id: 'act-$id',
              name: 'parent-$id',
              color: 1,
              updatedAt: deletedAt,
              userId: Value(userId),
            ),
            mode: InsertMode.insertOrIgnore,
          );
      await db
          .into(db.activityCategories)
          .insert(
            ActivityCategoriesCompanion.insert(
              id: 'cat-$id',
              name: 'parentcat-$id',
              color: 1,
              updatedAt: deletedAt,
              userId: Value(userId),
            ),
            mode: InsertMode.insertOrIgnore,
          );
    }
    switch (table) {
      case 'activities':
        await db
            .into(db.activities)
            .insert(
              ActivitiesCompanion.insert(
                id: id,
                name: 'a-$id',
                color: 1,
                updatedAt: deletedAt,
                deletedAt: Value(deletedAt),
                userId: Value(userId),
              ),
            );
      case 'timeEntries':
        await db
            .into(db.timeEntries)
            .insert(
              TimeEntriesCompanion.insert(
                id: id,
                activityId: 'act-$id',
                activityName: const Value(''),
                startAt: deletedAt,
                deviceId: 'dev',
                updatedAt: deletedAt,
                deletedAt: Value(deletedAt),
                userId: Value(userId),
              ),
            );
      case 'trackingRules':
        await db
            .into(db.trackingRules)
            .insert(
              TrackingRulesCompanion.insert(
                id: id,
                pattern: 'p-$id',
                matchKind: 'process',
                activityId: 'act-$id',
                updatedAt: deletedAt,
                deletedAt: Value(deletedAt),
                userId: Value(userId),
              ),
            );
      case 'activityCategories':
        await db
            .into(db.activityCategories)
            .insert(
              ActivityCategoriesCompanion.insert(
                id: id,
                name: 'c-$id',
                color: 1,
                updatedAt: deletedAt,
                deletedAt: Value(deletedAt),
                parentId: const Value(null),
                userId: Value(userId),
              ),
            );
      case 'activityCategoryLinks':
        await db
            .into(db.activityCategoryLinks)
            .insert(
              ActivityCategoryLinksCompanion.insert(
                id: id,
                activityId: 'act-$id',
                categoryId: 'cat-$id',
                updatedAt: deletedAt,
                deletedAt: Value(deletedAt),
                userId: Value(userId),
              ),
            );
      case 'actionLogs':
        await db
            .into(db.actionLogs)
            .insert(
              ActionLogsCompanion.insert(
                id: id,
                actionType: 'x',
                occurredAt: deletedAt,
                deviceId: 'dev',
                updatedAt: deletedAt,
                deletedAt: Value(deletedAt),
                userId: Value(userId),
              ),
            );
      default:
        // **r12 修正**：未知表名静默吞掉会使种子失效误判为实现 bug——显式抛。
        throw ArgumentError('未知表名：$table');
    }
  }

  group('retentionDays 覆盖与回退', () {
    test('无配置 → 默认 180', () async {
      expect(await service.retentionDays(), 180);
      expect(
        AppConstants.defaultDeletedRetentionDays,
        180,
        reason: '默认值常量与测试断言一致',
      );
    });

    test('覆盖值（正整数）生效', () async {
      await putMeta(AppMetadataKeys.deletedRetentionDays, '30');
      expect(await service.retentionDays(), 30);
    });

    test('非法覆盖值（非数字/零/负）回退默认', () async {
      for (final evil in ['abc', '0', '-5', '']) {
        await putMeta(AppMetadataKeys.deletedRetentionDays, evil);
        expect(await service.retentionDays(), 180, reason: '非法覆盖回退：$evil');
      }
    });

    test('超大覆盖值上界钳制（r10/r12）：超 3650 钳制、恰在上限保留', () async {
      // Duration(days:) int64 微秒溢出回绕（约 1.07 亿天）会致 cutoff 失真、
      // 未满保留期墓碑被提前物理删除——钳制到 3650（10 年）。
      await putMeta(AppMetadataKeys.deletedRetentionDays, '999999');
      expect(await service.retentionDays(), 3650, reason: '超上限钳制');
      await putMeta(AppMetadataKeys.deletedRetentionDays, '3650');
      expect(await service.retentionDays(), 3650, reason: '恰在上限保留');
      await putMeta(AppMetadataKeys.deletedRetentionDays, '3651');
      expect(await service.retentionDays(), 3650, reason: '超 1 天钳制');
    });
  });

  group('sync 守卫', () {
    test('从未同步（无游标）→ 保守跳过物理删除', () async {
      await seedSoftDeleted('activities', 'a1', const Duration(days: 400));
      final report = (await service.run()).requireValue();
      expect(report.skippedDueToNoSync, isTrue, reason: '从未同步跳过');
      expect(report.deletedTotal, 0);
      final left = await (db.select(db.activities)).get();
      expect(left.length, 1, reason: '软删行保留（墓碑未经同步传播）');
      // 未写 last_cleanup_at（跳过即不推进清理时间——编排层按实际清理限频）。
      final meta = await (db.select(
        db.appMetadata,
      )..where((t) => t.key.equals(AppMetadataKeys.lastCleanupAt))).get();
      expect(meta, isEmpty);
    });

    test('cursorOverride 晚于当前时刻 → skippedDueToFutureCursor 跳过', () async {
      // 契约违规水位：未来时刻 → 跳过物理删除（软删行保留），且独立
      // 跳过原因（与 skippedDueToNoSync 区分）。
      await seedSoftDeleted('activities', 'a1', const Duration(days: 400));
      final future = DateTime.now().add(const Duration(hours: 1));
      final report = (await service.run(cursorOverride: future)).requireValue();
      expect(report.skippedDueToFutureCursor, isTrue);
      expect(report.skippedDueToNoSync, isFalse);
      expect(report.deletedTotal, 0);
      final left = await (db.select(db.activities)).get();
      expect(left.length, 1, reason: '未来水位跳过：软删行保留');
      // 未来水位跳过不推进清理时刻（同"从未同步"契约）。
      final meta = await (db.select(
        db.appMetadata,
      )..where((t) => t.key.equals(AppMetadataKeys.lastCleanupAt))).get();
      expect(meta, isEmpty, reason: '未来水位跳过不写 last_cleanup_at');
    });

    test('cursorOverride 早于保留期截止 → skippedDueToOutOfRangeCursor 跳过', () async {
      // 陈旧水位（保留期 180 天，override 在 200 天前）：独立跳过原因。
      await seedSoftDeleted('activities', 'a1', const Duration(days: 400));
      final stale = DateTime.now().subtract(const Duration(days: 200));
      final report = (await service.run(cursorOverride: stale)).requireValue();
      expect(report.skippedDueToOutOfRangeCursor, isTrue);
      expect(report.skippedDueToFutureCursor, isFalse);
      expect(report.deletedTotal, 0);
      final left = await (db.select(db.activities)).get();
      expect(left.length, 1, reason: '陈旧水位跳过：软删行保留');
    });

    test('cursorOverride == 保留期截止 → 放行不跳过（边界，固定时钟）', () async {
      await seedSoftDeleted('activities', 'a1', const Duration(days: 400));
      // 边界 == 必须用固定时钟注入（run 内部 now 与测试侧 now 会微秒漂移，
      // 使 override 恒早于 retentionCutoff 误入跳过分支——复用既有固定时钟模式）。
      final fixedNow = DateTime.now().toUtc();
      final pinnedService = CleanupService(
        database: db,
        vacuumThreshold: 5,
        now: () => fixedNow,
      );
      final boundary = fixedNow.subtract(const Duration(days: 180));
      final report = (await pinnedService.run(cursorOverride: boundary))
          .requireValue();
      expect(report.skippedDueToOutOfRangeCursor, isFalse);
      expect(report.skippedDueToFutureCursor, isFalse);
      expect(report.skippedDueToNoSync, isFalse);
      expect(report.deletedByTable['activities'], 1, reason: '边界水位正常清理');
    });

    test('cursorOverride 正常水位：跳过库内游标读取，直接物理删除', () async {
      // 无库内游标（从未同步）但 override 水位可信：物理删除执行——
      // 证明 override 分支绕过了 sync 守卫（库内路径会 skippedDueToNoSync）。
      await seedSoftDeleted('activities', 'a1', const Duration(days: 400));
      final report =
          (await service.run(cursorOverride: DateTime.now())).requireValue();
      expect(report.skippedDueToNoSync, isFalse);
      expect(report.skippedDueToFutureCursor, isFalse);
      expect(report.deletedByTable['activities'], 1);
      final left = await (db.select(db.activities)).get();
      expect(left, isEmpty, reason: 'override 水位下超期墓碑被物理删除');
    });

    test('有游标且墓碑早于游标 → 正常物理删除', () async {
      // 游标 = 现在（墓碑早于游标成立）。
      await putMeta(AppMetadataKeys.lastSyncAt, nowStr());
      await seedSoftDeleted('activities', 'a1', const Duration(days: 400));
      final report = (await service.run()).requireValue();
      expect(report.skippedDueToNoSync, isFalse);
      expect(report.deletedByTable['activities'], 1);
      final left = await (db.select(db.activities)).get();
      expect(left, isEmpty, reason: '超期且已同步的软删行被物理删除');
    });

    test('登录用户分区游标（r6/r9）：run(userId) 读分区键、仅删同 userId 行', () async {
      // r6 关键缺陷回归锁定：SyncStatusStore 在登录用户下写分区键
      // `last_sync_at:<userId>`——守卫若只读全局键会恒判"从未同步"、物理清理
      // 静默失效。run(userId) 必须读分区键。
      await putMeta('${AppMetadataKeys.lastSyncAt}:alice', nowStr());
      // alice 的超期墓碑（userId='alice'）→ 应删。
      await seedSoftDeleted(
        'activities',
        'a-part',
        const Duration(days: 400),
        userId: 'alice',
      );
      // bob 的超期墓碑（userId='bob'，r9 分区隔离）→ 保留（alice 清理不能删
      // bob 行——bob 分区游标无法证明已传播）。
      await seedSoftDeleted(
        'activities',
        'b-part',
        const Duration(days: 400),
        userId: 'bob',
      );
      final report = (await service.run(userId: 'alice')).requireValue();
      expect(report.skippedDueToNoSync, isFalse, reason: '分区游标读到');
      expect(report.deletedByTable['activities'], 1, reason: '仅 alice 行删');
      final left = await (db.select(db.activities)).get();
      expect(left.map((r) => r.id).toSet(), {
        'b-part',
      }, reason: 'bob 行保留（r9 分区隔离）');
    });

    test('子表分区隔离（r11）：actionLogs 双用户超期墓碑仅清本用户', () async {
      // 其余 5 张表的分区谓词同样须锁定——actionLogs 无 FK 依赖最简。
      await putMeta('${AppMetadataKeys.lastSyncAt}:alice', nowStr());
      await seedSoftDeleted(
        'actionLogs',
        'log-a',
        const Duration(days: 400),
        userId: 'alice',
      );
      await seedSoftDeleted(
        'actionLogs',
        'log-b',
        const Duration(days: 400),
        userId: 'bob',
      );
      final report = (await service.run(userId: 'alice')).requireValue();
      expect(report.deletedByTable['actionLogs'], 1, reason: '仅 alice 日志删');
      final left = await (db.select(db.actionLogs)).get();
      expect(left.map((r) => r.id).toSet(), {'log-b'}, reason: 'bob 日志保留');
    });

    test('登录用户无分区游标 → 跳过（即使全局键存在，r6）', () async {
      // 共享设备残留全局游标（他用户/历史未登录会话）——不得误判当前登录用户
      // 的墓碑已传播（r6：全局键不能用于登录用户判定）。
      await putMeta(AppMetadataKeys.lastSyncAt, nowStr()); // 全局键存在
      await seedSoftDeleted('activities', 'a-no', const Duration(days: 400));
      final report = (await service.run(userId: 'bob')).requireValue();
      expect(report.skippedDueToNoSync, isTrue, reason: 'bob 无分区游标跳过');
      expect(report.deletedTotal, 0);
    });

    test('空白/超长 userId → ArgumentError（调用方编程错误，r6/r7）', () async {
      // async 函数内 throw 进入返回 Future——须 await expectLater 捕获
      //（同步 throwsA 匹配不了，r7 修正）。
      await expectLater(
        service.run(userId: '  '),
        throwsArgumentError,
        reason: '空白 userId 拒绝',
      );
      await expectLater(
        service.run(userId: 'x' * 200),
        throwsArgumentError,
        reason: '超长 userId 拒绝（与 SyncStatusStore._maxUserIdLength=128 对齐）',
      );
    });

    test('无时区偏移游标 → 损坏跳过（r11：isUtc 校验与 SyncStatusStore 对齐）', () async {
      // 无偏移字符串被 Dart 按本地时区解析"成功"（isUtc=false）——负时区设备
      // 上解析时刻比本意 UTC 晚、cutoff 推晚可能提前删除未传播墓碑（数据丢失）。
      // 须与 SyncStatusStore.markSuccess 的 `isUtc` 校验一致判损坏跳过。
      await putMeta(AppMetadataKeys.lastSyncAt, '2026-01-01T00:00:00'); // 无 Z
      await seedSoftDeleted('activities', 'a-noutc', const Duration(days: 400));
      final report = (await service.run()).requireValue();
      expect(report.skippedDueToNoSync, isTrue, reason: '无偏移游标视为损坏跳过');
      expect(report.deletedTotal, 0);
    });
  });

  group('物理删除与保留', () {
    test('超期删除 / 未超期保留 / 存活行保留', () async {
      await putMeta(AppMetadataKeys.lastSyncAt, nowStr());
      // 超期（400 天）：应删。
      await seedSoftDeleted('timeEntries', 'e1', const Duration(days: 400));
      // 未超期（30 天）：保留。
      await seedSoftDeleted('timeEntries', 'e2', const Duration(days: 30));
      // 存活（deletedAt null）：保留（先造 FK 父行）。
      await db
          .into(db.activities)
          .insert(
            ActivitiesCompanion.insert(
              id: 'act-e3',
              name: 'parent-e3',
              color: 1,
              updatedAt: nowStr(),
            ),
            mode: InsertMode.insertOrIgnore,
          );
      await db
          .into(db.timeEntries)
          .insert(
            TimeEntriesCompanion.insert(
              id: 'e3',
              activityId: 'act-e3',
              activityName: const Value(''),
              startAt: nowStr(),
              deviceId: 'dev',
              updatedAt: nowStr(),
            ),
          );

      final report = (await service.run()).requireValue();
      expect(report.deletedByTable['timeEntries'], 1, reason: '仅超期 1 条被删');
      final left = await (db.select(db.timeEntries)).get();
      expect(left.map((r) => r.id).toSet(), {'e2', 'e3'});
    });

    test('6 张表超期行全部物理删除', () async {
      await putMeta(AppMetadataKeys.lastSyncAt, nowStr());
      // **独立 id（r4）**：共用 'x' 会让 seedSoftDeleted 的共享存活父行（act-x/
      // cat-x）产生隐式依赖——每表独立 id 隔离种子数据。
      final byTable = <String, String>{
        'activities': 'x-act',
        'timeEntries': 'x-entry',
        'trackingRules': 'x-rule',
        'activityCategories': 'x-cat',
        'activityCategoryLinks': 'x-link',
        'actionLogs': 'x-log',
      };
      for (final entry in byTable.entries) {
        await seedSoftDeleted(
          entry.key,
          entry.value,
          const Duration(days: 400),
        );
      }
      final report = (await service.run()).requireValue();
      // 每表恰好 1 条超期软删 → 各表删除计数 1。
      for (final table in CleanupService.tableNames) {
        expect(report.deletedByTable[table], 1, reason: '$table 超期行删除');
      }
      expect(report.deletedTotal, 6);
    });

    test('分类：父被删时存活子 parentId 置 NULL（升级根分类）', () async {
      await putMeta(AppMetadataKeys.lastSyncAt, nowStr());
      final parentDeletedAt = mapping.utcString(
        DateTime.now().subtract(const Duration(days: 400)),
      );
      // 父分类（超期软删）。
      await db
          .into(db.activityCategories)
          .insert(
            ActivityCategoriesCompanion.insert(
              id: 'parent',
              name: 'parent',
              color: 1,
              updatedAt: parentDeletedAt,
              deletedAt: Value(parentDeletedAt),
              parentId: const Value(null),
            ),
          );
      // 子分类（存活，parentId 指向将被物理删除的父）。
      await db
          .into(db.activityCategories)
          .insert(
            ActivityCategoriesCompanion.insert(
              id: 'child',
              name: 'child',
              color: 1,
              updatedAt: nowStr(),
              parentId: const Value('parent'),
            ),
          );

      final report = (await service.run()).requireValue();
      expect(report.deletedByTable['activityCategories'], 1, reason: '父被物理删除');
      final child = (await (db.select(
        db.activityCategories,
      )..where((t) => t.id.equals('child'))).get()).single;
      expect(child.parentId, isNull, reason: '存活子升级根分类（无悬空引用）');
      expect(child.updatedAt, isNotNull, reason: 'parentId 置空更新 updatedAt');
    });

    test('父未超期软删 → 子 parentId 保留', () async {
      await putMeta(AppMetadataKeys.lastSyncAt, nowStr());
      final recentDeleted = mapping.utcString(
        DateTime.now().subtract(const Duration(days: 30)),
      );
      await db
          .into(db.activityCategories)
          .insert(
            ActivityCategoriesCompanion.insert(
              id: 'parent2',
              name: 'parent2',
              color: 1,
              updatedAt: recentDeleted,
              deletedAt: Value(recentDeleted),
              parentId: const Value(null),
            ),
          );
      await db
          .into(db.activityCategories)
          .insert(
            ActivityCategoriesCompanion.insert(
              id: 'child2',
              name: 'child2',
              color: 1,
              updatedAt: nowStr(),
              parentId: const Value('parent2'),
            ),
          );
      await service.run();
      final child = (await (db.select(
        db.activityCategories,
      )..where((t) => t.id.equals('child2'))).get()).single;
      expect(child.parentId, 'parent2', reason: '父未超期 → 子引用保留');
    });
  });

  group('VACUUM 阈值', () {
    test('未超阈值（0 删除）→ 不 VACUUM；记录 last_cleanup_at', () async {
      await putMeta(AppMetadataKeys.lastSyncAt, nowStr());
      final report = (await service.run()).requireValue();
      expect(report.deletedTotal, 0);
      expect(report.vacuumed, isFalse, reason: '无删除不触发全库重建');
      // 本次无删除也记录清理时刻（编排层频率控制仍推进）。
      final meta = await (db.select(
        db.appMetadata,
      )..where((t) => t.key.equals(AppMetadataKeys.lastCleanupAt))).getSingle();
      expect(meta.value, isNotEmpty);
    });

    test('超阈值 → VACUUM + checkpoint 执行（vacuumed=true）', () async {
      await putMeta(AppMetadataKeys.lastSyncAt, nowStr());
      // 6 条超期 > 阈值 5。
      for (var i = 0; i < 6; i++) {
        await seedSoftDeleted('activities', 'a$i', const Duration(days: 400));
      }
      final report = (await service.run()).requireValue();
      expect(report.deletedTotal, 6);
      expect(
        report.vacuumed,
        isTrue,
        reason: '超阈值触发 VACUUM',
      ); // VACUUM 后库仍可用（重写未损坏）。
      final left = await (db.select(db.activities)).get();
      expect(left, isEmpty);
    });

    test('恰等于阈值 → 不 VACUUM（严格大于语义）', () async {
      await putMeta(AppMetadataKeys.lastSyncAt, nowStr());
      for (var i = 0; i < 5; i++) {
        await seedSoftDeleted('activities', 'b$i', const Duration(days: 400));
      }
      final report = (await service.run()).requireValue();
      expect(report.deletedTotal, 5);
      expect(report.vacuumed, isFalse, reason: '恰等于阈值不触发');
    });

    test('VACUUM 失败隔离（r3）：vacuumed=false、删除不回滚、last_cleanup_at 照写', () async {
      // 注入抛错 vacuumRunner——验证 r2 修复的关键失败路径（旧缺陷：未 await
      // 时标志被同步置位、VACUUM 实际失败无感知）。
      var vacuumCalled = false;
      final failService = CleanupService(
        database: db,
        vacuumThreshold: 3,
        vacuumRunner: () async {
          vacuumCalled = true; // 调用标记：区分"被调且抛错"与"未触发 VACUUM"（r7）
          throw const FileSystemException('vacuum blocked');
        },
      );
      await putMeta(AppMetadataKeys.lastSyncAt, nowStr());
      for (var i = 0; i < 5; i++) {
        await seedSoftDeleted('activities', 'v$i', const Duration(days: 400));
      }
      final report = (await failService.run()).requireValue();
      expect(vacuumCalled, isTrue, reason: 'VACUUM 确实被触发（非阈值未达）');
      expect(report.deletedTotal, 5, reason: '物理删除不回滚');
      expect(report.vacuumed, isFalse, reason: 'VACUUM 失败如实标记未执行');
      final left = await (db.select(db.activities)).get();
      expect(left, isEmpty, reason: 'VACUUM 失败不影响已完成的删除');
      // last_cleanup_at 照写（清理主流程未中断）。
      final meta = await (db.select(
        db.appMetadata,
      )..where((t) => t.key.equals(AppMetadataKeys.lastCleanupAt))).get();
      expect(meta, isNotEmpty, reason: 'VACUUM 失败后仍记录清理时刻');
    });

    test('IN 分块跨块边界（r3）：501+ 行全量删除、残留精确', () async {
      // 块大小 500——501 条强制触发多块迭代（末块截取/跨块 id 丢失/重复的
      // off-by-one 回归锁定）。真空阈值注入 0 防超阈值干扰（实际 501 远大于
      // 注入阈值也触发 VACUUM——无妨）。
      final chunkService = CleanupService(database: db, vacuumThreshold: 0);
      await putMeta(AppMetadataKeys.lastSyncAt, nowStr());
      for (var i = 0; i < 501; i++) {
        await seedSoftDeleted('activities', 'c$i', const Duration(days: 400));
      }
      final report = (await chunkService.run()).requireValue();
      expect(
        report.deletedByTable['activities'],
        501,
        reason: '501 条全删（跨 2 块）',
      );
      final left = await (db.select(db.activities)).get();
      expect(left, isEmpty, reason: '跨块删除无残留');
    });
  });

  group('cutoff 与 sync 边界（r2）', () {
    test('lastSyncAt 早于保留截止（min 分支）：cutoff 取游标', () async {
      // lastSyncAt = now-200 天（< 保留截止 now-180）→ cutoff = lastSyncAt。
      final syncAt = mapping.utcString(
        DateTime.now().subtract(const Duration(days: 200)),
      );
      await putMeta(AppMetadataKeys.lastSyncAt, syncAt);
      // deletedAt = now-210 天（< now-200 游标）→ 删。
      await seedSoftDeleted('activities', 'c1', const Duration(days: 210));
      // deletedAt = now-190 天（> now-200 游标，即使早于保留截止 180 天）→ 保留
      //（墓碑晚于最近同步时刻——尚未传播到远端，min 分支必须拦住）。
      await seedSoftDeleted('activities', 'c2', const Duration(days: 190));
      final report = (await service.run()).requireValue();
      expect(report.deletedByTable['activities'], 1, reason: '仅早于游标者删');
      final left = await (db.select(db.activities)).get();
      expect(left.map((r) => r.id).toSet(), {'c2'}, reason: '晚于游标的墓碑保留');
    });

    test('deletedAt 恰等于游标 → 保留（严格小于语义，同步窗口边缘保守）', () async {
      // 设备停止同步后 cutoff 恒等于 lastSyncAt：deleted_at == 游标时刻的行
      // 是否已传播到远端不确定——有意保留（数据安全优先，宁留勿删）。
      final syncAt = mapping.utcString(
        DateTime.now().subtract(const Duration(days: 200)),
      );
      await putMeta(AppMetadataKeys.lastSyncAt, syncAt);
      // **复用游标字符串（r2 修正）**：两次 DateTime.now() 计算会有微秒级漂移
      //（utcString 固定 6 位微秒）——atCutoff 实际几乎恒 > syncAt，用例退化为
      // 测 `deletedAt > cutoff` 而非 == 边界；复用 syncAt 保证精确相等。
      final atCutoff = syncAt;
      await db
          .into(db.activities)
          .insert(
            ActivitiesCompanion.insert(
              id: 'edge',
              name: 'edge',
              color: 1,
              updatedAt: atCutoff,
              deletedAt: Value(atCutoff),
            ),
          );
      final report = (await service.run()).requireValue();
      expect(
        report.deletedByTable['activities'] ?? 0,
        0,
        reason: '恰等于游标不删（严格小于）',
      );
      final left = await (db.select(db.activities)).get();
      expect(left.map((r) => r.id).toSet(), {'edge'});
    });

    test('deletedAt 恰等于保留截止（now-180）→ 保留（严格小于，r3）', () async {
      // 游标近期（cutoff 取保留截止侧）：deletedAt == now-180 天时须按严格小于
      // 语义保留（若实现误写成 <= 则此用例失败——off-by-one 回归锁定）。
      // **注入固定时钟（r4）**：run() 的 now 与测试 now 的微秒漂移会让
      // deletedAt 略早于 run 的保留截止 → 误删。固定两者一致。
      final fixedNow = DateTime.now().toUtc();
      final pinnedService = CleanupService(
        database: db,
        vacuumThreshold: 5,
        now: () => fixedNow,
      );
      await putMeta(AppMetadataKeys.lastSyncAt, mapping.utcString(fixedNow));
      final atCutoff = mapping.utcString(
        fixedNow.subtract(const Duration(days: 180)),
      );
      await db
          .into(db.activities)
          .insert(
            ActivitiesCompanion.insert(
              id: 'edge180',
              name: 'edge180',
              color: 1,
              updatedAt: atCutoff,
              deletedAt: Value(atCutoff),
            ),
          );
      final report = (await pinnedService.run()).requireValue();
      expect(
        report.deletedByTable['activities'] ?? 0,
        0,
        reason: '恰等于保留截止不删（严格小于）',
      );
      final left = await (db.select(db.activities)).get();
      expect(left.map((r) => r.id).toSet(), {'edge180'});
    });
  });

  group('FK 引用完整性（r2）', () {
    test('存活条目引用超期活动 → 跳过删除该活动（防悬空条目）', () async {
      await putMeta(AppMetadataKeys.lastSyncAt, nowStr());
      // 活动 A：超期软删；活动 B：超期软删（无引用）。
      final deletedAt = mapping.utcString(
        DateTime.now().subtract(const Duration(days: 400)),
      );
      await db
          .into(db.activities)
          .insert(
            ActivitiesCompanion.insert(
              id: 'actA',
              name: 'A',
              color: 1,
              updatedAt: deletedAt,
              deletedAt: Value(deletedAt),
            ),
          );
      await db
          .into(db.activities)
          .insert(
            ActivitiesCompanion.insert(
              id: 'actB',
              name: 'B',
              color: 1,
              updatedAt: deletedAt,
              deletedAt: Value(deletedAt),
            ),
          );
      // 存活 time_entry 引用 A（deletedAt null）——父被删会制造悬空条目。
      await db
          .into(db.timeEntries)
          .insert(
            TimeEntriesCompanion.insert(
              id: 'e-alive',
              activityId: 'actA',
              activityName: const Value(''),
              startAt: nowStr(),
              deviceId: 'dev',
              updatedAt: nowStr(),
            ),
          );
      final report = (await service.run()).requireValue();
      expect(report.deletedByTable['activities'], 1, reason: '仅无引用的 B 被删');
      final left = await (db.select(db.activities)).get();
      expect(left.map((r) => r.id).toSet(), {'actA'}, reason: 'A 被存活引用跳过');
      // 存活条目仍在（未回滚、未误删）。
      final entries = await (db.select(db.timeEntries)).get();
      expect(entries.map((r) => r.id).toSet(), {'e-alive'});
    });

    test('软删未超期条目引用超期活动 → 阻塞父删除（未传播子行保留，r5）', () async {
      await putMeta(AppMetadataKeys.lastSyncAt, nowStr());
      final parentDeleted = mapping.utcString(
        DateTime.now().subtract(const Duration(days: 400)),
      );
      await db
          .into(db.activities)
          .insert(
            ActivitiesCompanion.insert(
              id: 'actP',
              name: 'P',
              color: 1,
              updatedAt: parentDeleted,
              deletedAt: Value(parentDeleted),
            ),
          );
      // 软删**未超期**（10 天前，早于游标=now 但晚于 cutoff=now-180）条目引用
      // P——**未传播到远端的墓碑**（r5 修正）：不得随父物理清除（否则下次同步
      // 时子行从远端复活/语义缺口）；且阻塞父删除（父被物理删会 FK 违约）。
      final childDeleted = mapping.utcString(
        DateTime.now().subtract(const Duration(days: 10)),
      );
      await db
          .into(db.timeEntries)
          .insert(
            TimeEntriesCompanion.insert(
              id: 'e-soft',
              activityId: 'actP',
              activityName: const Value(''),
              startAt: childDeleted,
              deviceId: 'dev',
              updatedAt: childDeleted,
              deletedAt: Value(childDeleted),
            ),
          );
      final report = (await service.run()).requireValue();
      // 未传播子行阻塞父删除：P 保留、e-soft 保留（r5 修复后语义）。
      expect(report.deletedByTable['activities'] ?? 0, 0, reason: '未传播子行阻塞父删除');
      expect(
        report.deletedByTable['timeEntries'] ?? 0,
        0,
        reason: '未传播子行保留（不做物理清除）',
      );
      final activities = await (db.select(db.activities)).get();
      expect(activities.map((r) => r.id).toSet(), {'actP'});
      final entries = await (db.select(db.timeEntries)).get();
      expect(entries.map((r) => r.id).toSet(), {'e-soft'});
    });

    test('trackingRules/links 存活引用同样阻塞父删除（r2 对称）', () async {
      await putMeta(AppMetadataKeys.lastSyncAt, nowStr());
      final deleted = mapping.utcString(
        DateTime.now().subtract(const Duration(days: 400)),
      );
      await db
          .into(db.activities)
          .insert(
            ActivitiesCompanion.insert(
              id: 'actR',
              name: 'R',
              color: 1,
              updatedAt: deleted,
              deletedAt: Value(deleted),
            ),
          );
      await db
          .into(db.activities)
          .insert(
            ActivitiesCompanion.insert(
              id: 'actL',
              name: 'L',
              color: 1,
              updatedAt: deleted,
              deletedAt: Value(deleted),
            ),
          );
      // 存活 tracking_rule 引用 actR；存活 link 引用 actL（link 的 FK 依赖
      // category 先建——插入顺序：分类 → link）。
      await db
          .into(db.trackingRules)
          .insert(
            TrackingRulesCompanion.insert(
              id: 'rule-alive',
              pattern: 'p',
              matchKind: 'process',
              activityId: 'actR',
              updatedAt: nowStr(),
            ),
          );
      await db
          .into(db.activityCategories)
          .insert(
            ActivityCategoriesCompanion.insert(
              id: 'cat-alive',
              name: 'cat',
              color: 1,
              updatedAt: nowStr(),
            ),
          );
      await db
          .into(db.activityCategoryLinks)
          .insert(
            ActivityCategoryLinksCompanion.insert(
              id: 'link-alive',
              activityId: 'actL',
              categoryId: 'cat-alive',
              updatedAt: nowStr(),
            ),
          );
      final report = (await service.run()).requireValue();
      expect(
        report.deletedByTable['activities'] ?? 0,
        0,
        reason: 'trackingRules/links 存活引用均阻塞父删除',
      );
      final left = await (db.select(db.activities)).get();
      expect(left.map((r) => r.id).toSet(), {'actR', 'actL'});
    });

    test('软删未超期子分类引用将删父 → parentId 置 NULL 且墓碑子 updatedAt 不被刷新（r12）', () async {
      await putMeta(AppMetadataKeys.lastSyncAt, nowStr());
      final parentDeleted = mapping.utcString(
        DateTime.now().subtract(const Duration(days: 400)),
      );
      await db
          .into(db.activityCategories)
          .insert(
            ActivityCategoriesCompanion.insert(
              id: 'parent3',
              name: 'parent3',
              color: 1,
              updatedAt: parentDeleted,
              deletedAt: Value(parentDeleted),
              parentId: const Value(null),
            ),
          );
      // 软删未超期子分类（10 天前）引用 parent3——父被物理删除时子引用悬空
      //（自引用 FK）；即使子自身未到保留期，parentId 也须置 NULL。
      final childDeleted = mapping.utcString(
        DateTime.now().subtract(const Duration(days: 10)),
      );
      await db
          .into(db.activityCategories)
          .insert(
            ActivityCategoriesCompanion.insert(
              id: 'child3',
              name: 'child3',
              color: 1,
              updatedAt: childDeleted,
              deletedAt: Value(childDeleted),
              parentId: const Value('parent3'),
            ),
          );
      final report = (await service.run()).requireValue();
      expect(report.deletedByTable['activityCategories'], 1, reason: '父被删');
      final child = (await (db.select(
        db.activityCategories,
      )..where((t) => t.id.equals('child3'))).get()).single;
      expect(child.parentId, isNull, reason: '软删未传播子 parentId 置空（防自引用 FK）');
      // **r12 修正**：墓碑子本轮不删——只置空 parentId、**不刷新 updatedAt**
      //（刷新会伪造同步增量/已传播墓碑重复推送）。断言保持原软删时刻。
      expect(
        child.updatedAt,
        childDeleted,
        reason: '墓碑子 updatedAt 不被清理刷新（防伪造同步增量）',
      );
    });

    test('被存活 link.categoryId 引用的超期分类 → 跳过删除（r2 对称）', () async {
      // r2 对称修复：_deleteExpiredCategories 按 categoryId 计算 blocked 集合
      //（存活或软删未传播 link 引用将删分类 → 分类保留、link 不悬空）。
      await putMeta(AppMetadataKeys.lastSyncAt, nowStr());
      final catDeleted = mapping.utcString(
        DateTime.now().subtract(const Duration(days: 400)),
      );
      await db
          .into(db.activityCategories)
          .insert(
            ActivityCategoriesCompanion.insert(
              id: 'catX',
              name: 'X',
              color: 1,
              updatedAt: catDeleted,
              deletedAt: Value(catDeleted),
              parentId: const Value(null),
            ),
          );
      await db
          .into(db.activityCategories)
          .insert(
            ActivityCategoriesCompanion.insert(
              id: 'catY',
              name: 'Y',
              color: 1,
              updatedAt: catDeleted,
              deletedAt: Value(catDeleted),
              parentId: const Value(null),
            ),
          );
      // 存活 link 引用 catX（FK 依赖活动——先建活动）；catY 无引用可删。
      await db
          .into(db.activities)
          .insert(
            ActivitiesCompanion.insert(
              id: 'actX',
              name: 'actX',
              color: 1,
              updatedAt: nowStr(),
            ),
          );
      await db
          .into(db.activityCategoryLinks)
          .insert(
            ActivityCategoryLinksCompanion.insert(
              id: 'linkX',
              activityId: 'actX',
              categoryId: 'catX',
              updatedAt: nowStr(),
            ),
          );
      final report = (await service.run()).requireValue();
      expect(
        report.deletedByTable['activityCategories'],
        1,
        reason: '仅无引用的 Y 删',
      );
      final left = await (db.select(db.activityCategories)).get();
      expect(left.map((r) => r.id).toSet(), {
        'catX',
      }, reason: '被存活 link 引用的分类跳过删除');
      // link 不悬空（catX 仍在）。
      final links = await (db.select(db.activityCategoryLinks)).get();
      expect(links.map((r) => r.id).toSet(), {'linkX'});
    });

    test('软删未传播 link 引用超期分类 → 同样阻塞分类删除（r4）', () async {
      // r4：blocked 集合含"软删但未传播"（deletedAt >= cutoff）的 link——
      // 与 r5 timeEntries 方向对称，link 方向缺正向用例防退化。
      await putMeta(AppMetadataKeys.lastSyncAt, nowStr());
      final catDeleted = mapping.utcString(
        DateTime.now().subtract(const Duration(days: 400)),
      );
      await db
          .into(db.activityCategories)
          .insert(
            ActivityCategoriesCompanion.insert(
              id: 'catZ',
              name: 'Z',
              color: 1,
              updatedAt: catDeleted,
              deletedAt: Value(catDeleted),
              parentId: const Value(null),
            ),
          );
      // 软删未传播 link（10 天前，早于游标=now 但晚于 cutoff=now-180）引用 catZ。
      final linkDeleted = mapping.utcString(
        DateTime.now().subtract(const Duration(days: 10)),
      );
      await db
          .into(db.activities)
          .insert(
            ActivitiesCompanion.insert(
              id: 'actZ',
              name: 'actZ',
              color: 1,
              updatedAt: linkDeleted,
            ),
          );
      await db
          .into(db.activityCategoryLinks)
          .insert(
            ActivityCategoryLinksCompanion.insert(
              id: 'linkZ',
              activityId: 'actZ',
              categoryId: 'catZ',
              updatedAt: linkDeleted,
              deletedAt: Value(linkDeleted),
            ),
          );
      final report = (await service.run()).requireValue();
      expect(
        report.deletedByTable['activityCategories'] ?? 0,
        0,
        reason: '软删未传播 link 引用阻塞分类删除',
      );
      final left = await (db.select(db.activityCategories)).get();
      expect(left.map((r) => r.id).toSet(), {'catZ'});
      // **link 自身保留（r5 对称）**：阻塞来源精确化——linkZ 不得被误删（防
      // "catZ 因别的原因保留、linkZ 被误清"的组合回归无感知）。
      expect(
        report.deletedByTable['activityCategoryLinks'] ?? 0,
        0,
        reason: '软删未传播 link 自身保留（不随父清）',
      );
      final links = await (db.select(db.activityCategoryLinks)).get();
      expect(links.map((r) => r.id).toSet(), {'linkZ'});
    });

    test('blocked 集防 FK 违约路径：父跳过、软删已传播子清理、last_cleanup_at 照写（r3/r7）', () async {
      // 用例名如实反映验证内容（r7 修正）：blocked 集使 FK 违约**不可自然触发**
      //——含存活引用的父必被跳过（设计上无违约路径），事务永不因 FK 违约
      // 回滚；故验证的是"父跳过 + 软删已传播子清理 + 事务成功提交（清理时刻
      // 照写）"而非"回滚 + 不推进"。
      await putMeta(AppMetadataKeys.lastSyncAt, nowStr());
      final deleted = mapping.utcString(
        DateTime.now().subtract(const Duration(days: 400)),
      );
      await db
          .into(db.activities)
          .insert(
            ActivitiesCompanion.insert(
              id: 'actAtom',
              name: 'atom',
              color: 1,
              updatedAt: deleted,
              deletedAt: Value(deleted),
            ),
          );
      // 软删已传播条目引用 actAtom（< cutoff，随父清理、不阻塞）。
      await db
          .into(db.timeEntries)
          .insert(
            TimeEntriesCompanion.insert(
              id: 'e-atom',
              activityId: 'actAtom',
              activityName: const Value(''),
              startAt: deleted,
              deviceId: 'dev',
              updatedAt: deleted,
              deletedAt: Value(deleted),
            ),
          );
      // 存活条目引用 actAtom（blocked 集拦截 → 父跳过）。
      await db
          .into(db.timeEntries)
          .insert(
            TimeEntriesCompanion.insert(
              id: 'e-live',
              activityId: 'actAtom',
              activityName: const Value(''),
              startAt: nowStr(),
              deviceId: 'dev',
              updatedAt: nowStr(),
            ),
          );
      final report = (await service.run()).requireValue();
      // 父被存活引用跳过（不回滚、不失败）；软删已传播子被清；存活子保留。
      expect(report.deletedByTable['activities'] ?? 0, 0, reason: '父跳过');
      expect(report.deletedByTable['timeEntries'], 1, reason: '软删已传播子清理');
      final entries = await (db.select(db.timeEntries)).get();
      expect(entries.map((r) => r.id).toSet(), {'e-live'});
      // 清理正常完成 → last_cleanup_at 已推进（无违约、事务成功提交）。
      final meta = await (db.select(
        db.appMetadata,
      )..where((t) => t.key.equals(AppMetadataKeys.lastCleanupAt))).get();
      expect(meta, isNotEmpty, reason: '事务成功提交后推进清理时刻');
    });
  });

  group('retentionDays DB 异常回退（r2）', () {
    test('数据库已关闭 → 回退默认 180（不崩溃）', () async {
      await db.close();
      expect(await service.retentionDays(), 180, reason: 'DB 异常回退默认');
    });
  });

  group('文件库 VACUUM 集成（r3）', () {
    test('文件型库 WAL 模式下 VACUUM + checkpoint 真实可执行', () async {
      final dir = await Directory.systemTemp.createTemp('cleanup_file');
      final fileDb = AppDatabase(
        NativeDatabase(File('${dir.path}/timetrack.sqlite')),
      );
      final fileService = CleanupService(database: fileDb, vacuumThreshold: 3);
      final mapping = _MappingHost();
      try {
        await fileDb.customStatement('PRAGMA journal_mode = WAL');
        await fileDb
            .into(fileDb.appMetadata)
            .insert(
              AppMetadataCompanion.insert(
                key: AppMetadataKeys.lastSyncAt,
                value: mapping.utcString(DateTime.now()),
              ),
              mode: InsertMode.insertOrReplace,
            );
        for (var i = 0; i < 5; i++) {
          final deleted = mapping.utcString(
            DateTime.now().subtract(const Duration(days: 400)),
          );
          await fileDb
              .into(fileDb.activities)
              .insert(
                ActivitiesCompanion.insert(
                  id: 'f$i',
                  name: 'f$i',
                  color: 1,
                  updatedAt: deleted,
                  deletedAt: Value(deleted),
                ),
              );
        }
        final report = (await fileService.run()).requireValue();
        expect(report.deletedTotal, 5);
        // **强断言（r3）**：仅 `report.vacuumed == true` 无法区分"VACUUM 真实完成"
        // 与"标志误置"（旧缺陷正是未 await 时标志被同步置位）——VACUUM 把
        // freelist_count（空闲页）清零（删除行遗留的空闲页被重写回收）：
        // 删除 5 行前 fileService 运行时页有可回收空间，VACUUM 后空闲页必须为 0。
        expect(report.vacuumed, isTrue, reason: '文件库 WAL 下 VACUUM 真实执行');
        final freelist =
            (await fileDb.customSelect('PRAGMA freelist_count').getSingle())
                    .data
                    .values
                    .first
                as int;
        expect(freelist, 0, reason: 'VACUUM 后空闲页归零（空间真实回收）');
        // VACUUM 后库仍可查询（重写未损坏）。
        final left = await (fileDb.select(fileDb.activities)).get();
        expect(left, isEmpty);
      } finally {
        await fileDb.close();
        await dir.delete(recursive: true);
      }
    });
  });
}

/// 混入 RepositoryMappings 以调用其 utcString 实例方法（与 time_mappings_test
/// 的 _MappingHost 同模式）。
class _MappingHost with RepositoryMappings {}
