# 开发进度记录

> 供中断后快速恢复。权威细节以 `TimeTrack2 从零重建执行计划（完整最终版）.md` 为准；
> 开发纪律见 `AGENTS.md`（逐模块确认、审查循环至清零、无用户指示不 push）。

## 当前状态（2026-09-12 · 阶段 4 完成，阶段 5 收尾中）

**阶段 4（UI/平台层）批次 0-6 全部实现**（PR #13 已合并 main，`31f4e63`）：
- 批次 0-3：主题/本地化地基 → 应用壳（StatefulShellRoute 5 页保活 + 全局计时条 + undo/redo 入口）→ 计时/今日页 + 活动-分类合并选择器 → 时间线/统计页
- 批次 4：设置页十分区 + schema v3 通用偏好（6 列）+ tracking_rules.enabled 启停 + 后台记录 UI + 更新状态机集成 + 主题持久化
- 批次 5：entry_update/activity_create 指令收口（单条撤销）；统计过滤下沉 compute（分类筛选/排除自动）；提醒弹窗体系（运行阈值/快速提醒/可疑条目三场景 + 手动会话保持防冲突）；l10n 收口
- 批次 6：Windows 托盘（关窗三模式 + 菜单/tooltip 本地化）+ FFI 前台检测器；Android 使用情况授权引导 + UsageStats 检测 + 前台服务常驻通知（specialUse + 文案下发）

**审查制度变更**：ocr 停用（智谱 GLM Coding Plan 体验套餐额度仅限官方指定工具，
自研 CLI 不可用，详见 AGENTS.md），代码审查改由**子智能体**按原纪律执行（范围
分层 / 属实才修 / 停循环判据不变）。

**审查处置（三轮，全部属实项已修）**：
- 批次 5 审查（`12f36be`）：统计"排除自动"极性接反、可疑条目漏滤未分配活动
  （每启动误弹）、编辑运行条目竞态、跨天"结束到现在"算错（entry_update 增
  `--start/--end=now` 绝对语义）等
- 批次 4 审查（`c7bf198`/`0c5b0be`/`1848b5b`）：schema.sql 补 v3 列镜像（防云
  推送 PGRST204 全败）、设置分区 GlobalKey 逐帧重建、编辑运行条目被 --end
  静默结束（keepRunning 透传）、sync/update 直调收口指令通道
- 批次 6 审查（`951f452` 等）：主 manifest 补 INTERNET（release 断网）、FGS
  dataSync→specialUse（Android 15 6h 上限）、关窗对话框先隐藏后弹（不可见，
  偏好无法建立）、托盘/通知文案原生硬编码中文（改 ARB 下发）、捕获自身、
  每秒服务同步去重、ForegroundDetector 契约下沉 viewmodels（依赖方向）
- 门禁：`flutter analyze` 0 issues / 全量 820 测试绿

## Riverpod 状态管理迁移（已完成，2026-10-23 ~ 10-24）

**决策**：经用户确认切换为 Riverpod（flutter_riverpod 3.4.3，手写 provider，
不用 codegen）；范围仅 UI 状态订阅层（stores + 页面订阅），data/api/viewmodels/
utils 不动；分 2 个 PR（PR1 = B0 地基 + B1 基础状态，PR2 = 其余）。存量引擎类
（sync/update/tracking/lan/ai）也按 Notifier 包装（用户选 B），但排在最后。

**已完成（`feat/riverpod-migration` / `feat/riverpod-migration-2`）**：
- B0（`ba04571`）：容器启动装配（`ProviderContainer` + `UncontrolledProviderScope`）、
  `lib/providers/infrastructure.dart` + `app.dart`（appDatabase/appStore provider、
  装配参数 provider 化）、删除 get_it、`test/support/provider_harness.dart`、
  `test/providers/app_store_provider_test.dart`、AGENTS.md 迁移期规则。
- B1（PR #15）：`lib/providers/foundation.dart`——`clockTickProvider`（1Hz ClockStore
  包装）、`currentDayProvider`（跨午夜自动翻日）、`dataRevisionProvider`（Notifier
  镜像）、`undoStateProvider`（撤销可用性快照，undo/redo 走 Notifier）；基础服务
  所有权从 AppStore 移到容器（`AppStore.create(clock/revision/undo + ownsFoundation)`）；
  壳层 undo/redo 按钮改为 `ConsumerWidget` 示例；`TimeTrack2App(container:)` 安装
  作用域（测试内自建 ProviderScope 并桥接 AppStore 的数据库/时钟/修订号/undo）。
- B2（`9e1d133`）：`lib/providers/data.dart` 查询即 provider——`dayEntriesProvider(day)`、
  `rangeEntriesProvider((start,end))`、`activitiesProvider`、
  `unassignedActivityIdProvider`、`actionLogsProvider(limit)`（family autoDispose、
  统一 watch 修订号）；删除 TodayStore/TimelineStore 及其测试；今日页/时间线页改
  ConsumerStatefulWidget（跨午夜自动翻日；前日对比按前一日边界裁剪，修旧 bug）；
  计时页/统计页/设备分区改读 provider；视图中不再持有仓储结果副本。
- B3：`statsProvider(StatsQuery)` family 替代 StatsStore 缓存（值相等键 +
  `StatsSnapshot` 下沉 `lib/viewmodels/stats/`，删 stats_store.dart 及其 659 行
  测试）；TimerStore 空闲秒级 notify 收敛；删除 ThemeModeStore 双源（主题唯一
  事实源 = `ProfileSettings.themeMode`）；计时页删除全部手工监听（活动/今日条目
  走 provider、1Hz 仅运行中订阅），并补测试作用域对时钟/修订号的桥接（修“写后
  页面不刷新”的根因）。

- B4a（`feat/riverpod-migration-3`）：`lib/providers/engines.dart` 引擎状态镜像——
  `appStoreInstanceProvider`（main 用 `late bootStore` 绑定、测试作用域
  `overrideWithValue`）+ `timerSnapshotProvider`/`reminderSnapshotProvider`/
  `updateSnapshotProvider`（监听物理引擎 → 值快照，`==` 过滤，dispose 摘监听）；
  AppShell 改 `ConsumerStatefulWidget`，3 个引擎 `addListener` 换成 build 内
  `ref.listen`（通知语义不变，只剩 settings 一个过渡白名单监听）；
  `test/support` 基座绑定 store 实例；新增 `test/providers/engines_test.dart`
  （快照只在运行条目真实变化时通知、stop=切未分配的语义）。801→803 测试。
- B4b-1（同分支）：计时引擎订阅面收敛——`TimerSnapshot` 增活动名/色快照；
  `timer_page` 运行态改 `ref.watch(timerSnapshotProvider)`（不再读 `app.timer`）；
  AppShell 删除 `_timerTick = Listenable.merge([timer, clock])`，计时条改
  `Consumer` + 条件 `clockTickProvider`（空闲不随秒重建），托盘推送/可疑条目
  检测改读快照。五个主页面已无 `app.timer` 引用（仅设置分区残留）。
- B4c-1（同分支）：设置变更桥接 provider——`lib/providers/engines.dart` 增
  `settingsStoreProvider`/`categoryStoreProvider`（实例访问器）与
  `settingsChangeProvider`/`categoryChangeProvider`（监听引擎并 +1 的变更计数，
  解决 Provider 对同一 store 实例做 == 过滤不重建的问题）；
  `settings_section_general` 三个分区 + `_TriggerTimeField` 转 `ConsumerWidget`，
  经 provider 读设置；AppShell 删最后一个 settings `addListener`，改 build 内
  `ref.listen(settingsChangeProvider)`。`lib/pages` 页面侧 `addListener` 清零。
  803 测试保持全绿。

**全替代决策（2026-10-23，用户确认）**：剩余迁移一律采用 **A 方案「Notifier
原地改造」**——保留 store 内部字段与方法体，只替换类声明/构造注入/通知语句
（`notifyListeners()` → `_publish(state = XState(...))`），业务协议零重写；
测试只换夹具（容器 + 读 provider），断言不变。迁移完成后再按热点做**增量纯化**
（C 方案：provider API 不变，把状态转移抽成纯函数），不一次性重写。
配套决定：PR4/PR5 分两个 PR；PR3 先合 main 再开 PR4；迁移期**不允许**保留
`ListenableBuilder` 过渡。完整方案与风险表见
`docs/Riverpod迁移B4全替代方案.md`。

**B4c-2（同分支，PR3 收尾）**：读取面去 store——`lib/providers/engines.dart`
新增通用 `_EngineChangeNotifier` 与 `timer/tracking/lan/sync/updateChangeProvider`
（任意引擎 `Listenable` → int 变更计数）；`today_page`/`stats_page`/
`timeline_page`/`timer_page` 的 `app.category`/`app.settings` 读取改
`ref.watch(categoryChangeProvider|settingsChangeProvider)` + `ref.read(...StoreProvider)`；
`AppShell` 提醒横幅改 `Consumer`（无提醒时不订阅 1Hz）、同步状态小字改
`ref.watch(syncChangeProvider)`；设置分区 general（3 处）/sync/update/device（LAN）
/background（tracking+settings+timer 合并监听）全部由 `ListenableBuilder` 改
`Consumer`；`DeviceSection`/`BackgroundSection` 改 `ConsumerStatefulWidget`。
验收：`lib/pages` 中 `ListenableBuilder` 与 `addListener` 均为 0；analyze 0；
803 测试全绿。PR3 可合并。

**PR4-a（feat/riverpod-migration-4）**：领域 store 装配归属先行——新建
`lib/providers/stores.dart`（`DomainStores` + `domainStoresProvider`，容器构造并
按注册逆序释放 timer/settings/category/activity）；`AppStore.create` 新增
`timerOverride/categoryOverride/activityOverride/settingsOverride`（四者必须同时
注入或同时省略）与 `ownsDomain` 字段，注入时不再创建/释放这四个 store；
`appStoreProvider` 传入领域实例；`settingsStoreProvider`/`categoryStoreProvider`
改为读 `domainStoresProvider`（解除对 `appStoreInstanceProvider` 的依赖）；
`TimeTrack2App` 的测试作用域补 `domainStoresProvider.overrideWithValue(...)`
——否则设置/分类页读到的容器自建实例与 `AppStore` 分叉，主题/时制写库后页面
不刷新（3 个 UI 用例曾失败）。新增 `test/providers/stores_test.dart` 2 例
（同一实例 + 容器释放后领域 store 已 dispose）。验收：analyze 0；全量
**803 passed**。

**PR4-b 第一步（活动）**：`ActivityStore` 去掉 `ChangeNotifier`（保留
`createActivity` 写路径、undo applier 与 `dataRevision.bump()`），新增
`activityProvider`（`Notifier<int>`）承接通知：`ActivityStore.onChanged` 由
notifier build 时挂载，写成功与撤销恢复都推进；`ActivityStore` 不再有
`dispose`。Dispatcher 暂时仍持 `ActivityStore`（PR4-g 统一读面）。新增
`test/providers/activity_test.dart` 2 例（指令写路径递增、undo 恢复递增）。
验收：analyze 0；全量 **807 passed**。

**PR4-b 其余步骤（feat/riverpod-migration-4，PR #18 已合并 `a47652b`）**：
按 A 方案原地改造，形状统一为“去 `ChangeNotifier` + 单一 `onChanged` 槽（或
`addChangeListener` 监听表）+ provider 挂载/摘除（identical 守卫）”：
Settings（save/reload/applier 三处通知；`settingsChangeProvider` 挂载）、
Category（`43492a7`）、Timer（多监听者用 `addChangeListener` 监听表）、
Reminder（`d6a7f78`）、Undo（`cbea01e`，`undoStateProvider` 挂 `onChanged`，
删除 `undo.dispose`）、CommandDispatcher 读面（`aa74c4f` 新增
`commandDispatcherProvider`，20 处页面调用改 `ref.read`；`19b2d2a` 页面剩余
引擎读改 provider，`lib/pages` 对领域 store 引用归零）。新增
`activity/settings/category/timer` 四个 provider 测试文件。全量 812 绿。

**PR5（feat/riverpod-migration-5，PR #19 草稿）**：
- 引擎去 ChangeNotifier（`3c5d443`/`788cad6`）：Sync/Update/Tracking/LAN 改
  `onChanged` 单槽；`lib/providers/engines.dart` 用显式 Notifier 挂载并 +1，
  新增 `sync/update/tracking/lanStoreProvider`；页面 22 处改 `ref.read`。
- 平台服务 provider 化（`20c994d`）：`lib/providers/services.dart`（托盘/前台
  检测/Android 桥/数据清除/文件互通/分发器）；AppShell 与设置分区改 provider。
- 页面/路由去 AppStore 参数（`31b37c3`）：5 页面改无参构造，`AppRouter.create()`。
- **删除 `AppStore`（`de32f0e`）**：`lib/providers/bootstrap.dart` 构造全部后台
  引擎/服务（`trackingRuleRepositoryProvider`、`androidDetectionStoreProvider`、
  `lanStoreProvider`、`syncStatusServiceProvider`、`cleanUpServiceProvider`、
  `syncStoreProvider`、`updateStoreProvider`、`trackingStoreProvider`、
  `commandDispatcherProvider`、`reminderStoreProvider` 等），`startupProvider`
  承接 seed/rollover/normalize/加载缓存/静默更新检查/清理；`main.dart` 只建
  容器并 await 启动；`app.dart` 只收容器（测试桥接只剩数据库/时钟/修订号/
  undo/领域 store 五个 override）；删除 `lib/stores/app_store.dart`、
  `test/stores/app_store_test.dart`，新增 `test/providers/bootstrap_test.dart`；
  测试基座 `test/support/app_store_fixture.dart` 的 `TestStore` 以同名 getter
  兼容既有 74 处 `store.xxx` 写法。全量 **806 passed**（删除 app_store 旧测试、
  其余用例改写为容器读取）。说明：`lib/` 仍有 19 处**说明性注释**提及
  `AppStore`（历史沿革，非代码依赖；其中 4–5 处措辞已过时可后续统一改词）。
- 迁移收尾（`a2d1be5`）：AGENTS.md 技术栈/目录注释终稿（去掉迁移期例外、
  `stores/` 定位为无 UI 依赖的服务层）；PROGRESS 本节与 `docs/Riverpod迁移B4执行计划.md`
  `/docs/Riverpod迁移B4全替代方案.md` 记录完成状态与遗留项。

**迁移分支累积 diff 审查（2026-10-24，e212dd3..main，fix/riverpod-audit）**：
子智能体按六个重点只读审查（通知丢失/生命周期、1Hz 订阅/ref.mounted、
dataRevision/失效粒度），逐条证据核证后处置：
- **已修（迁移引入回归）**：① `UpdateStore.onChanged` 单槽被
  `updateSnapshotProvider`（壳层）与 `updateChangeProvider`（设置页）先后
  覆盖——用户打开设置页后壳层镜像永久断更，强制更新对话框（不变式 12）
  不再弹出；改 `addChangeListener` 监听表（TimerStore 同款）+ 双挂并存
  回归测试。② stats 页按 tick 传 `StatsQuery.effectiveNow` 使 family 键每秒
  变化：每秒 SQL 重查 + 新键无旧值整页 loading 闪烁 + 保活 offstage 分支
  空转（迁移前 StatsStore 为事件驱动，无此三项）；改不传 effectiveNow，
  仓储执行时取当刻，恢复事件驱动语义。
- **已修（low 加固）**：`SyncStore.runCleanupIfDue` 补 `_disposed` 入口守卫；
  `TimerStore.addChangeListener` 同引用去重；stats/today/timeline/background/
  device 5 处 await 后补 `mounted` 守卫（`_wipe` 改为 await 前捕获全部句柄）；
  data.dart 两处注释对齐实现；删除误提交的 `analyze_test.txt`。
- **存量缺陷（迁移前后行为等价，非本次回归，记待办）**：云同步拉取设置后
  `SettingsStore._current`/主题不刷新到重启；LAN 主机侧合并落库不 bump
  dataRevision（host 端页面不刷新）；保留期清理删除不 bump。详见收尾清单。
- **核实无回归**：dataRevision bump 点迁移前后 15→15 逐点对应；失效粒度
  等价或更优（设置保存双信号：bump + settingsChangeProvider）；1Hz 订阅
  全部条件化（空闲零秒级重建，较迁移前更优）；startupProvider await 后
  `ref.watch` 合法（riverpod 3.4.3 源码：仅 `!mounted` 抛错）；容器释放链
  完整（ClockStore/Sync/Tracking/Reminder/Lan/Update/DB 均有 dispose 接线，
  `stores_test` 验证释放不抛）。


**严格收尾（`refactor/riverpod-strict-finish`）**：把最后两个基础类去 `ChangeNotifier`——
`ClockStore`（1Hz 时钟）与 `DataRevision`（修订号）改普通类，订阅统一为
`addChangeListener` / `removeChangeListener` 显式配对，且逐监听者异常隔离
（`FlutterError.reportError`：任一订阅者抛错不再取消周期 Timer、也不阻断其他
派生缓存失效）；`ClockStore` 增 `@visibleForTesting emitTick()` 供 tick 限频用例；
`providers/foundation.dart` 挂载点与 4 个领域 store 的监听调用同步改名。
注释与文档清理：`lib/` 不再有 `AppStore`、也不再写“迁移期桥接/仍由
ChangeNotifier store 持有”等过期说明；历史决策保留在 docs 与本节。
验收：analyze 0；全量 **807 passed**；`lib/stores/` 已无任何 `ChangeNotifier` /
`ValueNotifier` 子类，`lib/pages` 无 `addListener` / `ListenableBuilder`。


## 阶段 5 收尾清单（待办）

**人工/实机（需有 VS 的机器 + Android 真机）**：
- [ ] Windows Release 构建验证（本机无 Visual Studio——C++ 侧关窗流/托盘文案
      改动未经编译验证）+ 托盘/关窗/前台检测冒烟
- [ ] Android 真机：使用情况授权引导、前台服务常驻、锁屏 null、通知暂停动作
- [ ] 更新流程人工冒烟（检查→下载→校验→Windows staging 重启生效 / Android 兜底浏览器）
      ——检查段 2026-10-24 实测通过（种子清单 0.1.0 → 已是最新，PR #21；
      网络前提：raw.githubusercontent 直连被墙，需代理/TUN 环境）；下载/
      校验/安装段待真实发版产物

**代码挂账（延续阶段 2e/3/4）**：
- [ ] 云同步拉取设置后刷新 `SettingsStore._current`（迁移审查 M：设备 A 改
      主题 → 设备 B 同步拉取直写库绕过 store 缓存 → 主题/设置分区陈旧到
      重启；迁移前后等价的存量缺陷。方向：同步成功后编排 reload，需考虑
      与本地保存竞态）
- [ ] LAN 主机侧合并落库后 bump dataRevision（迁移审查 M：host 收到客户端
      推送 mergeBundle 后本端页面不刷新；api 层无 DataRevision 引用，需
      LanSyncServer 合并成功回调上抛 LanStore）
- [ ] 保留期清理删除数据后补 bump（迁移审查 L：覆盖清理区间的统计视图
      陈旧至下次任意 bump；fire-and-forget，需与 syncNow 的 bump 合并语义）
- [ ] 正常退出不释放 ProviderContainer（迁移审查 L 挂起：进程退出 OS 回收
      + SQLite journal 兜底，迁移前后等价；引入优雅退出属新特性）
- [ ] UpdateStore.dispose 不中止在途下载（迁移审查 L 挂起：通知已 `_closed`
      守卫，下载完成落盘无害；中止属增强）
- [ ] HTTPS 出网代理支持（2026-10-24 更新检查诊断结论，**之后再扩展**：
      应用内 http 包/dart:io HttpClient 一律直连，不读系统/环境/本地代理
      ——受限网络下 raw.githubusercontent 等需全局 TUN 才可达，更新检查
      可用性依赖用户网络环境。扩展方向：HttpClient.findProxyFromEnvironment
      读 HTTPS_PROXY（注意 dart:io 无原生 socks，需 http/混合端口）或系统
      代理发现；受益面：更新检查/下载、云同步、二期 AI 调用的统一出网通道）
- [ ] Windows 安装器真实目录注入（main 装配，现为 Directory.current 占位）+
      待安装标记消费（applyStaging 重启闭环）——更新系统最后一段
- [ ] Android 自动安装接线（tryInstallApk 平台守卫 + REQUEST_INSTALL_PACKAGES +
      FileProvider + file_paths.xml——installer 骨架已入库）
- [ ] update_download / signOut / ignoreVersion 指令化（铁律 7 收口）
- [ ] 壳层提醒/更新对话框接线 widget 测试（可疑条目与统计开关已补）
- [ ] pairClient IPv6 lastIndexOf 拆分错位（LAN 以 IPv4 为主）
- [ ] ActionLog 事务提交后写入的统一收口（沿袭模式：失败误报但数据已落库）
- [ ] Play 合规：受限权限用途声明 + 隐私政策 + Data safety（docs/ 草稿待落）
- [ ] 留档：gradle wrapper 腾讯镜像未设 distributionSha256Sum；Win32 隐藏窗口
      SetForegroundWindow quirk（菜单点击外不消失的既有边界）

**二期（阶段 6）**：AI 总结（设计文档 `docs/AI总结数据需求与模板.md`，信号层复用
slicesForRange/computeDayMetrics）+ 自然语言→指令解析。

## 历史状态（2026-08-15 · 阶段 0-3）

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

## 下一阶段（阶段 5 收尾 → 阶段 6 二期 AI）

- 阶段 5：见顶部「阶段 5 收尾清单」——双平台构建冒烟（含更新流程人工验证）+
  后台自动记录验收 + Play 合规文档
- 阶段 6（二期）：AI 解析自然语言→CommandInvocation→命令分发执行（可编辑草稿、
  走现有写路径）+ AI 总结（只读信号 + 独立缓存表；密钥 flutter_secure_storage；
  启用披露数据出境 + Ollama 本地选项）——设计输入见 `docs/AI总结数据需求与模板.md`
- 实现前先报要点，确认后开工

## UI 重建（进行中，2026-10-24 起）

方案见 `docs/UI重建方案.md`（已确认：计时页紧凑分组列表、设置路由化主从、设置 10 项扁平导航）。

- **PR-A（feat/ui-rebuild-foundation）**：新增布局令牌 `lib/constants/layout.dart`（断点 600/840/1280、内容宽 timer 1440·today 1120·stats 1440·settings 1280·form 760）、`lib/components/page_frame.dart`；壳层去掉全壳统一 1024 限宽，内容宽度由各页面声明；计时/今日/统计/设置页包 `PageFrame`；Windows 窗口最小尺寸 960×640（`WM_GETMINMAXINFO`）；`test/components/page_frame_test.dart` 3 例。验收：analyze 0 / 全部测试绿。
- 后续：PR-B 计时页（焦点区压缩 + 分组列表 + 自适应列）、PR-C 统计页（两栏 + 响应式图表 + 分类树表）、PR-D 设置路由化主从 + 撤销/重做改版。

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









