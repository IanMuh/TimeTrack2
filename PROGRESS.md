# 开发进度记录

> 供中断后快速恢复。权威细节以 `TimeTrack2 从零重建执行计划（完整最终版）.md` 为准；
> 开发纪律见 `AGENTS.md`（逐模块确认、ocr 审查循环至清零、无用户指示不 push）。

## 当前状态（2026-08-11）

**阶段 0-1 完成并推送**（ocr 全模块清零，200 测试）：
- viewmodels（领域模型 deletedAt/parentId/容错）→ utils（CLI 解析器/SemVer/时间/SHA-256）→ constants（配置/指令定义）→ data（drift 8 表 + 5 仓储）
- 门禁：analyze 0 / 测试全绿 / Windows Release 构建通过

**阶段 2 进行中（2a/2b 已合并 main，2c 待审批，2d 待开始）**：
- 2a 同步包 + 文件互通：已合并 main
- 2b LAN：已合并 main（PR #2）；协议/服务器/客户端 + 真 HttpServer 测试
- 2c 云同步：已完成、ocr 2 轮清零（98 条）、280 测试、已推送 PR #3（待审批）
  - `api/supabase/`：SyncBackend 抽象 + NoopSyncBackend（未配置离线）、CloudSyncEngine
    （先拉后推/推送防旧/游标=最大行时间/in-flight 互斥/settings 归属过滤）、
    RemoteTableGateway 抽象 + Supabase 实现（uuid 归属/idKey/tie-breaker/onConflict/
    重试 3 次/表名白名单）、SupabaseAuthService（OTP 登录/快照流/脱敏）、
    SyncStatusStore（单事务读/单调性/损坏显式失败/lastTarget 仅成功写）
  - `supabase/schema.sql`：6 表镜像（user_id uuid、color bigint）+ 递归软删触发器
    （WITH RECURSIVE + greatest() LWW + FOR KEY SHARE）+ 3 校验触发器 + RLS + 增量索引
  - 测试：引擎 mock（先拉后推/分页精确/增量 since/删除传播双向/LWW/并发互斥/边界行）
    + 状态存储 + schema 结构锁定

## 阶段 2 剩余模块（按序）
- 2d AI 预留：`api/ai/` LlmClient 接口 + OpenAI 兼容骨架
- 2e 更新：`api/update/`（清单/下载/校验）+ `data/update/`（Windows staging/Android FileProvider 安装器）
- 2f 清理：`data/cleanup/` 保留期 180 天 + VACUUM

## 关键约定（实现勿破坏）
- 三通道（云/LAN/文件）统一行级 LWW：`updated_at` 比较，删除=软删行推进 updated_at 传播（无独立删除列表）
- 云同步：since 单游标（last_successful_sync_at）增量 + 分页 1000 + 先拉后推 + 推送批量防旧 + 指数退避 3 次
- 时间列 text 存固定 6 位微秒 UTC ISO8601（字典序=时间序，utcString 单一转换点）
- 旧数据互通只走 `.timetrack.json`（schema_version 1..2，解析先于写库）
- 阶段 2 不做：更新状态机编排（阶段 3 stores）、UI（阶段 4）、Android Manifest/FileProvider（阶段 4）、AI 密钥（二期）

## 提交纪律
- 每模块一个 Conventional Commit；未经用户明确指示不 push（最多 commit）
