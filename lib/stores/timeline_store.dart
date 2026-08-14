/// 时间线 store（模块 3b）：任意范围的条目查询缓存。
///
/// 职责：
/// - [loadRange]：加载 [start, end) 范围未删条目（时间线/统计明细用）；
/// - 缓存失效：dataRevision 变更自动重新加载；时钟 tick 不驱动（时间线
///   是已结束条目的浏览视图，范围总时长不随时间增长——仅 dataRevision 失效）；
/// - 编辑走 TimerStore（本 store 无写路径）。
library;

import 'package:flutter/foundation.dart';

import '../data/repositories/time_entry_repository.dart';
import '../viewmodels/time_entry.dart';
import 'data_revision.dart';

/// 时间线 store：范围条目缓存 + dataRevision 驱动刷新。
class TimelineStore extends ChangeNotifier {
  TimelineStore({
    required this.entries,
    required this.dataRevision,
  }) {
    _dataRevisionListener = () {
      if (_range != null) {
        loadRange(_range!.$1, _range!.$2);
      }
    };
    dataRevision.addListener(_dataRevisionListener);
  }

  final TimeEntryRepository entries;
  final DataRevision dataRevision;

  late final VoidCallback _dataRevisionListener;

  bool _disposed = false;
  (DateTime, DateTime)? _range;
  List<TimeEntry> _rangeEntries = const [];
  bool _loadFailed = false;

  /// 当前范围条目（startAt 升序；dataRevision 后自动刷新）。
  List<TimeEntry> get entriesForRange => _rangeEntries;

  /// 当前已加载范围（null = 尚未加载）。
  (DateTime, DateTime)? get loadedRange => _range;

  /// 最近一次加载失败。
  bool get loadFailed => _loadFailed;

  /// 加载 [start, end) 范围条目。
  Future<void> loadRange(DateTime start, DateTime end) async {
    if (_disposed) return;
    _range = (start, end);
    final loaded = await entries.entriesForRange(start, end);
    if (_disposed) return;
    _rangeEntries = List.unmodifiable(loaded);
    _loadFailed = false;
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    dataRevision.removeListener(_dataRevisionListener);
    super.dispose();
  }
}
