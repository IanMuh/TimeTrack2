# TimeTrack2 设计稿统一设计语言（所有 HTML 设计稿必须遵守）

> 唯一功能输入：`D:\MyAPP\TimeTrack2\UI功能契约.md`。本文件只规定视觉一致性，不重复功能需求。
> 所有产出文件放在 `D:\MyAPP\TimeTrack2\design\` 下。

## 技术形态（每个 HTML 文件都遵守）

- 单文件 HTML：Tailwind CDN + lucide 图标 + （需要图表时）chart.js CDN。头部模板：

```html
<!DOCTYPE html>
<html lang="zh-CN">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>TimeTrack · {页面名}</title>
<script src="https://cdn.tailwindcss.com"></script>
<script>
  tailwind.config = { darkMode: 'class' }   // 深色用 class 策略，这是唯一允许的 config
</script>
<script src="https://unpkg.com/lucide@latest/dist/umd/lucide.min.js"></script>
<style>
  body { font-family: Inter, "Noto Sans SC", "Microsoft YaHei", system-ui, sans-serif; }
  .tnum { font-variant-numeric: tabular-nums; }  /* 计时/时长数字必须加此类，保证不跳动 */
</style>
</head>
```

- 图标：`<i data-lucide="timer" class="w-4 h-4"></i>`（stroke-width 由 lucide 默认 2 即可，统一 `w-4 h-4` / `w-5 h-5` 档），body 末尾 `<script>lucide.createIcons()</script>`。
- 除上述 style 外不写自定义 CSS 类，全部用 Tailwind 原子类；深浅色一律用 `dark:` 变体。
- 交互只写最小 JS（tab 切换、折叠展开、深色切换、对话框显示/隐藏），不实现业务逻辑；展示型对话框可直接以"已打开"状态呈现在页面中（用场景分区平铺展示，而非默认隐藏）。

## 断点映射（契约 §1 三档 → Tailwind 任意变体）

- 紧凑 < 600px：默认（无前缀）
- 中宽 600–840：`min-[600px]:`
- 宽屏 ≥ 840：`min-[840px]:`
- 导航形态：≥840 左侧纵向导航栏（固定 232px 宽）；< 840 底部导航（5 项，图标+文字）。**每个页面文件都必须带完整应用壳**（见下）。

## 色彩令牌

- 品牌主色：indigo-600（`bg-indigo-600` 按钮 / `text-indigo-600` 强调）；hover: indigo-500。
- 浅色：页面底 `bg-zinc-50`，卡片 `bg-white`，边框 `border-zinc-200`，主文字 `text-zinc-900`，次文字 `text-zinc-500`。
- 深色：`dark:bg-zinc-950` 页面底，`dark:bg-zinc-900` 卡片，`dark:border-zinc-800`，`dark:text-zinc-100`，`dark:text-zinc-400`。
- 语义色：成功 emerald-500，警告 amber-500，危险 red-500，信息 sky-500。
- 活动色板（8 色，活动分类用，深浅色同色相）：rose-500 / orange-500 / amber-500 / emerald-500 / teal-500 / sky-500 / indigo-500 / violet-500。色点用 `bg-{c}-500`，大面积底色浅色用 `bg-{c}-50` 深色用 `dark:bg-{c}-500/10`，文字色 `text-{c}-600 dark:text-{c}-400`。
- "未分配"活动固定用 zinc-400。

## 字体与排版

- 标题 > 20px 一律 `tracking-tight font-semibold`；页面大标题 24–28px；卡片标题 15–16px `font-medium`。
- 字重压一档：视觉上想要 bold 的地方用 `font-semibold`，想要 semibold 用 `font-medium`。
- 所有计时/时长/统计数字加 `tnum` 类；运行中大计时数字 56–72px `font-semibold tracking-tight tnum`。
- 文案全部中文占位（契约 §1.4）。

## 组件形态

- 卡片：`rounded-2xl border border-zinc-200 dark:border-zinc-800 bg-white dark:bg-zinc-900`，需要层次处加 `shadow-sm`；不要重阴影。
- 主按钮：`rounded-lg bg-indigo-600 text-white text-sm font-medium px-4 py-2 hover:bg-indigo-500`；次按钮：`rounded-lg border border-zinc-200 dark:border-zinc-700 text-sm px-4 py-2 hover:bg-zinc-50 dark:hover:bg-zinc-800`；危险按钮用 red。
- 输入框：`rounded-lg border border-zinc-200 dark:border-zinc-700 bg-white dark:bg-zinc-900 px-3 py-2 text-sm`，focus 示意 `focus:ring-2 ring-indigo-500/40`。
- 开关（toggle）、复选、滑块：用自绘样式（div+span），不用原生控件外观。
- 标签/徽标：`rounded-full text-xs px-2 py-0.5`；is_auto 自动条目标识 = `sky-500` 色系小徽标"自动"（带 sparkles/zap 图标）。
- 分割线：`border-zinc-100 dark:border-zinc-800` 细线，多用 1px 分割而非留白硬切。
- 对话框：桌面居中 `max-w-lg w-full rounded-2xl`；移动底部抽屉 `rounded-t-2xl`。遮罩 `bg-zinc-950/40`。
- Snackbar：深色浮条 `bg-zinc-900 dark:bg-zinc-800 text-white rounded-xl px-4 py-3 shadow-lg`，可带"撤销"按钮（indigo-300 文字）。
- 横幅：`border-l-4` + 浅底色（如 amber-50 / dark:amber-500/10）。

## 应用壳（除 index.html 外每个页面文件必须包含）

- 品牌：侧导航顶部 / 移动顶栏显示 `TimeTrack` 字样（`font-semibold tracking-tight`，字母标，不做图形 logo）。
- 导航 5 项（lucide 图标）：计时 timer / 今日 calendar-days / 时间线 rows-3（或 gallery-vertical）/ 统计 chart-pie（pie-chart）/ 设置 settings。当前页高亮：`bg-indigo-50 dark:bg-indigo-500/10 text-indigo-600 dark:text-indigo-400`。
- 宽屏侧导航内含：撤销/重做按钮组（undo-2/redo-2 图标 + 动作名提示）、同步状态小指示（cloud 图标 + "已同步"）。
- **全局计时条**（常驻，贯穿所有页）：宽屏固定在主内容底部，高 56px，左=活动色点+活动名+实时计时（tnum 秒级样式，静态写死如 01:24:36），右="停止"按钮 + "切换"按钮；未运行态在相应页面弱化呈现"未在记录"。紧凑档：底部导航上方叠置一层计时条（两层叠置）。
- 每个页面右上角放一个深/浅色切换按钮（moon/sun 图标，JS 切 `document.documentElement.classList.toggle('dark')`），方便验收双主题。
- 主内容区：宽屏 `min-[840px]:ml-[232px]`，底部为计时条留出 padding（`pb-20`）。

## index.html（总览页，由系统组件 agent 产出）

- 浅色专业风格的设计提案导航页：顶部产品名 + 设计说明一句话；每个页面一张卡片（页面名 + 覆盖的契约要点简述 + "打开"链接）；卡片内嵌三个宽度（390 / 700 / 1280px）的 iframe 预览（可用 `transform: scale()` 缩放嵌入）；另附深浅色说明与活动色板展示条。
