# 开发进度记录

> 供中断后快速恢复。权威细节以 `TimeTrack2 从零重建执行计划（完整最终版）.md` 为准；
> 开发纪律见 `AGENTS.md`（逐模块确认、ocr 审查循环至清零、无用户指示不 push）。

## 当前状态（2026-08-15）

**阶段 0-1 完成并推送**（ocr 全模块清零，200 测试）：
- viewmodels（领域模型 deletedAt/parentId/容错）→ utils（CLI 解析器/SemVer/时间/SHA-256）→ constants（配置/指令定义）→ data（drift 8 表 + 5 仓储）
- 门禁：analyze 0 / 测试全绿 / Windows Release 构建通过

**阶段 2（请求与更新）全部完成并合并 main，阶段门禁三过**：
- **analyze 0 issues / 全量 530 测试绿 / `flutter build windows` 构建通过**

**阶段 3（stores）全部完成并合并 main，阶段门禁三过**：
- **analyze 0 issues / 全量 705 测试绿**（阶段末 701 + 全仓库扫描新增 4 用例）
- **全仓库总 ocr 扫描（56 文件 215 评论）处置完毕，7 轮增量复审收敛**（末 2 轮无新增 high/medium）
- main HEAD：`6071b73`（PR #11 合并）

| 阶段 | 模块 | 内容 | PR | 状态 |
|---|---|---|---|---|
| 2a | 同步包 + 文件互通（SyncBundle codec/LWW 合并/归一化调用链） | #2 | 已合并 |
| 2b | LAN 同步（dart:io 协议/配对码/限流/私网白名单/真 HttpServer 测试） | #2 | 已合并 |
| 2c | 云同步 + OTP 认证 + supabase schema（6 表镜像/递归软删触发器 greatest()/RLS/增量索引） | #3 | 已合并 |
| 2c' | 后台自动记录数据层（`time_entries.is_auto` + `tracking_rules` 表 + `sync_enabled` per-rule 开关 + 引擎行级过滤 + 删除单调时间/索引补齐） | #4 | 已合并 |
| 2d | AI 预留（LlmClient 接口 + LlmCapability 能力矩阵 + OpenAI 兼容骨架诚实拒绝 stream/useTools） | #5 | 已合并 |
| 2e | 更新系统（update.json 清单/流式下载+总字节双层上限/SHA-256 边收边算/Windows staging 两阶段安装/Android FileProvider 安装器） | #6 | 已合并 |
| 2f | 保留期清理 + VACUUM（sync 守卫 userId 分区/isUtc 校验/FK 引用完整性/阈值驱动/retentionDays 接缝） | #7 | 已合并 |
| 3a | 基础 store：UndoStore（快照 diff/两阶段恢复/级联单条 undo/事务化 applier）+ ClockStore + DataRevision | #8 | 已合并 |
| 3b | 领域 store：Stats/Category/Settings/Today/Timeline/Timer + StatsRepository | #9 | 已合并 |
| 3c | 编排 store：SyncStore + UpdateStore（显式状态迁移表）+ TrackingStore（轮询/匹配器/ForegroundDetector） | #10 | 已合并 |
| 3d | 收尾：CommandDispatcher（21 指令路由 + 窄接口 SyncNowProvider/UpdateActions）+ AppStore 聚合 + dataRevision 三类来源收口 | #11 | 已合并 |

**2e/2f 关键设计点（实现勿破坏）**：
- 2e：zip-slip 多层防护 + zip bomb 双层+压缩后大小+条目数上限（全部条目计数/解压前检查）、staging 目录名纯函数校验（Win32 尾部空格点号折叠）、applyStaging 入参路径校验（防误传 programDir）+ **数据/程序目录分离校验（大小写不敏感，前置到备份之前）**、Link 备份链接本身、陈旧备份清理、下载总字节上限（contentLength 前置 + 流式累计）+ **实收字节校验**、manifest 流式消费（防缓冲期 OOM）+ 总时限 + 体积上限、`autoUncompress=false`、HandshakeException 层级（SDK 源码实证 `extends TlsException`，`on TlsException` 已覆盖）
- 2f：cutoff=min(保留截止,同步游标) 严格小于、userId 分区删除谓词（共享设备隔离）+ 分区游标（`last_sync_at:<userId>`）、isUtc 损坏游标校验、blocked 集（存活/软删未传播阻塞父删除，activities 三引用方向 + link.categoryId 对称）+ **跨用户子引用排除**（FK 违约防回滚）、墓碑子 parentId 置空不刷新 updatedAt（防伪造同步增量）、IN 分块 500、VACUUM 阈值 1000 + checkpoint busy 校验 + 失败隔离、retentionDays 覆盖回退 + 上界钳制 3650、同用户引用不变式声明

**阶段 3 关键设计点（实现勿破坏）**：
- **dataRevision 三类来源收口**：用户操作 / 同步导入（syncNow/import 成功后 bump）/ undo 恢复均递增共享修订号（不变式 9，修"同步后 UI 不刷新"历史坑）；单调递增 setter（回退拒绝）
- **UndoStore**：快照 diff、两阶段恢复（validate 全部通过后再 apply，失败整体回滚）、`_executing` 互斥（await 前抢占）、删除分类递归级联 = 一条 undo 记录、redo 清空、冲突校验（目标行已删/状态不符拒绝）
- **TimerStore**：写路径（switch/stop/add/split/merge/delete）统一 `_tryBeginWrite()/_endWrite()` 互斥（防并发写污染 undo 快照）；运行段保留原 id（LWW 防双运行）；零时长/未来条目软删
- **CommandDispatcher（铁律 7 落位）**：21 指令路由（计时/撤销/同步/互通/更新/分类/映射规则）；活动名→id 映射（重名歧义明确失败，错误随 record 返回不落共享字段）；`category_update` 补全（含 `--root=true` 移回顶级）；`--at/--sync` 取值校验；export/import `--path` 通道
- **UpdateStore**：显式迁移表 `Map<UpdateState, Set<UpdateState>>`（非法迁移抛 StateError），进度作为字段而非 enum 拆分，check/download/install 重入保护
- **SyncStore**：authStateStream 订阅 + `_pendingSyncUserId` 重放（pending != 本次捕获用户才重放）、清理限频（last_cleanup_at）、`_runCleanup` 统一互斥、启动编排（seed/rollover/cache 加载/静默更新检查）
- **并发安全**：settings save 防重入 + undo 基准从库重读（修同步覆盖）；category reload 去重（bump 触发 + seq 乱序防护）+ try/catch 兜底；today 重试退避 + hasRunning 失败隔离；clock tick 异常隔离（防 Timer 被取消）
- **业务一致性**：LWW 事务内读-判-写；删除永远赢（unknown 墓碑仍参与 LWW）；未分配单例事务内复查（防并发升级被改写）；one-off 自动软删读-判-写包事务；split 读-判-写包事务（防陈旧快照覆盖/复活已删行）

## 全仓库总扫描处置记录（2026-08-15，`ocr scan` 56 文件 215 评论）

**属实缺陷修复（约 45 条，8 个 commit，`d814c41`…`23ef13b`）**：
- **critical**：`AppBuildConfig.getString` 非 const 调用恒返默认值——SUPABASE_URL/ANON_KEY/UPDATE_MANIFEST_URL **从未真正注入**（云同步恒离线）。改为 const 字段直接引用
- **high**：LAN 同步无互斥（可交错合并致数据回退）、activity 仓储未分配竞态×2 + one-off 软删未包事务、cleanup 跨用户 parentId 篡改（补 userId 分区谓词 + 跨用户子引用 FK 排除）、tracking_rule unknown 墓碑短路（删除不落地，改仅存活行跳过）、时间条目裁剪运行段随机 id（改运行段保原 id）、app_store 占位 dataDir 在程序目录内（移出到系统临时目录）、clock tick 异常取消 Timer、command_dispatcher `_lastIdError` 共享可变竞态（改 record 返回）
- **medium（约 25 条）**：导入/导出路径安全（符号链接解析/50MB 上限/原子写 rename）、LAN 配对码先校验后消耗、LAN 响应累计超时（防 slow-loris）+ 多地址按序回退、cloud_sync 单行脏数据隔离（前置校验 isUtc）+ user_id 类型 fail-fast、LLM baseUrl 编码绕过（`%2e`/`%5c`）、OTP 解析异常收口、sync_status 自愈回退保留 lastError（仅推进时清）、408/425 瞬态 4xx 可重试、`category_update` 指令补全、导入链接缺失父兜底、exportBundle 只读事务快照一致、signOut 网络段超时、token 刷新延迟清理身份守卫收紧、verifyEmailOtp 非预期异常兜底等
- **low（约 20 条）**：LAN scheme 前缀识别（`localhost:9000` 放行 / `https:…` 拒绝，IPv6 十六进制收紧）、staging 名尾部空格拒绝、checkWritable 唯一探测名 + try/finally、farFutureDate/maxDateTime UTC 构造、`--at` 非法格式显式报错、`--sync` 取值校验、5 分钟容差收敛常量、utcString 正则复用 + fail-fast 等

**误报排除（硬证据，非"我觉得不对"）**：drift `where()` 多次调用按 `&` 合并不抛错（源码 query.dart:344）；drift 嵌套事务复用外层 zone 不抛错（源码 connection_user.dart:494）；Dart 3.12 final bool 局部变量空值提升（最小复现 analyze 0）；app.dart 冒烟测试已存在

**7 轮复审收敛轨迹**：一轮审修复引入 8 high → 二轮 1 high+3 medium → 三轮 2 high+1 medium（测试缺陷）→ 四轮 2 medium → 五轮 1 medium+1 low → 六轮 1 low → 七轮 **0 评论**。末 2 轮无新增 high/medium，按停循环判据收尾

## 阶段 3 已知边界（如实声明，归后续阶段/已挂起）

- **偏移分页 keyset 化**（remote_tables）：同步期间远端新写入致翻页窗口漂移漏行（文档已披露，唯一恢复 = 全量重拉；接口破坏性变更挂起）
- **LAN 配对 TLS / 记录级归属校验**：局域网嗅探抢配对 + 已授权客户端可伪造高 updatedAt 记录覆盖（LAN 对等信任模型边界，已修注释如实标注）
- **token 明文落库**（sync_peers.token `text()`）：flutter_secure_storage 化属平台层，挂起
- **OTP 注册状态枚举**（shouldCreateUser:false 二元响应）：服务端限流/统一响应配合，已注释声明接受
- **同步等值决胜**（updated_at 完全相等时收敛规则）/ **周期全量重拉机制**：阶段 3 编排显式权衡，注释标注
- **`tryInstallApk` 平台守卫级入口**（TOCTOU/父级链接兜底）：阶段 4 实现（现显式 UnsupportedError）
- **Android Manifest/FileProvider 配置**、**Windows 安装器真实目录注入（main 装配）**、**AI key 入库（flutter_secure_storage）**：阶段 4
- **后台自动记录平台检测层**（Windows FFI 轮询 / Android usage_stats + specialUse 前台服务）：阶段 3/4
- **同步超时活锁**（syncTimeout 墙钟总时长，Future.timeout 不取消底层）：编排层动态放大超时挂起

## 下一阶段（阶段 4 UI）预告

- components（公共组件，无业务状态）/ pages（壳/计时/今日/时间线/统计/设置/登录）/ routes（go_router StatefulShellRoute 保活 5 主页面 + 深链预留）/ 本地化（ARB 中英，铁律 6）/ Android Manifest + FileProvider / main 装配真实目录
- 实现前先报要点，确认后开工

## 关键约定（实现勿破坏）

- 三通道（云/LAN/文件）统一行级 LWW：`updated_at` 比较，删除=软删行推进 updated_at 传播（无独立删除列表）
- 云同步：since 单游标（`last_sync_at:<userId>` 分区）增量 + 分页 1000 + 先拉后推 + 推送批量防旧 + 指数退避 3 次
- 时间列 text 存固定 6 位微秒 UTC ISO8601（字典序=时间序，utcString 单一转换点；**isUtc 校验**——无偏移字符串按本地时区解析会失真）
- 旧数据互通只走 `.timetrack.json`（schema_version 1..2，解析先于写库）
- 保留不变式：离线优先 / 软删统一 deleted_at / 跨天拆分+运行中跨日滚转 / 条目带活动快照 / 双向 LWW 删除永远赢 / undo 单条级联 / 唯一未分配活动 / UUID+UTC / dataRevision 缓存失效 / LAN 手动启动 / 保留期清理+VACUUM / 数据程序目录分离 / 分类 parentId 层级
- 铁律 7：全部操作经 CLI 指令系统统一分发（UI/快捷键/深链/未来 AI 收敛同一通道）

## 提交纪律

- 每模块一个 Conventional Commit；合并到 main 走 feature 分支 + PR（用户审批）；未经用户明确指示不 push 除 feature 分支以外的任何分支
- ocr 审查：日常 `--commit` 增量、模块门禁 `--from main --to` 分支 diff、全仓库 `ocr scan`；属实缺陷清零 + 误报硬证据排除；停循环=连续 2 轮无新增属实 high/medium
