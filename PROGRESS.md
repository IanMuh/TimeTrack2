# 开发进度记录

> 供中断后快速恢复。权威细节以 `TimeTrack2 从零重建执行计划（完整最终版）.md` 为准；
> 开发纪律见 `AGENTS.md`（逐模块确认、ocr 审查循环至清零、无用户指示不 push）。

## 当前状态（2026-08-12）

**阶段 0-1 完成并推送**（ocr 全模块清零，200 测试）：
- viewmodels（领域模型 deletedAt/parentId/容错）→ utils（CLI 解析器/SemVer/时间/SHA-256）→ constants（配置/指令定义）→ data（drift 8 表 + 5 仓储）
- 门禁：analyze 0 / 测试全绿 / Windows Release 构建通过

**阶段 2 进行中（2a/2b/2c 已合并 main，2c' 待开始）**：
- 2a 同步包 + 文件互通：已合并 main
- 2b LAN：已合并 main（PR #2）；协议/服务器/客户端 + 真 HttpServer 测试
- 2c 云同步：已合并 main（PR #3）；ocr 增量 r50→r55 收敛至 0 评论 + 分支门禁 39 条（含 1 critical schema 0x、1 high 校验触发器）全部修复复验；381 测试
  - `api/supabase/`：SyncBackend 抽象 + NoopSyncBackend、CloudSyncEngine（先拉后推/推送防旧/游标=最大行时间/in-flight 互斥/settings 归属过滤）、RemoteTableGateway 抽象 + Supabase 实现、SupabaseAuthService（OTP 登录/快照流/脱敏）、SyncStatusStore（单事务读/单调性/未来游标自愈/损坏显式失败）
  - `supabase/schema.sql`：6 表镜像 + 递归软删触发器（WITH RECURSIVE + greatest() LWW + pg_trigger_depth 嵌套守卫）+ 分类/活动级联软删 links + 外键校验（仅引用字段变更时 + 显式归属）+ RLS + 增量索引
- **2c' 后台自动记录数据层（已批准，待开始）**：TimeEntry 加 `is_auto` 列 + 新增 `tracking_rules` 表（`sync_enabled` per-rule 同步开关）+ 同步引擎行级过滤（规则进云同步：schema.sql + RLS + RemoteTables 白名单 + memory_remote + 引擎测试扩展）
  - 背景：用户新增需求「应用后台运行时查看前台程序、自动记录事项」，已确认双平台（Windows/Android）+ 全自动 + 规则可配置进/不进同步；方案调研完成（Windows：dart:ffi + win32 轮询 GetForegroundWindow；Android：usage_stats + specialUse 前台服务 + UsageStats 特殊权限）；平台检测层归阶段 3/4（见执行计划「后台自动记录设计」）

## 阶段 2 剩余模块（按序）
- 2c' 后台自动记录数据层（见上）
- 2d AI 预留：`api/ai/` LlmClient 接口 + OpenAI 兼容骨架
- 2e 更新：`api/update/`（清单/下载/校验）+ `data/update/`（Windows staging/Android FileProvider 安装器）
- 2f 清理：`data/cleanup/` 保留期 180 天 + VACUUM

## 阶段 3/4 新增落点（后台自动记录，登记非本期）
- 阶段 3：前台检测状态机（ForegroundDetector 接口 + 规则匹配 + 生成记录指令，接入 CommandDispatcher）
- 阶段 4：规则配置页 + 授权引导页（Android 使用情况访问/Windows 说明）+ 托盘驻留关窗不退出 + Android 前台服务常驻通知 + Windows FFI 检测器；阶段 5 增补后台自动记录验收（Play 受限权限声明 + 隐私政策 + Data safety）

## 关键约定（实现勿破坏）
- 三通道（云/LAN/文件）统一行级 LWW：`updated_at` 比较，删除=软删行推进 updated_at 传播（无独立删除列表）
- 云同步：since 单游标（last_successful_sync_at）增量 + 分页 1000 + 先拉后推 + 推送批量防旧 + 指数退避 3 次
- 时间列 text 存固定 6 位微秒 UTC ISO8601（字典序=时间序，utcString 单一转换点）
- 旧数据互通只走 `.timetrack.json`（schema_version 1..2，解析先于写库）
- 阶段 2 不做：更新状态机编排（阶段 3 stores）、UI（阶段 4）、Android Manifest/FileProvider（阶段 4）、AI 密钥（二期）

## 提交纪律
- 每模块一个 Conventional Commit；未经用户明确指示不 push（最多 commit）
