/// 基础状态 provider：时钟、修订号、撤销栈。
///
/// 三个服务对象由本文件唯一持有（容器释放即 dispose），并向 UI 暴露只读
/// Riverpod 状态：`clockTickProvider` / `currentDayProvider`（秒级时刻与
/// 当前日）、`dataRevisionProvider`（写库失效信号）、`undoStateProvider`
/// （撤销可用性与标签）。服务类不继承 ChangeNotifier，订阅经
/// `addChangeListener` / `removeChangeListener` 显式配对，只由 provider 层
/// 与领域 store 使用；页面一律 `ref.watch`。
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
/// TimerStore/TrackingStore/ReminderStore 与 Android 前台检测器通过构造注入持有它；UI 用 [clockTickProvider] /
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
    clock.addChangeListener(tick);
    ref.onDispose(() => clock.removeChangeListener(tick));
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
    revision.addChangeListener(onChange);
    ref.onDispose(() => revision.removeChangeListener(onChange));
    return revision.value;
  }

  /// 递增修订号（写库成功后调用）。
  void bump() => ref.read(dataRevisionStoreProvider).bump();
}

/// 撤销栈服务（唯一实例；被领域 store 记录快照）。
final undoStoreProvider = Provider<UndoStore>((ref) => UndoStore());

/// 撤销栈的只读状态快照（UI 只订阅这个）。
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



