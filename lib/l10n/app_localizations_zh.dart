// ignore: unused_import
import 'package:intl/intl.dart' as intl;
import 'app_localizations.dart';

// ignore_for_file: type=lint

/// The translations for Chinese (`zh`).
class AppLocalizationsZh extends AppLocalizations {
  AppLocalizationsZh([String locale = 'zh']) : super(locale);

  @override
  String get appTitle => 'TimeTrack2';

  @override
  String get appBrand => 'TimeTrack';

  @override
  String get appSubtitle => '时间追踪';

  @override
  String get navTimer => '计时';

  @override
  String get navToday => '今日';

  @override
  String get navTimeline => '时间线';

  @override
  String get navStats => '统计';

  @override
  String get navSettings => '设置';

  @override
  String get pagePlaceholder => '骨架占位——此区域由后续模块填充';

  @override
  String get settingsGeneral => '通用';

  @override
  String get settingsData => '备份与导出';

  @override
  String get settingsReminders => '提醒';

  @override
  String get settingsTimeline => '时间线';

  @override
  String get settingsCloudSync => '云同步';

  @override
  String get settingsInterop => '设备互通';

  @override
  String get settingsUpdate => '版本更新';

  @override
  String sectionPlaceholder(Object section) {
    return '“$section”设置分区（骨架占位）';
  }

  @override
  String get back => '返回';

  @override
  String get loading => '加载中…';

  @override
  String get noData => '暂无数据';

  @override
  String get save => '保存';

  @override
  String get cancel => '取消';

  @override
  String get delete => '删除';

  @override
  String get ok => '确定';

  @override
  String get commandDone => '已完成';

  @override
  String get notStartedRecord => '未开始记录';

  @override
  String get notRecording => '未在记录';

  @override
  String get timerBarGoToTimer => '回到计时页';

  @override
  String get timerBarSwitchHint => '点击切换活动';

  @override
  String get timerBarSwitch => '切换活动';

  @override
  String get timerBarSwitchUnavailable => '切换活动选择器将在后续版本提供';

  @override
  String get undo => '撤销';

  @override
  String get redo => '重做';

  @override
  String get undoHint => '撤销上一步操作';

  @override
  String get redoHint => '重做上一步操作';

  @override
  String undoWithLabel(Object label) {
    return '撤销：$label';
  }

  @override
  String redoWithLabel(Object label) {
    return '重做：$label';
  }

  @override
  String get history => '历史';

  @override
  String get currentDoing => '正在做什么';

  @override
  String get recording => '记录中';

  @override
  String get notStarted => '未开始';

  @override
  String get stop => '停止';

  @override
  String get switchActivity => '切换活动';

  @override
  String get today => '今天';

  @override
  String get sessions => '会话数';

  @override
  String get quickActivity => '快捷活动';

  @override
  String get oneOff => '临时';

  @override
  String get newActivity => '新建活动';

  @override
  String get editActivity => '编辑活动';

  @override
  String get editTooltip => '编辑';

  @override
  String get stopCurrentActivity => '停止当前活动';

  @override
  String get currentSession => '当前会话';

  @override
  String get confirmSwitch => '再次点击确认切换';

  @override
  String switchToSemantics(Object name) {
    return '切换到 $name';
  }

  @override
  String currentActivitySemantics(Object name) {
    return '当前活动：$name';
  }

  @override
  String confirmSwitchSemantics(Object name) {
    return '确认切换到 $name';
  }

  @override
  String get selectDate => '选择日期';

  @override
  String get previousDay => '前一天';

  @override
  String get nextDay => '后一天';

  @override
  String get emptyDayEntries => '今日暂无记录';

  @override
  String get emptyRangeEntries => '该时段暂无记录';

  @override
  String get emptyDayActions => '今日暂无操作';

  @override
  String get emptyRangeActions => '该时段暂无操作';

  @override
  String get addEntry => '添加条目';

  @override
  String get entries => '条目';

  @override
  String get actions => '日志';

  @override
  String get singleDay => '当天';

  @override
  String get threeDays => '三天';

  @override
  String get thisWeek => '本周';

  @override
  String get sevenDays => '七天';

  @override
  String get viewMode => '视图模式';

  @override
  String get timeline => '时间线';

  @override
  String get zoomableTimeline => '时间线画布';

  @override
  String get entryList => '条目列表';

  @override
  String get entryListHint => '按时间排列的详细记录';

  @override
  String get totalRangeRecords => '总时长';

  @override
  String get longestStreak => '最长连续';

  @override
  String get inProgress => '进行中';

  @override
  String futureDayBanner(Object date) {
    return '“$date”是未来日期，暂无可记录';
  }

  @override
  String get noDataToVisualize => '暂无数据可展示';

  @override
  String get startRecordingHint => '开始记录你的时间吧';

  @override
  String get recordHint => '记录从计时页开始';

  @override
  String get switchToRecordHint => '去计时页开始记录';

  @override
  String get stats => '统计';

  @override
  String statsSubtitle(Object range) {
    return '统计范围：$range';
  }

  @override
  String get todayLabel => '今天';

  @override
  String get yesterday => '昨天';

  @override
  String get lastWeek => '上周';

  @override
  String get customDay => '自定义';

  @override
  String get statsDimension => '统计维度';

  @override
  String get activityDimension => '按活动';

  @override
  String get primaryCategoryDimension => '按主分类';

  @override
  String get durationBucketDimension => '按时长区间';

  @override
  String get categoryDurationDimension => '分类×时长';

  @override
  String get dailyTotal => '每日总计';

  @override
  String get dailyTotalHint => '范围内逐日累计时长';

  @override
  String distributionChartTitle(Object range) {
    return '$range 时间分布';
  }

  @override
  String get activityColorLegend => '颜色对应活动';

  @override
  String get statsCountTimes => ' 次';

  @override
  String get settings => '设置';

  @override
  String get settingsSubtitle => '应用偏好与数据管理';

  @override
  String get checkUpdates => '检查更新';

  @override
  String get openDownloadPage => '打开下载页';

  @override
  String get currentVersion => '当前版本';

  @override
  String get latestVersion => '最新版本';

  @override
  String get updateStatusIdle => '空闲';

  @override
  String get updateStatusChecking => '检查中…';

  @override
  String get updateStatusUpToDate => '已是最新';

  @override
  String get updateStatusAvailable => '有可用更新';

  @override
  String get updateStatusFailed => '检查失败';

  @override
  String get syncNow => '立即同步';

  @override
  String get syncing => '同步中…';

  @override
  String get syncStatusCloud => '云同步';

  @override
  String get syncStatusLocal => '本地模式';

  @override
  String get syncStatus => '同步状态';

  @override
  String get syncStatusSynced => '已同步';

  @override
  String get lastSyncNever => '从未同步';

  @override
  String lastSyncAt(Object time) {
    return '上次同步：$time';
  }

  @override
  String lastSyncError(Object error) {
    return '上次同步出错：$error';
  }

  @override
  String get signOut => '退出登录';

  @override
  String get notLoggedIn => '未登录';

  @override
  String get loggedIn => '已登录';

  @override
  String get supabaseConfigured => '云同步已配置';

  @override
  String get supabaseNotConfigured => '云同步未配置';

  @override
  String get reminderSettings => '提醒设置';

  @override
  String get reminderSettingsHint => '设置运行提醒的时机与方式';

  @override
  String get triggerTime => '触发时刻';

  @override
  String get durationLabel => '运行时长';

  @override
  String get interval => '重复间隔';

  @override
  String get method => '提醒方式';

  @override
  String get methodDialog => '对话框';

  @override
  String get methodBanner => '横幅';

  @override
  String get methodSilent => '静音';

  @override
  String minutesFormat(Object minutes) {
    return '$minutes 分钟';
  }

  @override
  String hoursMinutesFormat(Object hours, Object minutes) {
    return '$hours 小时 $minutes 分钟';
  }

  @override
  String get mergeThreshold => '合并阈值';

  @override
  String get cloudSync => '云同步';

  @override
  String get cloudSyncHint => '登录并同步你的数据';

  @override
  String get deviceInterop => '设备互通';

  @override
  String get deviceInteropHint => '局域网配对与文件导入导出';

  @override
  String get versionUpdate => '版本更新';

  @override
  String get versionUpdateHint => '检查并安装应用更新';

  @override
  String get lanHost => '局域网主机';

  @override
  String get connectLanHost => '连接主机';

  @override
  String get startHost => '启动主机';

  @override
  String get stopHost => '停止主机';

  @override
  String get windowsOnly => '仅 Windows 可用';

  @override
  String get pairAndSync => '配对并同步';

  @override
  String get hostAddress => '主机地址';

  @override
  String get pairingCodeInput => '配对码';

  @override
  String get importFile => '导入文件';

  @override
  String get exportFile => '导出文件';

  @override
  String get lanHostStartNote => '启动后在局域网内提供同步服务';

  @override
  String get lanHostWindowsNote => 'Windows 桌面端作为主机';

  @override
  String get connectLanHostHint => '输入主机地址与配对码建立连接';

  @override
  String get lanHostAndroidNote => '主机已运行，等待设备连接';

  @override
  String pairedWith(Object name) {
    return '已配对：$name';
  }

  @override
  String get removePairing => '解除配对';

  @override
  String get selectValidActivity => '请选择有效的活动';

  @override
  String get start => '开始';

  @override
  String get endTime => '结束';

  @override
  String get note => '备注';

  @override
  String get keepRunning => '保持运行';

  @override
  String get closeToSaveHint => '关闭开关以设置结束时间';

  @override
  String get deleteEntry => '删除条目';

  @override
  String get editEntryTitle => '编辑条目';

  @override
  String get addEntryTitle => '添加条目';

  @override
  String get createActivityTitle => '新建活动';

  @override
  String get persistent => '持续';

  @override
  String get create => '创建';

  @override
  String get split => '拆分';

  @override
  String get mergeLeft => '与左合并';

  @override
  String get mergeRight => '与右合并';

  @override
  String get extendToNow => '延伸到当前';

  @override
  String mergeConfirm(Object duration, Object name) {
    return '与「$name」（$duration）合并？';
  }

  @override
  String get splitEntryTitle => '拆分条目';

  @override
  String get splitPoint => '拆分时刻';

  @override
  String get splitPointError => '拆分时刻必须在条目范围内';

  @override
  String get endMustBeAfterStart => '结束时间必须晚于开始时间';

  @override
  String get runningCannotStartFuture => '运行中的条目开始时间不能在未来';

  @override
  String get overlapWarning => '与既有条目时间重叠';

  @override
  String get primaryCategory => '主分类';

  @override
  String get uncategorized => '未分类';

  @override
  String get categoryName => '分类名称';

  @override
  String get categoryColor => '分类颜色';

  @override
  String get createCategory => '创建分类';

  @override
  String get newCategory => '新建分类';

  @override
  String get deleteCategoryTitle => '删除分类';

  @override
  String confirmDeleteCategory(Object name) {
    return '删除分类「$name」将同时删除其子分类与关联，确定？';
  }

  @override
  String get name => '名称';

  @override
  String get color => '颜色';

  @override
  String get sortBy => '排序方式';

  @override
  String get sortAscending => '升序';

  @override
  String get sortDescending => '降序';

  @override
  String get recentlyUpdated => '最近更新';

  @override
  String get all => '全部';

  @override
  String get retry => '重试';

  @override
  String errorOccurred(Object message) {
    return '出错了：$message';
  }

  @override
  String get viewFullTimeline => '查看完整时间线';

  @override
  String get topActivities => '顶部活动';

  @override
  String get totalTime => '总时长';

  @override
  String get focusTime => '专注时间';

  @override
  String get breakTime => '休息时间';

  @override
  String get dailyAvg => '日均';

  @override
  String get vsPreviousDay => '较前日';

  @override
  String get vsLastWeek => '较上周';

  @override
  String get timeByDay => '每日时间';

  @override
  String get timeByActivity => '事项时间';

  @override
  String get aiSummary => 'AI 总结';

  @override
  String get aiSummaryHint => '用一句话总结你的时间记录';

  @override
  String get aiNotConfigured => '配置 AI 密钥后可用';

  @override
  String get aiGoSettings => '去设置';

  @override
  String get aiAskPlaceholder => '问问你的时间…';

  @override
  String get aiGenerate => '生成总结';

  @override
  String get aiRegenerate => '重新生成';

  @override
  String get aiSummaryThisWeek => '本周总结';

  @override
  String get aiSummaryToday => '今天做了什么';

  @override
  String get aiSummaryCompare => '较上周对比';

  @override
  String get aiExecuting => '执行中…';

  @override
  String get aiResultError => '总结生成失败';

  @override
  String get backgroundTracking => '后台记录';

  @override
  String get backgroundTrackingHint => '按规则自动记录前台应用';

  @override
  String get trackingRule => '规则';

  @override
  String get newRule => '新建规则';

  @override
  String get editRule => '编辑规则';

  @override
  String get rulePattern => '匹配模式';

  @override
  String get ruleKind => '匹配类型';

  @override
  String get ruleKindProcess => '进程名';

  @override
  String get ruleKindTitle => '窗口标题';

  @override
  String get ruleActivity => '目标活动';

  @override
  String get ruleSyncEnabled => '进云同步';

  @override
  String get ruleSyncHint => '该规则产生的记录是否参与云同步';

  @override
  String get rulePriorityHint => '匹配优先级：精确 > 通配 > 标题';

  @override
  String get deleteRule => '删除规则';

  @override
  String confirmDeleteRule(Object pattern) {
    return '删除规则「$pattern」？';
  }

  @override
  String get usageAccess => '使用情况访问';

  @override
  String get usageAccessGranted => '已授权';

  @override
  String get usageAccessNotGranted => '未授权';

  @override
  String get usageAccessGuide => '需要“使用情况访问”权限才能自动记录前台应用';

  @override
  String get usageAccessButton => '去系统设置开启';

  @override
  String get usageAccessLater => '暂不开启';

  @override
  String get trackingWindowsNote => 'Windows 端通过检测前台窗口自动记录';

  @override
  String get trackingNotEnabled => '后台记录未启用';

  @override
  String get closeAppTitle => '最小化到托盘？';

  @override
  String get closeAppContent => '最小化到托盘可继续后台记录';

  @override
  String get minimizeToTray => '最小化到托盘';

  @override
  String get exitApp => '退出应用';

  @override
  String get stillDoingThis => '仍在进行这个活动？';

  @override
  String activityRunningMinutes(Object minutes) {
    return '已运行 $minutes 分钟';
  }

  @override
  String get remindLater => '稍后提醒';

  @override
  String get continueLabel => '继续';

  @override
  String get confirmPreviousPeriod => '确认上一时段记录？';

  @override
  String suspiciousEntryContent(Object time) {
    return '检测到从 $time 开始的活动仍处于运行状态';
  }

  @override
  String get keepCurrent => '保留当前';

  @override
  String get endToNow => '结束到现在';

  @override
  String updateAvailablePrompt(Object version) {
    return '发现新版本 $version';
  }

  @override
  String get viewInSettings => '去查看';

  @override
  String get themeAppearance => '外观';

  @override
  String get themeModeSystem => '跟随系统';

  @override
  String get themeModeLight => '浅色';

  @override
  String get themeModeDark => '深色';

  @override
  String get appearancePending => '主题切换随系统自动生效';

  @override
  String get aiSettings => 'AI 配置';

  @override
  String get aiSettingsHint => '配置 AI 密钥与模型（二期启用总结能力）';

  @override
  String get aiKeyLabel => 'AI 密钥';

  @override
  String get aiModelLabel => '模型';

  @override
  String get aiEndpointLabel => '端点';

  @override
  String get aiTestConnection => '测试连接';

  @override
  String get aiClearKey => '清除密钥';

  @override
  String get exportData => '导出数据';

  @override
  String get importData => '导入数据';

  @override
  String get clearAllData => '清除全部数据';

  @override
  String get clearAllDataHint => '清除本地记录前，请先导出备份';

  @override
  String get firstDayOfWeek => '每周起始日';

  @override
  String get timeFormat => '时间格式';

  @override
  String get defaultSessionLength => '默认记录时长';

  @override
  String get quickReminder => '快速提醒';

  @override
  String get on => '开';

  @override
  String get off => '关';

  @override
  String get monday => '周一';

  @override
  String get twelveHour => '12 小时';

  @override
  String get settingsCategories => '分类管理';

  @override
  String get editCategory => '编辑分类';

  @override
  String get deleteCategory => '删除分类';

  @override
  String get parentCategory => '父级分类';

  @override
  String get topLevelCategory => '顶级分类';

  @override
  String get close => '关闭';

  @override
  String get errorTitle => '出错了';

  @override
  String get unassignedActivity => '未分配';

  @override
  String get timerAll => '全部';

  @override
  String get timerTodayTotal => '今日累计';

  @override
  String get timerTodaySessions => '会话数';

  @override
  String get timerRunning => '运行中';

  @override
  String get timerTapToConfirm => '再击确认切换';

  @override
  String get timerTemporaryActivity => '临时活动';

  @override
  String get timerNewActivity => '新增活动';

  @override
  String get timerInteractionHint => '单击选中 · 再击确认 · 双击直接切换 · 长按编辑';

  @override
  String get timerNoActivities => '暂无活动，先创建一个吧';

  @override
  String get timerCategoryEmpty => '此分类暂无活动';

  @override
  String get todayTotalDuration => '总时长';

  @override
  String get todayFocusDuration => '专注时长';

  @override
  String get todayRestDuration => '休息时长';

  @override
  String get todayVsPrevious => '较前日';

  @override
  String get todayPreviewTitle => '时间线预览';

  @override
  String get todayViewFullTimeline => '查看完整时间线';

  @override
  String get todayBackToToday => '回到今天';

  @override
  String get todayStartRecording => '开始记录吧';

  @override
  String get todayEmptyDay => '该日暂无记录';

  @override
  String get todayCreateCategory => '新建分类';

  @override
  String get edit => '编辑';

  @override
  String get ongoing => '持续';

  @override
  String get secondaryCategories => '副分类';

  @override
  String get rootCategory => '根分类';

  @override
  String get searchActivities => '搜索活动与分类…';

  @override
  String get activityNameRequired => '名称不能为空';

  @override
  String get categoryEmptyActivities => '此分类暂无活动';

  @override
  String get categoryCreated => '分类已创建';

  @override
  String get activityCreated => '活动已创建';

  @override
  String get activityEdited => '活动已更新';

  @override
  String get categoryDeleted => '分类已删除，可撤销';

  @override
  String get deleteFailed => '操作失败';

  @override
  String get createFailed => '创建失败';

  @override
  String get currentActivity => '当前';

  @override
  String get active => '已选中';

  @override
  String get categoryDeleteHint => '将删除此分类、N 个子分类与 N 个活动的关联（可撤销）';

  @override
  String get categoryUpdated => '分类已更新';

  @override
  String get timerStartRecording => '开始记录';

  @override
  String get timerLoadFailed => '数据加载失败，请重试';

  @override
  String get todayPrevDay => '前一天';

  @override
  String get todayNextDay => '后一天';

  @override
  String get todayPickDate => '选择日期';

  @override
  String get todayClearFilters => '清除筛选';

  @override
  String get timerQuickSection => '快捷活动';

  @override
  String get timerAllActivities => '全部活动';

  @override
  String get timerTodayShort => '今日';

  @override
  String timerGroupCount(Object n) {
    return '共 $n 个活动';
  }

  @override
  String get timerSwitchHint =>
      '切换 = 结束当前会话并立即开始新活动（原子操作，不留空档）；两种操作均可通过全局撤销恢复。';

  @override
  String get entryEditorEdit => '编辑条目';

  @override
  String get entryEditorNew => '添加条目';

  @override
  String get entryChangeActivity => '更换';

  @override
  String get entryStartAt => '开始';

  @override
  String get entryEndAt => '结束';

  @override
  String get entryKeepRunning => '保持运行';

  @override
  String get entryNoteHint => '备注…';

  @override
  String get entryErrEndBeforeStart => '结束时间必须晚于开始时间';

  @override
  String get entryErrRunningInFuture => '运行中的条目不能落在将来';

  @override
  String get entryWarnOverlap => '与既有条目时间重叠，仍要保存吗？';

  @override
  String get entryOverlapContinue => '仍要保存';

  @override
  String get entryHintSplit => '跨越 0 点，保存后将自动拆分为两条';

  @override
  String get entryEditOps => '相邻条目操作';

  @override
  String get entryMergePrev => '与前一条合并';

  @override
  String get entryMergeNext => '与后一条合并';

  @override
  String get entrySplit => '按时刻拆分';

  @override
  String get entryExtendNow => '延伸到现在';

  @override
  String get entryDeleteTitle => '删除这条记录？';

  @override
  String get entryDeleteHint => '删除后可通过全局撤销恢复。';

  @override
  String get tlAdd => '添加条目';

  @override
  String get tlSpanToday => '今天';

  @override
  String get tlSpanThree => '三天';

  @override
  String get tlSpanWeek => '本周';

  @override
  String get tlViewEntries => '条目';

  @override
  String get tlViewLogs => '日志';

  @override
  String get tlLongest => '最长连续';

  @override
  String get tlAuto => '自动';

  @override
  String get tlMerged => '已合并';

  @override
  String get tlRunningTag => '进行中';

  @override
  String get tlContinueNext => '延续至次日';

  @override
  String get tlFutureBanner => '未来日期暂无记录——这是正常状态，开始记录后这里会显示条目。';

  @override
  String get tlLegendAuto => '自动';

  @override
  String get tlLegendUnassigned => '未分配';

  @override
  String get tlLegendContinue => '延续次日';

  @override
  String get tlZoom => '缩放';

  @override
  String get tlSegments => '分段/日';

  @override
  String get tlNow => '现在';

  @override
  String get tlAxisTab => '时间轴';

  @override
  String get tlStripTab => '比例条';

  @override
  String get tlGroupEntries => '条';

  @override
  String get tlLogsEmpty => '暂无操作日志';

  @override
  String tlEntriesCount(Object n) {
    return '$n 条记录';
  }

  @override
  String get tlSplitPickTime => '选择拆分时刻';

  @override
  String get tlNoActivity => '未选择活动';

  @override
  String get logSwitch => '切换';

  @override
  String get logStop => '停止';

  @override
  String get logEdit => '编辑';

  @override
  String get logDelete => '删除';

  @override
  String get logUndo => '撤销';

  @override
  String get logRedo => '重做';

  @override
  String get logMerge => '合并';

  @override
  String get logManual => '手动';

  @override
  String get logSplit => '拆分';

  @override
  String get logActivityDelete => '删除活动';

  @override
  String get logCategoryCreate => '新建分类';

  @override
  String get logCategoryUpdate => '更新分类';

  @override
  String get logCategoryDelete => '删除分类';

  @override
  String get logRuleUpdate => '规则变更';

  @override
  String get logSync => '同步';

  @override
  String get stRangeToday => '今天';

  @override
  String get stRangeYesterday => '昨天';

  @override
  String get stRangeThisWeek => '本周';

  @override
  String get stRangeLastWeek => '上周';

  @override
  String get stRangeCustom => '自定义';

  @override
  String get stDimActivity => '活动';

  @override
  String get stDimTree => '主分类 · 树聚合';

  @override
  String get stDimBucket => '时长区间';

  @override
  String get stDimCross => '分类 × 时长';

  @override
  String get stFilterTitle => '分类筛选';

  @override
  String get stFilterAll => '全选';

  @override
  String get stFilterNone => '清空';

  @override
  String get stDailyChart => '每日分布';

  @override
  String get stShareChart => '占比分布';

  @override
  String get stDailyDetail => '每日明细';

  @override
  String get stLegendOther => '其他';

  @override
  String get stExcludeAuto => '排除自动条目';

  @override
  String get stExcludeAutoHint =>
      '后台自动记录的条目不参与统计（明细与图表生效；聚合行过滤随批次 5 接入 compute 参数）';

  @override
  String get stAiButton => 'AI 总结';

  @override
  String get stAiPhase2 => '二期';

  @override
  String get stAiGuideTitle => 'AI 总结尚未配置';

  @override
  String get stAiGuideMessage => '需要先在「设置 → AI 配置」中开启并测试模型连接。你的数据仍优先保存在本地。';

  @override
  String get stAiGoSettings => '去设置';

  @override
  String get stAiNotNow => '暂不';

  @override
  String get stEmpty => '开始记录吧';

  @override
  String get stEmptyHint => '记录几天后，这里会呈现你的时间去向';

  @override
  String get stBucketShort => '<30 分';

  @override
  String get stBucketMedium => '30 分–1 时';

  @override
  String get stBucketLong => '1–3 时';

  @override
  String get stBucketXl => '3 时以上';

  @override
  String stCountShort(Object n) {
    return '$n 次';
  }

  @override
  String get stPickStart => '选择开始日期';

  @override
  String get stPickEnd => '选择结束日期';
}
