/// 远程表访问抽象：云同步编排（CloudSyncEngine）只依赖此网关，不触达
/// supabase client——编排逻辑可注入 mock 网关做单元测试。
///
/// 网关覆盖 5 张业务表 + 配置单例（profile_settings），行均为
/// viewmodels `toMap` 形态的 `Map<String, Object?>`（字段键与本地模型一致）。
///
/// 约束：
/// - `table` 仅允许 5 张业务表 + `profile_settings`（实现必须白名单校验，
///   拒绝未知值——防误操作非白名单表）；
/// - `ids` / `rows` 单次传入**有界**（建议 ≤ 500）：实现按固定块**内部分批**
///   （`fetchRemoteUpdatedAt` 的 `id in` 分批、`upsertRows` 分批 upsert），
///   不因单次超大列表一次打爆请求——但内存占用与请求次数随列表长度线性
///   增长，调用方仍应分批传入（全量数据一次传入会显著放大往返次数）；
/// - 增量拉取按 **(updated_at, 次级唯一键) 复合排序**（次级键防同时间戳行
///   跨页乱序；常规表 id，profile_settings 用 user_id），偏移分页在同步期间
///   远端新写入时窗口会漂移（可能重复/漏行）。
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
  /// 默认分页大小（**单一事实来源**）：所有实现的上限必须 ≥ 该值——否则
  /// 调用方省略 pageSize 时会被实现以 ArgumentError 拒绝（同步失败）。
  /// Supabase 实现当前上限（remoteMaxPageSize=999）与之相等；实现上限
  /// 下探时须同步本常量（一致性由测试锁定，见 remote_tables_retry_test）。
  static const defaultPageSize = 999;

  /// 增量拉取某表行：`user_id = userId AND updated_at >= since`，按
  /// **(updated_at, 次级唯一键) 复合升序**偏移分页（每页 [pageSize]）。
  /// [since] 为 null 时全量拉取。
  ///
  /// 排序的次级键 = 行唯一列（常规表 `id`；`profile_settings` 无 id 列，
  /// 用 `user_id`——实现特判），防多条行 updated_at 相同时跨页乱序。
  /// 偏移分页在同步期间远端新写入时会偏移翻页窗口（可能重复/漏行）——
  /// **调用方逐条 LWW 应用（按行身份键整行替换）即幂等**：偏移窗口漂移产生
  /// 的重复行反复应用结果一致（不污染本地数据）；漏行不出现于任何页、无法
  /// 靠合并恢复，属已接受的边界——**下轮兜底范围**：仅 `updated_at` 晚于
  /// 游标的行会被下轮增量重拉，落在已读区间内的漏行须远端再变更或全量
  /// 重拉才能恢复（游标推进为本轮实际处理行最大 updated_at，不覆盖该窗口）；
  /// **[page] 非负、[pageSize] 为正且不超过实现上限（Supabase 实现为 999，
  /// 受服务端 max-rows 约束）为前置条件**（实现必须校验，违规抛 ArgumentError）。
  ///
  /// [pageSize] 默认 [defaultPageSize]：与 Supabase 实现上限一致（接口默认值
  /// 不应超过**任一**实现的上限，否则调用方省略 pageSize 时会被该实现拒绝——
  /// 真正有约束力的是上限最小的实现，见 [defaultPageSize] 文档）；
  /// 其他实现可放宽，但调用方省略时应得到可用的合理页大小。
  ///
  /// 结果语义：仅返回属于 [userId] 的行（实现必须过滤，防越权读取）；
  /// 行均为 `toMap` 形态，`updated_at` 键为固定 6 位微秒 UTC ISO8601。
  Future<RemoteRowsPage> fetchRowsSince({
    required String table,
    required String userId,
    DateTime? since,
    int pageSize = defaultPageSize,
    int page = 0,
  });

  /// 批量查询远端 updated_at（推送防旧）：返回行身份 → 远端 updated_at。
  ///
  /// **缺失 id 的语义**：结果中无对应条目 = **远端无此行**（已删除/从未存在），
  /// 调用方应走**插入分支**（upsert 新行/恢复）——不可把"缺失"理解为
  /// "远端已有更新"而跳过（否则本地新行永远不会被插入/恢复）。
  ///
  /// [idKey] 为行身份列（默认 `id`；profile_settings 无 id 列，用 `user_id`）。
  /// 返回值的 updated_at 已归一化为 UTC。
  Future<Map<String, DateTime>> fetchRemoteUpdatedAt({
    required String table,
    required String userId,
    required List<String> ids,
    String idKey = 'id',
  });

  /// 批量 upsert 行（推送；行自带 user_id/updated_at）。
  ///
  /// **强制归属契约**：实现必须**无条件把每行 user_id 覆盖为 [userId]**
  /// （忽略行内原值，纵深防御）——调用方传入他人 user_id 的行不得越权写入
  /// 他人数据（云端 RLS 仍作最终防线）；云端 LWW 由 updated_at 列比较——
  /// 客户端负责比较。
  Future<void> upsertRows({
    required String table,
    required String userId,
    required List<Map<String, Object?>> rows,
  });
}
