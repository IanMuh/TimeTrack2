# 开发进度记录

> 供中断后快速恢复。权威细节以 `TimeTrack2 从零重建执行计划（完整最终版）.md` 为准；
> 开发纪律见 `AGENTS.md`（逐模块确认、ocr 审查循环至清零、无用户指示不 push）。

## 当前状态（2026-08-11）

**阶段 0-1 完成并推送**（ocr 全模块清零，200 测试）：
- viewmodels（领域模型 deletedAt/parentId/容错）→ utils（CLI 解析器/SemVer/时间/SHA-256）→ constants（配置/指令定义）→ data（drift 8 表 + 5 仓储）
- 门禁：analyze 0 / 测试全绿 / Windows Release 构建通过

**阶段 2 进行中（模块 2a、2b 完成，2c 待开始）**：
- 2a 同步包 + 文件互通：已完成、ocr 5 轮清零、212 测试、已推送（678f0b2）
  - `data/sync/`：SyncBundle（schema 严格 1..2）+ Codec（校验先于写库）+ BundleRepository（单事务行级 LWW + normalizeAfterMerge）
  - `data/interop/file_interop_service.dart`：.timetrack.json 导入导出（降级选目录）
  - `data/repositories/sync_peer_store.dart`：LAN 对端表
  - 仓储补：xxxSince 增量/全量含删导出/saveMergedEntry（逐段 LWW+悬挂回退）/3 归一化
- 2b LAN：已完成、ocr 3 轮清零（67 条）、248 测试、已提交本地（0b6eea9，未推送）
  - `api/lan/lan_sync_protocol.dart`：/health /pair /sync 端点、包络编解码、错误码 wireValue+statusCode 推导、私网白名单（IPv4 段/IPv6 链路本地·ULA·映射·回环等价形式/zone id 拒绝）、主机输入归一化（仅 http scheme、端口 1..65535、拒 userinfo、剥离 ?/#）
  - `api/lan/lan_sync_server.dart`：端口 8787..8797 候选+回退、6 位配对码 TTL5min 单次使用+绑定设备身份防冒用轮换、每 IP 限流+定期清扫、/sync Bearer 鉴权+source_device_id 校验+merge→normalize（失败 5xx 不返回收敛包）、body 双重超时+上限、错误脱敏不泄露内部细节
  - `api/lan/lan_sync_client.dart`：配对即自动同步、先存后清对端（clearLanClientPeersExcept）、token 字符白名单防头注入、响应体限长+超时、单次解析+connectionFactory 直连已校验 IP（消 TOCTOU）、异常全收敛 on Object
  - 测试：协议纯函数（白名单边界/归一化/包络一致性）+ 真 HttpServer 集成（配对/鉴权/限流/过期/单次/轮换/设备身份/413/双向收敛/删除传播/幂等）

## 阶段 2 剩余模块（按序）
- 2c 云同步：`api/supabase/` 抽象 SyncBackend + OTP 认证 + sync_status_store + `supabase/schema.sql`（6 表 + parent_id 递归软删触发器 greatest() LWW + RLS）+ mock 测试
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
