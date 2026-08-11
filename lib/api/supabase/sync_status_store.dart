/// 同步状态存储：SyncStatus（lastSuccessfulSyncAt/lastError/lastTarget）落
/// `app_metadata` 表（随库备份；技术选型无 shared_preferences）。
///
/// 游标语义（计划模块 2c）：
/// - **失败不清游标**：拉取/推送失败只记录 lastError，`lastSuccessfulSyncAt`
///   保持不变——下次同步从上次成功点继续，不丢数据也不重发已确认行；
/// - **从未同步则全量**：游标为 null 时上层判定全量拉取；
/// - 目标标识 [SyncTarget]：记录最近一次成功同步的目标（supabase/lan）。
library;

import 'package:drift/drift.dart';

import '../../constants/storage_keys.dart';
import '../../data/database/app_database.dart';
import '../../utils/result.dart';

/// 云同步状态（本地持久化视图）。
class SyncStatus {
  const SyncStatus({
    this.lastSuccessfulSyncAt,
    this.lastError,
    this.lastTarget,
  });

  /// 最近一次成功同步完成时刻（增量游标起点）；null = 从未同步。
  final DateTime? lastSuccessfulSyncAt;

  /// 最近一次同步失败原因（成功后清除）。
  final String? lastError;

  /// 最近一次成功同步的目标（[SyncTarget] 取值；null = 未同步过）。
  final String? lastTarget;

  bool get hasSynced => lastSuccessfulSyncAt != null;

  SyncStatus copyWith({
    DateTime? lastSuccessfulSyncAt,
    bool clearLastSyncAt = false,
    String? lastError,
    bool clearLastError = false,
    String? lastTarget,
    bool clearLastTarget = false,
  }) {
    // 未传字段回退原值（与项目其他模型 copyWith 的 ?? this.x + clear 标志
    // 组合一致）：防止只更新单个字段时静默清空游标/目标（违背"失败不清游标"）。
    return SyncStatus(
      lastSuccessfulSyncAt: clearLastSyncAt
          ? null
          : (lastSuccessfulSyncAt ?? this.lastSuccessfulSyncAt),
      lastError:
          clearLastError ? null : (lastError ?? this.lastError),
      lastTarget:
          clearLastTarget ? null : (lastTarget ?? this.lastTarget),
    );
  }
}

/// 同步状态读写（app_metadata key-value）。
class SyncStatusStore {
  SyncStatusStore({required this.database});

  final AppDatabase database;

  /// 读取当前同步状态（3 个 key 点查，**单事务**保证快照一致——防各次 await
  /// 之间被写入交错读到互相矛盾的快照）。
  Future<AppResult<SyncStatus>> read() async {
    try {
      return await database.transaction(() async {
        DateTime? lastSyncAt;
        String? lastError;
        String? lastTarget;
        for (final key in [
          AppMetadataKeys.lastSyncAt,
          AppMetadataKeys.lastSyncError,
          AppMetadataKeys.lastSyncTarget,
        ]) {
          final row = await (database.select(database.appMetadata)
                ..where((t) => t.key.equals(key)))
              .getSingleOrNull();
          if (row == null) continue;
          switch (key) {
            case AppMetadataKeys.lastSyncAt:
              // 区分"键不存在"（正常 null）与"值损坏"（显式失败）：
              // 损坏值静默降级为"从未同步"会触发无谓全量拉取。
              final parsed = DateTime.tryParse(row.value);
              if (parsed == null) {
                return AppFailure('同步游标数据损坏，无法解析：${row.value}');
              }
              lastSyncAt = parsed;
            case AppMetadataKeys.lastSyncError:
              lastError = row.value.isEmpty ? null : row.value;
            case AppMetadataKeys.lastSyncTarget:
              lastTarget = row.value.isEmpty ? null : row.value;
          }
        }
        return AppSuccess(SyncStatus(
          lastSuccessfulSyncAt: lastSyncAt,
          lastError: lastError,
          lastTarget: lastTarget,
        ));
      });
    } catch (e) {
      return AppFailure('读取同步状态失败：$e');
    }
  }

  /// 记录一次成功的同步（推进游标 + 清错误 + 记目标）。
  ///
  /// 单调性保护：若现有游标**不早于** [syncedAt]（乱序/重复完成），不覆盖
  /// ——防并发完成时后结束的旧同步回退已推进的游标。
  Future<AppResult<void>> markSuccess({
    required DateTime syncedAt,
    required String target,
  }) async {
    try {
      return await database.transaction(() async {
        final existing = await (database.select(database.appMetadata)
              ..where((t) => t.key.equals(AppMetadataKeys.lastSyncAt)))
            .getSingleOrNull();
        final existingAt = existing == null
            ? null
            : DateTime.tryParse(existing.value);
        if (existingAt != null && !syncedAt.toUtc().isAfter(existingAt)) {
          // 游标未前进（乱序/重复完成）：不覆盖游标（防回退），只清错误 + 记目标。
          await database.batch((batch) {
            batch.insert(database.appMetadata, AppMetadataCompanion.insert(
              key: AppMetadataKeys.lastSyncTarget,
              value: target,
            ), mode: InsertMode.insertOrReplace);
            batch.insert(database.appMetadata, AppMetadataCompanion.insert(
              key: AppMetadataKeys.lastSyncError,
              value: '',
            ), mode: InsertMode.insertOrReplace);
          });
          return const AppSuccess(null);
        }
        await database.batch((batch) {
          batch.insert(database.appMetadata, AppMetadataCompanion.insert(
            key: AppMetadataKeys.lastSyncAt,
            value: syncedAt.toUtc().toIso8601String(),
          ), mode: InsertMode.insertOrReplace);
          batch.insert(database.appMetadata, AppMetadataCompanion.insert(
            key: AppMetadataKeys.lastSyncTarget,
            value: target,
          ), mode: InsertMode.insertOrReplace);
          batch.insert(database.appMetadata, AppMetadataCompanion.insert(
            key: AppMetadataKeys.lastSyncError,
            value: '',
          ), mode: InsertMode.insertOrReplace);
        });
        return const AppSuccess(null);
      });
    } catch (e) {
      return AppFailure('保存同步状态失败：$e');
    }
  }

  /// 记录一次失败（只记错误，**不清游标**）。
  Future<AppResult<void>> markFailure(String message) async {
    try {
      await database.into(database.appMetadata).insert(
            AppMetadataCompanion.insert(
              key: AppMetadataKeys.lastSyncError,
              value: message,
            ),
            mode: InsertMode.insertOrReplace,
          );
      return const AppSuccess(null);
    } catch (e) {
      return AppFailure('保存同步失败状态失败：$e');
    }
  }
}
