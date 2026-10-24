# Riverpod 迁移 B4 执行计划（PR3）

> 前情：B0–B3 已并入 main（PR #15、#16）。页面层（今日/时间线/统计/计时/壳层撤销）
> 已全部 `ref.watch`，查询经 `lib/providers/data.dart`，基础状态经
> `lib/providers/foundation.dart`。本阶段目标：把**剩余 store 与引擎**迁到 Notifier，
> 删除 `AppStore`，让 `stores/` 只保留撤销执行器与命令分发器。

## 不变式（每一刀都必须满足）

1. 行为等价：既有 801 测试全绿，`flutter analyze` 0 issues；每刀独立 commit。
2. 通知收敛：1Hz 只允许出现在「运行中计时展示」与「时钟叶子」两处。
3. 失效语义：写库成功后 `dataRevisionProvider` 必增；跨端/外部来源（云、LAN、
   导入、undo 全局恢复）由数据 provider watch 修订号兜底，页面不再手工失效。
4. 引擎状态快照必须值相等（手写 `==`/`hashCode` 或 record），否则 Riverpod 的
   `==` 过滤会漏刷新或引发重建风暴。
5. `await` 之后必须 `if (!ref.mounted) return;`（Riverpod 3 释放后使用 Ref 抛
   `UnmountedRefException`）。
6. family 带参数一律 `isAutoDispose: true`；写路径用 `ref.invalidate` 精准失效，
   非外部来源不 bump 修订号。

## 分刀顺序（风险从低到高）

### B4a 壳层引擎快照（AppShell 去监听）
- 新增 `lib/providers/engines.dart`：
  - `appStoreInstanceProvider = Provider<AppStore>((ref) => throw StateError(...))`，
    由 main 容器与 `TimeTrack2App` 测试作用域 `overrideWithValue`；
  - `timerSnapshotProvider`、`reminderSnapshotProvider`、`updateSnapshotProvider`：
    Notifier 监听对应 store，只暴露 UI 需要的不可变快照（运行条目、活动提醒、
    更新可用状态），快照实现 `==`/`hashCode`；
  - 保留 `settingsSnapshotProvider` 供壳层 Android 服务同步订阅一次。
- `AppShell` 改 `ConsumerStatefulWidget`：`initState` 的 4 个 `addListener` 与
  `dispose` 对应摘除，改为 `ref.listen`（弹窗/托盘）或 `ref.watch`（横幅、
  计时条）；`_timerTick` 合并对象删除，计时条改 `ListenableBuilder` → 直接
  `ref.watch(timerSnapshotProvider)` + 条件 `ref.watch(clockTickProvider)`。
- 验收：`grep addListener lib/pages` 为空；壳层 8 个 UI 测试绿；手工：托盘菜单、
  关窗、提醒横幅、更新提示、双击托盘中「显示主窗口」。
- 注意：`_wireTray`/`_wireAndroidTracking` 的回调仍指向 State，`dispose` 里必须
  继续清空 `onCommand`/`onCloseToTray`/`onPauseRequested`。

### B4b TimerStore → TimerNotifier（最大单块）
- `lib/providers/timer.dart`：`TimerNotifier extends Notifier<TimerState>`，内部持有
  仓储/时钟/修订号/撤销，公开 `runningEntry`、`elapsedAt(now)`、`switchTo`、
  `stop`、`refresh` 等；`TimerState` 只含 UI 需要的不可变字段（运行条目快照、
  写互斥标志、未分配判定的活动 id）。
- 依赖窄接口：`CommandDispatcher`、`ReminderStore`、`TrackingStore` 需要的
  `TimerGateway`（`runningEntry`/`stop`/`switchTo`）由 provider 注入实现，避免
  它们反向依赖 Notifier 类型。
- 迁移 `app.timer` 的 29 处引用（`app_store.dart:97/:172`、`reminder_store.dart:88`、
  `command_dispatcher.dart:50`、`tracking_store.dart:52`、
  `settings_section_device.dart:169`、`settings_section_background.dart:107/:129`、
  `app_shell.dart:66/:117/:125/:341/:401/:782/:861`、`timer_page.dart` 全量）。
- 测试：`test/stores/timer_store_test.dart`（539 行）改写为 `test/providers/timer_test.dart`
  （`ProviderContainer.test` / `createTestContainer`）；覆盖切活动合并相邻未分配、
  跨天滚转、写互斥、恢复失败分支。
- 验收：计时页/壳层计时条/托盘/提醒/追踪全链路手测；`dataRevisionProvider` 在
  每次写后必增（测试守护）。

### B4c 领域 store → AsyncNotifier
顺序：`CategoryStore`（28 处页面引用，树索引下沉 `CategoryTree` 值对象）→
`SettingsStore`（21 处；`settingsProvider = AsyncNotifierProvider<..., ProfileSettings>`，
主题/周始/时制全部派生）→ `ActivityStore`（6 处；读走 `activitiesProvider`，写走
仓储 + invalidate）→ `ReminderStore`（7 处）。
- 每刀同时迁移其 `UndoApplier`（`apply/validate` 保留在 viewmodels 层，Notifier 只
  负责状态与调用）。
- 页面侧：`app.category.links` → `ref.watch(categoryTreeProvider).requireValue.links`
  等；避免把 AsyncValue 传进无状态子件（在 build 顶层解包）。
- 测试：各 store 测试改 provider 测试；UI 测试补「分类改名后统计筛选树/今日页
  同步刷新」用例。

### B4d 引擎 → Notifier
`SyncStore` → `SyncNotifier`（状态机 + 进度流）、`UpdateStore` → `UpdateNotifier`、
`TrackingStore` → `TrackingNotifier`、`LanStore` → `LanNotifier`、`AiStore`（二期，
当前无页面引用，最后做）。
- 引擎内部保持现有仓储/平台桥接依赖，不重写协议逻辑；只把「状态 + 通知」换成
  `state = ...`，并把 `Future` 结果映射为 `AsyncValue`/状态机快照。
- 所有定时器/订阅在 `ref.onDispose` 释放；后台轮询不得直接 `notifyListeners`。
- 验收：同步/更新/追踪/LAN 手工冒烟（含飞行模式、断网重试、更新校验失败降级）。

### B4e 收尾：删 AppStore
- `lib/main.dart`：装配改为 `appStartupProvider`（FutureProvider，内部串起
  seed→rollover→normalize→静默更新/清理），失败仍走 `_StartupErrorApp`；
  `ProviderContainer` 仍先 await 首帧所需状态再 `runApp`。
- `lib/app.dart` 删除 `appStore` 参数与桥接 override；路由构造改用 provider。
- `CommandDispatcher` 构造参数从 `AppStore` 改为 `Ref`（或注入 5 个窄接口）。
- 删除 `lib/stores/app_store.dart` 及 `test/stores/app_store_test.dart`；
  `test/support/` 基座改为「容器 + 内存库 + 固定时钟」。
- 文档终稿：AGENTS.md 技术栈/目录/依赖方向、执行计划文档阶段 0 段落、
  PROGRESS.md 迁移章节收尾。

## 测试基座改造

- `createTestContainer({database, now, clockInterval, overrides})` 统一提供：
  内存 drift、`runStartupChecksProvider=false`、`clockIntervalProvider=1h`、
  可注入 `now`。
- UI 测试 pump 助手统一 `ProviderScope(overrides: [appDatabaseProvider..., ...])`，
  不再依赖 `TimeTrack2App` 内部桥接（B4e 后桥接删除）。
- 新增守护测试：
  - 写操作后 `dataRevisionProvider` 必增（按命令注册表遍历）；
  - 页面在「其它页写库」后必须刷新（过去日期、日志视图、分类改名三类）；
  - 空闲 10 分钟无 1Hz 重建（用 `tester.pump` 计数帧）。

## 回滚与风险

- 每刀 commit 可独立 revert；B4a 的快照 provider 若引发壳层抖动，先回退壳层、
  保留 provider（互不依赖）。
- 风险最高：B4b 写互斥与 undo 记录、B4c 分类树索引与 `dataRevision` 递增、
  B4d 同步 LWW 语义。这三处必须有对应测试再改页面。
- 禁止在 B4 期间新增 `ChangeNotifier`；临时桥接代码必须标 `TODO(B4e)` 并在
  收尾时删除。

## 完成状态（2026-10-23）

- B4a–B4c、PR4（B4b 全步骤 + dispatcher 读面）、PR5（引擎 onChanged、
  `providers/services.dart`、页面去参、删除 `AppStore` + `providers/bootstrap.dart`）
  已全部落地；PR #15–#18 已合并，PR #19 待审。
- 验收：`flutter analyze` 0 issues；全量 806 测试绿；`lib/pages` 中
  `addListener`/`ListenableBuilder`/`app.<store>` 引用均为 0；`lib/stores/`
  仅剩无 UI 依赖的后台引擎/领域服务（不继承 `ChangeNotifier`）。
- 本计划中的 `TODO(B4e)` 桥接已随 PR4 清零；测试基座改为容器装配
  （`createTestContainer` + `test/support/app_store_fixture.dart` 的 `TestStore`）。
- 未按原计划实现的两点及理由、纯化 C 的遗留热点，见
  `docs/Riverpod迁移B4全替代方案.md` 末尾「执行结果与偏差」。
