import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../stores/category_store.dart';
import '../stores/reminder_store.dart';
import '../stores/settings_store.dart';
import '../stores/timer_store.dart';
import '../stores/update_store.dart';
import 'bootstrap.dart';
import 'stores.dart';


/// 运行中计时条目的**值快照**（只含壳层展示/判定需要的字段）。
///
/// 用值相等（而非条目对象身份）作为通知门槛：`TimerStore` 内部任何无关字段的
/// 变更都不会引起壳层重建；条目结束（entryId 变 null）或切换活动才通知。
class TimerSnapshot {
  const TimerSnapshot({
    this.entryId,
    this.activityId,
    this.startAt,
    this.activityName,
    this.activityColor,
  });

  factory TimerSnapshot.from(TimerStore store) {
    final running = store.runningEntry;
    return TimerSnapshot(
      entryId: running?.id,
      activityId: running?.activityId,
      startAt: running?.startAt,
      activityName: running?.activityNameSnapshot,
      activityColor: running?.activityColorSnapshot,
    );
  }

  /// 运行中条目 id；null = 空闲。
  final String? entryId;
  final String? activityId;
  final DateTime? startAt;

  /// 活动名/色快照（条目携带的历史快照，改名不改既往展示）。
  final String? activityName;
  final int? activityColor;

  bool get isRunning => entryId != null;

  @override
  bool operator ==(Object other) =>
      other is TimerSnapshot &&
      other.entryId == entryId &&
      other.activityId == activityId &&
      other.startAt == startAt &&
      other.activityName == activityName &&
      other.activityColor == activityColor;

  @override
  int get hashCode => Object.hash(
        entryId,
        activityId,
        startAt,
        activityName,
        activityColor,
      );

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
    final store = ref.watch(domainStoresProvider).timer;
    void onChange() {
      if (!ref.mounted) return;
      state = TimerSnapshot.from(store);
    }

    store.addChangeListener(onChange);
    ref.onDispose(() => store.removeChangeListener(onChange));
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
    final store = ref.watch(reminderStoreProvider);
    void onChange() {
      if (!ref.mounted) return;
      state = ReminderSnapshot.from(store);
    }

    store.onChanged = onChange;
    ref.onDispose(() {
      if (identical(store.onChanged, onChange)) store.onChanged = null;
    });
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
    final store = ref.watch(updateStoreProvider);
    void onChange() {
      if (!ref.mounted) return;
      state = UpdateSnapshot.from(store);
    }

    store.onChanged = onChange;
    ref.onDispose(() {
      if (identical(store.onChanged, onChange)) store.onChanged = null;
    });
    return UpdateSnapshot.from(store);
  }
}

/// 迁移期（B4c）设置/分类引擎的**实例访问器**。
///
/// 这两个 provider 只负责“拿到当前实例”，本身不触发重建；页面/分区在 build
/// 里 `ref.watch(settingsChangeProvider)`（或分类对应 change provider）拿到
/// 变更信号，再用 `ref.read(...StoreProvider)` 读最新值——等价于旧
/// `ListenableBuilder(listenable: store)` 的语义，但订阅面收在 provider 层。
final settingsStoreProvider = Provider<SettingsStore>(
  (ref) => ref.watch(domainStoresProvider).settings,
);

final categoryStoreProvider = Provider<CategoryStore>(
  (ref) => ref.watch(domainStoresProvider).category,
);

/// 设置变更计数：每次 `SettingsStore` 通知 +1，作为 build 的失效信号。
///
/// 用计数而不是直接暴露 store 实例：Provider 对相同实例做 `==` 过滤，依赖方
/// 不会重建；计数变化才能把通知传下去。
final settingsChangeProvider =
    NotifierProvider<SettingsChangeNotifier, int>(SettingsChangeNotifier.new);

class SettingsChangeNotifier extends Notifier<int> {
  @override
  int build() {
    final store = ref.watch(settingsStoreProvider);
    void onChange() {
      if (!ref.mounted) return;
      state = state + 1;
    }

    store.onChanged = onChange;
    ref.onDispose(() {
      if (identical(store.onChanged, onChange)) store.onChanged = null;
    });
    return 0;
  }
}

/// 分类树变更计数（`CategoryStore` 通知 → +1）。
final categoryChangeProvider =
    NotifierProvider<CategoryChangeNotifier, int>(CategoryChangeNotifier.new);

class CategoryChangeNotifier extends Notifier<int> {
  @override
  int build() {
    final store = ref.watch(categoryStoreProvider);
    void onChange() {
      if (!ref.mounted) return;
      state = state + 1;
    }

    store.onChanged = onChange;
    ref.onDispose(() {
      if (identical(store.onChanged, onChange)) store.onChanged = null;
    });
    return 0;
  }
}

/// 计时变更计数（手动会话保持/运行条目/写路径成功 → +1）。
final timerChangeProvider =
    NotifierProvider<TimerChangeNotifier, int>(TimerChangeNotifier.new);

class TimerChangeNotifier extends Notifier<int> {
  @override
  int build() {
    final store = ref.watch(timerStoreProvider);
    void onChange() {
      if (!ref.mounted) return;
      state = state + 1;
    }

    store.addChangeListener(onChange);
    ref.onDispose(() => store.removeChangeListener(onChange));
    return 0;
  }
}
/// 引擎变更计数（`SyncStore`）——`onChanged` → state+1。
final syncChangeProvider =
    NotifierProvider<SyncChangeNotifier, int>(SyncChangeNotifier.new);

class SyncChangeNotifier extends Notifier<int> {
  @override
  int build() {
    final store = ref.watch(syncStoreProvider);
    void onChange() {
      if (!ref.mounted) return;
      state = state + 1;
    }

    store.onChanged = onChange;
    ref.onDispose(() {
      if (identical(store.onChanged, onChange)) store.onChanged = null;
    });
    return 0;
  }
}

/// 引擎变更计数（`UpdateStore`）。
final updateChangeProvider =
    NotifierProvider<UpdateChangeNotifier, int>(UpdateChangeNotifier.new);

class UpdateChangeNotifier extends Notifier<int> {
  @override
  int build() {
    final store = ref.watch(updateStoreProvider);
    void onChange() {
      if (!ref.mounted) return;
      state = state + 1;
    }

    store.onChanged = onChange;
    ref.onDispose(() {
      if (identical(store.onChanged, onChange)) store.onChanged = null;
    });
    return 0;
  }
}

/// 引擎变更计数（`TrackingStore`）。
final trackingChangeProvider =
    NotifierProvider<TrackingChangeNotifier, int>(TrackingChangeNotifier.new);

class TrackingChangeNotifier extends Notifier<int> {
  @override
  int build() {
    final store = ref.watch(trackingStoreProvider);
    void onChange() {
      if (!ref.mounted) return;
      state = state + 1;
    }

    store.onChanged = onChange;
    ref.onDispose(() {
      if (identical(store.onChanged, onChange)) store.onChanged = null;
    });
    return 0;
  }
}

/// 引擎变更计数（`LanStore`）。
final lanChangeProvider =
    NotifierProvider<LanChangeNotifier, int>(LanChangeNotifier.new);

class LanChangeNotifier extends Notifier<int> {
  @override
  int build() {
    final store = ref.watch(lanStoreProvider);
    void onChange() {
      if (!ref.mounted) return;
      state = state + 1;
    }

    store.onChanged = onChange;
    ref.onDispose(() {
      if (identical(store.onChanged, onChange)) store.onChanged = null;
    });
    return 0;
  }
}

/// 计时引擎实例（写路径经命令分发；读取面走快照 provider）。
final timerStoreProvider = Provider<TimerStore>(
  (ref) => ref.watch(domainStoresProvider).timer,
);






