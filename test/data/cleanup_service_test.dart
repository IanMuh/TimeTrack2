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

  tearDown(() => db.close());

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
    Duration deletedAge,
  ) async {
    final deletedAt = mapping.utcString(DateTime.now().subtract(deletedAge));
    // FK 依赖：子表行引用 activities/activityCategories——先造对应父行（存活，
    // 否则本用例的物理删除断言会受父行存在性干扰）。
    if (table == 'timeEntries' || table == 'trackingRules') {
      await db
          .into(db.activities)
          .insert(
            ActivitiesCompanion.insert(
              id: 'act-$id',
              name: 'parent-$id',
              color: 1,
              updatedAt: deletedAt,
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
              ),
            );
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
      for (final table in CleanupService.tableNames) {
        await seedSoftDeleted(table, 'x', const Duration(days: 400));
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
      expect(report.vacuumed, isTrue, reason: '超阈值触发 VACUUM');
      // VACUUM 后库仍可用（重写未损坏）。
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
      // 造 deletedAt 精确等于游标时刻的软删活动。
      final atCutoff = mapping.utcString(
        DateTime.now().subtract(const Duration(days: 200)),
      );
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

    test('软删未超期条目引用超期活动 → 随父清理（父已移除，子墓碑无参照价值）', () async {
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
      // 软删未超期（10 天前）条目引用 P——父被物理移除后此墓碑失去参照价值。
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
      // 活动被删（无存活引用）；软删子条目随父清理（引用清理分支）。
      expect(report.deletedByTable['activities'], 1, reason: 'P 被删');
      expect(report.deletedByTable['timeEntries'], 1, reason: '引用 P 的软删子清理');
      final entries = await (db.select(db.timeEntries)).get();
      expect(entries, isEmpty);
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
        expect(report.vacuumed, isTrue, reason: '文件库 WAL 下 VACUUM 真实执行');
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
