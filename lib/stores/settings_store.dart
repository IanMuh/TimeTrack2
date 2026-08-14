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
        onApplied?.call();
      }
      return result;
    }
    return const AppFailure('未知恢复目标类型');
  }

  /// 恢复写库成功后的回调（store 注入：bump dataRevision）。
  void Function()? onApplied;
}

/// 设置 store。
class SettingsStore extends ChangeNotifier {
  SettingsStore({
    required this.settings,
    required this.undo,
    required this.dataRevision,
  }) : _applier = SettingsChangeApplier(settings) {
    _applier.onApplied = () {
      if (_disposed) return;
      dataRevision.bump();
      reload(); // undo 恢复写库后刷新当前配置（_current 同步）
    };
  }

  final SettingsRepository settings;
  final UndoStore undo;
  final DataRevision dataRevision;

  final SettingsChangeApplier _applier;

  bool _disposed = false;

  ProfileSettings? _current;

  /// 当前配置（null = 尚未加载）。
  ProfileSettings? get current => _current;

  /// 加载配置（默认值回退）。
  Future<void> reload() async {
    if (_disposed) return;
    final result = await settings.settings();
    if (result case AppFailure<ProfileSettings> _) {
      return; // 加载失败保持旧值（默认值由仓储兜底）
    }
    _current = result.requireValue();
    notifyListeners();
  }

  /// 保存配置（updatedAt 显式推进到 now——LWW 不丢修改）。
  Future<AppResult<ProfileSettings>> save(ProfileSettings next) async {
    final before = _current;
    // copyWith 不自动推进 updatedAt：显式推进到 now（LWW 传播必需）。
    final now = DateTime.now();
    final withNow = next.copyWith(updatedAt: now);
    final result = await settings.save(withNow);
    if (result case AppFailure<ProfileSettings> failure) {
      return failure;
    }
    final saved = result.requireValue();
    _current = saved;
    if (before != null && before != saved) {
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
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}
