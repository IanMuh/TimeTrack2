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
/// **游标与目标按 userId 分区**（键名 `lastSyncAt:<userId>`）：共享设备切换用户后，
/// 新用户不得复用上一用户的成功游标（否则增量窗口晚于新用户远端最新更新，
/// 拉取/推送永久漏行）；**lastError 同样按 userId 分区**（共享设备上互不串扰、
/// 不误清）；未传 userId（null）时使用全局键（默认/向后兼容）。
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
          // lastError 与游标/目标一样按 userId 分区：共享设备上用户 B 不得
          // 读到用户 A 的失败原因（信息串扰），也不得被 A 的 markSuccess
          // 清掉（"错误反映最近一次失败"不变量在共享设备场景成立）。
          _statusKey(AppMetadataKeys.lastSyncError, userId):
              AppMetadataKeys.lastSyncError,
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
              // 未来时间游标（旧版本写入/远端时钟偏差）显式失败：上层据此
              // 提示需重置，防以其为增量起点导致同步永久停滞（与 markSuccess
              // 的守卫对称）。
              if (parsed.isAfter(
                DateTime.now().toUtc().add(const Duration(minutes: 5)),
              )) {
                return AppFailure(
                  '同步游标时间不合理（晚于当前时间），需重置：${row.value}',
                );
              }
              // lastSuccessfulSyncAt 是增量同步游标，会被上层序列化传给远端：
              // 存储层固化 UTC 语义（parsed 已带偏移，直接返回，防 toLocal 后
              // 无时区后缀被远端按不同时区解析产生窗口偏移）。
              lastSyncAt = parsed;
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

  /// 记录一次成功的同步（推进分区游标 + 记目标；**仅真正推进时清错误**）。
  ///
  /// 单调性保护：若现有游标**不早于** [syncedAt]（乱序/相等/重复完成），不覆盖
  /// 游标与 lastTarget（防并发完成时后结束的旧同步回退游标、且目标与游标指向
  /// 的最近成功点不一致）；乱序/相等分支**保留 lastError**——本次成功并未晚于
  /// 失败时刻（游标未推进），清空会抹掉真实失败记录（"错误反映最近一次失败"）。
  Future<AppResult<void>> markSuccess({
    required DateTime syncedAt,
    required String target,
    String? userId,
  }) async {
    final trimmedTarget = target.trim();
    if (trimmedTarget.isEmpty) {
      return const AppFailure('同步目标不能为空');
    }
    // 合理性校验：syncedAt 不得晚于当前时间 + 容差（5 分钟）——远端时钟偏差/
    // 脏数据产生未来时间戳会推高游标，使后续所有真实同步被判"未推进"而永久
    // 漏同步（read() 一直返回未来游标，且无恢复路径）。
    if (syncedAt.toUtc().isAfter(DateTime.now().toUtc().add(
          const Duration(minutes: 5),
        ))) {
      return AppFailure('同步游标时间不合理（晚于当前时间）：$syncedAt');
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
          // 库中已有游标为未来时间（旧版本写入/远端时钟偏差）：后续所有真实
          // syncedAt 都判"未推进"而永久停滞且无恢复路径——显式失败并提示重置。
          if (existingAt.isAfter(
            DateTime.now().toUtc().add(const Duration(minutes: 5)),
          )) {
            return AppFailure(
              '同步游标时间不合理（晚于当前时间），需重置：${existing.value}',
            );
          }
          if (syncedAt.toUtc().isBefore(existingAt)) {
            // **乱序完成**（旧 syncedAt 早于现有游标）：不覆盖游标/目标，
            // **保留 lastError**——较早开始的慢同步乱序完成不得抹掉更新的
            // 失败记录（"错误反映最近一次失败"语义；正常推进分支才清错误）。
            return const AppSuccess(null);
          }
          if (syncedAt.toUtc().isAtSameMomentAs(existingAt)) {
            // **相等时间戳**（无新行空跑同步的确定性路径）：游标无需覆盖，
            // 但更新 lastTarget——"最近一次成功同步的目标"应反映本次成功
            //（防连续空跑后 lastTarget 停留在上次目标）；**保留 lastError**
            //（游标未推进，本次成功并未晚于失败时刻，清空会抹掉真实失败）。
            await database.batch((batch) {
              batch.insert(database.appMetadata, AppMetadataCompanion.insert(
                key: _statusKey(AppMetadataKeys.lastSyncTarget, userId),
                value: trimmedTarget,
              ), mode: InsertMode.insertOrReplace);
            });
            return const AppSuccess(null);
          }
        }
        // 游标真正推进：写入新游标/目标，并清该用户分区的错误。
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
            key: _statusKey(AppMetadataKeys.lastSyncError, userId),
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
  /// trim + 限制长度防键名膨胀/重复分区（共享设备游标隔离失效）。
  static String _statusKey(String base, String? userId) {
    final normalized = userId?.trim();
    if (normalized == null || normalized.isEmpty) return base;
    if (normalized.length > 128) {
      throw ArgumentError('userId 过长，无法生成游标分区键');
    }
    return '$base:$normalized';
  }

  /// 记录一次失败（只记错误，**不清游标**）。
  ///
  /// [message] 必须非空（trim 后）：空串会静默清掉已有错误，破坏
  /// "失败不清游标/成功后清错误"的状态不变量。
  /// lastError 与游标一样按 userId 分区（共享设备上互不串扰）。
  Future<AppResult<void>> markFailure(String message, {String? userId}) async {
    final trimmed = message.trim();
    if (trimmed.isEmpty) {
      return const AppFailure('失败原因不能为空');
    }
    try {
      await database.into(database.appMetadata).insert(
            AppMetadataCompanion.insert(
              key: _statusKey(AppMetadataKeys.lastSyncError, userId),
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
