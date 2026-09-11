/// 活动 store（批次 5a）：活动写路径的 undo 收口。
///
/// 背景：活动此前由页面直连 [ActivityRepository]（无撤销记录、不递增
/// dataRevision）；批次 5a 以 `activity_create` 指令收口**新建**路径——
/// 一条指令 = 一条撤销记录（§5.3），undo=软删新活动 / redo=复活
///（原挂账名"ActivityCreateApplier"职责落位于 [ActivityChangeApplier]）。
///
/// undo 语义与 TimerStore/CategoryStore 一致：快照权威、恢复推进
/// updatedAt 参与同步传播、冲突预检（[ActivityChangeApplier.validate]）
/// 拒绝恢复已被并发改动的状态。
library;

import 'package:flutter/foundation.dart';

import '../data/repositories/activity_repository.dart';
import '../utils/result.dart';
import '../viewmodels/activity.dart';
import 'data_revision.dart';
import 'undo_store.dart';

/// 一次活动状态恢复的复合操作（3a 契约：一条 undo 记录一个 change）。
class ActivityStateChange {
  const ActivityStateChange(this.ops);

  /// 每项 entry 为**恢复目标状态**；softDelete=false 写该状态（推进
  /// updatedAt），true 软删该行。
  final List<({Activity entry, bool softDelete})> ops;
}

/// 活动恢复写库契约（3a [UndoApplier] 实现）：单事务恢复，updatedAt 推进
/// 到 now（恢复作为新修改参与 LWW 传播）。
class ActivityChangeApplier implements UndoApplier {
  ActivityChangeApplier(this._activities);

  final ActivityRepository _activities;

  /// 冲突预检（不写库）：按 [expected] 校验当前库状态——softDelete=false
  /// （预期当前未删）行必须存在且未删；softDelete=true（预期当前软删）行
  /// 必须存在且已删。任一不符 = 恢复前状态被并发改动，拒绝恢复。
  @override
  Future<AppResult<void>> validate(Object? expected) async {
    if (expected case ActivityStateChange change) {
      for (final op in change.ops) {
        // activityById 不滤软删行（含墓碑返回），可区分两种失败态。
        final current = await _activities.activityById(op.entry.id);
        if (op.softDelete) {
          if (current == null || !current.isDeleted) {
            return const AppFailure('活动当前未处于软删态，无法撤销');
          }
        } else {
          if (current == null) {
            return const AppFailure('活动已被删除，无法恢复');
          }
          if (current.isDeleted) {
            return const AppFailure('活动当前已软删，无法恢复');
          }
        }
      }
      return const AppSuccess(null);
    }
    return const AppFailure('未知恢复目标类型');
  }

  @override
  Future<AppResult<void>> apply(Object? target) async {
    if (target case ActivityStateChange change) {
      final result =
          await _activities.restoreActivityStatesForUndo(change.ops);
      if (result.isSuccess) {
        onApplied?.call();
      }
      return result;
    }
    return const AppFailure('未知恢复目标类型');
  }

  /// 恢复写库成功后的回调（store 注入：bump dataRevision + notify）。
  void Function()? onApplied;
}

/// 活动 store。
class ActivityStore extends ChangeNotifier {
  ActivityStore({
    required this.activities,
    required this.undo,
    required this.dataRevision,
  }) : _applier = ActivityChangeApplier(activities) {
    _applier.onApplied = () {
      // 恢复也是数据变更来源：bump 使 picker/统计等派生缓存失效
      //（不变式 9）。dispose 后仍须 bump（DB 实际变更），仅跳过通知。
      dataRevision.bump();
      if (_disposed) return;
      notifyListeners();
    };
  }

  final ActivityRepository activities;
  final UndoStore undo;
  final DataRevision dataRevision;

  final ActivityChangeApplier _applier;

  bool _disposed = false;

  /// 新建活动（`activity_create` 指令落点）：undo=软删 / redo=复活。
  ///
  /// 分类关联不在此收口（picker 提交后仍经 CategoryStore.setActivityCategories，
  /// 挂账不变——关联的指令通道化随批次后续评估）。
  Future<AppResult<Activity>> createActivity({
    required String name,
    required int color,
    bool isOneOff = false,
  }) async {
    final result = await activities.createActivity(
      name: name,
      color: color,
      isOneOff: isOneOff,
    );
    if (result case AppFailure<Activity> failure) {
      return failure;
    }
    final created = result.requireValue();
    undo.record(
      label: '新建活动',
      changes: [
        UndoChange(
          // before 自包含"软删该行"指令：undo 删除新建活动、redo 复活
          // ——恢复目标完整承载在 change 内（3a 契约）。
          before: ActivityStateChange([(entry: created, softDelete: true)]),
          after: ActivityStateChange([(entry: created, softDelete: false)]),
          applier: _applier,
        ),
      ],
    );
    _afterWrite();
    return result;
  }

  void _afterWrite() {
    dataRevision.bump();
    if (_disposed) return; // await 写路径后可能已 dispose：跳过通知
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}
