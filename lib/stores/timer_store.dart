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

  /// 恢复写库成功后的回调：供 store 递增 dataRevision 并刷新缓存
  ///（恢复也是数据变更来源，UI 派生缓存须失效——3b 要点）。store 构造后
  /// 注入（构造器初始化列表无法引用实例方法）。
  void Function()? onApplied;

  /// 冲突预检（不写库）：按 [expected]（恢复前预期状态）校验当前库状态——
  /// undo 时 expected=after、redo 时 expected=before：
  /// - op.softDelete=false（预期当前为未删态）：行必须存在且未软删；
  /// - op.softDelete=true（预期当前为软删态）：行必须存在且已软删。
  /// 任一不符 = 恢复前状态已被并发操作改动（他人删除/恢复），拒绝恢复
  ///（防撤销掉别人的修改）；行已物理删除 = 恢复目标已不存在，拒绝。
  @override
  Future<AppResult<void>> validate(Object? expected) async {
    // 未知类型（含 null）：拒绝而非放行——与 apply 的未知类型失败一致，
    // 防后续扩展/调用方缺陷时绕过冲突预检。
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
      return const AppSuccess(null);
    }
    return const AppFailure('未知恢复目标类型');
  }

  @override
  Future<AppResult<void>> apply(Object? target) async {
    if (target case TimerEntryChange change) {
      final result = await _entries.restoreEntriesForUndo(change.ops);
      if (result.isSuccess) {
        onApplied?.call(); // 恢复写库成功：bump dataRevision + 刷新缓存
      }
      return result;
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
    // 恢复写库成功 → bump + 刷新运行条目缓存（恢复也是数据变更来源，
    // 且可能改变运行条目——如 switch undo 恢复旧运行）。refresh 为 async，
    // 可能在 dispose 后恢复执行，须防护。
    _applier.onApplied = () {
      if (_disposed) {
        // 恢复写库已成功（DB 实际变更）——dispose 后仍须递增 revision
        //（派生缓存/同步逻辑依赖），仅跳过 notify/refresh。
        dataRevision.bump();
        return;
      }
      _afterWrite();
      refresh();
    };
    // 时钟 tick：刷新运行时长展示（runningEntry 时长随时间增长）。
    clock.addListener(notifyListeners);
  }

  final TimeEntryRepository entries;
  final UndoStore undo;
  final ClockStore clock;
  final DataRevision dataRevision;

  final TimerChangeApplier _applier;

  /// 已 dispose：恢复写库回调（async refresh）可能在 dispose 后才恢复执行，
  /// 需防护"used after disposed"（回调由 undo 异步链驱动，时序不受控）。
  bool _disposed = false;

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
    if (_disposed) return; // dispose 后静默跳过（防 async 恢复执行崩溃）
    final running = await entries.runningEntry();
    if (_disposed) return; // await 期间可能已 dispose
    _runningEntry = running;
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
    // 采集操作后旧运行实际状态（已结束 endAt）——undo after 快照需可校验。
    TimeEntry? oldRunningAfter;
    if (beforeRunning != null) {
      oldRunningAfter =
          await entries.entryByIdIncludingDeleted(beforeRunning.id);
    }
    _lastAction = after;
    _runningEntry = after; // 写路径同步刷新运行条目缓存（时钟 tick 不触发 refresh）
    _recordSwitchOrStop('切换', beforeRunning, after, oldRunningAfter);
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
    // 采集操作后旧运行实际状态（已结束 endAt）——undo after 快照需可校验。
    TimeEntry? oldRunningAfter;
    if (beforeRunning != null) {
      oldRunningAfter =
          await entries.entryByIdIncludingDeleted(beforeRunning.id);
    }
    _lastAction = result.requireValue();
    _runningEntry = result.requireValue(); // stop 后新运行（未分配）条目
    _recordSwitchOrStop('停止', beforeRunning, result.requireValue(), oldRunningAfter);
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
    final parts = result.requireValue();
    if (before != null) {
      undo.record(
        label: '切割',
        changes: [
          UndoChange(
            // before=原条目完整时段（undo 恢复覆盖首段）+ 切分第二段软删
            //（新 id 段残留会与恢复的完整条目重叠，须一并清除）；
            // after=操作后状态（原条目切分态 + 第二段）——redo 恢复切分后
            // 状态，且 validate 可校验（非空 after 防冲突预检绕过）。
            before: TimerEntryChange([
              (entry: before, softDelete: false),
              for (final part in parts)
                if (part.id != before.id) (entry: part, softDelete: true),
            ]),
            after: TimerEntryChange([
              for (final part in parts) (entry: part, softDelete: false),
            ]),
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
    if (result case AppFailure failure) {
      return AppFailure<TimeEntry?>(failure.message);
    }
    final merged = result.requireValue();
    if (merged == null || before == null) {
      _afterWrite();
      return const AppSuccess(null); // 无合并对象/原条目缺失：无 undo 记录
    }
    _lastAction = merged.entry;
    // 合并不涉及运行条目（merge 仅已结束条目，仓储已拒绝运行中）——
    // 运行态缓存保持不变（若有运行计时，不得因合并其他条目被清空）。
    final neighborValue = neighbor.requireValue();
    undo.record(
      label: '合并',
      changes: [
        UndoChange(
          // before=原条目+邻居（undo 恢复二者，覆盖 merged）+ 合并产物
          // 跨日派生段软删（新 id 段残留会与恢复条目重叠，须一并清除）；
          // after=操作后状态（**合并产物全部入库行**——首段+跨日派生段，
          // 与 before 清理逻辑对称；只含首段会致 redo 恢复截断/数据丢失）
          // + 邻居软删。
          before: TimerEntryChange([
            (entry: before, softDelete: false),
            if (neighborValue != null) (entry: neighborValue, softDelete: false),
            for (final row in merged.savedRows)
              if (row.id != before.id && row.id != neighborValue?.id)
                (entry: row, softDelete: true),
          ]),
          after: TimerEntryChange([
            for (final row in merged.savedRows) (entry: row, softDelete: false),
            if (neighborValue != null) (entry: neighborValue, softDelete: true),
          ]),
          applier: _applier,
        ),
      ],
    );
    _afterWrite();
    return AppSuccess(merged.entry);
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
    _lastAction = null; // 删除：lastAction 置空（契约：删除为 null）
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
  /// - after（redo 恢复操作后状态）：旧运行已结束态 + 新运行恢复运行——
  ///   非空 after 让 validate 可校验（防冲突预检绕过）。
  /// 旧运行条目为 null（无切换前运行）时无撤销意义（无操作）。
  void _recordSwitchOrStop(
    String label,
    TimeEntry? beforeRunning,
    TimeEntry? after,
    TimeEntry? oldRunningAfter,
  ) {
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
          after: TimerEntryChange([
            // 旧运行操作后已结束态（redo 写回结束）。
            if (oldRunningAfter != null)
              (entry: oldRunningAfter, softDelete: false),
            // 新运行条目（redo 恢复运行态）。
            if (after != null && after.id != beforeRunning.id)
              (entry: after, softDelete: false),
          ]),
          applier: _applier,
        ),
      ],
    );
  }

  void _afterWrite() {
    dataRevision.bump();
    if (_disposed) return; // await 写路径后可能已 dispose：跳过通知
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    clock.removeListener(notifyListeners);
    super.dispose();
  }
}
