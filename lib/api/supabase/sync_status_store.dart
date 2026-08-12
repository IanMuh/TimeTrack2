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

  /// 增量同步游标：**最近一次成功同步实际处理数据的最大 updated_at（高水位）**，
  /// 而非墙钟完成时刻（同步期间远端新增/本地更新的行 updated_at 必然 ≤ 该值，
  /// 下一轮 `>= 游标` 才不会漏行）；null = 从未同步。
  /// **例外（非严格高水位）**：唯一写方 CloudSyncEngine 存在两类
  /// 兜底——空全量同步写墙钟 startedAt、远端时钟偏快时截断到 startedAt，
  /// 此时**已处理行**的 updated_at 可**大于**游标（下轮靠 LWW 幂等重复处理）。
  /// 下游不得按"严格高水位"解读本字段（如用于裁剪/去重）。
  /// **字段名保留说明**：虽语义为高水位游标（非墙钟），字段名沿用
  /// `lastSuccessfulSyncAt`（历史命名，改名为 cursor 会波及 app_metadata
  /// 键/序列化契约——键 `last_sync_at` 已固化，见 [AppMetadataKeys.lastSyncAt]）；
  /// 文档与键注释已统一为游标语义。
  /// **升级迁移**：本键语义由"墙钟完成时刻"迁移为"高水位"——
  /// 存量库若存在旧版墙钟游标值，按高水位解释会跳过 updated_at ∈（真实
  /// 高水位, 墙钟时刻] 的行（静默漏同步）；**升级路径须对存量库做一次性
  /// 游标 reset（[SyncStatusStore.reset] 触发全量重同步，LWW 幂等不丢数据）**。
  /// 本项目从零重建（无存量库），该迁移归阶段 3 首次云同步前的升级逻辑。
  final DateTime? lastSuccessfulSyncAt;

  /// 最近一次同步失败原因（**游标真正推进时**清除——相等时间戳/乱序成功
  /// 分支不清，防抹掉游标未推进期间的真实失败记录）。
  /// **消费语义**：本字段 = "游标推进周期内的最近失败"，**非**
  /// "最近一次同步结果"——无新数据的空跑成功（相等分支）保留 lastError，
  /// 一次真实失败后可能跨多轮空跑长期残留（read() 呈 hasSynced=true +
  /// lastTarget 已更新 + lastError 非空）；阶段 3 消费方据此展示"最近失败"
  /// 而非"上次同步失败"。
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
///
/// **并发约束**：`markSuccess` 的读-改-写原子性依赖 drift 在**单连接**上串行化
/// 事务——仅支持单 AppDatabase 实例（阶段 3 编排在单实例内调用）；若未来以
/// 多 isolate/多实例打开同一库文件，两个事务可各自读到旧游标后并发写，较旧
/// syncedAt 可能后落盘回退游标（超出本类支持范围，需迁移为条件 UPDATE）。
///
/// **userId 入参契约（行为变更）**：空/空白/超长 userId 属调用方编程错误，
/// 各公开方法在**进入 try 之前直接抛 ArgumentError**（此前被 try 包装成
/// AppFailure 返回）——编程错误不被静默降级为普通运行期数据错误，且该路径
/// 不经 catch 掩盖（null 仍走全局键，语义不变）。
///
/// 失败文案常量（供测试引用做精确断言——不绑定具体措辞变化）。
abstract final class SyncStatusMessages {
  /// 游标损坏（无法解析/无时区偏移）失败前缀。
  static const cursorCorrupted = '同步游标数据损坏，无法解析：';

  /// 未来/不合理游标失败前缀（提示需重置）。
  static const cursorUnreasonable = '同步游标时间不合理（晚于当前时间）';
}

class SyncStatusStore with RepositoryMappings {
  SyncStatusStore({required this.database});

  final AppDatabase database;

  /// 读取当前同步状态（按 userId 分区键点查，**单事务**保证快照一致——防
  /// 各次 await 之间被写入交错读到互相矛盾的快照）。
  Future<AppResult<SyncStatus>> read({String? userId}) async {
    final normalized = _normalizeUserId(userId); // 编程错误在 try 之外直接抛
    try {
      return await database.transaction(() async {
        DateTime? lastSyncAt;
        String? lastError;
        String? lastTarget;
        final statusKeys = {
          _statusKey(AppMetadataKeys.lastSyncAt, normalized):
              AppMetadataKeys.lastSyncAt,
          // lastError 与游标/目标一样按 userId 分区：共享设备上用户 B 不得
          // 读到用户 A 的失败原因（信息串扰），也不得被 A 的 markSuccess
          // 清掉（"错误反映最近一次失败"不变量在共享设备场景成立）。
          _statusKey(AppMetadataKeys.lastSyncError, normalized):
              AppMetadataKeys.lastSyncError,
          _statusKey(AppMetadataKeys.lastSyncTarget, normalized):
              AppMetadataKeys.lastSyncTarget,
        };
        // 一次 IN 查询取齐三个状态键（单事务快照一致，降往返/持锁时间）。
        final rows = await (database.select(database.appMetadata)
              ..where((t) => t.key.isIn(statusKeys.keys.toList())))
            .get();
        final byKey = {for (final row in rows) row.key: row.value};
        for (final entry in statusKeys.entries) {
          final value = byKey[entry.key];
          if (value == null) continue;
          switch (entry.value) {
            case AppMetadataKeys.lastSyncAt:
              // 区分"键不存在"（正常 null）与"值损坏"（显式失败）：
              // 损坏值静默降级为"从未同步"会触发无谓全量拉取。
              // 严格校验带时区偏移（isUtc）：无偏移值被 Dart 按本地时区
              // 解析，游标单调比较会发生时区漂移。
              final parsed = DateTime.tryParse(value);
              if (parsed == null || !parsed.isUtc) {
                return AppFailure('${SyncStatusMessages.cursorCorrupted}$value');
              }
              // 未来时间游标（旧版本写入/远端时钟偏差）显式失败：上层据此
              // 提示需重置，防以其为增量起点导致同步永久停滞（与 markSuccess
              // 的守卫对称）。
              if (parsed.isAfter(
                DateTime.now().toUtc().add(const Duration(minutes: 5)),
              )) {
                return AppFailure(
                  '${SyncStatusMessages.cursorUnreasonable}，需重置：$value',
                );
              }
              // lastSuccessfulSyncAt 是增量同步游标，会被上层序列化传给远端：
              // 存储层固化 UTC 语义（parsed 已带偏移，直接返回，防 toLocal 后
              // 无时区后缀被远端按不同时区解析产生窗口偏移）。
              lastSyncAt = parsed;
              break;
            case AppMetadataKeys.lastSyncError:
              lastError = value.isEmpty ? null : value;
              break;
            case AppMetadataKeys.lastSyncTarget:
              lastTarget = value.isEmpty ? null : value;
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
    final normalized = _normalizeUserId(userId); // 编程错误在 try 之外直接抛
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
      return AppFailure('${SyncStatusMessages.cursorUnreasonable}：$syncedAt');
    }
    try {
      return await database.transaction(() async {
        final cursorKey = _statusKey(AppMetadataKeys.lastSyncAt, normalized);
        final existing = await (database.select(database.appMetadata)
              ..where((t) => t.key.equals(cursorKey)))
            .getSingleOrNull();
        if (existing != null) {
          // 严格校验带时区偏移（readUtc 语义）：无偏移字符串会被 Dart 按
          // 本地时区解析，单调性比较产生时区漂移，可能误判游标未前进。
          final existingAt = DateTime.tryParse(existing.value);
          if (existingAt == null || !existingAt.isUtc) {
            // 与 read() 一致：损坏游标显式失败，不静默重置（防回退实际成功点）。
            return AppFailure('${SyncStatusMessages.cursorCorrupted}${existing.value}');
          }
          // 库中已有游标为未来时间（旧版本写入/远端时钟偏差）：后续所有真实
          // syncedAt 都判"未推进"而永久停滞且无恢复路径——显式失败并提示重置。
          if (existingAt.isAfter(
            DateTime.now().toUtc().add(const Duration(minutes: 5)),
          )) {
            return AppFailure(
              '${SyncStatusMessages.cursorUnreasonable}，需重置：${existing.value}',
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
                key: _statusKey(AppMetadataKeys.lastSyncTarget, normalized),
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
            key: _statusKey(AppMetadataKeys.lastSyncTarget, normalized),
            value: trimmedTarget,
          ), mode: InsertMode.insertOrReplace);
          batch.insert(database.appMetadata, AppMetadataCompanion.insert(
            key: _statusKey(AppMetadataKeys.lastSyncError, normalized),
            value: '',
          ), mode: InsertMode.insertOrReplace);
        });
        return const AppSuccess(null);
      });
    } catch (e) {
      return AppFailure('保存同步状态失败：$e');
    }
  }

  /// userId 长度上限（**单一事实来源**）：`_statusKey` 与 `_normalizeUserId`
  /// 两处校验共用（防单处调整造成 debug/release 行为分叉或分区键长度口径
  /// 不一致）。
  static const _maxUserIdLength = 128;

  /// 生成分区键：userId 非 null 时 `base:<userId>`，否则原键（全局）。
  /// **双层校验（r50 措辞澄清）**：入口权威校验在 [_normalizeUserId]（各公开
  /// 方法在 try 之外统一调用一次）——这里**不重复 trim/长度检查作为主路径**，
  /// 但保留**防御兜底校验**（无 assert）：若未来新增调用点未先归一化就调用
  /// 本方法，未归一化的 userId 直接生成脏分区键会拆裂共享设备游标隔离——
  /// **debug 与 release 均直接抛 ArgumentError**（不依赖 assert）。两层语义
  /// 不同：入口校验是"调用方契约"（正常流程），本分支是"防御失效检测"
  ///（编程错误哨兵）。
  /// **契约说明**：四个公开方法（read/markSuccess/markFailure/reset）在 try
  /// 之前统一调用 [_normalizeUserId] 并传归一化结果；新增方法须遵循同一约定。
  /// **范围说明**：`normalized.length != userId.length` 仅捕获**首尾**
  /// 空白；含**内部空白**的 userId（如 `'user 1'`）无法在此识别（会生成
  /// 带空格的键）——属调用方约定边界（[_normalizeUserId] 同样只 trim 首尾）。
  /// **可达性（如实声明）**：当前四个公开方法均先经 [_normalizeUserId]
  /// 归一化（本分支不可达）；若未来新增方法在 try 内直接调用本方法且未
  /// 先归一化，抛出的 ArgumentError 会被外层 catch 包成 AppFailure（被静默
  /// 降级）——属已知边界，新增调用点须遵循"先归一化、try 之外校验"约定。
  static String _statusKey(String base, String? userId) {
    if (userId == null) return base;
    final normalized = userId.trim();
    if (normalized.isEmpty ||
        normalized.length != userId.length ||
        normalized.length > _maxUserIdLength) {
      // **不嵌入原始 userId（防 PII 泄露）**：本分支在四个公开方法归一化后
      // 不可达，但若未来新增调用点触发，携带邮箱/手机号等 PII 的 userId 会
      // 随 ArgumentError 被外层 catch 写入日志——只输出长度摘要（与
      // [_normalizeUserId] 的报错口径一致）。
      throw ArgumentError(
        'userId 未归一化（空白/空串/超长，长度 ${normalized.length}）'
        '——须先经 _normalizeUserId',
      );
    }
    return '$base:$normalized';
  }

  /// userId 归一化：null → null（未登录用全局键）；空白/超长 → 显式抛错
  /// （调用方 bug，与 null 语义区分——静默回落全局键会污染未登录状态）。
  /// 各公开方法在 try 之外调用一次并传归一化结果给 [_statusKey]。
  static String? _normalizeUserId(String? userId) {
    if (userId == null) return null;
    final normalized = userId.trim();
    if (normalized.isEmpty) {
      throw ArgumentError('userId 不能为空字符串，需显式传 null 使用全局键');
    }
    if (normalized.length > _maxUserIdLength) {
      throw ArgumentError('userId 过长，无法生成游标分区键');
    }
    return normalized;
  }

  /// 记录一次失败（只记错误，**不清游标**）。
  ///
  /// [message] 必须非空（trim 后）：空串会静默清掉已有错误，破坏
  /// "失败不清游标/成功后清错误"的状态不变量。
  /// lastError 与游标一样按 userId 分区（共享设备上互不串扰）。
  Future<AppResult<void>> markFailure(String message, {String? userId}) async {
    final normalized = _normalizeUserId(userId); // 编程错误在 try 之外直接抛
    final trimmed = message.trim();
    if (trimmed.isEmpty) {
      return const AppFailure('失败原因不能为空');
    }
    try {
      await database.into(database.appMetadata).insert(
            AppMetadataCompanion.insert(
              key: _statusKey(AppMetadataKeys.lastSyncError, normalized),
              value: trimmed,
            ),
            mode: InsertMode.insertOrReplace,
          );
      return const AppSuccess(null);
    } catch (e) {
      return AppFailure('保存同步失败状态失败：$e');
    }
  }

  /// 重置该用户分区的同步状态（游标 + 目标 + 错误）。
  ///
  /// 供"游标损坏/未来游标需重置"场景的恢复入口：清除分区键（userId 为 null
  /// 时清全局键），下次同步将从全量重新开始（LWW 幂等，不丢数据）。
  Future<AppResult<void>> reset({String? userId}) async {
    final normalized = _normalizeUserId(userId); // 编程错误在 try 之外直接抛
    try {
      await database.transaction(() async {
        for (final base in [
          AppMetadataKeys.lastSyncAt,
          AppMetadataKeys.lastSyncTarget,
          AppMetadataKeys.lastSyncError,
        ]) {
          await (database.delete(database.appMetadata)
                ..where((t) => t.key.equals(_statusKey(base, normalized))))
              .go();
        }
      });
      return const AppSuccess(null);
    } catch (e) {
      return AppFailure('重置同步状态失败：$e');
    }
  }
}
