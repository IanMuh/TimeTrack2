# 开发进度记录

> 供中断后快速恢复。权威细节以 `TimeTrack2 从零重建执行计划（完整最终版）.md` 为准；
> 开发纪律见 `AGENTS.md`（逐模块确认、ocr 审查循环至清零、无用户指示不 push）。

## 当前状态（2026-08-14）

**阶段 0-1 完成并推送**（ocr 全模块清零，200 测试）：
- viewmodels（领域模型 deletedAt/parentId/容错）→ utils（CLI 解析器/SemVer/时间/SHA-256）→ constants（配置/指令定义）→ data（drift 8 表 + 5 仓储）
- 门禁：analyze 0 / 测试全绿 / Windows Release 构建通过

**阶段 2（请求与更新）全部完成并合并 main，阶段门禁三过**：
- **analyze 0 issues / 全量 530 测试绿 / `flutter build windows` 构建通过**
- main HEAD：`784bee6`（PR #7 合并）

| 模块 | 内容 | PR | 状态 |
|---|---|---|---|
| 2a | 同步包 + 文件互通（SyncBundle codec/LWW 合并/归一化调用链） | #2 | 已合并 |
| 2b | LAN 同步（dart:io 协议/配对码/限流/私网白名单/真 HttpServer 测试） | #2 | 已合并 |
| 2c | 云同步 + OTP 认证 + supabase schema（6 表镜像/递归软删触发器 greatest()/RLS/增量索引） | #3 | 已合并 |
| 2c' | 后台自动记录数据层（`time_entries.is_auto` + `tracking_rules` 表 + `sync_enabled` per-rule 开关 + 引擎行级过滤 + 删除单调时间/索引补齐） | #4 | 已合并 |
| 2d | AI 预留（LlmClient 接口 + LlmCapability 能力矩阵 + OpenAI 兼容骨架诚实拒绝 stream/useTools） | #5 | 已合并 |
| 2e | 更新系统（update.json 清单/流式下载+总字节双层上限/SHA-256 边收边算/Windows staging 两阶段安装/Android FileProvider 安装器） | #6 | 已合并 |
| 2f | 保留期清理 + VACUUM（sync 守卫 userId 分区/isUtc 校验/FK 引用完整性/阈值驱动/retentionDays 接缝） | #7 | 已合并 |

**2e/2f 关键设计点（实现勿破坏）**：
- 2e：zip-slip 多层防护 + zip bomb 双层+压缩后大小+条目数上限（全部条目计数/解压前检查）、staging 目录名纯函数校验（Win32 尾部空格点号折叠）、applyStaging 入参路径校验（防误传 programDir）、Link 备份链接本身、陈旧备份清理、下载总字节上限（contentLength 前置 + 流式累计）、manifest 流式消费（防缓冲期 OOM）+ 总时限 + 体积上限、`autoUncompress=false`、HandshakeException 层级（SDK 源码实证 `extends TlsException`，`on TlsException` 已覆盖）
- 2f：cutoff=min(保留截止,同步游标) 严格小于、userId 分区删除谓词（共享设备隔离）+ 分区游标（`last_sync_at:<userId>`）、isUtc 损坏游标校验、blocked 集（存活/软删未传播阻塞父删除，activities 三引用方向 + link.categoryId 对称）、墓碑子 parentId 置空不刷新 updatedAt（防伪造同步增量）、IN 分块 500、VACUUM 阈值 1000 + checkpoint busy 校验 + 失败隔离、retentionDays 覆盖回退 + 上界钳制 3650、同用户引用不变式声明

## 阶段 2 已知边界（如实声明，归后续阶段）
- **同步水位**：cleanup cutoff 严格小于假设 `deleted_at < 游标` 即已传播——同步窗口内新建墓碑的精确水位对齐归阶段 3 `cloud_sync_engine`
- **zip 流式解码**（decodeBytes 物化阶段内存防护）/ 全表 DELETE 分批（长锁）：后续优化
- **失败文案 code 化**（AppResult.code）随 r14 全量落地；本轮测试有意文案耦合处已注明
- **`tryInstallApk` 平台守卫级入口**（TOCTOU/父级链接兜底）：阶段 4 实现（现显式 UnsupportedError）
- **Android Manifest/FileProvider 配置**、**LAN/云更新编排 UI**：阶段 4
- **更新状态机枚举与编排**（UpdateStore）：阶段 3 stores
- **后台自动记录平台检测层**（Windows FFI 轮询 / Android usage_stats + specialUse 前台服务）：阶段 3/4

## 下一阶段（阶段 3 stores）预告
- AppStore 聚合 + 各功能状态类（计时/今日/时间线/统计/设置/更新状态机）+ 刷新编排 + 时钟 + undo 栈 + **CLI 指令分发器**（铁律 7：UI/快捷键/深链/AI 统一通道，扩展 = 注册指令不改核心）
- 触发编排落位：清理服务（last_cleanup_at 限频）、云/LAN/文件同步编排、更新检查/安装编排
- 实现前先报要点，确认后开工

## 关键约定（实现勿破坏）
- 三通道（云/LAN/文件）统一行级 LWW：`updated_at` 比较，删除=软删行推进 updated_at 传播（无独立删除列表）
- 云同步：since 单游标（`last_sync_at:<userId>` 分区）增量 + 分页 1000 + 先拉后推 + 推送批量防旧 + 指数退避 3 次
- 时间列 text 存固定 6 位微秒 UTC ISO8601（字典序=时间序，utcString 单一转换点；**isUtc 校验**——无偏移字符串按本地时区解析会失真）
- 旧数据互通只走 `.timetrack.json`（schema_version 1..2，解析先于写库）
- 保留不变式：离线优先 / 软删统一 deleted_at / 跨天拆分+运行中跨日滚转 / 条目带活动快照 / 双向 LWW 删除永远赢 / undo 单条级联 / 唯一未分配活动 / UUID+UTC / dataRevision 缓存失效 / LAN 手动启动 / 保留期清理+VACUUM / 数据程序目录分离 / 分类 parentId 层级

## 提交纪律
- 每模块一个 Conventional Commit；合并到 main 走 feature 分支 + PR（用户审批）；未经用户明确指示不 push 除 feature 分支以外的任何分支
- ocr 审查：日常 `--commit` 增量、模块门禁 `--from main --to` 分支 diff；属实缺陷清零 + 误报硬证据排除；停循环=连续 2 轮无新增属实 high/medium
