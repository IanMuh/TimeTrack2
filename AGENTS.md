# TimeTrack2 项目规则（AGENTS.md）

TimeTrack 从零重建项目（时间追踪应用）。权威细节以仓库根目录 `TimeTrack2 从零重建执行计划（完整最终版）.md` 为准；本文档是开发期通用规则，两者冲突时以计划文档为准。

## 技术栈（阶段 0 锁定版本，不中途升级）
- Flutter 3.44.2 / Dart 3.12.2（build_runner 需 Dart ≥ 3.4）
- 状态管理：ChangeNotifier 状态类 + ListenableBuilder；导航：go_router（StatefulShellRoute 保活 5 主页面）；DI：get_it
- 数据：drift + sqlite3 3.x **默认捆绑**（不含 sqlite3_flutter_libs、不配 winsqlite3 钩子）；build_runner 生成代码纳入版本管理
- 云同步/认证：supabase_flutter；LAN：dart:io 自研（主机手动启动）；更新：http 流式下载 + crypto SHA-256 + 平台安装器自研
- 图表 fl_chart / 文件选择 file_selector / 本地化 flutter_localizations + ARB
- AI（二期）：手写 http 薄封装 + flutter_secure_storage

## 目录结构与依赖方向（下不依赖上，新增代码必须落位）
```
lib/
├── main.dart / app.dart
├── api/        # supabase（云同步+认证）、lan、update（清单/下载/校验）、ai/（预留）
├── assets/     # 图标、图片、ARB 文案源文件
├── components/ # 公共组件（无业务状态，参数注入）
├── constants/  # 编译配置、默认值/阈值/端口、存储键、枚举存储值、主题令牌、指令定义、更新配置
├── data/       # drift 数据库、仓储、同步包合并、文件互通、清理、平台更新安装器
├── pages/      # 壳、计时、今日、时间线、统计、设置、登录
├── routes/     # go_router（5 主页面壳保活 + 深链预留）
├── stores/     # 各功能状态类 + AppStore 聚合 + 刷新编排 + 时钟 + undo 栈 + 命令分发器 + 更新状态机
├── utils/      # Result、日期扩展、版本解析、格式化、CLI 文本解析器、SHA-256
└── viewmodels/ # 领域模型（纯类型，含 parentId）+ 统计聚合 + 指令类型 + 更新清单类型
```
依赖方向：`viewmodels / utils / constants / assets` ← `data / api` ← `stores` ← `pages / components` ← `routes` → `app.dart → main.dart`。

## 铁律
1. 老项目 `D:\MyAPP\TimeTrack` 只读：整个重建期间不修改（含 dist 产物、pubspec.lock），仅作参照
2. 阶段门禁：每阶段结束 `flutter analyze` 0 issues + 该阶段测试全绿，才进下一阶段；阶段 0 空壳必须真能运行
3. 逐模块确认：每个模块实现前先报要点，用户确认后写；功能等价 ≠ 逐行相同，不照抄老项目代码
4. TimeTrack2 独立 git 仓库（`D:\MyAPP\TimeTrack2`），分阶段 commit；绝不在老项目内部建新项目
5. 数据不兼容老 SQLite 文件：老数据进新库走 `.timetrack.json` 文件互通导入，不走库迁移
6. 所有用户可见文字提取为 ARB 本地化（中/英）或常量配置，代码不硬编码
7. 全部操作经 CLI 指令系统统一分发（UI/快捷键/深链/未来 AI 收敛同一通道），扩展 = 注册指令，不改核心代码
8. 提交纪律：未经用户明确指示**不得推送远程（push）**，最多只能本地提交（commit）；提交信息遵循 Conventional Commits

## 保留不变式（行为级，实现不得破坏）
1. 离线优先：读写先落本地 SQLite，云/LAN 异步不阻塞
2. 软删除统一为 `deleted_at` 时间戳 + 更新 `updated_at`（删除永远赢）
3. 跨天拆分 + 运行中条目跨日滚转
4. 时间条目携带活动名/色快照
5. 同步双向 LWW + 删除永远赢
6. 撤销/重做：本地 undo 栈 + 冲突校验；删除分类递归级联必须是**一条** undo 记录
7. 唯一未分配活动 + 相邻未分配条目合并
8. UUID 主键 + UTC ISO8601 时间存储
9. dataRevision 驱动 UI 缓存失效（分类变更必须递增，老项目已知坑）
10. LAN 主机手动启动
11. 保留期清理 + 定期 VACUUM 控制数据增长
12. 更新系统：数据与程序目录分离；下载校验一致才安装；失败逐层降级兜底浏览器；强制更新不可跳过
13. 分类层级：ActivityCategory 含 parentId 自引用，删除父分类递归软删子孙及 links；分类/事项选择合并交互；树统计覆盖全屏宽

## 代码约定
- 领域模型为纯类型放 viewmodels/，含 deleted_at、parentId，JSON 序列化缺键容错
- SQL 层聚合（GROUP BY 在库内）、分页/懒加载、部分索引只索引未删行
- 同步"删除永远赢"（并发更新不复活）；LWW 整行替换、updated_at 用 greatest() 语义
- drift 表结构 Dart 类声明，schema 版本由 drift 管理；build_runner 生成代码提交入库
- 时间条目编辑需处理跨天拆分/重叠裁剪/滚转，编辑冲突先校验

## 常用命令
- 依赖：`flutter pub get`
- 生成：`dart run build_runner build --delete-conflicting-outputs`
- 运行：`flutter run -d windows`
- 构建：`flutter build windows` / `flutter build apk --release`
- 验证：`flutter analyze` / `flutter test`

## 安全与提交
- `.gitignore` 不提交：SUPABASE_URL/ANON_KEY、AI key、本地 `*.sqlite`、`dist/` 构建产物
- `--dart-define` 默认值指向公开地址（本仓库 raw.githubusercontent），可被覆盖；AI key 永不入编译参数
- 阶段 0 起每个阶段一个 commit，信息写明阶段与内容
