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
import '../../data/repositories/repository_mappings.dart';
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
///
/// **游标按 userId 分区**（键名 `lastSyncAt:<userId>`）：共享设备切换用户后，
/// 新用户不得复用上一用户的成功游标（否则增量窗口晚于新用户远端最新更新，
/// 拉取/推送永久漏行）；未传 userId（null）时使用全局键（默认/向后兼容）。
/// lastError 保持全局（最近一次同步失败，不分用户）。
class SyncStatusStore with RepositoryMappings {
  SyncStatusStore({required this.database});

  final AppDatabase database;

  /// 读取当前同步状态（按 userId 分区键点查，**单事务**保证快照一致——防
  /// 各次 await 之间被写入交错读到互相矛盾的快照）。
  Future<AppResult<SyncStatus>> read({String? userId}) async {
    try {
      return await database.transaction(() async {
        DateTime? lastSyncAt;
        String? lastError;
        String? lastTarget;
        final statusKeys = {
          _statusKey(AppMetadataKeys.lastSyncAt, userId):
              AppMetadataKeys.lastSyncAt,
          AppMetadataKeys.lastSyncError: AppMetadataKeys.lastSyncError,
          _statusKey(AppMetadataKeys.lastSyncTarget, userId):
              AppMetadataKeys.lastSyncTarget,
        };
        for (final entry in statusKeys.entries) {
          final row = await (database.select(database.appMetadata)
                ..where((t) => t.key.equals(entry.key)))
              .getSingleOrNull();
          if (row == null) continue;
          switch (entry.value) {
            case AppMetadataKeys.lastSyncAt:
              // 区分"键不存在"（正常 null）与"值损坏"（显式失败）：
              // 损坏值静默降级为"从未同步"会触发无谓全量拉取。
              // 严格校验带时区偏移（isUtc）：无偏移值被 Dart 按本地时区
              // 解析，游标单调比较会发生时区漂移。
              final parsed = DateTime.tryParse(row.value);
              if (parsed == null || !parsed.isUtc) {
                return AppFailure('同步游标数据损坏，无法解析：${row.value}');
              }
              lastSyncAt = parsed.toLocal();
              break;
            case AppMetadataKeys.lastSyncError:
              lastError = row.value.isEmpty ? null : row.value;
              break;
            case AppMetadataKeys.lastSyncTarget:
              lastTarget = row.value.isEmpty ? null : row.value;
              break;
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

  /// 记录一次成功的同步（推进分区游标 + 清错误 + 记目标）。
  ///
  /// 单调性保护：若现有游标**不早于** [syncedAt]（乱序/重复完成），不覆盖
  /// 游标与 lastTarget（防并发完成时后结束的旧同步回退游标、且目标与游标
  /// 指向的最近成功点不一致），只清错误。
  Future<AppResult<void>> markSuccess({
    required DateTime syncedAt,
    required String target,
    String? userId,
  }) async {
    final trimmedTarget = target.trim();
    if (trimmedTarget.isEmpty) {
      return const AppFailure('同步目标不能为空');
    }
    try {
      return await database.transaction(() async {
        final cursorKey = _statusKey(AppMetadataKeys.lastSyncAt, userId);
        final existing = await (database.select(database.appMetadata)
              ..where((t) => t.key.equals(cursorKey)))
            .getSingleOrNull();
        if (existing != null) {
          // 严格校验带时区偏移（readUtc 语义）：无偏移字符串会被 Dart 按
          // 本地时区解析，单调性比较产生时区漂移，可能误判游标未前进。
          final existingAt = DateTime.tryParse(existing.value);
          if (existingAt == null || !existingAt.isUtc) {
            // 与 read() 一致：损坏游标显式失败，不静默重置（防回退实际成功点）。
            return AppFailure('同步游标数据损坏，无法解析：${existing.value}');
          }
          if (!syncedAt.toUtc().isAfter(existingAt)) {
            // 游标未前进（乱序/重复完成）：不覆盖游标/目标，只清错误。
            await database.batch((batch) {
              batch.insert(database.appMetadata, AppMetadataCompanion.insert(
                key: AppMetadataKeys.lastSyncError,
                value: '',
              ), mode: InsertMode.insertOrReplace);
            });
            return const AppSuccess(null);
          }
        }
        await database.batch((batch) {
          batch.insert(database.appMetadata, AppMetadataCompanion.insert(
            key: cursorKey,
            value: utcString(syncedAt),
          ), mode: InsertMode.insertOrReplace);
          batch.insert(database.appMetadata, AppMetadataCompanion.insert(
            key: _statusKey(AppMetadataKeys.lastSyncTarget, userId),
            value: trimmedTarget,
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

  /// 生成分区键：userId 非 null 时 `base:<userId>`，否则原键。
  static String _statusKey(String base, String? userId) {
    if (userId == null || userId.isEmpty) return base;
    return '$base:$userId';
  }

  /// 记录一次失败（只记错误，**不清游标**）。
  ///
  /// [message] 必须非空（trim 后）：空串会静默清掉已有错误，破坏
  /// "失败不清游标/成功后清错误"的状态不变量。
  Future<AppResult<void>> markFailure(String message) async {
    final trimmed = message.trim();
    if (trimmed.isEmpty) {
      return const AppFailure('失败原因不能为空');
    }
    try {
      await database.into(database.appMetadata).insert(
            AppMetadataCompanion.insert(
              key: AppMetadataKeys.lastSyncError,
              value: trimmed,
            ),
            mode: InsertMode.insertOrReplace,
          );
      return const AppSuccess(null);
    } catch (e) {
      return AppFailure('保存同步失败状态失败：$e');
    }
  }
}
