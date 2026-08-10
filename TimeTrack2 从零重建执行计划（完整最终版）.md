# TimeTrack2 从零重建执行计划（完整最终版 · 含执行注意事项）

## 目标
在 `D:\MyAPP\TimeTrack2` 从零重建 TimeTrack，功能与现项目等价，并实现：**完整应用更新系统**（检查→下载/进度→校验→安装→重启）、**层级分类系统**（分类可嵌套 + 树统计/显示选项，分类管理与事项选择合并交互）、**CLI 风格指令系统**、**AI 二期预留**。技术栈保留、模块化架构保留、导航用 go_router、数据层用 drift + SQLite（单一新 schema）。现有项目仅作参照，**不修改**。具体实现方式在开发各模块时与你确认，不逐行照抄。

## 目录结构（10 目录 + 职责）
```
TimeTrack2/lib/
├── main.dart          # 依赖组装 + 入口
├── app.dart           # MaterialApp + 主题 + 路由
├── api/               # 存放请求：supabase（云同步+认证）、lan（协议/服务器/客户端）、update（清单/下载器/校验器）、ai/（LlmClient 接口预留）
├── assets/            # 存放资源：图标、图片、ARB 文案源文件
├── components/        # 存放公共组件（无业务状态，参数注入；含分类树选择器、更新进度卡、对话框）
├── constants/         # 存放常量：编译配置、默认值/阈值/端口、存储键、枚举存储值、主题令牌、指令定义、更新配置
├── data/              # 存放本地数据访问层：drift 数据库、仓储、同步包合并、文件互通、清理、平台更新安装器
├── pages/             # 存放页面：壳、计时、今日、时间线、统计、设置、登录
├── routes/            # 存放路由配置：go_router（5 主页面壳保活 + 深链预留）
├── stores/            # 存放全局状态组件：各功能状态类 + AppStore 聚合 + 刷新编排 + 时钟 + undo 栈 + 命令分发器 + 更新状态机
├── utils/             # 存放工具类：Result、日期扩展、版本解析、格式化、CLI 文本解析器、SHA-256
└── viewmodels/        # 存放类型文件：领域模型（纯类型，含 parentId）+ 统计聚合类型 + 指令类型 + 更新清单类型
```
依赖方向（下不依赖上）：`viewmodels / utils / constants / assets` ← `data / api` ← `stores` ← `pages / components` ← `routes` → `app.dart → main.dart`。

## 已确认的全部关键决策
1. **数据层**：drift + SQLite；单一新 schema；表结构 Dart 类声明，schema 版本由 drift 管理；**sqlite3 默认捆绑**（仅 drift + sqlite3 3.x，不复制 winsqlite3 钩子，去掉已废弃的 sqlite3_flutter_libs）
2. **删除策略（全面改进）**：`deleted_at` 时间戳替代布尔位；删除在事务内手动逐层级联软删；同步"删除永远赢"（并发更新不复活）；保留期清理（超期归档表→物理删除）+ 定期 VACUUM + WAL journal_size_limit
3. **撤销实现（本地 undo 栈解耦）**：快照 diff 存内存/本地库，回滚恢复快照而非反写主表；删活动/删分类不做全表快照
4. **性能（架构级默认）**：SQL 层聚合（GROUP BY 在库内完成）、分页/懒加载、dataRevision 失效缓存、部分索引只索引未删行
5. **文字配置化**：所有用户可见文字提取为 ARB 本地化（中/英）或常量配置，代码不硬编码
6. **LAN 主机手动启动**（不自动开启）
7. **AI 预留**：LlmClient 单接口（OpenAI 兼容覆盖 DeepSeek/Kimi/通义/Ollama）；密钥安全存储（flutter_secure_storage）；总结本地缓存表；AI 产出指令交命令分发器执行（不直接写库）
8. **更新系统**：update.json 清单源（raw.githubusercontent）；Windows staging+下次启动应用；Android FileProvider/ACTION_VIEW；强制/可选+忽略版本；下载安装自研
9. **层级分类（一期全量）**：ActivityCategory 含 parentId 自引用；删除分类递归软删子孙及 links；分类管理与事项选择合并交互（无独立管理页）

## 层级分类系统设计
- **数据层**：drift 表 `parent_id` 自引用 FK（`deleted_at` 沿用软删体系）；`ActivityCategory` 模型加 parentId（序列化缺键容错）；supabase schema 同步加 parent_id + 递归软删触发器（`WITH RECURSIVE`，`updated_at` 用 `greatest()` 保持 LWW 语义）
- **存储与状态**：分类缓存加 `childrenByParent`/`descendantsOf`/祖先链索引；删除分类→事务内递归软删子孙分类+各自 links；**分类变更 → dataRevision 递增**
- **撤销/同步兼容**：undo 快照按字段 diff 自动纳入 parentId；LWW 整行替换、bundle 序列化自动携带，旧 bundle 缺键容错
- **分类与事项选择合并交互（无独立管理页）**：
  - 计时器事项选择区 / 当前状态卡切换面板：集成分类树导航（先选分类→展示该分类及子分类下的事项），或事项按分类分组折叠
  - 新建/编辑/递归删除分类（含子孙确认）内嵌同一界面；空分类态显示"新建分类"入口
  - 分类变更实时刷新选择界面；无分类时退化回"全部事项"模式
- **树统计/显示选项（一期全量）**：
  - `StatsDimension` 加树聚合维度（按祖先链归并，label 拼接路径）
  - 统计页分类筛选树形化（缩进/层级分组）、折叠/展开显示选项
  - 覆盖全部屏宽（compact/medium/expanded 一致）

## 完整更新系统设计
### 发布侧
- tag `vX.Y.Z`；资产 `TimeTrack-windows-vX.Y.Z.zip` / `TimeTrack-android-vX.Y.Z.apk`
- 仓库根 `update.json`（raw.githubusercontent 拉取，规避 Releases API 60 req/h 限额）：`{ version, required, release_notes, windows:{url,sha256,size}, android:{url,sha256,size} }`
### 管线（平台共享，仅安装分平台）
| 环节 | 实现 |
|---|---|
| 检查 | 拉 update.json → 语义版本比较（保留 pre-release 规则）→ 忽略列表过滤 → available；启动静默 + 手动双通道 |
| 下载 | http 流式写临时目录，进度回调，失败指数退避重试 3 次，校验失败删重下 |
| 校验 | SHA-256 比对 update.json 内嵌值；安装前再确认包版本==清单版本 |
| Windows 安装 | zip 解压 staging → 数据目录写待安装标记 → 提示重启 → 下次启动（exe 未锁定）备份当前→staging 移入→删标记；标记异常回滚 |
| Android 安装 | APK 下载 cache → 校验 → FileProvider content:// URI → ACTION_VIEW + FLAG_GRANT_READ_URI_PERMISSION；Manifest 加 REQUEST_INSTALL_PACKAGES，未授权引导 ACTION_MANAGE_UNKNOWN_APP_SOURCES |
| 失败兜底 | 逐层降级，最终兜底浏览器打开 GitHub Releases 页面手动下载（保留现有能力） |
| 策略 | required 强制（不可跳过）；"忽略此版本"持久化；"稍后提醒" |
### 状态机扩展
`idle/checking/upToDate/available/failed` **+** `downloading(进度)/paused/verifying/installing/restartRequired`；设置页更新卡片展示下载进度条。

## CLI 风格指令系统
- 类命令行操作指令引擎，所有操作的统一程序化控制入口；**用户不直接操作**（无指令输入界面），供 AI、快捷键、深链、自动化、测试调用；扩展新操作 = 注册指令，不改核心代码
- 形态：`switch 学习` / `stop` / `add 开会 --start=15:00 --end=16:00 --note=周会` / `split <id> --at=15:30` / `delete <id>` / `merge` / `undo` / `redo` / `sync` / `export` / `import` / `update check` / `update install` / `category create --name=工作 --parent=...`
- 落位：`constants/commands/` 声明式指令定义 → `utils/commands/` 解析器（tokenize/校验/归一化）→ `viewmodels/commands/` 类型 → `stores/command_store.dart` 分发器（路由到各 store 既有写路径 → 自动继承撤销/日志/同步）
- UI 按钮、快捷键、深链、未来 AI 全部收敛到同一分发通道
- 解析器边界：`--note` 值含空格/引号、时间解析（"下午3点"/"15:00"）、活动名重名歧义（报错而非静默取第一个）、中英混合——必须有明确失败原因返回

## AI 预留（二期接入）
- 辅助记录：LLM 解析自然语言 → CommandInvocation → 命令分发器执行 → 用户可编辑草稿 → 走现有写路径（撤销/同步自动复用）
- 总结：只读查询 + 独立缓存表
- LlmClient 接口 + OpenAI 兼容（baseUrl/key/model 可配）+ 能力标记处理 provider 差异（通义 tools+stream 不可并用、Ollama 缺字段等）；密钥设置页输入存 flutter_secure_storage；启用时披露数据出境 + 提供本地 Ollama 选项；离线/失败禁用 AI 入口；总结结果本地缓存

## 技术选型
| 关注点 | 方案 |
|---|---|
| 导航 | go_router（StatefulShellRoute 保活 5 主页面） |
| 依赖注入 | get_it |
| 状态管理 | ChangeNotifier 状态类 + ListenableBuilder |
| 数据库 | drift + sqlite3 3.x（**默认捆绑**，Windows 用包自带 sqlite3.dll；不配置 winsqlite3 钩子；去掉 sqlite3_flutter_libs） |
| 云同步/认证 | supabase_flutter |
| LAN | dart:io HttpServer/HttpClient + JSON 协议 |
| 更新 | http 流式下载 + crypto(SHA-256) + 平台安装器（自研） |
| 图表/文件选择 | fl_chart / file_selector |
| 本地化 | flutter_localizations + ARB |
| 密钥存储（二期） | flutter_secure_storage |
| AI（二期） | 手写 http 薄封装实现 chat/completions |

## 执行阶段（从底到顶，每阶段验证通过再进入下一阶段）
- **阶段 0 骨架**：flutter create（windows+android）→ 配置依赖（drift/drift_flutter/build_runner 等，不含 sqlite3_flutter_libs）→ 建 10 目录 → 可运行空壳
- **阶段 1 底层**：viewmodels 领域类型（含 deleted_at、parentId）+ 指令/更新清单类型 → utils（CLI 解析器、SHA-256）→ constants（指令定义、更新配置、主题令牌）→ data（drift 单一 schema + 仓储：软删/事务递归级联/跨天拆分/重叠裁剪/滚转）
- **阶段 2 请求与更新**：api 云同步（删除永远赢）/LAN/AI 接口预留 + api/update（清单/下载/校验）+ data/update（平台安装器）+ 同步包合并/文件互通/清理 + supabase schema（含层级分类）
- **阶段 3 全局状态**：stores 各功能状态类（含分类树缓存/变更→dataRevision）+ AppStore 编排 + undo 栈 + CommandDispatcher + UpdateStore（扩展状态机+策略）
- **阶段 4 UI**：components（分类树选择器、更新进度卡等）→ pages（计时器/当前状态卡分类事项合并选择、统计树维度与显示选项、更新设置卡片）→ routes → 本地化 → Android Manifest/FileProvider
- **阶段 5 收尾**：`flutter analyze` + `flutter test` 全绿 → Windows/Android 双平台构建与冒烟（含更新流程人工验证）
- **阶段 6（二期）**：AI 解析自然语言→命令分发执行 + AI 总结缓存

## 执行注意事项（全阶段遵守）
### 执行前准备
1. **sqlite3 策略（已修正）**：TimeTrack2 用 drift + sqlite3 3.x **默认捆绑库**，不复制老项目的 `hooks.user_defines.sqlite3 source:system name_windows:winsqlite3` 配置，也不引入 `sqlite3_flutter_libs`（该包对 3.x 已废弃）。默认捆绑功能稳定可预测，代价仅是 Windows zip 多几百 KB sqlite3.dll
2. **环境确认**：drift 依赖 build_runner 代码生成，需 Dart SDK ≥ 3.4；开工前 `flutter --version` 确认
3. **新目录隔离**：`D:\MyAPP\TimeTrack2` 独立 git init，分阶段 commit；绝不在 TimeTrack 内部建项目
4. **老项目只读**：整个重建期间不修改 `D:\MyAPP\TimeTrack`（含 dist 产物、pubspec.lock），避免参照漂移
5. **数据兼容边界**：TimeTrack2 为全新 schema（drift 单一版本），**不兼容老项目 SQLite 文件**；老数据进新库走文件互通导入 `.timetrack.json`，不走库迁移——写入发布说明

### 阶段纪律
6. **阶段门禁**：每阶段结束 `flutter analyze` + 该阶段测试全绿才进下一阶段，不带债前进
7. **阶段 0 空壳必须真能运行**（不只 analyze 通过），后续所有阶段依赖它做运行验证
8. **逐模块确认**：功能等价 ≠ 逐行相同，每个模块实现前先向你报要点，你确认后写

### 阶段关键技术风险
9. **drift 首次配置**：优先用 `drift_flutter` 包（自动处理 Windows/Android NativeDatabase 初始化），避免手写平台分支；build_runner 生成代码纳入版本管理
10. **递归软删 + 撤销交互**：删除父分类递归软删子孙在 undo 栈必须是**一条记录**（标签"删除分类"），不能拆成多条快照——否则 undo 半恢复（只恢复父、子孙残留）；重点测试此路径
11. **分类变更 → dataRevision**：老项目已知坑（分类改完统计不刷新），阶段 1 就把链路打通
12. **update.json 的 sha256 必须与实际文件一致**：发布流程脚本化生成 update.json，手工维护易出错（校验不过→无法更新）
13. **Android FileProvider 配置全**：file_paths.xml + manifest（REQUEST_INSTALL_PACKAGES、provider 声明、grantUriPermissions），漏一个 API 24+ 安装即崩
14. **supabase 与本地 schema 镜像**：本地 drift schema 与 schema.sql 必须一致，递归软删触发器用 WITH RECURSIVE 且 updated_at 保持 greatest() LWW 语义；测试断言锁定一致性
15. **CLI 解析器边界**：--note 含空格/引号、时间解析（下午3点/15:00）、活动名重名歧义、中英混合——解析器返回明确失败原因
16. **Windows staging 安装前提是目录可写**：程序目录不可写（如 Program Files）时需可写性检查并降级提示（或降级"打开下载页"）；数据目录（%APPDATA%）与程序目录分离是铁律，待安装标记文件放数据目录
17. **go_router 版本锁定**：StatefulShellRoute API 在各大版本差异大，先定版本再写路由，避免中途升级重构

### 配置与安全
18. **.gitignore 提前写好**：不提交 SUPABASE_URL/ANON_KEY、AI key、本地 *.sqlite、dist/ 构建产物
19. **--dart-define 默认值**：UPDATE_MANIFEST_URL 等默认指向公开地址（本仓库 raw.githubusercontent），可被覆盖；AI key 永不入编译参数

### 验收验证清单
20. **功能等价对照**：计时/跨天/撤销/同步/分类/更新六类核心行为逐项打勾验收
21. **更新流程人工冒烟**（阶段 5 必做）：检查→下载进度→SHA-256 校验→Windows staging→重启生效 / Android ACTION_VIEW→失败兜底浏览器打开 Releases
22. **双平台布局验证**：分类树选择器、统计树维度、更新进度卡在 compact/medium/expanded 三宽度无溢出（沿用老项目 adaptive_layout_test 思路）

## 保留不变式（行为级）
1. 离线优先：读写先落本地 SQLite，云/LAN 异步不阻塞
2. 软删除统一为 `deleted_at` 时间戳 + 更新 `updated_at`
3. 跨天拆分 + 运行中条目跨日滚转
4. 时间条目携带活动名/色快照
5. 同步双向 LWW + 删除永远赢
6. 撤销/重做：本地 undo 栈 + 冲突校验
7. 唯一未分配活动 + 相邻未分配条目合并
8. UUID 主键 + UTC ISO8601 时间存储
9. dataRevision 驱动 UI 缓存失效（分类变更必须递增）
10. LAN 主机手动启动
11. 保留期清理 + 定期 VACUUM 控制数据增长
12. 全部操作经 CLI 指令系统统一分发（UI/快捷键/AI 收敛同一通道）
13. 更新系统：数据与程序目录分离；下载校验一致才安装；失败逐层降级兜底浏览器；强制更新不可跳过
14. 分类层级：删除父分类递归软删子孙；分类/事项选择合并交互；树统计覆盖全屏宽