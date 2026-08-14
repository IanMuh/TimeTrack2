/// 保留期清理服务（计划模块 2f + 保留不变式 #11）。
///
/// 职责（**触发编排归阶段 3 stores**，本层只做"一次清理做什么"）：
/// 1. **软删行物理删除**：6 张业务表（activities / time_entries /
///    tracking_rules / activity_categories / activity_category_links /
///    action_logs）中 `deleted_at` **严格早于** 保留期截止（默认 180 天）的
///    行物理删除；
/// 2. **sync 感知守卫**（保留不变式 #5 删除永远赢的落地边界）：仅物理删除
///    **已传播到远端**的墓碑——`deleted_at` 须严格早于全局同步游标
///    （`last_sync_at`）；从未同步的设备（无游标）保守跳过物理删除（防
///    "本地先清、远端未来全量推送时缺口"的语义漂移）；
///    **cutoff = min(保留期截止, 最近同步时刻)**——`deleted_at < cutoff`
///    **严格小于**：恰等于游标时刻的墓碑视为"同步窗口边缘"（是否已传播到
///    远端不确定），保守留待下一轮（下一轮同步后游标推进即满足条件）；
/// 3. **FK 引用完整性（r2 修正）**：`PRAGMA foreign_keys=ON` 下物理删除父行
///    会被仍存在的引用行阻塞（整事务回滚）——删除前先清理引用：
///    - 引用将被删活动父的**软删**子行（links/tracking_rules/time_entries，
///      任意超期——父已物理移除，子墓碑失去参照价值）一并删除；
///    - **存活**子行引用将删父 → **跳过删除该父**（宁可留待下一轮，不制造
///      悬空条目/不回滚全部）；
///    - 分类：引用将被删分类的行（**含软删**，防自引用 FK）`parent_id` 置
///      NULL（存活子升级根分类、软删子置空无害），再删超期分类行；
/// 4. **VACUUM 阈值驱动**（空间回收与 I/O 成本权衡）：单次物理删除超过
///    [AppConstants.cleanupVacuumThresholdRows] 行才执行 `VACUUM` +
///    `wal_checkpoint(TRUNCATE)`（全库重写成本高，小删除不触发）；VACUUM
///    失败不阻塞清理主流程（如实标记未执行，已完成的物理删除不回滚）；
/// 5. 完成后写 `last_cleanup_at`（供阶段 3 编排层限频）。
///
/// **保留期可配置接缝（B 形态）**：[retentionDays] 是读侧最终形态——
/// `app_metadata[deletedRetentionDays]` 优先、无值/非法回退
/// [AppConstants.defaultDeletedRetentionDays]；阶段 4 设置 UI 只加写入口，
/// 读侧零改动。
///
/// **VACUUM 事务边界**：SQLite 禁止在事务内 VACUUM——物理删除在单事务内，
/// VACUUM/checkpoint 在事务提交后执行。
library;

import 'dart:io' show stderr;

import 'package:drift/drift.dart';

import '../../constants/app_constants.dart';
import '../../constants/storage_keys.dart';
import '../../data/database/app_database.dart';
import '../repositories/repository_mappings.dart';
import '../../utils/result.dart';

/// 清理报告（结果视图，供阶段 3 编排展示/日志）。
class CleanupReport {
  const CleanupReport({
    required this.deletedByTable,
    required this.vacuumed,
    this.skippedDueToNoSync = false,
    this.skippedDueToFutureCursor = false,
  });

  /// 各表物理删除行数（键为表名常量，见 [CleanupService.tableNames]）。
  final Map<String, int> deletedByTable;

  /// 本次是否执行了 VACUUM（物理删除超阈值才 true；VACUUM 失败如实为 false）。
  final bool vacuumed;

  /// 是否因"从未同步（无全局游标）"保守跳过物理删除。
  final bool skippedDueToNoSync;

  /// 是否因 cursorOverride 晚于当前时刻（调用方契约违规，模块 3c 编排
  /// 水位防御）跳过物理删除——与 [skippedDueToNoSync] 语义区分，防排查
  /// 把未来时间戳误报为"从未同步"。
  final bool skippedDueToFutureCursor;

  int get deletedTotal => deletedByTable.values.fold(0, (sum, n) => sum + n);
}

/// 保留期清理服务。
class CleanupService with RepositoryMappings {
  CleanupService({
    required this.database,
    int? vacuumThreshold,
    // **私有命名参数（Dart 3.12）**：this._x 调用名剥离下划线（写 vacuumRunner:/
    // now:）——已实证编译运行。
    this._vacuumRunner,
    this._now,
  }) : _vacuumThreshold =
           vacuumThreshold ?? AppConstants.cleanupVacuumThresholdRows;

  final AppDatabase database;

  /// VACUUM 执行钩子（**r3 可注入**）：null 时执行真实 `VACUUM` +
  /// `wal_checkpoint(TRUNCATE)`；测试注入抛错 runner 验证失败隔离路径
  ///（vacuumed=false、物理删除不回滚、last_cleanup_at 照写）。
  final Future<void> Function()? _vacuumRunner;

  /// 时钟（**r4 可注入**）：null 用 DateTime.now——测试注入固定时刻使
  /// "恰等于保留截止"等时间边界精确可测（两次 now() 微秒漂移会破坏 == 断言）。
  final DateTime Function()? _now;

  /// userId 长度上限（**与 SyncStatusStore._maxUserIdLength=128 保持一致的
  /// 本地副本，r8**）：cleanup 属 data 层、不可依赖 api 层（SyncStatusStore）
  /// 违反依赖方向——此处本地常量 + 两侧均有超长抛错测试锁定行为（防静默漂移
  /// 的缓解）；若 SyncStatusStore 侧调整须同步本值。
  static const _maxUserIdLength = 128;

  /// 保留期上界（天，10 年）：防 `Duration(days:)` int64 微秒溢出回绕
  ///（r10）——配置值超此钳制。
  static const _maxRetentionDays = 3650;

  /// VACUUM 阈值（行）：物理删除超过此值才全库重建；测试注入小值。
  final int _vacuumThreshold;

  /// 清理涉及的 6 张业务表（含软删列；报告按此键名）。
  static const tableNames = <String>[
    'activityCategoryLinks',
    'trackingRules',
    'timeEntries',
    'actionLogs',
    'activityCategories',
    'activities',
  ];

  /// 读取保留期（天）：`app_metadata[deletedRetentionDays]` 优先（阶段 4 设置
  /// UI 写入），无值/非法/DB 异常回退 [AppConstants.defaultDeletedRetentionDays]。
  /// **读侧最终形态**——阶段 4 加可配置只改写侧。
  /// **上界钳制（r10）**：超大配置值使 `Duration(days: retention)` 在 int64
  /// 微秒下溢出回绕（约 1.07 亿天）——retentionCutoff 变为未来时刻、cutoff
  /// 退化为游标，软删未满保留期的墓碑被提前物理删除（数据丢失）。钳制到
  /// 10 年（3650 天）内。
  Future<int> retentionDays() async {
    try {
      final row =
          await (database.select(database.appMetadata)..where(
                (t) => t.key.equals(AppMetadataKeys.deletedRetentionDays),
              ))
              .getSingleOrNull();
      final parsed = row == null ? null : int.tryParse(row.value);
      if (parsed != null && parsed > 0) {
        return parsed > _maxRetentionDays ? _maxRetentionDays : parsed;
      }
      return AppConstants.defaultDeletedRetentionDays;
    } catch (_) {
      // DB 异常回退默认（清理不可因配置读取失败而崩溃）。
      return AppConstants.defaultDeletedRetentionDays;
    }
  }

  /// 执行一次保留期清理。
  ///
  /// [userId]：**sync 守卫与删除谓词的分区（r6/r9）**——云同步的
  /// `SyncStatusStore.markSuccess` 在登录用户下写入**分区键** `last_sync_at:` +
  /// userId（共享设备各用户游标互不串扰）；传当前登录 userId 时守卫读分区游标
  ///（未同步跳过）、null（未登录/LAN/本地模式）读全局键。**不得用全局键判定
  /// 登录用户**（分区游标读不到会恒判"从未同步"、物理清理静默失效；共享设备
  /// 残留全局键会误判所有用户）。
  ///
  /// **删除谓词按同 userId 分区（r9 修正）**：物理删除仅作用于 `user_id ==
  /// 当前 userId` 的行（null 传参仅清 `user_id IS NULL` 的本地/LAN 行）——
  /// 共享设备上 B 用户的墓碑不得被 A 触发的清理（A 分区游标无法证明 B 已传播）
  /// 误删，否则 B 下次同步时远端行"复活"破坏删除永远赢（保留不变式 #5）。
  ///
  /// **同用户引用不变式（r11 声明）**：分区谓词依赖"子行与父行 `user_id`
  /// 相同"——schema FK 仅约束 id（`references(Activities, #id)` 等）不保证
  /// 同用户。跨用户引用（B 的 entry/link 引用 A 的 activity）会使 A 的清理
  /// 读不到 B 行阻塞父删除、随后删父时 B 行 FK 违约回滚整个事务。**写入层
  /// 须保证同用户引用**（活动归属/分类归属/条目归属的仓储契约——阶段 1 已有
  /// user_id 归属语义）；清理层不做跨用户兜底（属调用方契约，本注释为该
  /// 不变式的显式声明）。
  ///
  /// 流程：读保留期 → 读同步游标（sync 守卫）→ 单事务物理删除（引用表软删行
  /// 清理 + 存活引用者跳过 + 分类悬空处理）→ 事务外阈值驱动 VACUUM →
  /// 写 last_cleanup_at。
  ///
  /// [cursorOverride]（可选）：**同步编排水位**——由 SyncStore 传入"本次同步
  /// 开始时刻"（startedAt）。非 null 时跳过库内游标读取/损坏判定（override
  /// 为可信水位，直接作为同步截止参与 cutoff = min(保留截止, override)）：
  /// 同步期间新建墓碑 deleted_at > startedAt 被保护不误删，已推送墓碑
  /// deleted_at < startedAt 照常清理——解决"引擎游标被同表其他行推过未推送
  /// 墓碑"的真实数据丢失窗口（模块 3c 点 3 修正方案）。null 时沿用库内游标
  ///（手动清理/非同步触发路径）。
  Future<AppResult<CleanupReport>> run({
    String? userId,
    DateTime? cursorOverride,
  }) async {
    // 空白/超长 userId 属调用方编程错误（与 SyncStatusStore._normalizeUserId
    // 契约一致：超长防生成 SyncStatusStore 永远写不出的脏分区键导致恒判
    // "从未同步"）——try 外抛（async 函数内抛错进入返回 Future，由 expectLater
    // 捕获）。**文案拆分（r8）**：空白/超长各自独立（与 SyncStatusStore 口径
    // 一致，防超长触发时误导排查）。
    final normalized = userId?.trim();
    if (userId != null) {
      final trimmed = normalized!; // userId 非 null 时必非空（trim 结果）
      if (trimmed.isEmpty) {
        throw ArgumentError('userId 不能为空字符串，需显式传 null 使用全局游标');
      }
      if (trimmed.length > _maxUserIdLength) {
        throw ArgumentError('userId 过长，无法生成游标分区键');
      }
    }
    try {
      final retention = await retentionDays();
      final now = (_now?.call() ?? DateTime.now()).toUtc();

      // ---- sync 感知守卫（保留不变式 #5 落地）----
      // 游标键：登录用户读分区键 `last_sync_at:<userId>`（SyncStatusStore 写入
      // 形态一致），未登录读全局键。仅当游标存在才允许物理删除——从未同步
      //（该键无值）保守跳过（墓碑未经任何同步通道传播，先物理清除会造成本地
      // 与远端语义缺口）。
      DateTime? lastSyncAt;
      if (cursorOverride != null) {
        // 编排水位优先：跳过库内游标读取与损坏判定（override 为同步开始
        // 时刻，本字段语义即"最近一次可信同步时刻"，无需读库）。
        // **契约防御（r-cursorOverride）**：override 必须在保留期内合理
        // 窗口（不得晚于 now，也不得早于保留期上界）——防调用方误传异常
        // 时间戳导致 cutoff 错位/物理删除范围失控。仅 SyncStore 同步编排
        // 传入（startedAt 水位）。
        final override = cursorOverride.toUtc();
        if (override.isAfter(now)) {
          try {
            stderr.writeln('[cleanup] cursorOverride 晚于当前时刻（$override）——清理跳过');
          } catch (_) {
            // 日志写入失败不影响跳过结论。
          }
          return AppSuccess(
            const CleanupReport(
              deletedByTable: {},
              vacuumed: false,
              skippedDueToFutureCursor: true,
            ),
          );
        }
        lastSyncAt = override;
      } else {
        final cursorKey = normalized == null
            ? AppMetadataKeys.lastSyncAt
            : '${AppMetadataKeys.lastSyncAt}:$normalized';
        final syncRow = await (database.select(
          database.appMetadata,
        )..where((t) => t.key.equals(cursorKey))).getSingleOrNull();
        final parsed = syncRow == null ? null : DateTime.tryParse(syncRow.value);
        // **损坏游标判定（r10/r11 修正）**：tryParse 失败**或无时区偏移**（
        // `isUtc == false`——无偏移字符串被 Dart 按本地时区解析"成功"，负时区
        // 设备上解析时刻比本意 UTC 晚数小时、把 cutoff 推晚，可能把尚未传播
        // 到远端的墓碑提前物理删除）均视为损坏：与"从未同步（键不存在）"混同
        // 会静默跳过且无日志——写 stderr 警告（清理不因日志失败崩溃）。
        // 与 SyncStatusStore.markSuccess/readUtc 的 `isUtc` 校验口径一致。
        if (syncRow != null && (parsed == null || !parsed.isUtc)) {
          try {
            stderr.writeln('[cleanup] 同步游标损坏（$cursorKey）：${syncRow.value}——清理跳过');
          } catch (_) {
            // 日志写入失败不影响跳过结论。
          }
        }
        if (syncRow == null || parsed == null || !parsed.isUtc) {
          return AppSuccess(
            const CleanupReport(
              deletedByTable: {},
              vacuumed: false,
            ).copyWithSkippedNoSync(),
          );
        }
        lastSyncAt = parsed;
      }
      // **cutoff = min(保留期截止, 最近同步时刻)**：deleted_at **严格小于**
      // cutoff（r1/r2 统一）——恰等于游标时刻的墓碑视为同步窗口边缘（是否
      // 已传播不确定），保守留待下一轮；设备停止同步时 cutoff 恒等于游标、
      // 恰等于游标的行也永远满足 `< cutoff` 的上界（不会永久滞留）。
      final retentionCutoff = now.subtract(Duration(days: retention));
      final cutoff = lastSyncAt.isBefore(retentionCutoff)
          ? lastSyncAt
          : retentionCutoff;
      final cutoffStr = utcString(cutoff);

      // ---- 物理删除（单事务；FK 引用先处理、被引用者跳过）----
      // 顺序设计（r2/r4/r5）：
      // 1. 先算 activities 可删集（排除"存活或软删未传播"引用者——父被物理
      //    删除会制造悬空/未传播子行 FK 违约）；
      // 2. 引用表只删**通用 `< cutoff` 软删行**（已传播+超期的子墓碑，含引用
      //    将删父的——父是否真删不影响子自身清理合法性，无需专用分支）；
      // 3. 分类：可删集排除被 link.categoryId 引用（存活/未传播）者，parentId
      //    置空（**含软删子**——父被物理删后子引用悬空，防自引用 FK），再删；
      // 4. 最后删 activities（此时引用它的软删行已随通用清理移除）。
      final deleted = <String, int>{};
      await database.transaction(() async {
        final deletableActivities = await _deletableActivityIds(
          cutoffStr,
          normalized,
        );
        deleted['activityCategoryLinks'] = await _deleteExpiredLinks(
          cutoffStr,
          normalized,
        );
        deleted['trackingRules'] = await _deleteExpiredTrackingRules(
          cutoffStr,
          normalized,
        );
        deleted['timeEntries'] = await _deleteExpiredTimeEntries(
          cutoffStr,
          normalized,
        );
        deleted['actionLogs'] = await _deleteExpiredActionLogs(
          cutoffStr,
          normalized,
        );
        deleted['activityCategories'] = await _deleteExpiredCategories(
          cutoffStr,
          now,
          normalized,
        );
        deleted['activities'] = await _deleteActivitiesByIds(
          deletableActivities,
        );
      });

      // ---- VACUUM（事务外 + 阈值驱动；SQLite 禁止事务内 VACUUM）----
      // **await + 失败隔离（r2）**：customStatement 返回 Future——不 await 会
      // 让 VACUUM 失败成为未处理异步错误（绕过 run() 的 catch、报告声称已
      // 重建而实际未执行）；VACUUM 失败不阻塞清理主流程（已完成的物理删除
      // 不回滚），如实标记未执行。
      var vacuumed = false;
      final total = deleted.values.fold(0, (a, b) => a + b);
      if (total > _vacuumThreshold) {
        try {
          final runner = _vacuumRunner;
          if (runner != null) {
            await runner();
            vacuumed = true; // 注入 runner 成功即视为 VACUUM 完成（测试路径）
          } else {
            await database.customStatement('VACUUM');
            // **checkpoint 结果校验（r10）**：PRAGMA wal_checkpoint(TRUNCATE)
            // 不抛异常而是返回结果行——被其它连接占用时返回 busy（第 1 列
            // 非 0），customStatement 丢弃结果会误报"空间已回收"。用
            // customSelect 读 busy 字段，非 0 视为 checkpoint 未完成（如实
            // 标记未回收；VACUUM 本身已执行，主流程不受影响）。
            final cp =
                (await database
                        .customSelect('PRAGMA wal_checkpoint(TRUNCATE)')
                        .getSingle())
                    .data;
            final busy = cp['busy'] ?? 0;
            vacuumed = busy is int && busy != 0 ? false : true;
            if (busy is int && busy != 0) {
              // **checkpoint busy 告警（r12）**：与损坏游标路径的观测口径一致
              // ——空间回收未生效须可察觉（VACUUM 本身已执行、主流程不受影响）。
              try {
                stderr.writeln('[cleanup] wal_checkpoint busy=$busy——空间未完全回收');
              } catch (_) {
                // 日志写入失败不影响主流程。
              }
            }
          }
        } catch (e) {
          // VACUUM 失败不阻塞清理主流程（已完成的物理删除不回滚）。
          vacuumed = false;
          try {
            stderr.writeln('[cleanup] VACUUM 失败（跳过空间回收）：$e');
          } catch (_) {
            // 日志写入失败不影响主流程。
          }
        }
      }

      // 记录清理时刻（供阶段 3 编排层限频）。
      await database
          .into(database.appMetadata)
          .insert(
            AppMetadataCompanion.insert(
              key: AppMetadataKeys.lastCleanupAt,
              value: utcString(now),
            ),
            mode: InsertMode.insertOrReplace,
          );

      return AppSuccess(
        CleanupReport(deletedByTable: deleted, vacuumed: vacuumed),
      );
    } catch (e) {
      return AppFailure('保留期清理失败：$e');
    }
  }

  // ---------------------------------------------------------------------------
  // 各表物理删除（软删行；deleted_at 为 utcString 存储，字典序 = 时间序；
  // 谓词统一：`deletedAt < cutoff` 严格小于）
  // ---------------------------------------------------------------------------

  /// **可删活动集**：超期软删 − 阻塞引用者（3 张引用表中 `deleted_at IS NULL
  /// OR deleted_at >= cutoff` 且 activity_id ∈ 待删的行——存活或软删未传播的
  /// 引用者在父被物理删除后制造悬空条目/FK 违约，宁可留待下一轮；软删已传播
  /// 子行由各表通用 `< cutoff` 清理先行移除、不阻塞父）。**按 userId 分区
  ///（r9）**：仅处理 `user_id == [userId]` 的行（null 仅本地/LAN 行）。
  Future<List<String>> _deletableActivityIds(
    String cutoff,
    String? userId,
  ) async {
    final expired = await _expiredActivityIds(cutoff, userId);
    if (expired.isEmpty) return const [];
    final blocked = <String>{}
      ..addAll(await _blockingTimeEntryReferents(expired, cutoff, userId))
      ..addAll(await _blockingRuleReferents(expired, cutoff, userId))
      ..addAll(await _blockingLinkReferents(expired, cutoff, userId));
    return expired.where((id) => !blocked.contains(id)).toList();
  }

  /// 阻塞父删除的 time_entries 引用者：`user_id == userId AND activity_id IN
  /// (ids) AND (deleted_at IS NULL OR deleted_at >= cutoff)`（存活或软删未
  /// 传播）。**IN 分块（r3）**：软删大量累积时单次 IN 逼近 SQLite 绑定参数
  /// 上限——按块遍历合并。
  Future<Set<String>> _blockingTimeEntryReferents(
    List<String> parentIds,
    String cutoff,
    String? userId,
  ) async {
    final result = <String>{};
    for (final chunk in _chunks(parentIds)) {
      final rows =
          await (database.selectOnly(database.timeEntries)
                ..addColumns([database.timeEntries.activityId])
                ..where(
                  _userIdMatches(database.timeEntries.userId, userId) &
                      database.timeEntries.activityId.isIn(chunk) &
                      (database.timeEntries.deletedAt.isNull() |
                          database.timeEntries.deletedAt.isBiggerOrEqualValue(
                            cutoff,
                          )),
                ))
              .get();
      result.addAll(rows.map((r) => r.read(database.timeEntries.activityId)!));
    }
    return result;
  }

  /// 阻塞父删除的 tracking_rules 引用者（同 [_blockingTimeEntryReferents]）。
  Future<Set<String>> _blockingRuleReferents(
    List<String> parentIds,
    String cutoff,
    String? userId,
  ) async {
    final result = <String>{};
    for (final chunk in _chunks(parentIds)) {
      final rows =
          await (database.selectOnly(database.trackingRules)
                ..addColumns([database.trackingRules.activityId])
                ..where(
                  _userIdMatches(database.trackingRules.userId, userId) &
                      database.trackingRules.activityId.isIn(chunk) &
                      (database.trackingRules.deletedAt.isNull() |
                          database.trackingRules.deletedAt.isBiggerOrEqualValue(
                            cutoff,
                          )),
                ))
              .get();
      result.addAll(
        rows.map((r) => r.read(database.trackingRules.activityId)!),
      );
    }
    return result;
  }

  /// 阻塞父删除的 links 引用者（同 [_blockingTimeEntryReferents]）。
  Future<Set<String>> _blockingLinkReferents(
    List<String> parentIds,
    String cutoff,
    String? userId,
  ) async {
    final result = <String>{};
    for (final chunk in _chunks(parentIds)) {
      final rows =
          await (database.selectOnly(database.activityCategoryLinks)
                ..addColumns([database.activityCategoryLinks.activityId])
                ..where(
                  _userIdMatches(
                        database.activityCategoryLinks.userId,
                        userId,
                      ) &
                      database.activityCategoryLinks.activityId.isIn(chunk) &
                      (database.activityCategoryLinks.deletedAt.isNull() |
                          database.activityCategoryLinks.deletedAt
                              .isBiggerOrEqualValue(cutoff)),
                ))
              .get();
      result.addAll(
        rows.map((r) => r.read(database.activityCategoryLinks.activityId)!),
      );
    }
    return result;
  }

  /// 删除指定 id 集（分块防 IN 超限）。
  Future<int> _deleteActivitiesByIds(List<String> ids) async {
    if (ids.isEmpty) return 0;
    var count = 0;
    for (final chunk in _chunks(ids)) {
      count += await (database.delete(
        database.activities,
      )..where((t) => t.id.isIn(chunk))).go();
    }
    return count;
  }

  /// id 列表分块（SQLite 绑定参数上限防护；块大小 500 远低于新构建 32766、
  /// 兼容旧构建 999）。
  Iterable<List<String>> _chunks(List<String> ids) sync* {
    const size = 500;
    for (var i = 0; i < ids.length; i += size) {
      yield ids.sublist(i, i + size > ids.length ? ids.length : i + size);
    }
  }

  /// **userId 匹配谓词（r9）**：`equals()` 不接受可空值——null 传参须匹配
  /// `user_id IS NULL`（本地/LAN 行），非 null 匹配 `user_id == userId`。
  Expression<bool> _userIdMatches(
    GeneratedColumn<String> col,
    String? userId,
  ) => userId == null ? col.isNull() : col.equals(userId);

  /// 超期软删 activities 的 id 集（可删判定用；按 userId 分区，r9）。
  Future<List<String>> _expiredActivityIds(
    String cutoff,
    String? userId,
  ) async {
    final rows =
        await (database.selectOnly(database.activities)
              ..addColumns([database.activities.id])
              ..where(
                _userIdMatches(database.activities.userId, userId) &
                    database.activities.deletedAt.isNotNull() &
                    database.activities.deletedAt.isSmallerThanValue(cutoff),
              ))
            .get();
    return rows.map((r) => r.read(database.activities.id)!).toList();
  }

  /// timeEntries：只删通用 `< cutoff` 软删行（含引用将删父的——父是否真删
  /// 不影响子自身清理合法性；未传播子行保留、阻塞父删除）。按 userId 分区。
  Future<int> _deleteExpiredTimeEntries(String cutoff, String? userId) async {
    final query = database.delete(database.timeEntries)
      ..where(
        (t) =>
            _userIdMatches(t.userId, userId) &
            t.deletedAt.isNotNull() &
            t.deletedAt.isSmallerThanValue(cutoff),
      );
    return query.go();
  }

  /// trackingRules：同上。
  Future<int> _deleteExpiredTrackingRules(String cutoff, String? userId) async {
    final query = database.delete(database.trackingRules)
      ..where(
        (t) =>
            _userIdMatches(t.userId, userId) &
            t.deletedAt.isNotNull() &
            t.deletedAt.isSmallerThanValue(cutoff),
      );
    return query.go();
  }

  /// links：同上（activityId 与 categoryId 两方向引用将删父的软删已传播行
  /// 均被通用 `< cutoff` 覆盖）。
  Future<int> _deleteExpiredLinks(String cutoff, String? userId) async {
    final query = database.delete(database.activityCategoryLinks)
      ..where(
        (t) =>
            _userIdMatches(t.userId, userId) &
            t.deletedAt.isNotNull() &
            t.deletedAt.isSmallerThanValue(cutoff),
      );
    return query.go();
  }

  /// 分类：可删 = 超期 − 被 link.categoryId 引用（存活或软删未传播）者；
  /// 引用将删分类的行（**含软删**——父被物理删后引用悬空，防自引用 FK）
  /// parent_id 置 NULL；再删可删分类。分块防 IN 超限。按 userId 分区（r9）。
  Future<int> _deleteExpiredCategories(
    String cutoff,
    DateTime now,
    String? userId,
  ) async {
    final expiredRows =
        await (database.selectOnly(database.activityCategories)
              ..addColumns([database.activityCategories.id])
              ..where(
                _userIdMatches(database.activityCategories.userId, userId) &
                    database.activityCategories.deletedAt.isNotNull() &
                    database.activityCategories.deletedAt.isSmallerThanValue(
                      cutoff,
                    ),
              ))
            .get();
    final expired = expiredRows
        .map((r) => r.read(database.activityCategories.id)!)
        .toList();
    if (expired.isEmpty) return 0;
    // 阻塞分类删除的 link 引用者（categoryId 方向，存活或软删未传播；同
    // userId 分区——共享设备上他用户 link 不阻塞本用户分类）。
    final blocked = <String>{};
    for (final chunk in _chunks(expired)) {
      final rows =
          await (database.selectOnly(database.activityCategoryLinks)
                ..addColumns([database.activityCategoryLinks.categoryId])
                ..where(
                  _userIdMatches(
                        database.activityCategoryLinks.userId,
                        userId,
                      ) &
                      database.activityCategoryLinks.categoryId.isIn(chunk) &
                      (database.activityCategoryLinks.deletedAt.isNull() |
                          database.activityCategoryLinks.deletedAt
                              .isBiggerOrEqualValue(cutoff)),
                ))
              .get();
      blocked.addAll(
        rows.map((r) => r.read(database.activityCategoryLinks.categoryId)!),
      );
    }
    final deletable = expired.where((id) => !blocked.contains(id)).toList();
    if (deletable.isEmpty) return 0;
    // parentId 置空：引用将删分类的所有行（含软删——置空无害且防 FK）。
    // **拆两个 UPDATE（r12）**：软删未传播子（deleted_at >= cutoff）本轮不删、
    // 留待下一轮——刷新其 updatedAt 会伪造同步增量（墓碑以 update 形式先于
    // delete 传播/已传播墓碑重复推送，增加远端合并歧义）。仅存活子刷新
    // updatedAt（清理造成真实变更），墓碑子只置 parentId 不动 updatedAt。
    for (final chunk in _chunks(deletable)) {
      // 1) 存活子（deletedAt IS NULL）：置空 + 刷新 updatedAt。
      await (database.update(
        database.activityCategories,
      )..where((t) => t.parentId.isIn(chunk) & t.deletedAt.isNull())).write(
        ActivityCategoriesCompanion(
          parentId: const Value(null),
          updatedAt: Value(utcString(now)),
        ),
      );
      // 2) 软删子（deletedAt IS NOT NULL）：仅置空，不动 updatedAt。
      await (database.update(database.activityCategories)
            ..where((t) => t.parentId.isIn(chunk) & t.deletedAt.isNotNull()))
          .write(ActivityCategoriesCompanion(parentId: const Value(null)));
    }
    var count = 0;
    for (final chunk in _chunks(deletable)) {
      count += await (database.delete(
        database.activityCategories,
      )..where((t) => t.id.isIn(chunk))).go();
    }
    return count;
  }

  /// actionLogs：无 FK references（activityId/entryId 为 nullable 无外键），
  /// 直接删超期软删行。按 userId 分区（r9）。
  Future<int> _deleteExpiredActionLogs(String cutoff, String? userId) async {
    final query = database.delete(database.actionLogs)
      ..where(
        (t) =>
            _userIdMatches(t.userId, userId) &
            t.deletedAt.isNotNull() &
            t.deletedAt.isSmallerThanValue(cutoff),
      );
    return query.go();
  }
}

extension on CleanupReport {
  /// 从未同步跳过场景的构造（skippedDueToNoSync=true）。
  CleanupReport copyWithSkippedNoSync() => CleanupReport(
    deletedByTable: deletedByTable,
    vacuumed: vacuumed,
    skippedDueToNoSync: true,
  );
}
