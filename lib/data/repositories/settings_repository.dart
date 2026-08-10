
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
  Future<int> mergeNeighborThresholdMinutes() async {
    try {
      final row = await _settingsRow();
      return row?.mergeNeighborThresholdMinutes ??
          ProfileSettings.defaultMergeNeighborThresholdMinutes;
    } catch (_) {
      return ProfileSettings.defaultMergeNeighborThresholdMinutes;
    }
  }

  Future<ProfileSettingsRow?> _settingsRow() async {
    final query = database.select(database.profileSettings)
      ..where((t) => t.id.equals(1));
    return query.getSingleOrNull();
  }
}
