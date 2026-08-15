/// drift 单一 schema（阶段 1 建齐业务表 + 阶段 2 追加配置/同步元数据表）。
///
/// 设计要点（计划与不变式）：
/// - 时间一律 **UTC ISO8601 字符串**存储（`text()` 列；Dart 侧由仓储层
///   `viewmodels` 的 readDateTime + `toUtc().toIso8601String()` 转换），
///   字典序 = 时间序，与同步协议/文件互通格式一致；
/// - 软删统一 `deleted_at`（可空）替代布尔位，删除永远赢——**软删不变式
///   仅适用于业务表**（activities/activity_categories/activity_category_links/
///   time_entries/action_logs/tracking_rules）；app_metadata/sync_peers/
///   profile_settings 为配置/同步元数据表，无 deleted_at、不参与软删同步；
/// - 部分索引只索引未删行（`deleted_at is null`）；
/// - FK 不设 ON DELETE CASCADE：删除是 UPDATE（软删），物理级联会破坏
///   "删除永远赢"——递归级联在仓储层事务内手动完成（含分类层级）。
///
/// 注：drift 2.34 的列级 `TypeConverter.map` 在 analyzer 层无法把 `TextColumn`
/// 直接标注为 `Column<DateTime>`（返回类型仍是存储类型），且可空列有类型
/// 边界限制——故时间列用 `text()` 存 ISO8601，转换收敛在仓储层（单一转换点）。
library;

import 'package:drift/drift.dart';
import 'package:drift_flutter/drift_flutter.dart';
part 'app_database.g.dart';

/// 数据类：活动（事项）。
@DataClassName('ActivityRow')
class Activities extends Table {
  TextColumn get id => text()();
  TextColumn get userId => text().nullable()();
  TextColumn get name => text()();
  IntColumn get color => integer()();
  BoolColumn get isFavorite => boolean().withDefault(const Constant(true))();
  TextColumn get updatedAt => text()();
  TextColumn get deletedAt => text().nullable()();
  BoolColumn get isUnassigned => boolean().withDefault(const Constant(false))();
  BoolColumn get isOneOff => boolean().withDefault(const Constant(false))();

  @override
  Set<Column> get primaryKey => {id};
}

/// 数据类：时间条目。
@DataClassName('TimeEntryRow')
class TimeEntries extends Table {
  TextColumn get id => text()();
  TextColumn get userId => text().nullable()();
  TextColumn get activityId => text().references(Activities, #id)();
  TextColumn get activityName => text().withDefault(const Constant(''))();
  IntColumn get activityColor => integer().nullable()();
  TextColumn get startAt => text()();
  TextColumn get endAt => text().nullable()();
  TextColumn get note => text().withDefault(const Constant(''))();
  TextColumn get deviceId => text()();
  TextColumn get updatedAt => text()();
  TextColumn get deletedAt => text().nullable()();
  /// 自动生成标记（后台前台检测自动记录 vs 手动计时）：统计排除/批量清理/
  /// 防误编辑的判定依据；随行 LWW 同步（并入 time_entries 行）。
  BoolColumn get isAuto => boolean().withDefault(const Constant(false))();

  @override
  Set<Column> get primaryKey => {id};
}

/// 数据类：后台自动记录映射规则（进程/窗口标题模式 → 活动）。
///
/// - `sync_enabled`：**per-rule 同步开关**——true 的规则参与云同步（schema.sql
///   tracking_rules 表 + RLS + 引擎行级过滤），false 仅存本地（不进远端、
///   不被远端覆盖）；
/// - 软删统一 `deleted_at`（LWW 删除永远赢）；`user_id` 归属（同步表模式与
///   5 张业务表一致）。
@DataClassName('TrackingRuleRow')
@TableIndex(name: 'idx_tracking_rules_sync', columns: {#userId, #updatedAt})
@TableIndex(name: 'idx_tracking_rules_activity', columns: {#activityId})
class TrackingRules extends Table {
  TextColumn get id => text()();
  TextColumn get userId => text().nullable()();
  /// 匹配模式（进程名如 `chrome.exe` / 窗口标题模式）。
  TextColumn get pattern => text()();
  /// 匹配类型（process/title，存储值见 TrackingRuleMatchKind.storageValue）。
  TextColumn get matchKind => text()();
  /// 映射到的活动 id（必填：规则匹配到活动是映射的落点，无匹配活动的规则
  /// 无意义）。
  TextColumn get activityId => text().references(Activities, #id)();
  BoolColumn get syncEnabled => boolean().withDefault(const Constant(true))();
  TextColumn get updatedAt => text()();
  TextColumn get deletedAt => text().nullable()();

  @override
  Set<Column> get primaryKey => {id};
}

/// 数据类：活动分类（parentId 自引用层级）。
@DataClassName('ActivityCategoryRow')
class ActivityCategories extends Table {
  TextColumn get id => text()();
  TextColumn get userId => text().nullable()();
  TextColumn get name => text()();
  IntColumn get color => integer()();
  TextColumn get updatedAt => text()();
  TextColumn get deletedAt => text().nullable()();
  TextColumn get parentId =>
      text().nullable().references(ActivityCategories, #id)();

  @override
  Set<Column> get primaryKey => {id};
}

/// 数据类：活动-分类关联。
@DataClassName('ActivityCategoryLinkRow')
class ActivityCategoryLinks extends Table {
  TextColumn get id => text()();
  TextColumn get userId => text().nullable()();
  TextColumn get activityId => text().references(Activities, #id)();
  TextColumn get categoryId =>
      text().references(ActivityCategories, #id)();
  BoolColumn get isPrimary =>
      boolean().withDefault(const Constant(false))();
  IntColumn get sortOrder => integer().withDefault(const Constant(0))();
  TextColumn get updatedAt => text()();
  TextColumn get deletedAt => text().nullable()();

  @override
  Set<Column> get primaryKey => {id};
}

/// 数据类：配置文件（单例，id 恒为 1）。
@DataClassName('ProfileSettingsRow')
class ProfileSettings extends Table {
  IntColumn get id => integer().withDefault(const Constant(1))();
  TextColumn get userId => text().nullable()();
  IntColumn get reminderMinutes =>
      integer().withDefault(const Constant(45))();
  IntColumn get reminderIntervalMinutes =>
      integer().withDefault(const Constant(10))();
  TextColumn get reminderMethod =>
      text().withDefault(const Constant('dialog'))();
  IntColumn get reminderTimeOfDayMinutes =>
      integer().withDefault(const Constant(540))();
  IntColumn get mergeNeighborThresholdMinutes =>
      integer().withDefault(const Constant(1))();
  TextColumn get timezone => text()();
  TextColumn get updatedAt => text()();

  @override
  Set<Column> get primaryKey => {id};
}

/// 数据类：操作日志。
@DataClassName('ActionLogRow')
class ActionLogs extends Table {
  TextColumn get id => text()();
  TextColumn get userId => text().nullable()();
  TextColumn get actionType => text()();
  TextColumn get activityId => text().nullable()();
  TextColumn get entryId => text().nullable()();
  TextColumn get message => text().withDefault(const Constant(''))();
  TextColumn get occurredAt => text()();
  TextColumn get deviceId => text()();
  TextColumn get updatedAt => text()();
  TextColumn get deletedAt => text().nullable()();

  @override
  Set<Column> get primaryKey => {id};
}

/// 数据类：应用元数据（key-value；承载 device_id/同步游标/忽略版本等）。
@DataClassName('AppMetadataRow')
class AppMetadata extends Table {
  TextColumn get key => text()();
  TextColumn get value => text()();

  @override
  Set<Column> get primaryKey => {key};
}

/// 数据类：同步对端（LAN/云）。
@DataClassName('SyncPeerRow')
class SyncPeers extends Table {
  TextColumn get id => text()();
  TextColumn get kind => text()();
  TextColumn get displayName => text()();
  TextColumn get baseUrl => text().nullable()();
  TextColumn get token => text()();
  TextColumn get updatedAt => text()();

  @override
  Set<Column> get primaryKey => {id};
}

@DriftDatabase(
  tables: [
    Activities,
    TimeEntries,
    ActivityCategories,
    ActivityCategoryLinks,
    ProfileSettings,
    ActionLogs,
    AppMetadata,
    SyncPeers,
    TrackingRules,
  ],
)
class AppDatabase extends _$AppDatabase {
  AppDatabase(super.e);

  /// 打开平台数据库（drift_flutter 自动处理 Windows/Android 原生初始化）。
  factory AppDatabase.open() => AppDatabase(driftDatabase(name: 'timetrack'));

  @override
  int get schemaVersion => 2;

  @override
  MigrationStrategy get migration => MigrationStrategy(
        beforeOpen: (details) async {
          // 外键约束（软删体系下无 CASCADE，靠仓储事务内手动级联）。
          await customStatement('PRAGMA foreign_keys = ON');
          // 性能/可靠 PRAGMA：失败不阻塞启动（老项目语义）。
          await _tryPragma('PRAGMA journal_mode = WAL');
          await _tryPragma('PRAGMA synchronous = NORMAL');
          await _tryPragma('PRAGMA cache_size = -10000');
          await _tryPragma('PRAGMA temp_store = MEMORY');
          // 无条件补齐部分索引：beforeOpen 在 onCreate 之后执行（表已建），
          // `IF NOT EXISTS` 幂等，新建/已有库均生效，防索引与 schema 漂移。
          await _ensureIndexes();
        },
        onCreate: (m) async {
          await m.createAll();
        },
        onUpgrade: (m, from, to) async {
          // 模块 2c'：TimeEntries 加 is_auto 列 + 新增 tracking_rules 表。
          if (from < 2) {
            // 不用 drift 的 addColumn：其对带 CHECK 约束/默认值的列生成的
            // `ADD COLUMN ... CHECK (...)` 会被 SQLite 拒绝（ADD COLUMN 禁止
            // CHECK 约束），列静默不生效（旧行读取 is_auto 为 NULL 崩溃）。
            // 手工 ALTER（经本类 customStatement——迁移回调内可用，之前失败
            // 是夹具没设 user_version、迁移未触发所致）省略 CHECK（bool 亲和
            // 类型 0/1，drift 写入恒 0/1；CHECK 仅为生成层的保险约束，缺失
            // 不影响读写正确性）。
            await customStatement(
              'ALTER TABLE time_entries ADD COLUMN is_auto '
              'BOOLEAN NOT NULL DEFAULT false',
            );
            await m.createTable(trackingRules);
            // 迁移路径：tracking_rules 索引由 beforeOpen 的 [_ensureIndexes]
            // 无条件补齐（@TableIndex 仅 onCreate 的 createAll 建，m.createTable
            // 不建），此处不重复。
          }
        },
      );

  /// 执行 PRAGMA；失败静默忽略（部分 SQLite 构建不支持个别参数）。
  Future<void> _tryPragma(String statement) async {
    try {
      await customStatement(statement);
    } on Exception {
      // WAL/synchronous 等仅调优性能，不支持时保持默认即可。
    }
  }

  /// 确保索引就绪：部分索引只索引未删行（老项目性能索引思路）+ parent_id
  /// 全量索引（递归 CTE 需穿透已删节点，不能用部分索引）。
  Future<void> _ensureIndexes() async {
    // 部分索引以业务列开头（部分索引谓词已限定 deleted_at IS NULL，
    // 首列不再放 deleted_at——恒为常量属冗余开销）。
    await customStatement(
      'CREATE INDEX IF NOT EXISTS idx_time_entries_active_start '
      'ON time_entries (start_at) WHERE deleted_at IS NULL',
    );
    await customStatement(
      'CREATE INDEX IF NOT EXISTS idx_time_entries_active_end '
      'ON time_entries (end_at) WHERE deleted_at IS NULL',
    );
    await customStatement(
      'CREATE INDEX IF NOT EXISTS idx_time_entries_running_active '
      'ON time_entries (start_at) WHERE end_at IS NULL AND deleted_at IS NULL',
    );
    await customStatement(
      'CREATE INDEX IF NOT EXISTS idx_time_entries_activity_active '
      'ON time_entries (activity_id, start_at) WHERE deleted_at IS NULL',
    );
    await customStatement(
      'CREATE INDEX IF NOT EXISTS idx_activities_active_sort '
      'ON activities (is_favorite, name) WHERE deleted_at IS NULL',
    );
    await customStatement(
      'CREATE INDEX IF NOT EXISTS idx_activity_category_links_active_sort '
      'ON activity_category_links (activity_id, is_primary, sort_order) '
      'WHERE deleted_at IS NULL',
    );
    await customStatement(
      'CREATE INDEX IF NOT EXISTS idx_activity_category_links_category_active '
      'ON activity_category_links (category_id) WHERE deleted_at IS NULL',
    );
    // 分类 parent_id 普通索引（递归 CTE 需穿透已删节点，不能用部分索引）。
    await customStatement(
      'CREATE INDEX IF NOT EXISTS idx_activity_categories_parent '
      'ON activity_categories (parent_id)',
    );
    await customStatement(
      'CREATE INDEX IF NOT EXISTS idx_action_logs_active_occurred '
      'ON action_logs (occurred_at) WHERE deleted_at IS NULL',
    );
    await customStatement(
      'CREATE INDEX IF NOT EXISTS idx_action_logs_activity_active '
      'ON action_logs (activity_id, occurred_at) WHERE deleted_at IS NULL',
    );
    await customStatement(
      'CREATE INDEX IF NOT EXISTS idx_action_logs_entry_active '
      'ON action_logs (entry_id, occurred_at) WHERE deleted_at IS NULL',
    );
    // tracking_rules 同步索引（每次打开无条件补齐）：@TableIndex 仅在 onCreate
    // 的 createAll() 建索引、迁移库 m.createTable 不建——放这里幂等补齐，覆盖
    // 新建库 / v1→v2 升级 / 已升级但缺索引的存量库三类路径；同步引擎
    // rulesSince 的 (user_id, updated_at) 查询与 activity_id 反查依赖。
    await customStatement(
      'CREATE INDEX IF NOT EXISTS idx_tracking_rules_sync '
      'ON tracking_rules (user_id, updated_at)',
    );
    await customStatement(
      'CREATE INDEX IF NOT EXISTS idx_tracking_rules_activity '
      'ON tracking_rules (activity_id)',
    );
  }
}
