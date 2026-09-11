/// 数据全清服务（批次 4 设置页"清除全部数据"，契约 §4.5 备份与导出分区）。
///
/// 语义（危险操作，UI 层负责强制备份提示——本层不做交互决策）：
/// - **物理删除全部 6 张业务表行**（含未删行与墓碑）：activities /
///   time_entries / activity_categories / activity_category_links /
///   tracking_rules / action_logs；
/// - **重置配置**：profile_settings 单例行删除（下次读取回退默认值）；
/// - **保留设备标识**：`app_metadata.device_id` 是本机身份（非用户数据，
///   清除后重新生成会让云端出现"新设备"，破坏同步游标连续性）；其余
///   app_metadata 键（同步游标/忽略版本/清理水位）一并清除——数据已空，
///   旧游标无意义且会干扰全量同步判定；
/// - **同步对端清除**：sync_peers（LAN 配对关系随数据一并作废）；
/// - 单事务执行：任一步失败整体回滚（不清一半）。
///
/// 清除后由编排层（设置页）驱动各 store reload + dataRevision bump。
library;

import '../database/app_database.dart' hide ProfileSettings;
import '../../utils/result.dart';
import '../../constants/storage_keys.dart' show AppMetadataKeys;

class DataWipeService {
  DataWipeService({required this.database});

  final AppDatabase database;

  /// 执行全清，返回删除的总行数（展示用）。
  Future<AppResult<int>> wipeAll() async {
    try {
      var deleted = 0;
      await database.transaction(() async {
        // 6 张业务表全删（物理）。
        deleted += await database.delete(database.timeEntries).go();
        deleted += await database.delete(database.activityCategoryLinks).go();
        deleted += await database.delete(database.activityCategories).go();
        deleted += await database.delete(database.trackingRules).go();
        deleted += await database.delete(database.actionLogs).go();
        deleted += await database.delete(database.activities).go();
        // 配置重置 + 对端清除。
        deleted += await database.delete(database.profileSettings).go();
        deleted += await database.delete(database.syncPeers).go();
        // app_metadata：保留 device_id，清其余（游标/忽略版本/清理水位）。
        final keepId = AppMetadataKeys.deviceId;
        deleted += await (database.delete(database.appMetadata)
              ..where((t) => t.key.isNotIn([keepId])))
            .go();
      });
      return AppSuccess(deleted);
    } catch (e) {
      return AppFailure('清除数据失败：$e');
    }
  }
}
