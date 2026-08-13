import 'dart:io';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:timetrack2/data/database/app_database.dart' hide TimeEntries;

/// schema v1 → v2 迁移冒烟（模块 2c'）：
/// v1 库（TimeEntries 无 is_auto 列、无 tracking_rules 表）升级后——
/// 旧数据保留、新列默认 false、新表可写。
///
/// 用裸 sqlite3 建 v1 结构（drift 未导出 schema 快照，手写 v1 表结构镜像
/// 阶段 0-1 的 drift 定义），再让 AppDatabase 打开触发 onUpgrade。
void main() {
  test('v1 → v2：is_auto 列补默认 false + tracking_rules 表创建', () async {
    final dir = Directory.systemTemp.createTempSync('timetrack-migrate');
    final file = File('${dir.path}/v1.sqlite');
    try {
      // 裸建 v1 库（仅含 AppDatabase 打开时会校验/操作的关键表；activity FK
      // 由旧条目引用，一并建）。
      final db = sqlite3.open(file.path);
      db.execute('PRAGMA journal_mode = WAL');
      // **版本标注**：drift 以 `PRAGMA user_version` 判断迁移——裸建的 v1 库
      // 若不设 user_version=1，drift 视为全新库走 onCreate（表已存在会出错/
      // 迁移不触发），须显式标注版本以走 onUpgrade。
      db.execute('PRAGMA user_version = 1');
      // v1 表集合：beforeOpen 的 _ensureIndexes 引用 activities/time_entries/
      // activity_categories/activity_category_links/action_logs 五表——须建全，
      // 否则升级流程建索引时因缺表抛错（生产 v1 库恒有全部表，此处仅测试夹具）。
      db.execute('''
        CREATE TABLE activities (
          id TEXT PRIMARY KEY NOT NULL,
          user_id TEXT,
          name TEXT NOT NULL,
          color INTEGER NOT NULL,
          is_favorite INTEGER NOT NULL DEFAULT 1,
          updated_at TEXT NOT NULL,
          deleted_at TEXT,
          is_unassigned INTEGER NOT NULL DEFAULT 0,
          is_one_off INTEGER NOT NULL DEFAULT 0
        );
      ''');
      db.execute('''
        CREATE TABLE activity_categories (
          id TEXT PRIMARY KEY NOT NULL,
          user_id TEXT,
          name TEXT NOT NULL,
          color INTEGER NOT NULL,
          updated_at TEXT NOT NULL,
          deleted_at TEXT,
          parent_id TEXT
        );
      ''');
      db.execute('''
        CREATE TABLE activity_category_links (
          id TEXT PRIMARY KEY NOT NULL,
          user_id TEXT,
          activity_id TEXT NOT NULL,
          category_id TEXT NOT NULL,
          is_primary INTEGER NOT NULL DEFAULT 0,
          sort_order INTEGER NOT NULL DEFAULT 0,
          updated_at TEXT NOT NULL,
          deleted_at TEXT
        );
      ''');
      db.execute('''
        CREATE TABLE action_logs (
          id TEXT PRIMARY KEY NOT NULL,
          user_id TEXT,
          action_type TEXT NOT NULL,
          activity_id TEXT,
          entry_id TEXT,
          message TEXT NOT NULL DEFAULT '',
          occurred_at TEXT NOT NULL,
          device_id TEXT NOT NULL,
          updated_at TEXT NOT NULL,
          deleted_at TEXT
        );
      ''');
      db.execute('''
        CREATE TABLE time_entries (
          id TEXT PRIMARY KEY NOT NULL,
          user_id TEXT,
          activity_id TEXT NOT NULL,
          activity_name TEXT NOT NULL DEFAULT '',
          activity_color INTEGER,
          start_at TEXT NOT NULL,
          end_at TEXT,
          note TEXT NOT NULL DEFAULT '',
          device_id TEXT NOT NULL,
          updated_at TEXT NOT NULL,
          deleted_at TEXT
        );
      ''');
      db.execute('''
        INSERT INTO activities VALUES
          ('a1', NULL, '旧活动', 0, 1,
           '2026-08-12T00:00:00.000000Z', NULL, 0, 0);
      ''');
      db.execute('''
        INSERT INTO time_entries VALUES
          ('legacy-1', NULL, 'a1', '旧活动', NULL,
           '2026-08-12T01:00:00.000000Z', '2026-08-12T02:00:00.000000Z',
           '', 'devX', '2026-08-12T02:00:00.000000Z', NULL);
      ''');
      db.close(); // sqlite3 Database.close（非 drift 的 dispose）

      // AppDatabase 打开：schemaVersion=2 触发 onUpgrade（addColumn is_auto +
      // createTable tracking_rules）。
      final appDb = AppDatabase(NativeDatabase(file));
      try {
        // **迁移后 schema 不变量（r1）**：仅"能读写"不足以证明迁移正确——
        // 显式校验结构（防手工 ALTER 列静默不生效/约束缺失类回归）。
        final version = (await appDb.customSelect('PRAGMA user_version')
                .getSingle())
            .data['user_version'];
        expect(version, 2, reason: '迁移后 user_version 必须为 2');
        final teCols = await appDb.customSelect(
                'PRAGMA table_info(time_entries)')
            .get();
        final isAuto = teCols.firstWhere((c) => c.data['name'] == 'is_auto');
        expect(isAuto.data['notnull'], 1,
            reason: 'is_auto 列 notnull=1（非空）');
        // SQLite 原样存 DDL 中的默认值字面量（手工 ALTER 写 `DEFAULT false`
        // → 报告 'false'；新库生成 DDL 写 `DEFAULT 0` → 报告 '0'）——两种
        // 均须为非空（非 null），断言"有默认值"而非绑定具体字面量。
        expect(isAuto.data['dflt_value'], isNotNull,
            reason: 'is_auto 列必须带默认值（旧行补默认 false）');
        final trCols = await appDb.customSelect(
                'PRAGMA table_info(tracking_rules)')
            .get();
        final syncEnabled =
            trCols.firstWhere((c) => c.data['name'] == 'sync_enabled');
        expect(syncEnabled.data['dflt_value'], '1',
            reason: 'tracking_rules.sync_enabled 默认 true（新建规则默认进云）');
        // **迁移后索引存在性（r2）**：@TableIndex 由 m.createTable 在建表时
        // 创建——若后续改为手工 CREATE TABLE 或 drift 生成行为变化导致索引
        // 缺失（同步引擎 rulesSince 的 user_id/updated_at 查询关键路径），
        // 列级断言无法发现。
        final trIndexes = await appDb
            .customSelect("SELECT name FROM sqlite_master WHERE type='index' "
                "AND tbl_name='tracking_rules'")
            .get();
        final indexNames = trIndexes.map((r) => r.data['name']).toSet();
        expect(indexNames, contains('idx_tracking_rules_sync'),
            reason: '迁移后 idx_tracking_rules_sync 索引存在（同步查询路径）');
        expect(indexNames, contains('idx_tracking_rules_activity'),
            reason: '迁移后 idx_tracking_rules_activity 索引存在');
        // **索引定义校验（r3）**：仅名称存在不足以防"同名但列错误"的回归——
        // 校验同步索引确实覆盖 (user_id, updated_at) 两列（列序一致），否则
        // rulesSince 查询路径实际未获得预期索引。
        final syncIndexCols = await appDb
            .customSelect("SELECT name FROM pragma_index_info("
                "'idx_tracking_rules_sync') ORDER BY seqno")
            .get();
        expect(syncIndexCols.map((r) => r.data['name']).toList(),
            ['user_id', 'updated_at'],
            reason: 'idx_tracking_rules_sync 必须覆盖 (user_id, updated_at)');

        // 旧数据保留
        final rows = await (appDb.select(appDb.timeEntries)).get();
        expect(rows, hasLength(1), reason: '旧数据跨版本保留');
        expect(rows.single.id, 'legacy-1');
        expect(rows.single.isAuto, isFalse,
            reason: '旧行 is_auto 补默认 false（手动条目语义）');

        // tracking_rules 表可写（新表创建成功）
        await appDb.into(appDb.trackingRules).insert(
              TrackingRulesCompanion.insert(
                id: 'migrated-rule',
                userId: const Value(null),
                pattern: 'chrome.exe',
                matchKind: 'process',
                activityId: 'a1',
                syncEnabled: const Value(true),
                updatedAt: '2026-08-12T03:00:00.000000Z',
              ),
            );
        final rules = await (appDb.select(appDb.trackingRules)).get();
        expect(rules, hasLength(1), reason: '升级后 tracking_rules 表可用');
        expect(rules.single.pattern, 'chrome.exe');
      } finally {
        await appDb.close();
      }
    } finally {
      // WAL 模式可能残留 -wal/-shm 句柄占用：显式删三类文件 + 有限次重试，
      // 防临时目录残留污染测试环境。
      for (var attempt = 0; attempt < 3; attempt++) {
        try {
          dir.deleteSync(recursive: true);
          break;
        } on FileSystemException {
          await Future<void>.delayed(const Duration(milliseconds: 50));
        }
      }
    }
  });

  test('已 v2 存量库缺索引：重开时 _ensureIndexes 幂等补齐（r3 核心修复）', () async {
    // r3 修复的核心场景：上个 buggy 版本已升到 v2（user_version=2）的库——
    // onUpgrade 不再触发，若缺 tracking_rules 索引则**永远**缺（rulesSince 的
    // (user_id, updated_at) 查询持续全表扫描）。修复把索引移入 _ensureIndexes
    //（每次打开无条件幂等补齐），本用例锁定该行为。
    final dir = Directory.systemTemp.createTempSync('timetrack-migrate2');
    final file = File('${dir.path}/v2.sqlite');
    try {
      // 构造 v2 库：正常打开（含全部表/索引）后 DROP 同步索引模拟 buggy 状态。
      final seeded = AppDatabase(NativeDatabase(file));
      // **drift 惰性建库（r5）**：onCreate/beforeOpen 在首次执行语句时才触发
      // ——直接 close 不会建表（user_version 仍为 0），后续 DROP/断言落空。
      // 先执行 SELECT 1 强制触发建库生成 v2 schema。
      await seeded.customSelect('SELECT 1').get();
      await seeded.close();
      final raw = sqlite3.open(file.path);
      raw.execute('DROP INDEX IF EXISTS idx_tracking_rules_sync');
      // **模拟状态自校验（r5）**：断言 buggy 状态真实生效——索引确实已删，
      // 否则用例空转（若重开仍走 onCreate 而非 _ensureIndexes 补齐则假通过）。
      final afterDrop = raw.select(
          "SELECT name FROM sqlite_master WHERE type='index' "
          "AND name = 'idx_tracking_rules_sync'");
      if (afterDrop.isNotEmpty) {
        raw.close();
        fail('DROP 后 idx_tracking_rules_sync 仍存在——buggy 状态模拟失败');
      }
      raw.close();

      // 重新打开：_ensureIndexes 无条件补齐被删索引。
      final reopened = AppDatabase(NativeDatabase(file));
      try {
        final indexes = await reopened
            .customSelect("SELECT name FROM sqlite_master WHERE type='index' "
                "AND tbl_name='tracking_rules'")
            .get();
        final names = indexes.map((r) => r.data['name']).toSet();
        expect(names, contains('idx_tracking_rules_sync'),
            reason: '重开后 idx_tracking_rules_sync 被 _ensureIndexes 补齐');
        final syncIndexCols = await reopened
            .customSelect("SELECT name FROM pragma_index_info("
                "'idx_tracking_rules_sync') ORDER BY seqno")
            .get();
        expect(syncIndexCols.map((r) => r.data['name']).toList(),
            ['user_id', 'updated_at'],
            reason: '补齐的索引列定义正确（(user_id, updated_at)）');
      } finally {
        await reopened.close();
      }
    } finally {
      for (var attempt = 0; attempt < 3; attempt++) {
        try {
          dir.deleteSync(recursive: true);
          break;
        } on FileSystemException {
          await Future<void>.delayed(const Duration(milliseconds: 50));
        }
      }
    }
  });
}
