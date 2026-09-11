# AI 总结功能：数据需求与模板（二期前置设计文档）

> 版本 v1.0 · 2026-09-12 · 状态：**设计资产，未实现**
> 关联：《TimeTrack2 从零重建执行计划（完整最终版）.md》「AI 预留（二期接入）」章节、`AGENTS.md`、`lib/api/ai/`（LlmClient 骨架已就位）
> 依据：六领域科学调研（昼夜节律 / 专注与注意力 / 时间管理方法论 / 睡眠科学 / 时间哲学与时间感知 / 竞品总结实践）+ 数据层现状核查（schema v3）
> 定位：具体功能实现等应用一期完成后再启动；本文档只沉淀**需要什么数据**与**模板长什么样**，实现期按此逐项落位。

---

## 1. 设计原则（四条，来自调研与竞品教训）

1. **AI 不看原始数据，只看算好的信号。** 竞品调研核心教训（RescueTime / Reclaim / WakaTime Insights API）：解读必须锚定在可复现的指标上。统计由确定性 Dart 代码算出，LLM 只负责把「选中的信号 + 匹配的知识条目」组织成措辞。直接把时间条目丢给 LLM 必然产生幻觉式解读与算错数。
2. **证据分级引用。** 每条知识条目带 强 / 中 / 弱 等级：强证据可直接作建议依据；中等证据必须标注不确定性；弱证据（流行说法）禁止作为结论输出。
3. **个性化对照用户自己的基线，不对照人群固定钟点。** 昼夜节律调研明确结论：晨型/夜型相位差可达数小时，>80% 研究无 chronotype 对认知的主效应——不存在"全人类 9–11 点最佳"。一切时段结论以用户自身历史分布为准。
4. **只做信息性提醒，不做诊断、不制造时间罪恶感。** 时间哲学调研（塞内卡本意是唤醒而非谴责；Whillans 实证：主观时间贫困感本身损害幸福感）→ 总结语气必须是「中性观察 + 可选建议」，观察性关联不用因果措辞，医学判断一律不做。

---

## 2. 数据来源盘点（现有 schema v3 → 各字段支撑什么）

### 2.1 逐表清单

| 表 / 字段 | 对 AI 总结的用途 |
|---|---|
| `TimeEntries.startAt / endAt`（UTC ISO8601，endAt null=运行中） | 一切时间信号的基础：时长、时段、顺序、连续性 |
| `TimeEntries.activityId / activityName / activityColor`（快照） | 活动维度统计；快照保证活动改名/删除后历史可解读 |
| `TimeEntries.isAuto` | 口径开关：自动记录条目默认不计入统计（沿用 `includeAuto=false` 语义）；作息推断时须防"夜间自动记录持续"扭曲 |
| `TimeEntries.note` | **默认不进 LLM 提示词**（自由文本，隐私最小化）；信号层至多提供"有备注条目数"布尔/计数，是否引入正文由实现期单独决策 |
| `Activities.isUnassigned`（唯一未分配单例） | **作息推断的关键信号**：夜间/清晨的未分配（或无条目）窗口 = 入睡/起床代理；DayMetrics 的 focus/rest 分界已用它 |
| `Activities.isOneOff` | 一次性临时活动占比 → "计划外程度"信号 |
| `ActivityCategories`（parentId 自引用）+ `ActivityCategoryLinks.isPrimary` | 分类维度统计（主分类口径沿用 `slicesForRange`：isPrimary 优先 + sortOrder 升序取首个）；树聚合支持按祖先链归并 |
| `ProfileSettings.weekStartDay` | "本周"口径（统计页已用），周报环比必须同口径 |
| `ProfileSettings.timezone` | **非稳定 IANA 名**（`DateTime.timeZoneName`），仅展示兼容——跨时区/夏令时还原钟面时间有局限，作息类信号在时区变动期间标记为低可信 |
| `ActionLogs.actionType / occurredAt` | 真实交互时刻序列（switch/stop/undo…），可作"切换次数"的交叉验证信号；不作主信号 |
| 软删墓碑保留 180 天（`AppConstants.defaultDeletedRetentionDays`，之后 CleanupService 物理删除） | AI 基线的可用历史深度上限约 6 个月；实际受用户开始使用时间限制 |

### 2.2 数据形态事实（实现期必须遵守的口径）

- **已结束条目按本地日切段落库**（首段沿用原 id，后续段 uuid v5 派生 id `timetrack:entry-segment:<父id>:<段起点UTC ISO>`）——正常情况下"一天内条目不跨本地日"。但存在三类**暂态跨天行**：运行中条目（endAt=null）、合并导入后未归一化行、未来补记条目。**所有按日聚合必须沿用 `durationInWindow` / `StatsRepository.slicesForRange` 的半开区间裁剪口径**，不能直接按行 startAt 落日。
- 统计聚合现状：SQL 层无 GROUP BY，范围过滤在 SQL（软删 + 重叠判定），归并在 Dart 内存（`aggregate()` 纯函数）。AI 信号层应**复用** `StatsRepository.slicesForRange()` 与 `aggregate()`、`computeDayMetrics()`（`lib/utils/day_metrics.dart`），不另起炉灶。
- LLM 客户端现状：`LlmClient.chat(messages, options) -> AppResult<String>`（OpenAI 兼容），`LlmRequestOptions`（temperature/maxTokens/useJsonMode 等），`AiConfig`：超时 30s、重试 2 次、退避 500ms。总结=只读查询+独立本地缓存表；AI 产出的操作经命令分发器执行，不直接写库。

### 2.3 能算与不能算（诚实边界）

| 能算（有数据） | 只能代理（无直接数据） | 不能做 |
|---|---|---|
| 各活动/分类时长、占比、环比 | 入睡/起床时刻（用夜间未分配/无记录窗口代理） | 真实睡眠分期/睡眠质量 |
| 专注块、切换次数、碎片化 | 社交时差（工作日/休息日中点差代理） | 医学/心理判断（失眠、拖延症等） |
| 作息规律性（首末时刻的标准差） | 活动强度（无生理数据，只有时长） | 对单日数据下任何相位结论 |
| 个人基线偏离、新活动出现 | 打断原因（无中断源记录） | 诊断式归因（意志力/决策疲劳——已被证伪的理论） |

---

## 3. 信号清单（Insight Schema，5 组）

> 约定：每个信号 = {ID, 定义与计算口径, 数据来源, 复用/新算, 冷启动要求, 关联知识条目}。
> 所有信号汇总为一个 JSON（schema 见 §6.2），经信号选择层筛选后注入提示词。
> 默认阈值统一见 §3.6。

### 3.1 overview 组（时间去哪了）

| ID | 定义与口径 | 数据来源 | 复用/新算 | 冷启动 |
|---|---|---|---|---|
| `ov.total` | 范围内总记录时长（含未分配） | TimeEntries | **复用** `DayMetrics.total` | 0 天 |
| `ov.focus_rest` | 专注（非未分配）/ 休息（未分配）时长分列 | TimeEntries + isUnassigned | **复用** `DayMetrics.focus/rest` | 0 天 |
| `ov.category_share` | 主分类占比列表（含层级树可选） | slices + links.isPrimary | **复用** `slicesForRange`+`aggregate(primaryCategory / categoryTree)` | 0 天 |
| `ov.trend` | 环比：本周 vs 上周 / 今日 vs 上周同日（按 `weekStartDay` 口径） | 两次范围聚合相减 | **复用**（两次调用 + 相减） | 7 天 |
| `ov.top_activities` | Top N 活动时长与占比 | slices | **复用** `aggregate(activity)` | 0 天 |
| `ov.one_off_ratio` | 一次性活动（isOneOff）时长占比 → 计划外程度 | TimeEntries + Activities.isOneOff | **新算**（slices 无 isOneOff，需 join 活动表） | 0 天 |

### 3.2 rhythm 组（专注节奏）

| ID | 定义与口径 | 数据来源 | 复用/新算 | 冷启动 |
|---|---|---|---|---|
| `rh.focus_blocks` | 连续 ≥45min 的同主分类、非未分配条目块（相邻条目间隔 ≤5min 视为连续）；输出块列表 | 当日条目序列 | **新算** | 0 天 |
| `rh.longest_focus` | 当日最长专注块时长 | 同上 | **新算**（focus_blocks 派生） | 0 天 |
| `rh.switch_count` | 非未分配条目间的转变次数（相邻两条主分类或活动不同即 +1） | 当日条目序列 | **新算**（`DayMetrics.sessions` 可作粗近似） | 0 天 |
| `rh.fragmented_minutes` | 碎片化：时长 <15min 的非未分配条目时长之和及占比 | 当日条目序列 | **新算** | 0 天 |

关联知识：`attention_residue`（中）、`interruption_cost`（中）、`flow_conditions`（中）。

### 3.3 schedule 组（作息——全部为代理信号，措辞必须带"代理"意识）

| ID | 定义与口径 | 数据来源 | 复用/新算 | 冷启动 |
|---|---|---|---|---|
| `sc.first_last` | 当日首个非未分配条目开始时刻、末条目结束时刻（本地钟面） | 当日条目（运行中裁剪到 now） | **新算** | 0 天 |
| `sc.overnight_rest` | 夜间休息代理窗口：跨 [前一日 18:00, 今日 14:00] 内最长的"未分配或无条目"连续段，输出起/止/中点 | 未分配条目 + 条目空隙 | **新算**；isAuto 夜间持续、未来补记会扭曲，须按 §2.2 口径过滤 | 0 天 |
| `sc.midpoint_gap` | 社交时差代理：近 28 天工作日 vs 休息日 overnight_rest 中点均值之差 | sc.overnight 历史聚合 | **新算** | **14 天** |
| `sc.peak_window` | 个人活跃高峰窗口：按小时桶聚合专注时长，取连续 ≥14 天中总时长最高的 2–4h 窗口 | 历史条目 | **新算** | **14 天** |
| `sc.regularity` | 作息规律性：近 14 天 overnight_rest 起/止时刻的标准差 | sc.overnight 历史 | **新算** | **14 天** |

关联知识：`chronotype_individual_divergence`（强）、`social_jetlag`（强概念/中关联）、`sleep_duration_reference`（强）、`morning_light`（强）、`evening_light`（中-强）。
**约束**：`timezone` 非 IANA（§2.1），时区变动期间（检测到本地钟面跳变）本组信号降权或标记低可信。

### 3.4 anomaly 组（相对个人基线的异常）

| ID | 定义与口径 | 数据来源 | 复用/新算 | 冷启动 |
|---|---|---|---|---|
| `an.deviation` | 某分类当日时长 vs 滚动基线（近 28 天同类型日均值）：偏离 ≥2 倍且绝对差 ≥30min 记为异常日 | 历史 + 当日聚合 | **新算**（基线=滚动窗口均值，标准差可得时用 z-score） | **14 天** |
| `an.best_day` | 周期内 focus 时长最高的一天 | 历史聚合 | **新算**（WakaTime best_day 模式，验证有效的"亮点"） | 7 天 |
| `an.new_activities` | 周期内首次出现的活动 | Activities.createdAt 等价物（updatedAt 最早条目）/条目首次出现 | **新算** | 0 天 |

关联知识：`memory_density`（中，新活动 → 标记"值得记住"）、`peak_end_rule`（强）。

### 3.5 peakEnd 组（每日回放结构信号）

| ID | 定义与口径 | 数据来源 | 复用/新算 | 冷启动 |
|---|---|---|---|---|
| `pe.peak` | 当日最长/最连续专注块（=rh.longest_focus 对应块的起止与活动名） | 当日条目 | **新算**（rh 派生） | 0 天 |
| `pe.ending` | 当日最后 1–2 个条目（活动名 + 分类 + 时长） | 当日条目 | **新算** | 0 天 |

关联知识：`peak_end_rule`（强）——每日总结固定按"峰值 + 结尾"回放；建议模板"用一件满意的小事结束一天"直接对应此证据。

### 3.6 默认阈值表（**均为可调默认值，非科学定值**；实现期收敛到常量配置）

| 阈值 | 默认值 | 说明 |
|---|---|---|
| 专注块最短时长 | 45 min | rh.focus_blocks 判定线；心流/深工作无普适阈值，取中等常识值 |
| 相邻条目连续判定 | ≤5 min 间隔 | focus_blocks 合并条件 |
| 碎片条目线 | <15 min | fragmented_minutes 统计口径 |
| 基线窗口 | 滚动 28 天（最少 14 天可用） | an.deviation / sc.midpoint_gap |
| 异常判定 | ≥2 倍基线 且 绝对差 ≥30 min | 双条件防小基数误报 |
| 社交时差关注线 | 中点差 ≥1.5 h | 超过才触发提示（人群普遍 1–2h，>2h 才算高） |
| 睡眠参考 | 成人 ≥7h（知识库引用值，非应用阈值） | 仅用于"与推荐区间的差距"表述 |
| 解读冷启动线 | <3 天 / 3–13 天 / ≥14 天 | 见 §4 |

---

## 4. 冷启动分级（数据不足时的行为约定）

| 等级 | 条件 | 行为 |
|---|---|---|
| L0 仅统计 | 有记录天数 <3 天 | 只输出数字（总时长、分类占比），无任何解读与建议；附固定文案 |
| L1 趋势 | 3–13 天 | overview 组全部可用；`an.*`、`sc.midpoint_gap`、`sc.peak_window`、`sc.regularity` 禁用；建议可用但须注明"基于这几天" |
| L2 全量 | ≥14 天 | 全部信号可用；insightLevel=full |

L0 固定文案模板：

> 记录还刚开始。现在能告诉你的是：今天共记录 X 小时 Y 分，其中专注 Z 小时。数据积累到 3 天后，这里会开始出现趋势解读；积累到两周后，能看出你的作息规律和个人节奏。

（X/Y/Z 由信号填充；AI 不可用时同样输出此模板的降级版。）

---

## 5. 知识条目格式 + 种子条目表

### 5.1 条目格式

```
{
  "id": "afternoon_dip",                    // 知识条目唯一 ID
  "triggerSignals": ["rh.fragmented_high"], // 触发它的信号条件（信号选择层据此检索）
  "claim": "一句话科学结论",
  "evidenceGrade": "strong | moderate | weak",
  "phrasing": "给 AI 的措辞方向",
  "taboo": "该条目相关的禁止表述",
  "source": "URL / 论文"
}
```

注入规则：**只注入被选中信号命中的条目**（检索式，非全量塞入——token 预算 + 薄封装约束）。

### 5.2 种子条目表（23 条，证据等级沿用调研结论）

**强证据（strong）——可直接作建议依据**

| id | claim | 触发信号 | phrasing / taboo | source |
|---|---|---|---|---|
| `circadian_afternoon_dip` | 午后困倦是昼夜节律双峰曲线的固有第二峰（约 13–16 点），不吃午饭也会发生；高碳水午餐只是加重因素 | `rh.fragmented_minutes` 高 且 时段在午后 | 措辞：解释为正常生理现象，减少自责 / 禁忌：不说"下午效率低是态度问题" | europepmc（Monk 2005；Lavie 双峰） |
| `chronotype_individual_divergence` | 晨型/夜型昼夜节律相位可差数小时；"个人最佳时段"真实存在但高度个体化，无全人类固定最佳钟点 | 一切时段类结论 | 措辞：时段结论一律对照用户自己的 `sc.peak_window` / 禁忌：禁止"9–11 点最佳"类固定钟点表 | europepmc（同步效应综述；Kantermann MEQ↔DLMO r=0.70） |
| `social_jetlag` | 工作日与休息日作息中点差被称为"社交时差"，人群普遍 1–2h；>2h 与 BMI、情绪、学习成绩相关（观察性） | `sc.midpoint_gap` ≥1.5h | 措辞："与…相关" / 禁忌：不说"会导致肥胖/抑郁" | europepmc（Wittmann 2006；Roenneberg 2012） |
| `sleep_duration_reference` | 权威推荐：成人每晚 ≥7h，青少年 8–10h | `sc.overnight_rest` 明显偏短 | 措辞："你的数据与推荐区间的差距"，信息性 / 禁忌：不做失眠/睡眠障碍诊断 | sleepfoundation.org / nhlbi.nih.gov |
| `napping_inertia` | 约 20min 短睡提神且不易昏沉；约 90min 走完一个睡眠周期；超过 30min 在深睡中醒来会产生 15–60min 睡眠惰性（昏沉是正常的） | 白天出现长休息块（未分配 ≥30min，时段午后） | 措辞：把"越睡越困"解释为睡眠惰性，非异常 | sleepfoundation.org（napping / sleep-inertia） |
| `caffeine_half_life` | 咖啡因半衰期约 5–6h；睡前 6h 摄入仍使客观睡眠减少约 1.1–1.2h（RCT） | 晚间条目/备注含咖啡因类活动（若用户建了此类活动）+ 入睡晚 | 措辞：基于用户就寝时间反推"X 点后不喝" | pmc.ncbi.nlm.nih.gov/articles/PMC3805807（Drake） |
| `implementation_intentions` | 把计划写成"当 X 出现，我就做 Y"（if-then），目标达成率显著提升——元分析 94 项研究 d=0.65，是时间管理方法中证据最强的 | 建议类输出 | 措辞：建议默认用 if-then 形式 | doi.org/10.1016/S0065-2601(06)38002-1（Gollwitzer & Sheeran 2006） |
| `peak_end_rule` | 人对一段经历的记忆主要由"峰值时刻"和"结尾"决定，总时长几乎不影响回顾评价（duration neglect） | 每日总结固定结构 | 措辞：按"最投入时刻 + 怎么收尾"回放；可建议"用一件满意的小事结束一天" | nobelprize.org（Kahneman 自述）；Redelmeier & Kahneman 1996 |
| `time_poverty_language` | 主观"时间贫困感"本身损害幸福感与人际关系，与客观忙碌是两回事；"花钱买时间"可显著提升幸福感（PNAS 现场实验） | 全局语气约束 | 措辞：不制造时间罪恶感；忙碌但碎片化时建议"减少切换/整块留白"而非"排得更满" | doi.org/10.1073/pnas.1706541114（Whillans 2017） |
| `morning_light` | 早晨户外明亮光照可前移昼夜节律相位并提高日间警觉；室内办公光照普遍不足（阳光 ~10000 lux vs 办公室 <500 lux） | 作息偏晚的建议场景 | 措辞："早上接触 10–30 分钟户外光" | sleepfoundation.org；Khalsa 2003 PRC |
| `ego_depletion_ban` | "意志力是有限资源、会被耗尽"（自我损耗理论）在多实验室预注册复现中失败（d=0.04，CI 含零）；经典"假释法官决策疲劳"研究被认定为案件排序伪影 | 禁用型条目 | 禁忌：禁止用"意志力耗尽/决策疲劳/自控力不足"解释任何低效时段 | doi.org/10.1177/1745691616652873（Hagger 2016） |
| `zeigarnik_ban` | "未完成任务会一直占据头脑"（泽伊加尔尼克效应）在 2025 年元分析中无普适记忆优势，不可复制 | 禁用型条目 | 禁忌：不建议"故意留个尾巴/不做完更高效" | doi.org/10.1057/s41599-025-05000-w |

**中等证据（moderate）——必须标注不确定性**

| id | claim | 触发信号 | phrasing / taboo | source |
|---|---|---|---|---|
| `attention_residue` | 任务切换后注意力会"残留"在前一任务（未完成任务残留更强），拖累后续表现 | `rh.switch_count` 高 / `rh.fragmented_minutes` 高 | 措辞："有研究发现切换有认知代价" / 不给精确分钟数 | doi.org/10.1016/j.obhdp.2009.04.002（Leroy 2009） |
| `interruption_cost` | 现场观察：知识工作者平均约每 3 分钟切换一次工作事件，被打断的工作平均约 25 分钟才恢复；被打断时人会加速补偿，但压力与挫败感显著升高 | `rh.switch_count` 高 | 措辞：可作启发式估算并注明"现场研究、个体差异大" / 禁忌：不把"23 分钟"当精确事实（那是媒体转述，原文 25 分 26 秒） | ics.uci.edu/~gmark/chi08-mark.pdf（Mark 2005/2008） |
| `evening_planning` | 睡前写下明天要做的具体待办，入睡显著更快（多导睡眠图实验，n=57；写得越具体越快） | `sc.overnight_rest` 起点晚 + 当日有未完成事项语境 | 措辞："睡前花几分钟写下明天 1–3 件具体的事" | doi.org/10.1037/xge0000374（Scullin 2018） |
| `deadline_effect` | 外部、适度偏紧的截止日期提升完成率；过长的截止日期反而让人推断任务更难、更容易拖延（mere deadline effect） | 建议类输出 | 措辞：建议为拖延任务设"适度偏紧"的自设时限 | doi.org/10.1111/1467-9280.00441（Ariely 2002）；doi.org/10.1093/jcr/ucy030 |
| `regular_breaks` | 定时休息可降低累积疲劳（综述显示疲劳约降 20%），但"25 分钟工作+5 分钟休息"的番茄钟具体数字没有科学依据；休息时长应因人而异（20–90 分钟） | 连续工作 ≥2h 无休息 | 措辞："定时休息有帮助"，不绑定 25 分钟 / 禁忌：不把番茄钟当科学结论 | doi.org/10.1111/bjep.12593（Biwer 2023） |
| `recovery_detachment` | 工作后"心理脱离"（不再想工作）预测次日活力与表现（职业健康心理学多项纵向研究） | 晚间仍持续工作 / 全天高强度 | 措辞："晚上留一段与工作无关的时间" | doi.org/10.1037/1076-8998.10.4.393（Sonnentag） |
| `memory_density` | 时间感由记忆密度塑造：新体验让一段日子显得更长更充实；高度重复的日子会"连成一片、显得飞逝"——这是记忆机制，不是人生失败 | 连续高度重复日 / `an.new_activities` 非空 | 措辞：把"时间飞逝"解释为认知机制；新活动单独标记"值得记住" | 《Time Warped》(Claudia Hammond) |
| `flow_conditions` | 心流（全神贯注、时间感扭曲）出现的条件：挑战与技能匹配、目标清晰、反馈即时 | `rh.longest_focus` 长（解读深度块） | 措辞：用"挑战与技能匹配的投入"描述深度块 | doi.org/10.1037/0022-3514.56.5.815（Csikszentmihalyi & LeFevre 1989） |
| `evening_light` | 夜间光照会抑制褪黑素（实验室证据一致）；但真实屏幕使用场景的效应量较小，"夜间光照导致慢性病"不是因果结论 | 深夜屏幕类活动时长高 | 措辞：谨慎的"可能"，避免恐吓 / 禁忌：不说"蓝光会导致 XX 病" | health.harvard.edu（blue light）；sleepfoundation.org |

**弱证据（weak）——仅作禁用/谨慎依据，禁止作为结论输出**

| id | claim | 用途 | source |
|---|---|---|---|
| `morning_routine_myth` | "黄金一小时/晨间例行决定一天"无实验支持；有证据的只是"匹配个人时型"，固定晨间时段对夜型人反而有害 | 禁用依据：不输出"早起才是自律"类表述 | chronotype 与上课时间研究（Enright & Refinetti 2017 等） |
| `deep_work_cap` | "一天最多 3–4 小时深度工作"出自畅销书对刻意练习文献的引申，无直接实验 | 可作参考性提法（"许多深度工作者发现…"），不当硬标准、不评判未达标者 | Newport《Deep Work》(2016) |
| `pomodoro_no_magic` | 番茄工作法 25/5 的具体数字无科学依据（并入 `regular_breaks` 的禁忌面） | 禁用依据：不写"科学证明 25 分钟最有效" | todoist.com 方法论页自述 + Biwer 2023 |

### 5.3 禁用清单（提示词直接引用；后校验据此扫描）

1. 禁止"意志力耗尽 / 决策疲劳 / 自控力不足 / 懒 / 不自律"类归因（`ego_depletion_ban`）。
2. 禁止"浪费 / 荒废 / 又刷了 X 小时可耻"类评判；刷屏类活动用中性描述 + 可选建议（`time_poverty_language`）。
3. 禁止固定钟点表："上午 9–11 点效率最高 / 几点喝咖啡最好 / 黄金一小时"（`chronotype_individual_divergence`、`morning_routine_myth`）。
4. 禁止精确引用"被打断后 23 分钟恢复"等媒体数字；切换成本表述必须带"约/研究表明/个体差异"（`interruption_cost`）。
5. 禁止医学/心理诊断词：失眠、拖延症、抑郁、焦虑症、ADHD 等；只能做"与推荐区间的差距 / 与…相关"式信息性表述（`sleep_duration_reference`、`social_jetlag`）。
6. 观察性关联禁止因果措辞：不说"导致/造成/必然"，说"相关/伴随"。
7. 禁止"故意留未完成任务更高效"类建议（`zeigarnik_ban`）。
8. 禁止恐吓式健康警告（蓝光致病、睡眠不足致死等）（`evening_light`）。
9. **数字只能来自输入信号 JSON 与知识条目原文**，禁止自算新数字、禁止编造用户没有的活动名。
10. 建议一律"可选"语气（"如果你愿意，可以试试…"），不用命令式；不使用效率评分/打分制评价用户的一天。

---

## 6. 提示词模板

### 6.1 System prompt 模板（每日/每周共用骨架，占位符实现期填充）

```
你是时间记录应用 TimeTrack 的总结助手。用户的时间统计已由程序计算完成，以 JSON 提供给你。
你的任务：把这些数字组织成温和、具体、有依据的总结文字。你只做两件事——解释数字、给出可选建议；
不猜测数据之外的任何事实。

【硬性规则】
1. 只能使用【信号数据】中出现的数字、活动名、分类名；禁止心算新数字，禁止推测未提供的数据。
2. 引用研究结论时只能引用【知识条目】内容，并按 evidenceGrade 措辞：
   strong → 可作为建议依据（"研究表明…"）；moderate → 必须带不确定性（"有研究提示…/作为参考"）；
   weak → 禁止作为结论。
3. 遵守【禁用清单】全部条目。
4. 一切"什么时候适合做什么"的结论，以【信号数据】中用户自己的基线（baseline/peakWindow）为准，
   不引用人群固定钟点。
5. 语气：中性观察 + 可选建议；不评判人格；建议用"如果你愿意/可以试试"。
   同时照顾两个视角：效率视角（时间去了哪）与意义视角（这些时间里值得记住什么）。
6. 输出为纯文本，{length_limit}，不使用 markdown 标题。

【禁用清单】
{banned_list}

【输出结构】
{output_structure}   ← 每日/每周模板不同，见 §7

【知识条目（与本次信号匹配）】
{knowledge_entries}
```

### 6.2 User content 模板

```
【信号数据】
{signals_json}

【匹配的知识条目】
{matched_knowledge_json}
```

信号 JSON schema（示例值为示意，字段以 §3 为准）：

```json
{
  "meta": { "granularity": "daily", "date": "2026-09-12", "weekStartDay": 1,
            "daysWithRecord": 26, "insightLevel": "full" },
  "overview": { "totalMinutes": 512, "focusMinutes": 341, "restMinutes": 171,
    "categories": [ { "label": "工作", "minutes": 280, "shareNow": 0.55, "sharePrev": 0.42 } ],
    "topActivities": [ { "name": "写代码", "minutes": 180 } ],
    "oneOffMinutes": 25 },
  "rhythm": { "focusBlocks": [ { "start": "10:05", "end": "11:40", "label": "工作", "minutes": 95 } ],
    "focusBlockCount": 3, "longestFocusMinutes": 95,
    "switchCount": 23, "fragmentedMinutes": 84 },
  "schedule": { "firstActivity": "08:40", "lastEnd": "23:40",
    "overnightRest": { "from": "00:30", "to": "08:10", "midpoint": "04:20", "confidence": "normal" },
    "weekdayWeekendMidpointGapHours": 1.8,
    "peakWindow": { "start": "10:00", "end": "12:00" },
    "regularitySdMinutes": { "from": 55, "to": 40 } },
  "anomaly": { "deviations": [ { "label": "短视频", "todayMinutes": 180, "baselineMean": 35, "ratio": 5.1 } ],
    "bestDay": null, "newActivities": [] },
  "peakEnd": { "peak": { "start": "10:05", "end": "11:40", "name": "写代码" },
    "ending": [ { "name": "短视频", "minutes": 60 } ] }
}
```

匹配的知识条目 JSON（信号选择层输出）：

```json
[
  { "id": "circadian_afternoon_dip", "claim": "…", "evidenceGrade": "strong",
    "phrasing": "…" }
]
```

### 6.3 三粒度变体差异

| | daily（每日总结） | weekly（每周总结） | qa（按需问答） |
|---|---|---|---|
| 信号范围 | overview + rhythm + sc.overnight(当日) + an(当日) + peakEnd | overview(周) + trend + an.best_day/deviation + sc.midpoint_gap/regularity | 用户问题 → 信号选择层检索相关信号子集 |
| 输出结构 | §7.1 模板 | §7.2 模板 | 自由文本 ≤150 字，但硬性规则与禁用清单不变 |
| 知识注入 | 按当日信号命中 | 按周信号命中 | 按问题关键词 + 信号命中 |
| 触发方式 | 用户手动（或每日固定时刻，实现期定） | 周报（weekStartDay 口径） | 用户提问 |

---

## 7. 输出结构模板与措辞规范

### 7.1 每日输出结构（3 数字 + 2 发现 + 1 建议 + 峰终回放，≤250 字）

```
① 三个数字：今天共记录 X 小时 / 最投入的一块是「活动名」Y 分钟 / 与上周同日相比 ±Z%
② 发现一：来自 rhythm/schedule 信号 + 命中的知识条目解释（如午后碎片多 → circadian_afternoon_dip）
③ 发现二：来自 anomaly/对比（如某分类突增 → 中性描述 + 询问式关注）
④ 一个建议：优先从 implementation_intentions / evening_planning / regular_breaks 中按命中选一，
   以 if-then 形式给出（"明天下午 3 点左右，如果你愿意，可以…"）
⑤ 峰终回放：今天最投入的时刻 + 一天是怎么结束的
```

### 7.2 每周输出结构（≤350 字）

```
① 三个数字：周总时长 / 专注总时长 / vs 上周
② 趋势与迁移：分类占比变化最大的一两项（归因到活动名）
③ 异常与亮点：an.best_day（"最好的一天"）+ 显著偏离日（中性描述）
④ 作息观察：midpoint_gap / regularity（命中 social_jetlag 时严格相关性措辞）
⑤ 一个建议：if-then 形式，落在下周可执行的一件事上
```

### 7.3 措辞规范

- 结构固定、长度受限：宁可少说，不可堆砌（反思阶段头号障碍是"数据太多看不懂"，Li & Dey CHI 2010）。
- 每条建议必须可落成一个动作，并可在 UI 上跳转到相关设置（洞察→行动闭环，Apple Screen Time 模式）。
- 对比一律"比你自己上周/过去四周"，不比人群。
- 关联说关联，代理说代理（作息信号统一用"入睡代理/大概"口径，或以"最后活动/首次活动"表述）。

### 7.4 好/坏对照示例

信号输入（节选）：`rh.fragmentedMinutes` 午后偏高、`sc.midpointGapHours=1.8`、`pe.peak=10:05–11:40 写代码 95min`、`pe.ending=短视频 60min`。

❌ 坏的评价（无知识注入、无禁用清单的裸 LLM）：

> 你今天下午效率低下，意志力明显不足，拖延严重。上午 9-11 点是黄金工作时间，你没有抓住。建议你早起并使用番茄钟，25 分钟专注能够科学提升效率。你的睡眠也不达标，长期下去会损害健康。

✅ 好的评价（按本方案）：

> 今天共记录 8 小 32 分，最投入的一块是上午 10:05–11:40 的「写代码」，连续 95 分钟。下午碎片时间偏多——午后出现低谷是正常的昼夜节律现象，几乎人人如此，不用放在心上。你的工作日与休息日作息中点相差约 1.8 小时，这种差距常被称作"社交时差"，研究发现它与日间状态相关；如果你愿意，可以试试今晚把屏幕时间提前半小时。今天以一段短视频收尾——试着用一件让你满意的小事结束一天，会让这一天在记忆里更完整。

---

## 8. 护栏清单与实现期待定项

### 8.1 后校验规则（LLM 输出 → 用户可见之间，代码强制执行）

| 规则 | 做法 | 失败处置 |
|---|---|---|
| 数字溯源 | 正则提取输出中所有数字，必须能在输入 signals_json 或知识条目文本中找到（允许格式化差异） | 整条丢弃 → 降级模板 |
| 禁词扫描 | §5.3 禁用清单 → 词表匹配（意志力/决策疲劳/浪费/拖延症/黄金时间/导致…等） | 命中即降级或请求重试一次 |
| 活动名校验 | 输出中的活动/分类名必须是输入 JSON 出现过的 | 命中未知名 → 降级 |
| 长度上限 | 每日 ≤250 字 / 每周 ≤350 字 / 问答 ≤150 字 | 截断或降级 |
| 建议数量 | ≤1 条建议（模板结构强制） | 超出截断 |

### 8.2 降级策略（离线优先铁律）

- LLM 未配置 / 离线 / 超时（`AiConfig.requestTimeout`=30s，重试 2 次后仍失败）→ **模板化纯统计总结**：直接渲染信号数字 + 固定句式（"本周专注共 X 小时，比上周多 Y%；最好的一天是周 Z"），无解读无建议。UI 不因 AI 失败而空窗。
- 冷启动 L0/L1：模板文案见 §4。
- 总结结果写本地缓存表（执行计划已预留）；重复触发同范围总结优先读缓存（与 StatsStore 的 revision 失效思路一致：数据变更才重算）。

### 8.3 隐私约束

- 发送给 LLM 的内容**只有聚合信号与知识条目**：不含备注正文、不含原始条目逐条明细、不含设备/同步信息（隐私最小化 + 数据出境披露已在执行计划中）。
- 用户可选本地 Ollama（`LlmCapability` 已预置）时，无出境问题，约束不变。

### 8.4 实现期待定项（本文档不决策，实现时逐项确认）

1. 信号计算器落位：`data/`（复用仓储查询）vs `stores/`（编排+缓存）——倾向 signals 层放 `data/repositories` 新仓储、编排放新 store，与现有分层一致。
2. 总结缓存表 schema（表名、字段、revision 关联方式、保留条数）。
3. token 预算与 `LlmRequestOptions` 取值（temperature/maxTokens/useJsonMode）按所选模型实测后定。
4. 每日总结触发时机（固定时刻 vs 手动）与提醒集成。
5. `note` 正文是否进问答场景（默认否，见 §2.1）。
6. 知识条目的承载形式：Dart 常量表 vs assets JSON（倾向常量表，便于测试与 ARB 无关性——知识条目是 AI 提示词配置，不是 UI 文案）。
7. 后校验的禁词表维护方式与多语言（二期若做英文界面，提示词与词表需成对本地化）。
8. `ActionLogs` 交叉验证信号是否纳入首版（建议不纳入，保持信号层最小）。

---

## 附：调研证据源速查（种子条目 source 汇总）

- 昼夜节律/双峰/社交时差：europepmc（Lavie；Monk 2005；Wittmann 2006；Roenneberg 2012；Kantermann）；nigms.nih.gov；sleepfoundation.org/circadian-rhythm
- 光照：Khalsa 2003（PRC）；pmc.ncbi.nlm.nih.gov/articles/PMC4020279（Wright 露营）；health.harvard.edu（blue light）
- 睡眠结构/需求/午睡/咖啡因：sleepfoundation.org（stages-of-sleep / napping / sleep-inertia / caffeine-and-sleep）；ncbi.nlm.nih.gov/books/NBK526132（StatPearls）；pmc.ncbi.nlm.nih.gov/articles/PMC3805807（Drake）；pubmed.ncbi.nlm.nih.gov/12683469（van Dongen）
- 注意力/切换：doi.org/10.1016/j.obhdp.2009.04.002（Leroy）；ics.uci.edu/~gmark/（Mark 2005/2008/2016）；doi.org/10.3758/BF03193094（Altmann & Trafton）
- 自我损耗证伪：doi.org/10.1177/1745691616652873（Hagger 2016）；doi.org/10.3389/fpsyg.2014.00823（Carter 2014）
- 方法论：doi.org/10.1016/S0065-2601(06)38002-1（实施意图）；doi.org/10.1037/xge0000374（前夜规划）；doi.org/10.1111/1467-9280.00441（截止日期）；doi.org/10.1111/bjep.12593（番茄钟/休息）；doi.org/10.1057/s41599-025-05000-w（泽伊加尔尼克 2025 元分析）
- 哲学/感知：塞内卡《论生命之短暂》；Burkeman《四千周》；Odell《How to Do Nothing》《Saving Time》；Hammond《Time Warped》；nobelprize.org（Kahneman 峰终）
- 时间贫困：doi.org/10.1073/pnas.1706541114；doi.org/10.1038/s41562-020-0920-z
- 竞品/框架：rescuetime.com/features；wakatime.com/docs（Insights API）；support.apple.com/HT208982；reclaim.ai；doi.org/10.1145/1753326.1753409（Li & Dey, Personal Informatics, CHI 2010）
