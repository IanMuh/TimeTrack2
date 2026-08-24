
import 'dart:io' show stderr;

import '../../constants/storage_keys.dart';
import '../../utils/result.dart';
import '../../viewmodels/profile_settings.dart';
import '../database/app_database.dart' hide ProfileSettings;
import 'repository_mappings.dart';

/// 配置文件仓储（单例 id=1 读写）。
class SettingsRepository with RepositoryMappings {
  SettingsRepository({required this.database});

  final AppDatabase database;

  /// 读取配置；无记录返回 [ProfileSettings.defaults]（不落库，首次写时才落）。
  Future<AppResult<ProfileSettings>> settings() async {
    try {
      final row = await _settingsRow();
      return AppSuccess(row == null ? ProfileSettings.defaults() : settingsFromRow(row));
    } catch (e) {
      return AppFailure('读取设置失败：$e');
    }
  }

  /// 保存配置（单例 upsert，id 恒 1）。
  Future<AppResult<ProfileSettings>> save(ProfileSettings settings) async {
    try {
      final updated = settings.copyWith(updatedAt: DateTime.now());
      await database.into(database.profileSettings).insertOnConflictUpdate(
            settingsToCompanion(updated),
          );
      return AppSuccess(updated);
    } catch (e) {
      return AppFailure('保存设置失败：$e');
    }
  }

  /// LWW 应用远端配置：仅当远端 updated_at 晚于本地才替换（保留远端 updatedAt，
  /// 不篡改为本地 now——否则旧数据会在后续 LWW 中"永久获胜"）。
  Future<AppResult<ProfileSettings>> applyIfRemoteNewer(
    ProfileSettings remote,
  ) async {
    try {
      // LWW 读-判-写同一事务：防比较后写入前本地新写入被旧远端覆盖。
      return await database.transaction(() async {
        final row = await _settingsRow();
        final local = row == null ? null : settingsFromRow(row);
        if (local == null || local.updatedAt.isBefore(remote.updatedAt)) {
          await database.into(database.profileSettings).insertOnConflictUpdate(
                settingsToCompanion(remote),
              );
          return AppSuccess(remote);
        }
        return AppSuccess(local);
      });
    } catch (e) {
      return AppFailure('同步设置失败：$e');
    }
  }

  /// 当前合并阈值（相邻未分配条目合并判定用）；异常回退默认值。
  ///
  /// **错误可观测（r 修复）**：与 settings()/applyIfRemoteNewer 的显式
  /// AppFailure 语义不同，本方法契约是 int（合并判定高频调用，失败回退默认
  /// 值不阻塞流程）——但静默回退会掩盖真实健康问题（库损坏/连接故障），
  /// 回退时记 stderr 供排障。
  Future<int> mergeNeighborThresholdMinutes() async {
    try {
      final row = await _settingsRow();
      return row?.mergeNeighborThresholdMinutes ??
          ProfileSettings.defaultMergeNeighborThresholdMinutes;
    } catch (e) {
      // ignore: avoid_print
      stderr.writeln('[settings] 读取合并阈值失败（回退默认值）：$e');
      return ProfileSettings.defaultMergeNeighborThresholdMinutes;
    }
  }

  Future<ProfileSettingsRow?> _settingsRow() async {
    final query = database.select(database.profileSettings)
      ..where((t) => t.id.equals(1));
    return query.getSingleOrNull();
  }

  // ---------------------------------------------------------------------------
  // Windows 关窗到托盘模式（批次 6 托盘；app_metadata 键值存储）
  // ---------------------------------------------------------------------------

  /// 读取关窗模式：`ask`（默认）/ `minimize` / `exit`。库内无值或取值
  /// 非法均回退 [TrayCloseMode.ask]——白名单唯一权威在 [TrayCloseMode]。
  Future<String> trayCloseMode() async {
    try {
      final row = await (database.select(database.appMetadata)
            ..where((t) => t.key.equals(AppMetadataKeys.closeToTrayMode)))
          .getSingleOrNull();
      final value = row?.value;
      if (value != null && TrayCloseMode.all.contains(value)) {
        return value;
      }
      return TrayCloseMode.ask;
    } catch (e) {
      // ignore: avoid_print
      stderr.writeln('[settings] 读取关窗模式失败（回退 ask）：$e');
      return TrayCloseMode.ask;
    }
  }

  /// 写入关窗模式（非法取值抛 ArgumentError——调用方 UI 白名单内传值）。
  Future<void> setTrayCloseMode(String mode) async {
    if (!TrayCloseMode.all.contains(mode)) {
      throw ArgumentError.value(mode, 'mode', '非法关窗模式');
    }
    await database.into(database.appMetadata).insertOnConflictUpdate(
          AppMetadataCompanion.insert(
              key: AppMetadataKeys.closeToTrayMode, value: mode),
        );
  }
}
