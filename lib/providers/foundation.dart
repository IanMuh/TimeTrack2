/// 基础状态 provider（Riverpod 迁移 B1 地基）：时钟、修订号、撤销栈。
///
/// 迁移策略（strangler，见 AGENTS.md 迁移期约束）：
/// - 存量 `ClockStore` / `DataRevision` / `UndoStore` 仍是可变服务对象，被
///   `stores/` 内的 ChangeNotifier store 直接持有——B1 不一次性改它们的调用方；
/// - provider 负责**唯一所有权**（容器释放即 dispose），并向新代码暴露只读
///   Riverpod 状态（tick 时刻 / 修订号 / 撤销可用性与标签），新 UI 一律
///   `ref.watch`，不再 `addListener`；
/// - 服务类本身随其消费 store 在 B2-B4 分批转换后删除，届时这些 provider
///   改为直接持有不可变状态，接口不变。
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../stores/clock_store.dart';
import '../stores/data_revision.dart';
import '../stores/undo_store.dart';
import '../utils/date_time_ext.dart';
import '../utils/result.dart';
import 'infrastructure.dart';

/// 时钟周期（测试可覆盖为长周期避免真实 tick）。
final clockIntervalProvider = Provider<Duration>(
  (ref) => const Duration(seconds: 1),
);

/// 全局时钟服务（唯一实例；容器释放时取消 1Hz Timer）。
///
/// 存量 store 通过构造注入持有它；新代码改用 [clockTickProvider] /
/// [currentDayProvider]。
/// 是否自动启动 1Hz Timer（测试覆盖为 false，避免 fake async 里残留定时器）。
final clockAutoStartProvider = Provider<bool>((ref) => true);

final clockStoreProvider = Provider<ClockStore>((ref) {
  final clock = ClockStore(
    autoStart: ref.watch(clockAutoStartProvider),
    interval: ref.watch(clockIntervalProvider),
    now: ref.watch(nowProvider),
  );
  ref.onDispose(clock.dispose);
  return clock;
});

/// 时钟当前时刻（每秒推进一次；只订阅“秒级展示”的叶子组件）。
final clockTickProvider = NotifierProvider<ClockTickNotifier, DateTime>(
  ClockTickNotifier.new,
);

/// 把 [ClockStore] 的通知映射为 Riverpod 状态。
class ClockTickNotifier extends Notifier<DateTime> {
  @override
  DateTime build() {
    final clock = ref.watch(clockStoreProvider);
    void tick() => state = clock.now();
    clock.addListener(tick);
    ref.onDispose(() => clock.removeListener(tick));
    return clock.now();
  }
}

/// 当前本地日（00:00）——跨午夜自动翻页的唯一事实来源。
///
/// 与 [clockTickProvider] 不同：`DateTime` 按时刻比较，同一日内每秒的新时刻
/// 会通知 tick 订阅者，但本 provider 的值整天相等，跨日才通知一次。
final currentDayProvider = Provider<DateTime>(
  (ref) => ref.watch(clockTickProvider).startOfDay,
);

/// 修订号服务（dataRevision，保留不变式 9：写库成功后必递增）。
final dataRevisionStoreProvider = Provider<DataRevision>((ref) {
  final revision = DataRevision();
  ref.onDispose(revision.dispose);
  return revision;
});

/// 当前修订号（新代码用它替代 `dataRevision.addListener` 手工失效）。
///
/// 派生缓存订阅此值即可；写路径仍经 [DataRevisionNotifier.bump]。
final dataRevisionProvider = NotifierProvider<DataRevisionNotifier, int>(
  DataRevisionNotifier.new,
);

/// 把 [DataRevision] 的通知映射为 Riverpod 状态，并转发 bump。
class DataRevisionNotifier extends Notifier<int> {
  @override
  int build() {
    final revision = ref.watch(dataRevisionStoreProvider);
    void onChange() => state = revision.value;
    revision.addListener(onChange);
    ref.onDispose(() => revision.removeListener(onChange));
    return revision.value;
  }

  /// 递增修订号（写库成功后调用）。
  void bump() => ref.read(dataRevisionStoreProvider).bump();
}

/// 撤销栈服务（唯一实例；被领域 store 记录快照）。
final undoStoreProvider = Provider<UndoStore>((ref) => UndoStore());

/// 撤销栈的只读状态快照（UI 订阅这个，而不是 `ListenableBuilder`）。
final undoStateProvider = NotifierProvider<UndoStateNotifier, UndoState>(
  UndoStateNotifier.new,
);

/// 撤销栈对 UI 可见的最小状态。
class UndoState {
  const UndoState({
    required this.canUndo,
    required this.canRedo,
    this.lastUndoLabel,
    this.lastRedoLabel,
  });

  final bool canUndo;
  final bool canRedo;
  final String? lastUndoLabel;
  final String? lastRedoLabel;

  @override
  bool operator ==(Object other) =>
      other is UndoState &&
      other.canUndo == canUndo &&
      other.canRedo == canRedo &&
      other.lastUndoLabel == lastUndoLabel &&
      other.lastRedoLabel == lastRedoLabel;

  @override
  int get hashCode =>
      Object.hash(canUndo, canRedo, lastUndoLabel, lastRedoLabel);
}

/// 把 [UndoStore] 的通知映射为 Riverpod 状态，并转发撤销/重做。
class UndoStateNotifier extends Notifier<UndoState> {
  @override
  UndoState build() {
    final undo = ref.watch(undoStoreProvider);
    void onChange() => state = _snapshot(undo);
    undo.onChanged = onChange;
    ref.onDispose(() {
      if (identical(undo.onChanged, onChange)) undo.onChanged = null;
    });
    return _snapshot(undo);
  }

  /// 撤销最近一条记录（失败时栈不动，返回明确原因）。
  Future<AppResult<void>> undo() => ref.read(undoStoreProvider).undo();

  /// 重做最近一条被撤销的记录。
  Future<AppResult<void>> redo() => ref.read(undoStoreProvider).redo();

  static UndoState _snapshot(UndoStore undo) => UndoState(
        canUndo: undo.canUndo,
        canRedo: undo.canRedo,
        lastUndoLabel: undo.lastUndoLabel,
        lastRedoLabel: undo.lastRedoLabel,
      );
}



