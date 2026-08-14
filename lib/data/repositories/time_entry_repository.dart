import 'package:drift/drift.dart';
import 'package:uuid/uuid.dart';

import '../../constants/app_constants.dart';
import '../../utils/date_time_ext.dart';
import '../../utils/result.dart';
import '../../viewmodels/action_log.dart';
import '../../viewmodels/time_entry.dart';
import '../database/app_database.dart';
import 'activity_repository.dart';
import 'repository_mappings.dart';
import 'settings_repository.dart';

/// 时间条目仓储（阶段 1 核心）：跨日拆分、重叠裁剪、跨日滚转、
/// 相邻未分配合并、switch/stop/split/merge/delete/manual、查询、LWW。
///
/// 语义迁移自老项目（功能等价、非逐行照抄）：
/// - 存储时已结束条目按本地日切段（跨天拆分），运行中/已删除单行
/// - 重叠裁剪 = 区间减法（替换条目把被覆盖的旧条目切开/软删）
/// - 运行中条目跨日滚转（startAt 早于今天 → 按天切段 + 保留运行段）
/// - 相邻未分配合并（startAt <= endAt 连续判定，note 换行去重）
class TimeEntryRepository with RepositoryMappings {
  TimeEntryRepository({
    required this.database,
    required ActivityRepository activityRepository,
    required SettingsRepository settingsRepository,
    Uuid? uuid,
  })  : _activityRepo = activityRepository,
        _settingsRepo = settingsRepository,
        _uuid = uuid ?? const Uuid();

  final AppDatabase database;
  final ActivityRepository _activityRepo;
  final SettingsRepository _settingsRepo;
  final Uuid _uuid;

  DateTime _now() => DateTime.now();

  // ---------------------------------------------------------------------------
  // 查询
  // ---------------------------------------------------------------------------

  /// 当前运行中条目（end_at 为空且未删；startAt 最晚者优先）。
  Future<TimeEntry?> runningEntry() async {
    final query = database.select(database.timeEntries)
      ..where((t) => t.endAt.isNull() & t.deletedAt.isNull())
      ..orderBy([(t) => OrderingTerm.desc(t.startAt)])
      ..limit(1);
    final row = await query.getSingleOrNull();
    return row == null ? null : timeEntryFromRow(row);
  }

  /// 某日全部条目（跨日条目按窗口重叠查询）。
  Future<List<TimeEntry>> entriesForDay(DateTime day) async {
    return entriesForRange(day.startOfDay, day.startOfDay.add(const Duration(days: 1)));
  }

  /// 时间窗内条目（start < end 且 (end 为空或 end > start)）。
  Future<List<TimeEntry>> entriesForRange(DateTime start, DateTime end) async {
    if (!start.isBefore(end)) return const [];
    final endStr = utcString(end);
    final startStr = utcString(start);
    final query = database.select(database.timeEntries)
      ..where((t) =>
          t.deletedAt.isNull() &
          t.startAt.isSmallerThanValue(endStr) &
          (t.endAt.isNull() | t.endAt.isBiggerThanValue(startStr)))
      ..orderBy([(t) => OrderingTerm.asc(t.startAt)]);
    final rows = await query.get();
    return rows.map(timeEntryFromRow).toList();
  }

  /// 按 id 查询。
  Future<TimeEntry?> entryById(String entryId) async {
    final query = database.select(database.timeEntries)
      ..where((t) => t.id.equals(entryId));
    final row = await query.getSingleOrNull();
    return row == null ? null : timeEntryFromRow(row);
  }

  /// 按 id 查询（**含软删行**）：undo 恢复快照采集用——操作后软删的旧行
  /// 需读取其软删态作为 after 快照。
  Future<TimeEntry?> entryByIdIncludingDeleted(String entryId) async {
    try {
      final query = database.select(database.timeEntries)
        ..where((t) => t.id.equals(entryId));
      final row = await query.getSingleOrNull();
      return row == null ? null : timeEntryFromRow(row);
    } catch (_) {
      return null;
    }
  }

  /// 全量条目（含已删除，bundle 导出用；updated_at 升序）。
  Future<List<TimeEntry>> allEntries() async {
    final query = database.select(database.timeEntries)
      ..orderBy([(t) => OrderingTerm.asc(t.updatedAt)]);
    final rows = await query.get();
    return rows.map(timeEntryFromRow).toList();
  }

  /// 增量查询（云同步拉取用）：`updated_at >= since`（含已删除行）。
  Future<List<TimeEntry>> entriesSince(DateTime since) async {
    final query = database.select(database.timeEntries)
      ..where((t) => t.updatedAt.isBiggerOrEqualValue(utcString(since)))
      ..orderBy([(t) => OrderingTerm.asc(t.updatedAt)]);
    final rows = await query.get();
    return rows.map(timeEntryFromRow).toList();
  }

  // ---------------------------------------------------------------------------
  // 命令：switch / stop
  // ---------------------------------------------------------------------------

  /// 切换到指定活动：结束当前运行条目（早于 now 的落 endAt，未来条目标记删除）、
  /// 新建运行条目；切到未分配时合并相邻未分配条目。
  Future<AppResult<TimeEntry>> switchToActivity(
    String activityId, {
    DateTime? at,
    bool isAuto = false,
  }) async {
    try {
      final now = at ?? _now();
      await rolloverRunningEntriesIfNeeded(at: now);
      final deviceId = await _ensureDeviceId();
      final targetIsUnassigned = await _activityRepo.activityIdIsUnassigned(activityId);
      late TimeEntry next;

      await database.transaction(() async {
        final running = await _runningRow(database);
        if (targetIsUnassigned && running != null && running.activityId == activityId) {
          next = timeEntryFromRow(running);
          return;
        }

        if (running != null) {
          final model = timeEntryFromRow(running);
          // startAt == now：零时长运行条目（同一时刻连续 switch）直接软删，
          // 不误判为"未来条目"也不生成零长结束段。
          if (model.startAt.isAtSameMomentAs(now)) {
            final removed = model.copyWith(deletedAt: now, updatedAt: now);
            await _saveEntryRows(database, removed);
          } else if (model.startAt.isBefore(now)) {
            final ended = model.copyWith(endAt: now, updatedAt: now);
            await _saveEntryRows(database, ended);
          } else {
            // 未来条目（startAt >= now）：直接软删。
            final removed = model.copyWith(deletedAt: now, updatedAt: now);
            await _saveEntryRows(database, removed);
          }
          await _activityRepo.softDeleteOneOffActivityIfNeeded(
            running.activityId,
            updatedAt: now,
          );
        }

        final snapshot = await _activityRepo.entryWithActivitySnapshot(
          TimeEntry(
            id: _uuid.v4(),
            activityId: activityId,
            startAt: now,
            deviceId: deviceId,
            updatedAt: now,
            isAuto: isAuto,
          ),
          executor: database,
        );
        await database.into(database.timeEntries).insert(
              timeEntryToCompanion(snapshot),
            );
        next = snapshot;
        await _insertActionLog(
          actionType: ActionType.switch_,
          activityId: activityId,
          entryId: next.id,
          occurredAt: now,
          message: '切换事项',
          executor: database,
        );
      });

      if (targetIsUnassigned) {
        await mergeAdjacentUnassignedEntries(activityId, updatedAt: now);
        return AppSuccess(await runningEntry() ?? next);
      }
      return AppSuccess(next);
    } catch (e) {
      return AppFailure('切换活动失败：$e');
    }
  }

  /// 停止当前活动：结束运行条目并切到未分配（无运行条目则直接开始未分配）。
  Future<AppResult<TimeEntry>> stopRunning({DateTime? at}) async {
    try {
      final now = at ?? _now();
      await rolloverRunningEntriesIfNeeded(at: now);
      final unassigned = await _activityRepo.ensureUnassignedActivity();
      final running = await runningEntry();
      if (running == null) {
        return switchToActivity(unassigned.id, at: now);
      }
      if (running.activityId == unassigned.id) {
        await mergeAdjacentUnassignedEntries(unassigned.id, updatedAt: now);
        // 合并可能把更早的未分配条目并入运行段（运行行被软删）——重读最新运行条目。
        return AppSuccess(await runningEntry() ?? running);
      }
      if (running.startAt.isAfter(now)) {
        // 未来条目：软删后开始未分配。
        final removed = running.copyWith(deletedAt: now, updatedAt: now);
        await _saveEntry(removed);
        await _activityRepo.softDeleteOneOffActivityIfNeeded(
          running.activityId,
          updatedAt: now,
        );
        return switchToActivity(unassigned.id, at: now);
      }
      final ended = running.copyWith(endAt: now, updatedAt: now);
      await _saveEntry(ended);
      await _activityRepo.softDeleteOneOffActivityIfNeeded(
        running.activityId,
        updatedAt: now,
      );
      await _insertActionLog(
        actionType: ActionType.stop,
        activityId: running.activityId,
        entryId: running.id,
        occurredAt: now,
        message: '停止事项',
      );
      return switchToActivity(unassigned.id, at: now);
    } catch (e) {
      return AppFailure('停止活动失败：$e');
    }
  }

  // ---------------------------------------------------------------------------
  // 命令：add / split / merge / delete
  // ---------------------------------------------------------------------------

  /// 补记时间段（重叠时自动裁剪被覆盖条目）。
  Future<AppResult<TimeEntry>> createManualEntry({
    required String activityId,
    required DateTime startAt,
    required DateTime endAt,
    required String note,
    bool isAuto = false,
  }) async {
    try {
      if (!startAt.isBefore(endAt)) {
        return const AppFailure('补记时间段非法：start_at 必须早于 end_at');
      }
      final now = _now();
      final deviceId = await _ensureDeviceId();
      // _saveEntry 内部统一补快照（此处不重复调用避免冗余 DB 往返）。
      final saved = await _saveEntry(
        TimeEntry(
          id: _uuid.v4(),
          activityId: activityId,
          startAt: startAt,
          endAt: endAt,
          note: note,
          deviceId: deviceId,
          updatedAt: now,
          isAuto: isAuto,
        ),
        cutOverlaps: true,
      );
      await _insertActionLog(
        actionType: ActionType.manual,
        activityId: activityId,
        entryId: saved.first.id,
        occurredAt: now,
        message: '补记时间段',
      );
      return AppSuccess(saved.first);
    } catch (e) {
      return AppFailure('补记时间段失败：$e');
    }
  }

  /// 切割时间段（splitAt 须严格在 start/end 之间；不裁切重叠）。
  Future<AppResult<List<TimeEntry>>> splitEntry({
    required String entryId,
    required DateTime splitAt,
  }) async {
    try {
      final current = await entryById(entryId);
      if (current == null || current.isDeleted || current.isRunning) {
        return const AppFailure('条目不存在、已删除或运行中，无法切割');
      }
      final endAt = current.endAt!;
      if (!current.startAt.isBefore(splitAt) || !splitAt.isBefore(endAt)) {
        return const AppFailure('切割时间必须严格位于条目起止之间');
      }
      final now = _now();
      final saved = <TimeEntry>[];
      await database.transaction(() async {
        final first = await _activityRepo.entryWithActivitySnapshot(
          current.copyWith(endAt: splitAt, updatedAt: now),
          executor: database,
        );
        final second = await _activityRepo.entryWithActivitySnapshot(
          current.copyWith(
            id: _uuid.v4(),
            startAt: splitAt,
            endAt: endAt,
            updatedAt: now,
          ),
          executor: database,
        );
        saved.addAll(await _saveEntryRows(database, first));
        saved.addAll(await _saveEntryRows(database, second));
      });
      await _insertActionLog(
        actionType: ActionType.split,
        activityId: current.activityId,
        entryId: current.id,
        occurredAt: now,
        message: '切割时间段',
      );
      return AppSuccess(saved);
    } catch (e) {
      return AppFailure('切割时间段失败：$e');
    }
  }

  /// 与相邻条目合并（合并后软删相邻，取并集时间窗与合并 note）。
  Future<AppResult<TimeEntry?>> mergeEntryWithNeighbor({
    required String entryId,
    required bool mergePrevious,
  }) async {
    try {
      final neighborResult = await _findMergeNeighbor(
        entryId: entryId,
        mergePrevious: mergePrevious,
      );
      if (neighborResult case AppFailure<TimeEntry?> failure) {
        return AppFailure(failure.message);
      }
      final neighbor = neighborResult.requireValue();
      if (neighbor == null) {
        return const AppSuccess(null); // 无合并对象
      }
      final current = (await entryById(entryId))!;

      final now = _now();
      final merged = current.copyWith(
        startAt: current.startAt.isBefore(neighbor.startAt)
            ? current.startAt
            : neighbor.startAt,
        endAt: current.endAt!.isAfter(neighbor.endAt!)
            ? current.endAt
            : neighbor.endAt,
        note: _mergedNotes(current.note, neighbor.note),
        updatedAt: now,
      );
      final removed = neighbor.copyWith(deletedAt: now, updatedAt: now);

      final saved = <TimeEntry>[];
      await database.transaction(() async {
        saved.addAll(await _saveEntryRows(database, merged));
        await _saveEntryRows(database, removed);
      });
      await _insertActionLog(
        actionType: ActionType.merge,
        activityId: merged.activityId,
        entryId: merged.id,
        occurredAt: now,
        message: mergePrevious ? '合并左侧' : '合并右侧',
      );
      return AppSuccess(saved.first);
    } catch (e) {
      return AppFailure('合并条目失败：$e');
    }
  }

  /// 查询 merge 的实际合并对象（与 [mergeEntryWithNeighbor] 内部判定一致）：
  /// TimerStore 采集 undo 恢复快照用。判定失败/无对象返回 null（AppSuccess）。
  Future<AppResult<TimeEntry?>> neighborForMerge({
    required String entryId,
    required bool mergePrevious,
  }) async {
    try {
      return await _findMergeNeighbor(
        entryId: entryId,
        mergePrevious: mergePrevious,
      );
    } catch (e) {
      return AppFailure('查询合并邻居失败：$e');
    }
  }

  /// merge 邻居判定（与 merge 主体共用，消除逻辑漂移）：
  /// 同日相邻 + 同活动 + 非零长 + 间隔 <= 阈值 → 返回邻居；否则 null。
  Future<AppResult<TimeEntry?>> _findMergeNeighbor({
    required String entryId,
    required bool mergePrevious,
  }) async {
    final current = await entryById(entryId);
    if (current == null || current.isDeleted || current.isRunning) {
      return const AppFailure('条目不存在、已删除或运行中，无法合并');
    }
    final thresholdMinutes = await _settingsRepo.mergeNeighborThresholdMinutes();
    final dayEntries = await entriesForDay(current.startAt);
    final ordered = dayEntries
        .where((e) => !e.isDeleted && !e.isRunning)
        .toList()
      ..sort((a, b) => a.startAt.compareTo(b.startAt));
    final index = ordered.indexWhere((e) => e.id == current.id);
    if (index == -1) return const AppFailure('条目不在当日列表中');

    final neighborIndex = mergePrevious ? index - 1 : index + 1;
    if (neighborIndex < 0 || neighborIndex >= ordered.length) {
      return const AppSuccess(null);
    }
    final neighbor = ordered[neighborIndex];
    // 仅允许合并同一活动的相邻条目——跨活动合并会把邻居时段错误归入当前活动。
    if (neighbor.activityId != current.activityId) {
      return const AppSuccess(null);
    }
    final neighborEnd = neighbor.endAt;
    if (neighborEnd == null || !neighborEnd.isAfter(neighbor.startAt)) {
      return const AppSuccess(null);
    }

    // 阈值校验：间隔超过阈值不合并（老项目 mergeConfirmationRequired 语义——
    // 此处先按可配置阈值直接拒绝，UI 确认交互留阶段 4）。
    final gap = neighbor.startAt.isBefore(current.startAt)
        ? current.startAt.difference(neighborEnd)
        : neighbor.startAt.difference(current.endAt!);
    if (gap.inMinutes > thresholdMinutes) {
      return AppFailure(
        '与相邻条目间隔 ${gap.inMinutes} 分钟，超过合并阈值 $thresholdMinutes 分钟',
      );
    }
    return AppSuccess(neighbor);
  }

  /// 软删时间条目。
  Future<AppResult<void>> deleteEntry(TimeEntry entry) async {
    try {
      final now = _now();
      await _saveEntry(entry.copyWith(deletedAt: now, updatedAt: now));
      await _insertActionLog(
        actionType: ActionType.delete,
        activityId: entry.activityId,
        entryId: entry.id,
        occurredAt: now,
        message: '删除时间段',
      );
      return const AppSuccess(null);
    } catch (e) {
      return AppFailure('删除时间段失败：$e');
    }
  }

  /// undo/redo 恢复写库（**快照权威，非 LWW**——恢复的是操作时快照状态，
  /// 不做远端更新比较；配合 [UndoStore] 的内容状态校验，本地 undo 语义）。
  ///
  /// - [entry]：恢复目标状态（undo 时 = 操作前快照；redo 时 = 操作后快照）。
  ///   saved 前 updatedAt 推进到 [at]（默认 now）——恢复作为一次新修改参与
  ///   同步传播（LWW/删除传播），保留原 id（跨日条目沿用既有段切分归一化）；
  /// - [softDelete]：true 时改为软删该条目（deletedAt = 推进后的 updatedAt）。
  /// 单事务原子；失败返回可读原因（调用方 [UndoStore] 栈不动、可重试）。
  Future<AppResult<void>> restoreEntryForUndo(
    TimeEntry entry, {
    required bool softDelete,
    DateTime? at,
  }) async {
    try {
      final now = at ?? _now();
      await database.transaction(() async {
        final target = softDelete
            ? entry.copyWith(deletedAt: now, updatedAt: now)
            : entry.copyWith(updatedAt: now);
        await _saveEntryRows(database, target);
      });
      return const AppSuccess(null);
    } catch (e) {
      return AppFailure('恢复条目失败：$e');
    }
  }

  /// undo/redo 批量恢复写库（**单事务**）：整条 undo 记录涉及的所有条目
  /// 在同一个 drift transaction 内恢复/软删——满足 3a 事务化 applier 契约
  /// （同记录组合操作原子性，防 undo 半恢复）。
  ///
  /// [ops] 每项：`entry` 为恢复目标状态（softDelete=false 时写入该状态并推进
  /// updatedAt；true 时软删该行——entry 提供 id 与快照）；更新推进时刻统一取
  /// 单个 [at]（默认 now）。
  Future<AppResult<void>> restoreEntriesForUndo(
    List<({TimeEntry entry, bool softDelete})> ops, {
    DateTime? at,
  }) async {
    try {
      final now = at ?? _now();
      await database.transaction(() async {
        for (final op in ops) {
          final target = op.softDelete
              ? op.entry.copyWith(deletedAt: now, updatedAt: now)
              : op.entry.copyWith(updatedAt: now);
          await _saveEntryRows(database, target);
        }
      });
      return const AppSuccess(null);
    } catch (e) {
      return AppFailure('恢复条目失败：$e');
    }
  }

  // ---------------------------------------------------------------------------
  // 规范化：跨日滚转 / 相邻未分配合并 / 跨日拆分
  // ---------------------------------------------------------------------------

  /// 运行中条目跨日滚转：startAt 早于今日 0 点的运行条目，按天切段并保留运行段。
  Future<void> rolloverRunningEntriesIfNeeded({DateTime? at}) async {
    final now = at ?? _now();
    final todayStart = now.startOfDay;
    final running = await runningEntry();
    if (running == null || !running.startAt.isBefore(todayStart)) return;

    await database.transaction(() async {
      // 运行段保留原 id（LWW 同步按 id 匹配，改 id 会与他端运行段并存产生双运行）；
      // 历史切段全部使用新 id（原 id 已由运行段占用）。
      var cursor = running.startAt;
      while (cursor.startOfDay.isBefore(todayStart)) {
        final segmentEnd = DateTime(cursor.year, cursor.month, cursor.day + 1); // 下一本地零点（DST 安全）
        if (cursor.isBefore(segmentEnd)) {
          final segment = running.copyWith(
            // 历史切段用确定性派生 id（重复滚转可覆盖同段）。
            id: _derivedSegmentId(running.id, cursor),
            startAt: cursor,
            endAt: segmentEnd,
            updatedAt: now,
          );
          await _saveEntryRows(database, segment);
        }
        cursor = segmentEnd;
      }
      final nextRunning = running.copyWith(
        id: running.id,
        startAt: cursor,
        endAt: null,
        clearEndAt: true,
        updatedAt: now,
      );
      await _saveEntryRows(database, nextRunning);
    });
  }

  /// 合并后归一化：LAN/文件 merge 后恢复运行条目唯一性。
  ///
  /// 场景：不同设备各有运行中条目（LWW 合并后可能并存多个运行段）——
  /// 保留 startAt 最晚者为运行条目，其余运行段按时间切段（早于保留者→落 endAt，
  /// 晚于→软删）。老项目 normalizeRunningEntriesAfterMerge 语义。
  Future<void> normalizeRunningEntriesAfterMerge() async {
    final query = database.select(database.timeEntries)
      ..where((t) => t.endAt.isNull() & t.deletedAt.isNull())
      ..orderBy([(t) => OrderingTerm.desc(t.startAt)]);
    final runningRows = await query.get();
    if (runningRows.length <= 1) return;

    final keep = timeEntryFromRow(runningRows.first);
    final now = _now();
    await database.transaction(() async {
      for (final row in runningRows.skip(1)) {
        final entry = timeEntryFromRow(row);
        final normalized = entry.startAt.isBefore(keep.startAt)
            ? entry.copyWith(endAt: keep.startAt, updatedAt: now)
            : entry.copyWith(deletedAt: now, updatedAt: now);
        await _saveEntryRows(database, normalized);
      }
    });
  }

  /// 合并后归一化：已结束跨日条目按本地日重新切段（合并可能带入跨日未切段行）。
  Future<void> normalizeStoredCrossDayEntries() async {
    final query = database.select(database.timeEntries)
      ..where((t) => t.deletedAt.isNull() & t.endAt.isNotNull());
    final rows = await query.get();
    for (final row in rows) {
      final entry = timeEntryFromRow(row);
      if (_splitClosedEntryByLocalDay(entry, entry.updatedAt).length <= 1) {
        continue;
      }
      await _saveEntry(entry);
    }
  }

  /// 合并后归一化：缺快照的条目回填活动名/色（老数据/文件互通缺字段时）。
  Future<void> backfillMissingEntrySnapshots() async {
    final query = database.select(database.timeEntries)
      ..where((t) => t.activityName.equals('') | t.activityColor.isNull());
    final rows = await query.get();
    for (final row in rows) {
      final entry = timeEntryFromRow(row);
      final withSnapshot =
          await _activityRepo.entryWithActivitySnapshot(entry, executor: database);
      if (withSnapshot.activityNameSnapshot == entry.activityNameSnapshot &&
          withSnapshot.activityColorSnapshot == entry.activityColorSnapshot) {
        continue;
      }
      await _saveEntry(withSnapshot);
    }
  }

  /// 相邻未分配条目合并：startAt <= 前一条 endAt（连续）即合并，
  /// note 换行去重；合并后软删被并入者。
  Future<void> mergeAdjacentUnassignedEntries(
    String activityId, {
    DateTime? updatedAt,
  }) async {
    final now = updatedAt ?? _now();
    final query = database.select(database.timeEntries)
      ..where((t) => t.activityId.equals(activityId) & t.deletedAt.isNull())
      ..orderBy([
        (t) => OrderingTerm.asc(t.startAt),
        (t) => OrderingTerm.asc(t.endAt),
      ]);
    final rows = await query.get();
    if (rows.length <= 1) return;

    final entries = rows.map(timeEntryFromRow).toList();
    var survivor = entries.first;
    var survivorChanged = false;
    final updates = <TimeEntry>[];
    final removed = <TimeEntry>[];

    for (final entry in entries.skip(1)) {
      if (_continuous(survivor, entry)) {
        survivor = _merged(survivor, entry, now);
        survivorChanged = true;
        removed.add(entry.copyWith(deletedAt: now, updatedAt: now));
      } else {
        if (survivorChanged) updates.add(survivor);
        survivor = entry;
        survivorChanged = false;
      }
    }
    if (survivorChanged) updates.add(survivor);

    await database.transaction(() async {
      for (final entry in updates) {
        await _saveEntryRows(database, entry);
      }
      for (final entry in removed) {
        await _saveEntryRows(database, entry);
      }
    });
  }

  /// 两条是否连续（前一条 endAt == null 或后一条 startAt <= 前一条 endAt）。
  bool _continuous(TimeEntry first, TimeEntry second) {
    final firstEnd = first.endAt;
    return firstEnd == null || !second.startAt.isAfter(firstEnd);
  }

  /// 合并（取并集时间窗 + note 换行去重 + 清除被并入者的 endAt 若合并到运行段）。
  TimeEntry _merged(TimeEntry first, TimeEntry second, DateTime updatedAt) {
    final endAt = first.endAt == null || second.endAt == null
        ? null
        : (first.endAt!.isAfter(second.endAt!) ? first.endAt : second.endAt);
    return first.copyWith(
      endAt: endAt,
      clearEndAt: endAt == null,
      note: _mergedNotes(first.note, second.note),
      updatedAt: updatedAt,
    );
  }

  /// note 合并：非空去重，换行拼接。
  String _mergedNotes(String first, String second) {
    final notes = <String>{};
    for (final note in [first.trim(), second.trim()]) {
      if (note.isNotEmpty) notes.add(note);
    }
    return notes.join('\n');
  }

  // ---------------------------------------------------------------------------
  // 存储核心：跨日拆分 / 重叠裁剪 / 保存
  // ---------------------------------------------------------------------------

  /// 存储形态：已删除/运行中单行；已结束按本地日切段（跨日拆分）。
  List<TimeEntry> _entryRowsForStorage(TimeEntry entry) {
    return entry.isDeleted || entry.isRunning
        ? [entry]
        : _splitClosedEntryByLocalDay(entry, entry.updatedAt);
  }

  /// 确定性派生段 id：父条目 id + 段起点（UTC ISO8601）的 uuid v5。
  ///
  /// 保证同一逻辑条目在重复保存/LWW 覆盖时，同一日段命中同一 id（覆盖而非
  /// 叠加），避免随机 uuid 造成的"旧段残留 + 新段并存"重叠重复数据。
  String _derivedSegmentId(String parentId, DateTime segmentStart) {
    return _uuid.v5(
      Namespace.url.value,
      'timetrack:entry-segment:$parentId:${utcString(segmentStart)}',
    );
  }

  /// 已结束条目按本地日切段（保留原 id 给首段，其余段确定性派生）。
  List<TimeEntry> _splitClosedEntryByLocalDay(
    TimeEntry entry,
    DateTime updatedAt,
  ) {
    final endAt = entry.endAt;
    if (endAt == null || !entry.startAt.isBefore(endAt)) return [entry];
    final segments = <TimeEntry>[];
    var cursor = entry.startAt;
    var first = true;
    while (cursor.isBefore(endAt)) {
      final dayEnd = DateTime(cursor.year, cursor.month, cursor.day + 1); // 下一本地零点（DST 安全）
      final segmentEnd = endAt.isBefore(dayEnd) ? endAt : dayEnd;
      if (cursor.isBefore(segmentEnd)) {
        segments.add(
          entry.copyWith(
            // 首段保留原 id；后续段用确定性派生（父 id + 段起点）——重复 LWW
            // 覆盖可命中同段替换，避免随机 id 造成旧段残留/重叠重复段。
            id: first ? entry.id : _derivedSegmentId(entry.id, cursor),
            startAt: cursor,
            endAt: segmentEnd,
            updatedAt: updatedAt,
          ),
        );
      }
      cursor = segmentEnd;
      first = false;
    }
    return segments.isEmpty ? [entry] : segments;
  }

  /// 保存条目（可选重叠裁剪）——统一写路径。
  Future<List<TimeEntry>> _saveEntry(
    TimeEntry entry, {
    bool cutOverlaps = false,
  }) async {
    final saved = <TimeEntry>[];
    await database.transaction(() async {
      final normalized = await _activityRepo.entryWithActivitySnapshot(
        entry,
        executor: database,
      );
      final rows = _entryRowsForStorage(normalized);
      if (cutOverlaps) {
        await _cutOverlappingEntries(database, rows, normalized.updatedAt);
      }
      for (final row in rows) {
        await database.into(database.timeEntries).insert(
              timeEntryToCompanion(row),
              mode: InsertMode.insertOrReplace,
            );
        saved.add(row);
      }
    });
    return saved;
  }

  /// 合并保存（bundle merge 用）：补快照 + 跨日拆分 + 确定性段 id，不裁重叠
  ///（合并语义是行级 LWW 整行替换，非本地补记的裁剪语义）。无独立事务——
  /// 由调用方（SyncBundleRepository.mergeBundle）在统一事务内执行。
  ///
  /// - 每个派生段（含首段）**独立 LWW 判定**：仅当本地同名段缺失或更旧才替换，
  ///   防旧包覆盖本地更新的段（父行 LWW 门控不覆盖派生段）；
  /// - 活动缺失/已删时回退到未分配活动（外键约束在 foreign_keys=ON 下会因
  ///   悬挂引用使整包合并失败——回退避免单条脏数据阻塞合并）。
  Future<void> saveMergedEntry(TimeEntry entry) async {
    // 直接按活动行存在性判定（快照字段不可靠：远端条目几乎都带快照，
    // "快照为空"既不等于活动缺失，也不该触发回退）。
    // 已取到 activity，直接用它填充快照（避免 entryWithActivitySnapshot 二次查询）。
    final activity = await _activityRepo.activityById(
      entry.activityId,
      executor: database,
    );
    final TimeEntry normalized;
    if (activity == null || activity.isDeleted) {
      // 活动缺失/已删：回退未分配活动（防 FK 悬挂使整包合并失败）。
      final unassigned = await _activityRepo.ensureUnassignedActivity();
      normalized = entry.copyWith(
        activityId: unassigned.id,
        activityNameSnapshot: unassigned.name,
        activityColorSnapshot: unassigned.color,
      );
    } else {
      normalized = entry.copyWith(
        activityNameSnapshot: activity.name,
        activityColorSnapshot: activity.color,
      );
    }
    final rows = _entryRowsForStorage(normalized);
    for (final row in rows) {
      final query = database.select(database.timeEntries)
        ..where((t) => t.id.equals(row.id));
      final localRow = await query.getSingleOrNull();
      final localNewer = localRow != null &&
          readUtc(localRow.updatedAt).isAfter(row.updatedAt);
      if (localNewer) continue;
      await database.into(database.timeEntries).insert(
            timeEntryToCompanion(row),
            mode: InsertMode.insertOrReplace,
          );
    }
  }

  /// 事务内保存（供 switch/split/merge 等组合操作复用）。
  Future<List<TimeEntry>> _saveEntryRows(
    AppDatabase executor,
    TimeEntry entry,
  ) async {
    final rows = _entryRowsForStorage(entry);
    for (final row in rows) {
      await executor.into(database.timeEntries).insert(
            timeEntryToCompanion(row),
            mode: InsertMode.insertOrReplace,
          );
    }
    return rows;
  }

  /// 重叠裁剪：替换条目覆盖到的旧条目，按区间减法切开或整体软删。
  ///
  /// 规则（老项目语义）：
  /// - 被完全覆盖 → 软删；
  /// - 部分覆盖 → 切出未覆盖段（新 id），原 id 保留给最左段；
  /// - 运行中替换条目视为 +∞（覆盖其后全部条目）。
  Future<void> _cutOverlappingEntries(
    AppDatabase executor,
    List<TimeEntry> replacements,
    DateTime updatedAt,
  ) async {
    final active = replacements
        .where((e) => !e.isDeleted && (e.endAt == null || e.startAt.isBefore(e.endAt!)))
        .toList()
      ..sort((a, b) => a.startAt.compareTo(b.startAt));
    if (active.isEmpty) return;

    final protectedIds = active.map((e) => e.id).toSet();
    final firstStart = active.first.startAt;
    final hasRunning = active.any((e) => e.endAt == null);
    final finiteEnds = [
      for (final e in active)
        if (e.endAt != null) e.endAt!,
    ];
    final lastEnd = finiteEnds.isEmpty
        ? null
        : finiteEnds.reduce((a, b) => a.isAfter(b) ? a : b);

    final query = executor.select(database.timeEntries)
      ..where((t) {
        final startCond = hasRunning
            ? t.endAt.isNull() | t.endAt.isBiggerThanValue(utcString(firstStart))
            : t.startAt.isSmallerThanValue(utcString(lastEnd!)) &
                (t.endAt.isNull() | t.endAt.isBiggerThanValue(utcString(firstStart)));
        return t.deletedAt.isNull() & startCond;
      })
      ..orderBy([(t) => OrderingTerm.asc(t.startAt), (t) => OrderingTerm.asc(t.endAt)]);
    final rows = await query.get();

    for (final row in rows) {
      final candidate = timeEntryFromRow(row);
      if (protectedIds.contains(candidate.id)) continue;
      final pieces = _cutEntryByReplacements(candidate, active, updatedAt);
      if (pieces.length == 1 &&
          pieces.single.startAt == candidate.startAt &&
          pieces.single.endAt == candidate.endAt) {
        continue; // 无重叠
      }
      if (pieces.isEmpty) {
        await _saveEntryRows(
          executor,
          candidate.copyWith(deletedAt: updatedAt, updatedAt: updatedAt),
        );
        continue;
      }
      await _saveEntryRows(executor, pieces.first);
      for (final piece in pieces.skip(1)) {
        await _saveEntryRows(executor, piece);
      }
    }
  }

  /// 区间减法：把候选条目按替换区间切分（替换 = 挖掉的部分）。
  List<TimeEntry> _cutEntryByReplacements(
    TimeEntry entry,
    List<TimeEntry> replacements,
    DateTime updatedAt,
  ) {
    var remaining = <({DateTime start, DateTime? end})>[
      (start: entry.startAt, end: entry.endAt),
    ];
    for (final replacement in replacements) {
      final replacementEnd = replacement.endAt;
      final next = <({DateTime start, DateTime? end})>[];
      for (final interval in remaining) {
        final intervalEnd = interval.end;
        final overlaps = replacementEnd == null
            ? intervalEnd == null || replacement.startAt.isBefore(intervalEnd)
            : interval.start.isBefore(replacementEnd) &&
                (intervalEnd == null || replacement.startAt.isBefore(intervalEnd));
        if (!overlaps) {
          next.add(interval);
          continue;
        }
        if (interval.start.isBefore(replacement.startAt)) {
          next.add((start: interval.start, end: replacement.startAt));
        }
        if (replacementEnd != null &&
            (intervalEnd == null || replacementEnd.isBefore(intervalEnd))) {
          next.add((start: replacementEnd, end: intervalEnd));
        }
      }
      remaining = next;
      if (remaining.isEmpty) break;
    }

    final pieces = <TimeEntry>[];
    var first = true;
    for (final interval in remaining) {
      pieces.add(
        entry.copyWith(
          id: first ? entry.id : _uuid.v4(),
          startAt: interval.start,
          endAt: interval.end,
          clearEndAt: interval.end == null,
          updatedAt: updatedAt,
        ),
      );
      first = false;
    }
    return pieces;
  }

  // ---------------------------------------------------------------------------
  // 同步（LWW）
  // ---------------------------------------------------------------------------

  /// LWW upsert（删除永远赢：deleted_at 随行 LWW）。
  Future<AppResult<void>> replaceIfRemoteNewer(TimeEntry remote) async {
    try {
      // LWW 比较与写入同一事务：防比较后写入前本地新写入被旧远端覆盖。
      await database.transaction(() async {
        final local = await entryById(remote.id);
        if (local == null || local.updatedAt.isBefore(remote.updatedAt)) {
          await _saveEntry(remote);
        }
      });
      return AppSuccess(null);
    } catch (e) {
      return AppFailure('同步时间条目失败：$e');
    }
  }

  // ---------------------------------------------------------------------------
  // 内部工具
  // ---------------------------------------------------------------------------

  Future<TimeEntryRow?> _runningRow(AppDatabase executor) async {
    final query = executor.select(database.timeEntries)
      ..where((t) => t.endAt.isNull() & t.deletedAt.isNull())
      ..orderBy([(t) => OrderingTerm.desc(t.startAt)])
      ..limit(1);
    return query.getSingleOrNull();
  }

  Future<String> _ensureDeviceId() async {
    // 阶段 3 起由 AppStore 统一注入稳定 device id（app_metadata）；
    // 此处先取元数据，缺失则用随机 uuid 兜底（阶段 3 前仅作展示）。
    final query = database.select(database.appMetadata)
      ..where((t) => t.key.equals('device_id'));
    final row = await query.getSingleOrNull();
    if (row != null) return row.value;
    final id = _uuid.v4();
    await database.into(database.appMetadata).insertOnConflictUpdate(
          AppMetadataCompanion.insert(key: 'device_id', value: id),
        );
    return id;
  }

  /// 写操作日志（支持事务内）。
  Future<void> _insertActionLog({
    required ActionType actionType,
    String? activityId,
    String? entryId,
    required DateTime occurredAt,
    String message = '',
    AppDatabase? executor,
  }) async {
    final deviceId = await _ensureDeviceId();
    final log = ActionLog(
      id: _uuid.v4(),
      actionType: actionType,
      activityId: activityId,
      entryId: entryId,
      message: message,
      occurredAt: occurredAt,
      deviceId: deviceId,
      updatedAt: occurredAt,
    );
    final target = executor ?? database;
    await target.into(database.actionLogs).insert(actionLogToCompanion(log));
  }

  /// 可疑运行时长阈值（供 UI 警示，常量收敛在 constants）。
  bool isSuspiciousRunning(TimeEntry entry, DateTime now) {
    return entry.isRunning &&
        entry.durationUntil(now) > const Duration(hours: AppConstants.suspiciousEntryHours);
  }
}
