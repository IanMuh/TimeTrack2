import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../stores/app_store.dart';
import '../stores/reminder_store.dart';
import '../stores/timer_store.dart';
import '../stores/update_store.dart';

/// 迁移期（B4a）AppStore 实例接入点。
///
/// `AppStore` 仍是物理引擎（计时/同步/更新/追踪/LAN/托盘）的装配者，B4e 才会
/// 拆散。在拆散之前，壳层需要以 Riverpod 的方式**订阅**这些引擎的状态，而不是
/// 直接 `addListener`：
/// - main：容器创建时用 `overrideWith((ref) => bootStore)` 绑定，启动装配完成
///   前不会被读取；
/// - widget 测试：`TimeTrack2App` 内部作用域用 `overrideWithValue(store)` 绑定；
/// - 未装配即读取是编程错误，直接抛错（而不是悄悄给 null 让页面静默失效）。
final appStoreInstanceProvider = Provider<AppStore>((ref) {
  throw StateError(
    'appStoreInstanceProvider 未装配：main 必须用 overrideWith 绑定启动实例，'
    'widget 测试必须用 overrideWithValue 传入测试 store。',
  );
});

/// 运行中计时条目的**值快照**（只含壳层展示/判定需要的字段）。
///
/// 用值相等（而非条目对象身份）作为通知门槛：`TimerStore` 内部任何无关字段的
/// 变更都不会引起壳层重建；条目结束（entryId 变 null）或切换活动才通知。
class TimerSnapshot {
  const TimerSnapshot({this.entryId, this.activityId, this.startAt});

  factory TimerSnapshot.from(TimerStore store) {
    final running = store.runningEntry;
    return TimerSnapshot(
      entryId: running?.id,
      activityId: running?.activityId,
      startAt: running?.startAt,
    );
  }

  /// 运行中条目 id；null = 空闲。
  final String? entryId;
  final String? activityId;
  final DateTime? startAt;

  bool get isRunning => entryId != null;

  @override
  bool operator ==(Object other) =>
      other is TimerSnapshot &&
      other.entryId == entryId &&
      other.activityId == activityId &&
      other.startAt == startAt;

  @override
  int get hashCode => Object.hash(entryId, activityId, startAt);

  @override
  String toString() =>
      'TimerSnapshot(entryId: $entryId, activityId: $activityId)';
}

/// 当前待处置提醒的**值快照**。
class ReminderSnapshot {
  const ReminderSnapshot({
    this.requestId,
    this.requestKind,
    this.methodName,
  });

  factory ReminderSnapshot.from(ReminderStore store) {
    final active = store.active;
    return ReminderSnapshot(
      requestId: active?.id,
      requestKind: active?.runtimeType.toString(),
      methodName: active?.method.name,
    );
  }

  /// 展示去重键；null = 当前无提醒。
  final String? requestId;
  final String? requestKind;
  final String? methodName;

  bool get hasReminder => requestId != null;

  @override
  bool operator ==(Object other) =>
      other is ReminderSnapshot &&
      other.requestId == requestId &&
      other.requestKind == requestKind &&
      other.methodName == methodName;

  @override
  int get hashCode => Object.hash(requestId, requestKind, methodName);
}

/// 更新编排的**值快照**（状态 + 进度/版本/错误）。
///
/// 下载进度逐字节变化属于预期通知（横幅进度条需要），与迁移前 `addListener`
/// 的触发频率一致。
class UpdateSnapshot {
  const UpdateSnapshot({
    required this.state,
    this.receivedBytes = 0,
    this.totalBytes,
    this.latestVersion = '',
    this.required = false,
    this.releaseNotes = '',
    this.errorMessage,
  });

  factory UpdateSnapshot.from(UpdateStore store) {
    final status = store.status;
    return UpdateSnapshot(
      state: status.state,
      receivedBytes: status.receivedBytes,
      totalBytes: status.totalBytes,
      latestVersion: status.latestVersion,
      required: status.required,
      releaseNotes: status.releaseNotes,
      errorMessage: status.errorMessage,
    );
  }

  final UpdateState state;
  final int receivedBytes;
  final int? totalBytes;
  final String latestVersion;
  final bool required;
  final String releaseNotes;
  final String? errorMessage;

  @override
  bool operator ==(Object other) =>
      other is UpdateSnapshot &&
      other.state == state &&
      other.receivedBytes == receivedBytes &&
      other.totalBytes == totalBytes &&
      other.latestVersion == latestVersion &&
      other.required == required &&
      other.releaseNotes == releaseNotes &&
      other.errorMessage == errorMessage;

  @override
  int get hashCode => Object.hash(
        state,
        receivedBytes,
        totalBytes,
        latestVersion,
        required,
        releaseNotes,
        errorMessage,
      );
}

/// 运行中计时条目镜像（监听 TimerStore → 快照值变化才通知）。
final timerSnapshotProvider =
    NotifierProvider<TimerSnapshotNotifier, TimerSnapshot>(
  TimerSnapshotNotifier.new,
);

class TimerSnapshotNotifier extends Notifier<TimerSnapshot> {
  @override
  TimerSnapshot build() {
    final store = ref.watch(appStoreInstanceProvider).timer;
    void onChange() {
      if (!ref.mounted) return;
      state = TimerSnapshot.from(store);
    }

    store.addListener(onChange);
    ref.onDispose(() => store.removeListener(onChange));
    return TimerSnapshot.from(store);
  }
}

/// 待处置提醒镜像。
final reminderSnapshotProvider =
    NotifierProvider<ReminderSnapshotNotifier, ReminderSnapshot>(
  ReminderSnapshotNotifier.new,
);

class ReminderSnapshotNotifier extends Notifier<ReminderSnapshot> {
  @override
  ReminderSnapshot build() {
    final store = ref.watch(appStoreInstanceProvider).reminder;
    void onChange() {
      if (!ref.mounted) return;
      state = ReminderSnapshot.from(store);
    }

    store.addListener(onChange);
    ref.onDispose(() => store.removeListener(onChange));
    return ReminderSnapshot.from(store);
  }
}

/// 更新状态机镜像。
final updateSnapshotProvider =
    NotifierProvider<UpdateSnapshotNotifier, UpdateSnapshot>(
  UpdateSnapshotNotifier.new,
);

class UpdateSnapshotNotifier extends Notifier<UpdateSnapshot> {
  @override
  UpdateSnapshot build() {
    final store = ref.watch(appStoreInstanceProvider).update;
    void onChange() {
      if (!ref.mounted) return;
      state = UpdateSnapshot.from(store);
    }

    store.addListener(onChange);
    ref.onDispose(() => store.removeListener(onChange));
    return UpdateSnapshot.from(store);
  }
}
