# Riverpod 全替代方案（B4 收尾，PR4 + PR5）

> 目标：**引擎与领域状态全部 provider 化**，`lib/stores/` 删除，`AppStore` 删除，
> 页面不持有任何 store；同时**不重写**被测过的业务逻辑（计时互斥、撤销两阶段、
> 同步 LWW、跨天滚转），只替换"通知与装配"两层。
>
> **状态（2026-10-24）：已完成。** PR4（#18）、PR5（#19）、迁移后审查（#20）与
> 严格收尾（ClockStore/DataRevision 去 ChangeNotifier）见本分支 PR；现状与验收见
> `PROGRESS.md` 的「Riverpod 状态管理迁移」一节。本文保留为决策记录。

## 1. 为什么不是"把 4755 行逻辑重写进 Notifier"

`lib/stores/` 现有 12 个 `ChangeNotifier` 子类，其中 `TimerStore`(595)/`SyncStore`/
`TrackingStore`/`UpdateStore` 承载的是**并发与生命周期协议**（写互斥 `_writing`、
撤销两阶段校验、LWW 整行替换、后台循环去重），不是纯 UI 状态。把这些方法逐个搬进
Notifier 的 `build/state` 模型，等于重写并重新验证这些协议——风险最高、收益最低。

**替代做法：Notifier 直接继承现有类的工作方式**。
每个 store 原地改成 `extends Notifier<XState>`：

- 内部字段（`_runningEntry`、`_stack`、`_cleanupRunning`…）**原样保留**；
- `notifyListeners()` → `_publish(state = XState(...))`（不可变快照，手写 `==`）；
- 构造参数（仓储、undo、now）改在 `build()` 里 `ref.watch/read`；
- 公开 getter/方法保持签名，页面按需 `ref.watch(xProvider.select(...))`；
- 测试从"构造 store + 监听"改为"容器 + 读 provider"，断言方法不变。

这样业务代码只动"通知语句 + 构造函数"，`git diff` 可逐行核对，800 测试仍然是
真回归而不是重写后的假绿。

## 2. 目标架构

```
lib/providers/
  infrastructure.dart   # 数据库/版本/后端/now/安装器（已有）
  data.dart             # 仓储 + 查询 provider（已有）
  foundation.dart       # 时钟/修订号/撤销（已有）
  engines/
    clock.dart          # ClockNotifier（1Hz tick；页面只订叶子）
    data_revision.dart  # RevisionNotifier（外部来源 bump）
    settings.dart       # SettingsNotifier<ProfileSettings?>
    activity.dart       # ActivityNotifier<List<Activity>>
    category.dart       # CategoryNotifier<CategoryState>（树/链接/索引）
    timer.dart          # TimerNotifier<TimerState>
    reminder.dart       # ReminderNotifier<ReminderRequest?>
    undo.dart           # UndoNotifier<UndoState>（applier 注册表）
    sync.dart / update.dart / tracking.dart / lan.dart
    tray.dart / android.dart  # 平台服务 provider（非 Notifier）
    commands.dart       # CommandDispatcher provider（构造注入 Ref）
    startup.dart        # appStartupProvider（seed/rollover/清理/静默更新）
```

规则：

1. **快照即状态**：每个 Notifier 的 `state` 是不可变类，`==`/`hashCode` 手写；
   列表/映射字段用 `Object.hashAll`、`setEquals`，避免"每次通知都重建"。
2. **通知收敛**：状态无变化时 `state` 不变（Riverpod `==` 过滤），空转 tick
   不再唤醒页面；1Hz 只允许"运行中计时"与"提醒横幅"两处订阅。
3. **写后失效**：领域 Notifier 写库成功后不再 bump 全局修订号；只有外部来源
   （云同步/LAN/导入/撤销恢复）bump `dataRevisionProvider`，数据 provider 兜底。
4. **family 默认 autoDispose**，带参数 provider 必须开（防按参数泄漏）。
5. `await` 之后必须 `if (!ref.mounted) return;`（Riverpod 3 释放后读 Ref 抛
   `UnmountedRefException`）。
6. 平台能力（托盘/安装器/Android 桥）保持**纯服务**，由 provider 构造并用
   `ref.onDispose` 释放；壳层用 `ref.listen` 订阅它们的状态 Notifier。

## 3. 循环依赖的处理

- **撤销**：`UndoStore` 现在持有 applier 列表，而 store 又在构造时拿到 undo。
  改为：`undoProvider` 只维护栈与注册表；各领域 Notifier 在 `build()` 里
  `ref.read(undoProvider).register(this)` 并 `ref.onDispose(unregister)`。
  依赖方向单向（领域 → undo），构造期无环。
- **Dispatcher**：`commandDispatcherProvider` 的构造只依赖 `Ref`；处理器内部
  `ref.read(timerProvider)` 等，避免"装配期把 12 个 Notifier 全建出来"。
- **Shell**：只 `ref.watch(timerSnapshotProvider)`/`reminderSnapshotProvider`
  等派生 provider（B4a 已建），不直接碰引擎。

## 4. 分阶段与 PR

### PR3（当前分支，收尾读取面）— 0.5 天

- B4c-2：`today_page`(8)/`stats_page`(5)/`timeline_page`(2)/`timer_page`(14)
  的 `app.category`、`app.settings` 读取改 `categoryChangeProvider`/
  `settingsChangeProvider` + `ref.read(...StoreProvider)`；
- `settings_section_background/device/sync/update` 的 `ListenableBuilder` 改
  `Consumer` + 对应 change provider；
- 验收：`lib/pages` 中 `app.category|app.settings|app.activities|app.timer` 为 0；
  analyze 0、测试绿；合入 main（PR3）。

### PR4（领域层 + 命令层）— 2.5 天

顺序（每步一个 commit，analyze+test 绿再下一步）：

1. `SettingsNotifier`：`ProfileSettings?` 状态；`save()` 保持 undo + LWW；
   页面经 `settingsProvider` 读写；删 `SettingsStore`。
2. `ActivityNotifier` / `CategoryNotifier`：树/链接索引在 `build` 内重建，
   state 携带 `revision` 计数（替代 `categoryChangeProvider`）；
   分类写操作成功后只更新自身 state（不再全局 bump）。
3. `TimerNotifier`：`TimerState{ runningEntry, sessionStartedAt }`；
   `_writing` 互斥与跨天滚转原样；1Hz 由 `clockTickProvider` 驱动 elapsed
   （不在 Notifier 里定时），状态只在运行条目/活动切换时变化。
4. `ReminderNotifier`：状态 = `active` 请求；调度定时器保留在类内，dispose 取消。
5. `UndoNotifier`：栈与 applier 注册表；`undoStateProvider` 改为其 `state`。
6. `commandDispatcherProvider`：构造注入 `Ref`，13 个处理器改读 provider；
   `AppStore` 删除领域字段，`init()` 只留 seed/rollover/清理（暂由 main 调）。
7. 页面/测试切 provider：删 `widget.app.timer/category/settings/...` 读取，
   `test/support` 增 `pumpProviders`；17 个 store 测试改容器测试。

### PR5（引擎 + 装配收口）— 2.5 天

1. `SyncNotifier` / `UpdateNotifier` / `TrackingNotifier` / `LanNotifier`
   （后台循环/心跳/下载进度留在类内；通知改 state）。
2. `trayProvider` / `androidTrackingProvider` / `installerProvider`：纯服务 +
   `ref.onDispose`；壳层仅 `ref.listen`。
3. `appStartupProvider`：`FutureProvider<StartupResult>` 完成
   seed → rollover → normalize → 静默更新/清理；main 改为
   `await container.read(appStartupProvider.future)`；失败走 `_StartupErrorApp`。
4. 删除 `lib/stores/`（`app_store.dart`、`command_dispatcher.dart` 迁入
   `lib/providers/engines/commands.dart`），删除 `AppStore` 参数在
   pages/routes/tests 中的全部传递（约 74 处 lib + 34 处 test）。
5. 文档终稿：`AGENTS.md` 技术栈、执行计划阶段 0、`PROGRESS.md` 验收章节。

## 5. 验收（每阶段门槛）

- `flutter analyze` 0 issues；
- `flutter test` 全绿（当前 803，PR5 后预计 790±10，差额必须逐条解释）；
- `grep -R "ChangeNotifier\|addListener\|AppStore" lib/` 只剩注释/平台服务；
- 手工路径：启动装配、计时开始/暂停/切换/跨天、今日编辑+撤销、时间线补录、
  统计筛选、设置改主题/时制、云同步拉取；
- 1Hz 重建面：`flutter run --profile` 下计时页/壳层无空闲秒级重绘。

## 6. 风险与回滚

| 风险 | 缓解 |
| --- | --- |
| 撤销栈与 Notifier 状态不同步（record 后 UI 不更新） | `UndoNotifier` 保留"执行期忽略 record"标志，测试覆盖并发 record/undo |
| 同步/追踪后台循环在新装配下泄漏 | 所有循环在 `build` 内 `ref.onDispose(cancel)`；`ProviderContainer.test` 断言 dispose 后无 timer |
| 页面构造去掉 `AppStore` 导致 5 页/路由 diff 大 | PR4 第 7 步单独 commit，只改签名与调用点，不改行为 |
| 测试一次性从 803 掉到 700 | 禁止跳过测试；每删一个 store 测试前，先同等覆盖迁移到 provider 测试 |
| 迁移期两套装配并存 | PR4 完成后 `AppStore` 只剩引擎字段并在 PR5 删除，不允许新增 legacy 用法 |

## 7. 工期与决策点

- 合计：PR3 0.5 天 + PR4 2.5 天 + PR5 2.5 天（≈ 5.5 个工作日，含回归）。

### 已确认决策（2026-10-23，用户确认）

1. **采用 A 方案：Notifier 原地改造**。保留 store 内部字段与方法体，只替换
   类声明、构造注入（`build()` 里 `ref.watch`）与通知语句（`notifyListeners()`
   → `_publish(state = XState(...))`）。业务协议（写互斥、跨天滚转、撤销两阶段、
   LWW）零重写；测试只换夹具，断言不变。
   - **理由**：风险应放在"通知/装配替换"这一层，而不是"协议重写后重新证明"。
     本仓库历史缺陷（编辑运行条目竞态、跨天结束算错、设置逐帧重建）恰好集中在
     协议路径，且 UI 测试覆盖薄，重写的回归信号不可靠。
   - **代价**：内部可变字段与 `state` 快照并存，靠单一 `_publish()` 出口保证
     一致；形态偏命令式，`select` 粒度受快照设计限制。
2. **纯化（C 方案）留作迁移后的增量**：PR4/PR5 完成后，若某 store 成为热点
   （例如 Timer 需要更细的 `select`），在 **provider API 不变** 的前提下把状态
   转移抽成纯函数，用已有 provider 测试兜底。不一次性重写 4755 行。
3. **PR4 / PR5 分两个 PR**（各自约 2000 行 diff，可审查）。
4. **PR3 先合入 main，再开 PR4 分支**（保持 main 始终可发布）。
5. **迁移期不允许保留 `ListenableBuilder` 过渡**：B4c-2 把设置分区全部改
   `Consumer` + `ref.watch/ref.listen` 后，PR3 才能合并。

### 尚未落定的实施细节

- 撤销注册表在 `build()` 内注册 applier 的时序（必须早于任何写操作，见 §3）；
- `appStartupProvider` 失败时的错误页复用方式（`_StartupErrorApp` 是否保留）；
- PR4 中 CommandDispatcher 迁移采用"构造注入 Ref"还是"每个处理器一个 provider"。

## 8. 执行顺序修订（2026-10-23，实施勘察后）

**发现**：A 方案的"Notifier 原地改造"无法按 store 逐个独立落地。领域 store 当前全部在
`AppStore.create` 内构造（`lib/stores/app_store.dart:199` 起的 `final activity = ...`
一段），再通过构造参数注入 `CommandDispatcher`（`lib/stores/app_store.dart:272`）；
而 Notifier 实例只能由 `NotifierProvider` 创建。因此"把 `ActivityStore` 改成
`ActivityNotifier`"必然同时改动三处：① 该 store 的装配归属（从 AppStore 移到
`lib/providers/`）；② Dispatcher 的构造（当前持 `ActivityStore` 字段，
`lib/stores/command_dispatcher.dart:56`）；③ 页面 20 处 `app.dispatcher` 与测试 14 处
`store.dispatcher`。

**修订顺序**（每一步都保持可运行 + 全量测试绿）：

1. **PR4-a 装配归属**：新建 `lib/providers/stores.dart`，领域 store 改由 provider 构造
   （repo/undo/revision/clock 均已是 provider），`AppStore.create` 改为接收这些实例、
   不再内部 `new`；Dispatcher 仍由 AppStore 组装。此步是纯装配搬家，页面零改动，
   测试只改夹具（`createTestContainer()` 取 store）。
2. **PR4-b Activity**：`ActivityStore → ActivityNotifier extends Notifier<ActivityState>`；
   `activityProvider = NotifierProvider`；Dispatcher 改 `ref.read(activityProvider.notifier)`
   （或接收窄接口 `ActivityCreator`）；删 `AppStore.activity` 字段；`command_dispatcher_test`
   改容器夹具。该类无专属测试（`test/stores/activity_store_test.dart` 不存在），
   由 dispatcher 测试兜底。
3. **PR4-c Settings → PR4-d Category → PR4-e Timer → PR4-f Reminder**：同上模式；
   `settingsChangeProvider`/`categoryChangeProvider`/`timerChangeProvider` 等镜像
   provider 作为过渡，对应 Notifier 落地后立即删除并改页面 watch notifier。
4. **PR4-g Dispatcher**：构造改注入 `Ref`，`commandDispatcherProvider` 提供实例；
   页面 20 处 `app.dispatcher` → `ref.read(commandDispatcherProvider)`；删
   `AppStore.dispatcher`。
5. **PR5**：引擎（Sync/Update/Tracking/LAN/AI）+ `appStartupProvider` + 删 `AppStore`。

**代价与风险**：PR4-a 是原方案未写的一步（原方案默认 store 已可由 provider 构造）。
跳过它，任何单 store 转换都会产生"双实例并存"或"容器反向依赖 AppStore"的坏形状，
后续还要再拆一次。PR4-a 的 diff 集中在 `lib/stores/app_store.dart` 与新建的
`lib/providers/stores.dart`，业务逻辑零改动，是风险最低的起点。

**测试影响**：`AppStore.create` 的 9 处测试调用改为 `createTestContainer()` + 从容器取
store；`test/support/provider_harness.dart` 增加 store override 参数（后续每步复用）。

## 执行结果与偏差（2026-10-23 完成）

PR1 #15（B0/B1）→ PR2 #16（B2/B3）→ PR3 #17（B4a–B4c）→ PR4 #18（A 方案
原地改造 + dispatcher 读面）→ PR5 #19（引擎/provider 服务/删 AppStore），
已全部落地；`flutter analyze` 0 issues，全量 806 测试绿。

与原方案的偏差（均为落地时发现的更优/更小形状，已记录）：

1. **A 方案的具体形态**：store 类去掉 `ChangeNotifier`，保留字段与业务方法，
   通知改为单一 `onChanged` 槽（Timer 因多监听者保留 `addChangeListener` 监听表）；
   通知生命周期由 `providers/` 挂载/摘除（identical 守卫）。**没有**把
   store 类本身改成 `Notifier`——`Notifier` 实例只能由 `NotifierProvider`
   创建，而领域方法仍需要普通对象承载；改用“服务对象 + provider 镜像通知”
   后，页面/测试的读面仍是 provider，符合 A 的核心承诺（业务协议零重写）。
2. **引擎同样按第 1 条落地**（Sync/Update/Tracking/LAN），`lib/providers/engines.dart`
   用显式 `*ChangeNotifier` 把 `onChanged` 映射为 int 变更计数，替代原计划的
   “引擎直接 Notifier”。
3. **CommandDispatcher 未注入 `Ref`**：直接由 `commandDispatcherProvider`
   构造并注入窄依赖（Timer/Category/Settings/Activity + 仓储），页面 20 处
   `app.dispatcher` 改 `ref.read(commandDispatcherProvider)`。
4. **AppStore 删除方式**：`lib/providers/bootstrap.dart` 承接原 `create/init`
   编排，`startupProvider` 负责 seed/rollover/normalize/缓存加载/静默更新/清理；
   测试基座保留 `TestStore` 外观（`test/support/app_store_fixture.dart`，
   同名 getter）以避免一次性改写 74 处断言。
5. **页面构造参数提前清零**：PR5 第 3 步先删 5 页的 `AppStore` 参数与
   `AppRouter.create(app)`，再删 `AppStore`，避免“类已删但页面还在传”的中间态。

**遗留（纯化 C，按热点增量做，不改 provider API）**：
- TimerStore 的写互斥 `_writing` + `runningEntry` 与 undo 的交互；
- UndoStore 两阶段 `_applyRecord`（全 validate 后全 apply）；
- SyncStore 的 LWW 编排与 LAN 合并路径；
- `stores/*` 里剩余的 `debugPrint`/`stderr` 日志收口（可选）。


