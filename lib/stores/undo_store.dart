/// undo/redo 栈（快照 diff 机制，计划决策 3：快照 diff 存内存）。
///
/// 设计：
/// - 快照为**字段级 diff**（before/after 实体），由领域 store（模块 3b）在
///   操作处记录；删除活动/删除分类**不做全表快照**——分类递归级联删除
///   （CategoryDeletion 的 categories+links）整体作为**一条**记录
///   （保留不变式 6：级联删除必须是一条 undo 记录，防 undo 半恢复）。
/// - 恢复两阶段：先全部 [UndoApplier.validate]（冲突预检，**不写库**）通过后
///   再逐个 [UndoApplier.apply]（写回主库）——计划风险 10"undo 半恢复"。
/// - 快照存**内存**（会话内）：撤销恢复写库时 updatedAt 推进为一次新修改，
///   参与 LWW/同步传播；跨会话 undo 不做（与 updatedAt 冲突校验、同步游标
///   的交互复杂，如实降级）。
library;

import 'dart:io' show stderr;

import 'package:flutter/foundation.dart';

import '../utils/result.dart';

/// 一条恢复的写库契约：由领域 store（3b）构造时注入。
///
/// 两阶段语义：
/// 1. [validate]：校验"当前库状态 == [expected]"，**不写库**——恢复一组
///    change 前先全部校验，任一失败则整组拒绝（防 undo 半恢复）。
///    undo 时 expected = 操作后快照（最近记录的状态）；redo 时 expected =
///    操作前快照。
/// 2. [apply]：校验全部通过后逐个写回主库。**实现必须保证自身原子性**
///    （组合写必要时用 drift transaction 包裹）——本层不跨仓储做事务，
///    apply 中途失败时已写部分不残留由实现负责。
abstract interface class UndoApplier {
  /// 冲突预检（不写库）。失败返回明确原因（供 UI/日志展示）。
  Future<AppResult<void>> validate(Object? expected);

  /// 把 [target]（目标状态）写回主库；写库时 updatedAt 推进到 now、按需记
  /// ActionLog（LWW 传播语义由各领域实现保证）。
  Future<AppResult<void>> apply(Object? target);
}

/// 一条字段级 diff：操作前/后的状态快照 + 对应写库契约。
///
/// - `before` = null：新建（恢复 = 删除该行）；
/// - `after` = null：删除（恢复 = 重新写入该行）。
class UndoChange {
  const UndoChange({
    required this.before,
    required this.after,
    required this.applier,
  }) : assert(
          before != null || after != null,
          'before 与 after 至少一个非 null（无实际写库动作的 no-op change 无意义）',
        );

  /// 操作前快照（null = 新建）。
  final Object? before;

  /// 操作后快照（null = 删除）。
  final Object? after;

  /// 恢复写库契约（undo 时 apply before、redo 时 apply after）。
  final UndoApplier applier;
}

/// 一条 undo 记录（label + 一组 change）。
///
/// 组合操作（如递归级联删除分类）的所有 change 收在**同一**记录内——
/// 恢复时整体校验、整体应用（计划风险 10 核心）。
///
/// **原子性契约（r 模块门禁）**：同一记录内的所有 change **必须由同一
/// 事务化 applier 覆盖**——领域 store 用单个 drift transaction 包裹整条
/// 记录的恢复写库。本层不跨仓储做事务，apply 中途失败的组合原子性由
/// 实现（3b 的事务化 applier）保证；违反此契约时，多 change 记录在 apply
/// 中途失败会留下部分改写状态（库/栈不一致、重试 validate 可能失败）。
class UndoRecord {
  UndoRecord({required this.label, required List<UndoChange> changes})
      : assert(label.trim().isNotEmpty, 'undo 记录 label 不能为空'),
        changes = List.unmodifiable(changes);

  /// 用户可读标签（UI 撤销提示、日志）。
  final String label;

  /// 该记录的 change 集（不可变视图）。
  final List<UndoChange> changes;
}

/// 撤销/重做栈（内存，ChangeNotifier）。
///
/// 治理规则（被多套 production 验证的共识）：
/// - 新操作 [record] **清空 redo 栈**（undo 后的未来已失效）；
/// - 栈深度超限丢最旧（[UndoStore.maxDepth]）；
/// - undo/redo **执行期间**触发的 [record] 被忽略（防恢复写库把 redo 误清空，
///   同 Flutter 官方 UndoHistory 的 _duringTrigger 防护）；
/// - [undo]/[redo] 失败时**栈不动**（记录不迁移、不弹出）。
class UndoStore extends ChangeNotifier {
  UndoStore({int maxDepth = defaultMaxDepth}) : _maxDepth = maxDepth {
    // 运行时校验（非 assert）：release 下 assert 被裁剪，若 maxDepth <= 0 会
    // 导致 record() 立即移除新记录、undo 栈永远为空、功能静默失效。
    if (maxDepth <= 0) {
      throw ArgumentError.value(maxDepth, 'maxDepth', 'maxDepth 必须为正');
    }
  }

  /// 默认栈深度上限。
  static const defaultMaxDepth = 50;

  final int _maxDepth;
  final List<UndoRecord> _undoStack = [];
  final List<UndoRecord> _redoStack = [];

  /// 恢复执行期（validate + apply 全程）：期间触发的 record 一律忽略
  /// （防误清 redo）；并发 restore 直接拒绝（防同一记录重复 apply）。
  bool _executing = false;

  /// 是否可撤销 / 可重做。
  bool get canUndo => _undoStack.isNotEmpty;
  bool get canRedo => _redoStack.isNotEmpty;

  /// 栈深度（供 UI/测试观察）。
  int get undoDepth => _undoStack.length;
  int get redoDepth => _redoStack.length;

  /// 最近一条记录的标签（UI 撤销提示用）；空栈为 null。
  String? get lastUndoLabel => _undoStack.isEmpty ? null : _undoStack.last.label;
  String? get lastRedoLabel => _redoStack.isEmpty ? null : _redoStack.last.label;

  /// 记录一次用户操作（可多条 change 的组合，如递归级联删除）。
  ///
  /// - 新操作清空 redo 栈；
  /// - 深度超限丢最旧；
  /// - [changes] 为空 = 编程错误（[ArgumentError]）；
  /// - **恢复执行期（[undo]/[redo] 全程）的 record 被静默忽略**——调用方必须
  ///   保证恢复期间不发起新编辑（UI 侧锁定编辑入口）；被忽略的编辑既不进栈，
  ///   随后的 apply 又可能用旧快照覆盖库状态（数据丢失风险），此前提不可省略。
  void record({required String label, required List<UndoChange> changes}) {
    // 恢复执行期防护放最前：执行期内任何 record 一律忽略（防误清 redo）。
    // 若先判 changes.isEmpty 再判 _executing，恢复期触发空 changes 的 record
    // 会抛 ArgumentError 打断恢复流程，与本条防护语义冲突。
    if (_executing) {
      debugPrint('UndoStore: 忽略恢复执行期的 record（label=$label）——'
          '调用方应保证恢复期间不发起新编辑');
      return;
    }
    if (changes.isEmpty) {
      throw ArgumentError.value(changes, 'changes', 'undo 记录至少需要一条 change');
    }
    _undoStack.add(UndoRecord(label: label, changes: changes));
    if (_undoStack.length > _maxDepth) {
      _undoStack.removeAt(0);
    }
    _redoStack.clear();
    notifyListeners();
  }

  /// 撤销最近一条记录；失败时栈不动并返回明确原因。
  Future<AppResult<void>> undo() => _restore(restoringBefore: true);

  /// 重做最近一条被撤销的记录；失败时栈不动并返回明确原因。
  Future<AppResult<void>> redo() => _restore(restoringBefore: false);

  Future<AppResult<void>> _restore({required bool restoringBefore}) async {
    // 恢复互斥：validate 是异步阶段，期间用户可能触发新的 record/并发 restore
    // —— 置位必须在捕获 record 之后、首个 await 之前完成，保证恢复期间一切
    // record 与并发 restore 都被隔离（防"validate 期间新 record 入栈 →
    // source.removeLast() 弹出的是新记录而非本记录"的错位）。
    if (_executing) {
      // 中性文案：正在进行的可能是相反方向的恢复（redo 执行中点了 undo），
      // 按本次请求方向措辞会误导。
      return const AppFailure('恢复操作进行中，请稍后再试');
    }
    final source = restoringBefore ? _undoStack : _redoStack;
    final target = restoringBefore ? _redoStack : _undoStack;
    if (source.isEmpty) {
      return AppFailure(restoringBefore ? '没有可撤销的操作' : '没有可重做的操作');
    }
    final record = source.last;
    _executing = true;
    try {
      final result = await _applyRecord(record, restoringBefore: restoringBefore);
      if (result case AppFailure<void> _) {
        return result; // 失败：栈不动（记录不迁移、不弹出）。
      }
      source.removeLast();
      target.add(record);
      if (target.length > _maxDepth) {
        target.removeAt(0);
      }
      notifyListeners();
      return result;
    } finally {
      _executing = false;
    }
  }

  /// 两阶段恢复：先全部校验（不写库）→ 全部通过才逐个应用。
  ///
  /// [restoringBefore] = true（undo）：校验"当前 == after"、应用 before；
  /// false（redo）：校验"当前 == before"、应用 after。
  ///
  /// 调用方（[_restore]）已置 [_executing] 并负责复位；本方法只做两阶段，
  /// 不再自行管理 [_executing]。
  Future<AppResult<void>> _applyRecord(
    UndoRecord record, {
    required bool restoringBefore,
  }) async {
    final verb = restoringBefore ? '撤销' : '重做';
    for (final change in record.changes) {
      final expected = restoringBefore ? change.after : change.before;
      // 契约：applier 恒返回 AppResult；防御性捕获抛出的**Exception**（连接
      // 错误等），转 AppFailure 收敛，保持 undo()/redo() 恒以 AppResult 结束。
      // Error（TypeError/NoSuchMethodError 等编程错误）**不吞**——fail-fast
      // 外抛暴露 applier 实现缺陷（异步上下文抛 Error 同样走 zone 全局处理）。
      // 用户文案脱敏（只带异常类型），原始异常写 stderr 供排障。
      final AppResult<void> result;
      try {
        result = await change.applier.validate(expected);
      } on Exception catch (e) {
        stderr.writeln('[undo] $verb校验异常：$e');
        return AppFailure('$verb被拒绝：校验异常 ${e.runtimeType}');
      }
      if (result case AppFailure<void> failure) {
        return AppFailure('$verb被拒绝：${failure.message}');
      }
    }
    for (final change in record.changes) {
      final target = restoringBefore ? change.before : change.after;
      final AppResult<void> result;
      try {
        result = await change.applier.apply(target);
      } on Exception catch (e) {
        stderr.writeln('[undo] $verb应用异常：$e');
        return AppFailure('$verb失败：应用异常 ${e.runtimeType}');
      }
      if (result case AppFailure<void> failure) {
        return AppFailure('$verb失败：${failure.message}');
      }
    }
    return const AppSuccess(null);
  }
}
