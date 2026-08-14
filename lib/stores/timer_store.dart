/// 计时核心 store（模块 3b）：时间条目全部写路径的单一入口。
///
/// 职责：
/// - **统一写路径**：switch/stop/add/split/merge/delete 全部经仓储执行；
/// - **undo/redo 包装**：每次操作记录快照 diff（undo 恢复操作前、redo 恢复
///   操作后），由 [UndoStore] 统一两阶段校验/应用；
/// - **dataRevision 递增**：写成功后 bump（不变式 9，UI 派生缓存失效）；
/// - **ActionLog**：仓储写路径内部已记（switch/stop/manual/split/merge/delete）；
/// - **isAuto 透传**：TrackingStore（模块 3c）自动记录命中后经
///   [switchToActivity]/[addEntry] 透传 isAuto=true（2c' 新功能落位）。
///
/// undo 恢复语义（与数据层设计一致）：
/// - **快照权威**（非 LWW）：恢复的是操作时快照状态，不比较远端更新；
///   冲突校验由 [TimerChangeApplier.validate] 完成（当前行存在且未删）；
/// - **updatedAt 推进到 now**：恢复作为一次新修改参与同步传播；
/// - 软删行（null 快照的旧行）经 [TimeEntryRepository.entryByIdIncludingDeleted]
///   读取软删态作为 after 快照。
///
/// 各操作 undo 记录（before=恢复操作前 / after=恢复操作后）：
/// | 操作 | before | after | undo | redo |
/// |---|---|---|---|---|
/// | add（新建） | null | 新条目 | 软删新条目 | 恢复新条目 |
/// | split | 原条目 | 原条目软删 | 恢复原条目 | 软删原条目 |
/// | merge | 原条目+邻居 | 原条目软删 | 恢复二者 | 软删原条目 |
/// | delete | 原条目 | 原条目软删 | 恢复 | 软删 |
/// | switch/stop | 旧运行条目 | 无动作 | 旧运行恢复未结束态 | 保持现状 |
///
/// 注：switch/stop 的 after 为空操作（[TimerEntryChange] 空 ops）——redo 保持
/// 新运行条目现状；跨条目的完整时间线重放不在本地 undo 语义内（冲突校验
/// 会让时序不一致的恢复被拒）。
library;

import 'package:flutter/foundation.dart';

import '../data/repositories/time_entry_repository.dart';
import '../utils/result.dart';
import '../viewmodels/time_entry.dart';
import 'clock_store.dart';
import 'data_revision.dart';
import 'undo_store.dart';

/// 一次时间条目恢复的复合操作（3a 契约：一条 undo 记录一个 change，恢复
/// 目标在 change 内自包含——[UndoStore] 不感知领域结构）。
class TimerEntryChange {
  const TimerEntryChange(this.ops);

  /// 恢复操作：每项 entry 为**恢复目标状态**；softDelete=false 写该状态
  ///（推进 updatedAt），true 软删该行（deletedAt = 推进后的 updatedAt）。
  final List<({TimeEntry entry, bool softDelete})> ops;
}

/// 时间条目恢复写库契约（3a [UndoApplier] 实现）：单事务恢复，updatedAt
/// 推进到 now（恢复作为新修改参与 LWW 传播）。
class TimerChangeApplier implements UndoApplier {
  TimerChangeApplier(this._entries);

  final TimeEntryRepository _entries;

  /// 冲突预检（不写库）：按 [expected]（恢复前预期状态）校验当前库状态——
  /// undo 时 expected=after、redo 时 expected=before：
  /// - op.softDelete=false（预期当前为未删态）：行必须存在且未软删；
  /// - op.softDelete=true（预期当前为软删态）：行必须存在且已软删。
  /// 任一不符 = 恢复前状态已被并发操作改动（他人删除/恢复），拒绝恢复
  ///（防撤销掉别人的修改）；行已物理删除 = 恢复目标已不存在，拒绝。
  @override
  Future<AppResult<void>> validate(Object? expected) async {
    if (expected case TimerEntryChange change) {
      for (final op in change.ops) {
        final current = await _entries.entryByIdIncludingDeleted(op.entry.id);
        if (op.softDelete) {
          if (current == null || !current.isDeleted) {
            return const AppFailure('条目当前未处于软删态，无法撤销删除');
          }
        } else {
          if (current == null) {
            return const AppFailure('条目已被删除，无法恢复');
          }
          if (current.isDeleted) {
            return const AppFailure('条目当前已软删，无法恢复');
          }
        }
      }
    }
    return const AppSuccess(null);
  }

  @override
  Future<AppResult<void>> apply(Object? target) async {
    if (target case TimerEntryChange change) {
      return _entries.restoreEntriesForUndo(change.ops);
    }
    return const AppFailure('未知恢复目标类型');
  }
}

/// 计时 store。
class TimerStore extends ChangeNotifier {
  TimerStore({
    required this.entries,
    required this.undo,
    required this.clock,
    required this.dataRevision,
  }) : _applier = TimerChangeApplier(entries) {
    // 时钟 tick：刷新运行时长展示（runningEntry 时长随时间增长）。
    clock.addListener(notifyListeners);
  }

  final TimeEntryRepository entries;
  final UndoStore undo;
  final ClockStore clock;
  final DataRevision dataRevision;

  final TimerChangeApplier _applier;

  TimeEntry? _runningEntry;
  TimeEntry? _lastAction;

  /// 当前运行条目（缓存；写路径与 tick 后刷新）。
  TimeEntry? get runningEntry => _runningEntry;

  /// 最近一次操作产物（切换/停止/补记/切割/合并的条目；删除为 null）。
  TimeEntry? get lastAction => _lastAction;

  // ---------------------------------------------------------------------------
  // 查询
  // ---------------------------------------------------------------------------

  /// 刷新运行条目缓存（时钟 tick 或外部数据变更后调用）。
  Future<void> refresh() async {
    _runningEntry = await entries.runningEntry();
    notifyListeners();
  }

  // ---------------------------------------------------------------------------
  // 写路径（全部经 undo + dataRevision + ActionLog）
  // ---------------------------------------------------------------------------

  /// 切换到 [activityId]（可带 --at= 时刻；[isAuto] 透传自动记录）。
  Future<AppResult<TimeEntry>> switchToActivity(
    String activityId, {
    DateTime? at,
    bool isAuto = false,
  }) async {
    final beforeRunning = await entries.runningEntry();
    final result = await entries.switchToActivity(
      activityId,
      at: at,
      isAuto: isAuto,
    );
    if (result case AppFailure<TimeEntry> failure) {
      return failure;
    }
    final after = result.requireValue();
    _lastAction = after;
    _recordSwitchOrStop('切换', beforeRunning, after);
    _afterWrite();
    return result;
  }

  /// 停止当前活动（切到未分配）。
  Future<AppResult<TimeEntry>> stopRunning({DateTime? at}) async {
    final beforeRunning = await entries.runningEntry();
    final result = await entries.stopRunning(at: at);
    if (result case AppFailure<TimeEntry> failure) {
      return failure;
    }
    _lastAction = result.requireValue();
    _recordSwitchOrStop('停止', beforeRunning, result.requireValue());
    _afterWrite();
    return result;
  }

  /// 补记时间段。
  Future<AppResult<TimeEntry>> addEntry({
    required String activityId,
    required DateTime startAt,
    required DateTime endAt,
    required String note,
    bool isAuto = false,
  }) async {
    final result = await entries.createManualEntry(
      activityId: activityId,
      startAt: startAt,
      endAt: endAt,
      note: note,
      isAuto: isAuto,
    );
    if (result case AppFailure<TimeEntry> failure) {
      return failure;
    }
    final after = result.requireValue();
    _lastAction = after;
    undo.record(
      label: '补记',
      changes: [
        UndoChange(
          // before 自包含"软删该行"指令（非字面 null）：undo 软删新条目、
          // redo 恢复——change 的恢复目标完整承载在 change 内（3a 契约）。
          before: TimerEntryChange([(entry: after, softDelete: true)]),
          after: TimerEntryChange([(entry: after, softDelete: false)]),
          applier: _applier,
        ),
      ],
    );
    _afterWrite();
    return result;
  }

  /// 切割时间段。
  Future<AppResult<List<TimeEntry>>> splitEntry({
    required String entryId,
    required DateTime splitAt,
  }) async {
    final before = await entries.entryByIdIncludingDeleted(entryId);
    final result = await entries.splitEntry(entryId: entryId, splitAt: splitAt);
    if (result case AppFailure<List<TimeEntry>> failure) {
      return failure;
    }
    _lastAction = result.requireValue().first;
    if (before != null) {
      undo.record(
        label: '切割',
        changes: [
          UndoChange(
            // before=原条目完整时段（undo 恢复覆盖切分后两段）；
            // after=空（redo 保持切分后状态——切分信息不重放）。
            before: TimerEntryChange([(entry: before, softDelete: false)]),
            after: const TimerEntryChange([]),
            applier: _applier,
          ),
        ],
      );
    }
    _afterWrite();
    return result;
  }

  /// 与相邻条目合并（[mergePrevious] = true 向左、false 向右合并）。
  Future<AppResult<TimeEntry?>> mergeWithNeighbor({
    required String entryId,
    required bool mergePrevious,
  }) async {
    final before = await entries.entryByIdIncludingDeleted(entryId);
    final neighbor = await entries.neighborForMerge(
      entryId: entryId,
      mergePrevious: mergePrevious,
    );
    if (neighbor case AppFailure<TimeEntry?> failure) {
      return failure;
    }
    final result = await entries.mergeEntryWithNeighbor(
      entryId: entryId,
      mergePrevious: mergePrevious,
    );
    if (result case AppFailure<TimeEntry?> failure) {
      return failure;
    }
    final merged = result.requireValue();
    if (merged == null || before == null) {
      _afterWrite();
      return result; // 无合并对象/原条目缺失：无 undo 记录
    }
    _lastAction = merged;
    final neighborValue = neighbor.requireValue();
    undo.record(
      label: '合并',
      changes: [
        UndoChange(
          // before=原条目+邻居（undo 恢复二者，覆盖 merged）；
          // after=空（redo 保持合并后状态——合并信息不重放）。
          before: TimerEntryChange([
            (entry: before, softDelete: false),
            if (neighborValue != null) (entry: neighborValue, softDelete: false),
          ]),
          after: const TimerEntryChange([]),
          applier: _applier,
        ),
      ],
    );
    _afterWrite();
    return result;
  }

  /// 删除时间段。
  Future<AppResult<void>> deleteEntry(String entryId) async {
    final before = await entries.entryByIdIncludingDeleted(entryId);
    if (before == null) {
      return const AppFailure('条目不存在，无法删除');
    }
    final result = await entries.deleteEntry(before);
    if (result case AppFailure<void> failure) {
      return failure;
    }
    undo.record(
      label: '删除',
      changes: [
        UndoChange(
          before: TimerEntryChange([(entry: before, softDelete: false)]),
          after: TimerEntryChange([(entry: before, softDelete: true)]),
          applier: _applier,
        ),
      ],
    );
    _afterWrite();
    return result;
  }

  // ---------------------------------------------------------------------------
  // 内部
  // ---------------------------------------------------------------------------

  /// switch/stop 共用 undo 记录：
  /// - before（undo 恢复）：旧运行条目恢复未结束态 + **新运行条目软删**
  ///   （回到切换前状态——只有旧运行在运行，不残留新条目双运行）；
  /// - after（redo）：空操作（保持切换后现状）。
  /// 旧运行条目为 null（无切换前运行）时无撤销意义（无操作）。
  void _recordSwitchOrStop(String label, TimeEntry? beforeRunning, TimeEntry? after) {
    if (beforeRunning == null) {
      return;
    }
    undo.record(
      label: label,
      changes: [
        UndoChange(
          before: TimerEntryChange([
            (entry: beforeRunning, softDelete: false),
            // after 与 before 同条目（stop 已停在未分配上触发合并）时不软删。
            if (after != null && after.id != beforeRunning.id)
              (entry: after, softDelete: true),
          ]),
          after: const TimerEntryChange([]), // redo 无动作
          applier: _applier,
        ),
      ],
    );
  }

  void _afterWrite() {
    dataRevision.bump();
    notifyListeners();
  }

  @override
  void dispose() {
    clock.removeListener(notifyListeners);
    super.dispose();
  }
}
