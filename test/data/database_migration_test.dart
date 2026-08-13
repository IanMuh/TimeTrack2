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
      try {
        dir.deleteSync(recursive: true);
      } on FileSystemException {
        // 临时目录清理失败不影响测试结论
      }
    }
  });
}
