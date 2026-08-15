/// 设置 store（模块 3b）：配置文件读写（本地单例 id=1）。
///
/// 职责：
/// - 读取 [ProfileSettings]（默认值回退）；
/// - [save]：写库 + **updatedAt 显式推进到 now**（LWW 合并以 updatedAt
///   决胜负，copyWith 不自动推进——不推进会被远端版本覆盖而丢失）；
/// - undo 包装：恢复旧配置；dataRevision bump。
library;

import 'package:flutter/foundation.dart';

import '../data/repositories/settings_repository.dart';
import '../utils/result.dart';
import '../viewmodels/profile_settings.dart';
import 'data_revision.dart';
import 'undo_store.dart';

/// 设置恢复操作（3a 契约）。
class SettingsChange {
  const SettingsChange(this.settings);
  final ProfileSettings settings;
}

/// 设置恢复写库契约（3a [UndoApplier] 实现）。
class SettingsChangeApplier implements UndoApplier {
  SettingsChangeApplier(this._settings);

  final SettingsRepository _settings;

  @override
  Future<AppResult<void>> validate(Object? expected) async {
    // 单例配置行恒存在（id=1），冲突预检从简：无需比对（本地单例无并发
    // 写者；远端覆盖由 LWW 语义处理）。
    if (expected case SettingsChange _) {
      return const AppSuccess(null);
    }
    return const AppFailure('未知恢复目标类型');
  }

  @override
  Future<AppResult<void>> apply(Object? target) async {
    if (target case SettingsChange change) {
      final result = await _settings.save(change.settings);
      if (result.isSuccess) {
        // 回调携带恢复后的实体：store 同步 _current（避免 fire-and-forget
        // reload 的竞态——reload 失败/dispose 时 _current 与库不一致）。
        onApplied?.call(result.requireValue());
      }
      return result;
    }
    return const AppFailure('未知恢复目标类型');
  }

  /// 恢复写库成功后的回调（store 注入：bump dataRevision + 同步 _current）。
  void Function(ProfileSettings saved)? onApplied;
}

/// 设置 store。
class SettingsStore extends ChangeNotifier {
  SettingsStore({
    required this.settings,
    required this.undo,
    required this.dataRevision,
  }) : _applier = SettingsChangeApplier(settings) {
    _applier.onApplied = (saved) {
      if (_disposed) return;
      _current = saved; // 恢复写库后同步内存配置（与库一致）
      dataRevision.bump();
      notifyListeners();
    };
  }

  final SettingsRepository settings;
  final UndoStore undo;
  final DataRevision dataRevision;

  final SettingsChangeApplier _applier;

  bool _disposed = false;
  bool _saving = false; // save 防重入（并发保存以同一基准入栈冲突）
  int _reloadSeq = 0; // reload 请求序号（并发乱序防护）

  ProfileSettings? _current;

  /// 当前配置（null = 尚未加载）。
  ProfileSettings? get current => _current;

  /// 加载配置（默认值回退）。
  Future<void> reload() async {
    if (_disposed) return;
    final seq = ++_reloadSeq;
    final result = await settings.settings();
    if (result case AppFailure<ProfileSettings> _) {
      return; // 加载失败保持旧值（默认值由仓储兜底）
    }
    if (_disposed || seq != _reloadSeq) return; // await 期间 dispose/更新的 reload
    _current = result.requireValue();
    notifyListeners();
  }

  /// 保存配置（updatedAt 显式推进到 now——LWW 不丢修改）。
  Future<AppResult<ProfileSettings>> save(ProfileSettings next) async {
    // 防重入（模块门禁 medium）：连续 save（双击按钮）并发会以同一旧
    // _current 为 undo 基准入栈，undo/redo 历史与真实变更序列不一致。
    if (_saving) return const AppFailure('保存进行中，请稍后再试');
    _saving = true;
    try {
      // **undo 基准从库重读（模块门禁 medium）**：云同步经 applyIfRemoteNewer
      // 直写库不刷新 _current——用缓存基准会把远端更新回退丢失（与 LWW
      // 冲突）。始终从库读当前值作为基准。
      final existing = await settings.settings();
      final before = existing.isSuccess ? existing.requireValue() : _current;
      // copyWith 不自动推进 updatedAt：显式推进到 now（LWW 传播必需）。
      final now = DateTime.now();
      final withNow = next.copyWith(updatedAt: now);
      final result = await settings.save(withNow);
      if (result case AppFailure<ProfileSettings> failure) {
        return failure;
      }
      if (_disposed) return result; // await 期间可能已 dispose：不写缓存/不通知
      _reloadSeq++; // 使在途 reload 过期：其快照先于本次写，不能覆盖新值
      final saved = result.requireValue();
      _current = saved;
      // 业务字段有变化才记 undo（saved.updatedAt 恒推进为 now，直接 `!=`
      // 会使 no-op 保存也入栈——仅回滚时间戳，污染 undo/redo 栈）。
      if (before != null && !_sameBusinessFields(before, saved)) {
        undo.record(
          label: '修改设置',
          changes: [
            UndoChange(
              before: SettingsChange(before),
              after: SettingsChange(saved),
              applier: _applier,
            ),
          ],
        );
      }
      dataRevision.bump();
      notifyListeners();
      return result;
    } finally {
      _saving = false;
    }
  }

  /// 业务字段相等判定（排除 updatedAt/userId——恢复写库推进时间戳不代表
  /// 配置内容变化）。
  static bool _sameBusinessFields(ProfileSettings a, ProfileSettings b) {
    return a.reminderMinutes == b.reminderMinutes &&
        a.reminderIntervalMinutes == b.reminderIntervalMinutes &&
        a.reminderMethod == b.reminderMethod &&
        a.reminderTimeOfDayMinutes == b.reminderTimeOfDayMinutes &&
        a.mergeNeighborThresholdMinutes == b.mergeNeighborThresholdMinutes &&
        a.timezone == b.timezone;
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}
