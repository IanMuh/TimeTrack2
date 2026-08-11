/// 远程表访问抽象：云同步编排（CloudSyncEngine）只依赖此网关，不触达
/// supabase client——编排逻辑可注入 mock 网关做单元测试。
///
/// 网关覆盖 5 张业务表 + 配置单例（profile_settings），行均为
/// viewmodels `toMap` 形态的 `Map<String, Object?>`（字段键与本地模型一致）。
///
/// 约束：
/// - `table` 仅允许 5 张业务表 + `profile_settings`（实现必须白名单校验，
///   拒绝未知值——防误操作非白名单表）；
/// - `ids` / `rows` 单次调用有界：实现负责内部分块（`id in` 分批、upsert 分批）。
library;

/// 一次拉取分页结果。
class RemoteRowsPage {
  const RemoteRowsPage({required this.rows, required this.hasMore});

  final List<Map<String, Object?>> rows;

  /// 是否还有后续页：**返回行数等于请求页大小**时可能为 true（调用方继续翻页；
  /// 最后一页恰好满页时会多一次空页请求以结束，属预期行为）。
  final bool hasMore;
}

/// 远程表网关。
abstract interface class RemoteTableGateway {
  /// 增量拉取某表行：`user_id = userId AND updated_at >= since`，按
  /// updated_at 升序**偏移分页**（每页 [pageSize]）。[since] 为 null 时全量拉取。
  ///
  /// 注意：偏移分页在同步期间远端新写入时会偏移翻页窗口（可能重复/漏行）——
  /// 调用方按 id 合并（LWW upsert 天然幂等）并接受该边界；[pageSize] 必须为正。
  Future<RemoteRowsPage> fetchRowsSince({
    required String table,
    required String userId,
    DateTime? since,
    int pageSize = 1000,
    int page = 0,
  });

  /// 批量查询远端 updated_at（推送防旧）：返回行身份 → 远端 updated_at。
  ///
  /// [idKey] 为行身份列（默认 `id`；profile_settings 无 id 列，用 `user_id`）。
  Future<Map<String, DateTime>> fetchRemoteUpdatedAt({
    required String table,
    required String userId,
    required List<String> ids,
    String idKey = 'id',
  });

  /// 批量 upsert 行（推送；行自带 user_id/updated_at）。实现必须把行强制归属
  /// [userId]（纵深防御）；云端 LWW 由 updated_at 列比较——客户端负责比较。
  Future<void> upsertRows({
    required String table,
    required String userId,
    required List<Map<String, Object?>> rows,
  });
}
