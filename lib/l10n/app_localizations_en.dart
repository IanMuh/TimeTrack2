// ignore: unused_import
import 'package:intl/intl.dart' as intl;
import 'app_localizations.dart';

// ignore_for_file: type=lint

/// The translations for English (`en`).
class AppLocalizationsEn extends AppLocalizations {
  AppLocalizationsEn([String locale = 'en']) : super(locale);

  @override
  String get appTitle => 'TimeTrack2';

  @override
  String get appBrand => 'TimeTrack';

  @override
  String get appSubtitle => 'Time tracking';

  @override
  String get navTimer => 'Timer';

  @override
  String get navToday => 'Today';

  @override
  String get navTimeline => 'Timeline';

  @override
  String get navStats => 'Stats';

  @override
  String get navSettings => 'Settings';

  @override
  String get pagePlaceholder =>
      'Skeleton placeholder — filled by later modules';

  @override
  String get settingsGeneral => 'General';

  @override
  String get settingsData => 'Backup & Export';

  @override
  String get settingsReminders => 'Reminders';

  @override
  String get settingsTimeline => 'Timeline';

  @override
  String get settingsCloudSync => 'Cloud Sync';

  @override
  String get settingsInterop => 'Device Interop';

  @override
  String get settingsUpdate => 'Version Update';

  @override
  String sectionPlaceholder(Object section) {
    return '“$section” settings section (skeleton placeholder)';
  }

  @override
  String get back => 'Back';

  @override
  String get loading => 'Loading…';

  @override
  String get noData => 'No data';

  @override
  String get save => 'Save';

  @override
  String get cancel => 'Cancel';

  @override
  String get delete => 'Delete';

  @override
  String get ok => 'OK';

  @override
  String get commandDone => 'Done';

  @override
  String get notStartedRecord => 'No active session';

  @override
  String get notRecording => 'Not recording';

  @override
  String get timerBarGoToTimer => 'Back to timer';

  @override
  String get timerBarSwitchHint => 'Tap to switch activity';

  @override
  String get timerBarSwitch => 'Switch activity';

  @override
  String get timerBarSwitchUnavailable =>
      'Activity picker will be available in a later version';

  @override
  String get undo => 'Undo';

  @override
  String get redo => 'Redo';

  @override
  String get undoHint => 'Undo last action';

  @override
  String get redoHint => 'Redo last action';

  @override
  String undoWithLabel(Object label) {
    return 'Undo: $label';
  }

  @override
  String redoWithLabel(Object label) {
    return 'Redo: $label';
  }

  @override
  String get history => 'History';

  @override
  String get currentDoing => 'What are you doing';

  @override
  String get recording => 'Recording';

  @override
  String get notStarted => 'Not started';

  @override
  String get stop => 'Stop';

  @override
  String get switchActivity => 'Switch';

  @override
  String get today => 'Today';

  @override
  String get sessions => 'Sessions';

  @override
  String get quickActivity => 'Quick activities';

  @override
  String get oneOff => 'One-off';

  @override
  String get newActivity => 'New activity';

  @override
  String get editActivity => 'Edit activity';

  @override
  String get editTooltip => 'Edit';

  @override
  String get stopCurrentActivity => 'Stop current';

  @override
  String get currentSession => 'Current session';

  @override
  String get confirmSwitch => 'Tap again to switch';

  @override
  String switchToSemantics(Object name) {
    return 'Switch to $name';
  }

  @override
  String currentActivitySemantics(Object name) {
    return 'Current activity: $name';
  }

  @override
  String confirmSwitchSemantics(Object name) {
    return 'Confirm switch to $name';
  }

  @override
  String get selectDate => 'Select date';

  @override
  String get previousDay => 'Previous day';

  @override
  String get nextDay => 'Next day';

  @override
  String get emptyDayEntries => 'No entries today';

  @override
  String get emptyRangeEntries => 'No entries in this range';

  @override
  String get emptyDayActions => 'No actions today';

  @override
  String get emptyRangeActions => 'No actions in this range';

  @override
  String get addEntry => 'Add entry';

  @override
  String get entries => 'Entries';

  @override
  String get actions => 'Logs';

  @override
  String get singleDay => 'Day';

  @override
  String get threeDays => '3 days';

  @override
  String get thisWeek => 'Week';

  @override
  String get sevenDays => '7 days';

  @override
  String get viewMode => 'View mode';

  @override
  String get timeline => 'Timeline';

  @override
  String get zoomableTimeline => 'Timeline canvas';

  @override
  String get entryList => 'Entry list';

  @override
  String get entryListHint => 'Detailed records in time order';

  @override
  String get totalRangeRecords => 'Total';

  @override
  String get longestStreak => 'Longest block';

  @override
  String get inProgress => 'In progress';

  @override
  String futureDayBanner(Object date) {
    return '“$date” is in the future — nothing to record yet';
  }

  @override
  String get noDataToVisualize => 'Nothing to visualize yet';

  @override
  String get startRecordingHint => 'Start tracking your time';

  @override
  String get recordHint => 'Start recording from the Timer page';

  @override
  String get switchToRecordHint => 'Go to Timer to start recording';

  @override
  String get stats => 'Stats';

  @override
  String statsSubtitle(Object range) {
    return 'Range: $range';
  }

  @override
  String get todayLabel => 'Today';

  @override
  String get yesterday => 'Yesterday';

  @override
  String get lastWeek => 'Last week';

  @override
  String get customDay => 'Custom day';

  @override
  String get statsDimension => 'Dimension';

  @override
  String get activityDimension => 'By activity';

  @override
  String get primaryCategoryDimension => 'By primary category';

  @override
  String get durationBucketDimension => 'By duration bucket';

  @override
  String get categoryDurationDimension => 'Category × bucket';

  @override
  String get dailyTotal => 'Daily totals';

  @override
  String get dailyTotalHint => 'Per-day totals within range';

  @override
  String distributionChartTitle(Object range) {
    return '$range distribution';
  }

  @override
  String get activityColorLegend => 'Colors map to activities';

  @override
  String get statsCountTimes => ' ×';

  @override
  String get settings => 'Settings';

  @override
  String get settingsSubtitle => 'Preferences and data';

  @override
  String get checkUpdates => 'Check updates';

  @override
  String get openDownloadPage => 'Open download page';

  @override
  String get currentVersion => 'Current version';

  @override
  String get latestVersion => 'Latest version';

  @override
  String get updateStatusIdle => 'Idle';

  @override
  String get updateStatusChecking => 'Checking…';

  @override
  String get updateStatusUpToDate => 'Up to date';

  @override
  String get updateStatusAvailable => 'Update available';

  @override
  String get updateStatusFailed => 'Check failed';

  @override
  String get syncNow => 'Sync now';

  @override
  String get syncing => 'Syncing…';

  @override
  String get syncStatusCloud => 'Cloud sync';

  @override
  String get syncStatusLocal => 'Local mode';

  @override
  String get syncStatus => 'Sync status';

  @override
  String get syncStatusSynced => 'Synced';

  @override
  String get lastSyncNever => 'Never synced';

  @override
  String lastSyncAt(Object time) {
    return 'Last sync: $time';
  }

  @override
  String lastSyncError(Object error) {
    return 'Last sync error: $error';
  }

  @override
  String get signOut => 'Sign out';

  @override
  String get notLoggedIn => 'Not signed in';

  @override
  String get loggedIn => 'Signed in';

  @override
  String get supabaseConfigured => 'Cloud sync configured';

  @override
  String get supabaseNotConfigured => 'Cloud sync not configured';

  @override
  String get reminderSettings => 'Reminders';

  @override
  String get reminderSettingsHint => 'Configure when and how to remind';

  @override
  String get triggerTime => 'Trigger time';

  @override
  String get durationLabel => 'Duration';

  @override
  String get interval => 'Interval';

  @override
  String get method => 'Method';

  @override
  String get methodDialog => 'Dialog';

  @override
  String get methodBanner => 'Banner';

  @override
  String get methodSilent => 'Silent';

  @override
  String minutesFormat(Object minutes) {
    return '$minutes min';
  }

  @override
  String hoursMinutesFormat(Object hours, Object minutes) {
    return '$hours h $minutes min';
  }

  @override
  String get mergeThreshold => 'Merge threshold';

  @override
  String get cloudSync => 'Cloud Sync';

  @override
  String get cloudSyncHint => 'Sign in and sync your data';

  @override
  String get deviceInterop => 'Device Interop';

  @override
  String get deviceInteropHint => 'LAN pairing and file import/export';

  @override
  String get versionUpdate => 'Version Update';

  @override
  String get versionUpdateHint => 'Check and install app updates';

  @override
  String get lanHost => 'LAN host';

  @override
  String get connectLanHost => 'Connect to host';

  @override
  String get startHost => 'Start host';

  @override
  String get stopHost => 'Stop host';

  @override
  String get windowsOnly => 'Windows only';

  @override
  String get pairAndSync => 'Pair & sync';

  @override
  String get hostAddress => 'Host address';

  @override
  String get pairingCodeInput => 'Pairing code';

  @override
  String get importFile => 'Import';

  @override
  String get exportFile => 'Export';

  @override
  String get lanHostStartNote => 'Serve sync over LAN once started';

  @override
  String get lanHostWindowsNote => 'Windows desktop acts as host';

  @override
  String get connectLanHostHint =>
      'Enter host address and pairing code to connect';

  @override
  String get lanHostAndroidNote => 'Host running, waiting for devices';

  @override
  String pairedWith(Object name) {
    return 'Paired with $name';
  }

  @override
  String get removePairing => 'Remove pairing';

  @override
  String get selectValidActivity => 'Select a valid activity';

  @override
  String get start => 'Start';

  @override
  String get endTime => 'End';

  @override
  String get note => 'Note';

  @override
  String get keepRunning => 'Keep running';

  @override
  String get closeToSaveHint => 'Turn off to set an end time';

  @override
  String get deleteEntry => 'Delete entry';

  @override
  String get editEntryTitle => 'Edit entry';

  @override
  String get addEntryTitle => 'Add entry';

  @override
  String get createActivityTitle => 'New activity';

  @override
  String get persistent => 'Persistent';

  @override
  String get create => 'Create';

  @override
  String get split => 'Split';

  @override
  String get mergeLeft => 'Merge left';

  @override
  String get mergeRight => 'Merge right';

  @override
  String get extendToNow => 'Extend to now';

  @override
  String mergeConfirm(Object duration, Object name) {
    return 'Merge with “$name” ($duration)?';
  }

  @override
  String get splitEntryTitle => 'Split entry';

  @override
  String get splitPoint => 'Split point';

  @override
  String get splitPointError => 'Split point must be within the entry';

  @override
  String get endMustBeAfterStart => 'End must be after start';

  @override
  String get runningCannotStartFuture =>
      'A running entry cannot start in the future';

  @override
  String get overlapWarning => 'Overlaps an existing entry';

  @override
  String get primaryCategory => 'Primary category';

  @override
  String get uncategorized => 'Uncategorized';

  @override
  String get categoryName => 'Category name';

  @override
  String get categoryColor => 'Category color';

  @override
  String get createCategory => 'Create category';

  @override
  String get newCategory => 'New category';

  @override
  String get deleteCategoryTitle => 'Delete category';

  @override
  String confirmDeleteCategory(Object name) {
    return 'Deleting “$name” also deletes its subcategories and links. Continue?';
  }

  @override
  String get name => 'Name';

  @override
  String get color => 'Color';

  @override
  String get sortBy => 'Sort by';

  @override
  String get sortAscending => 'Ascending';

  @override
  String get sortDescending => 'Descending';

  @override
  String get recentlyUpdated => 'Recently updated';

  @override
  String get all => 'All';

  @override
  String get retry => 'Retry';

  @override
  String errorOccurred(Object message) {
    return 'Error: $message';
  }

  @override
  String get viewFullTimeline => 'View full timeline';

  @override
  String get topActivities => 'Top activities';

  @override
  String get totalTime => 'Total time';

  @override
  String get focusTime => 'Focus time';

  @override
  String get breakTime => 'Break time';

  @override
  String get dailyAvg => 'Daily avg';

  @override
  String get vsPreviousDay => 'vs previous day';

  @override
  String get vsLastWeek => 'vs last week';

  @override
  String get timeByDay => 'Time by day';

  @override
  String get timeByActivity => 'Time by activity';

  @override
  String get aiSummary => 'AI Summary';

  @override
  String get aiSummaryHint => 'Summarize your time in one line';

  @override
  String get aiNotConfigured => 'Configure an AI key to use this';

  @override
  String get aiGoSettings => 'Go to settings';

  @override
  String get aiAskPlaceholder => 'Ask about your time…';

  @override
  String get aiGenerate => 'Generate';

  @override
  String get aiRegenerate => 'Regenerate';

  @override
  String get aiSummaryThisWeek => 'This week summary';

  @override
  String get aiSummaryToday => 'What did I do today';

  @override
  String get aiSummaryCompare => 'Compare with last week';

  @override
  String get aiExecuting => 'Executing…';

  @override
  String get aiResultError => 'Summary generation failed';

  @override
  String get backgroundTracking => 'Background tracking';

  @override
  String get backgroundTrackingHint => 'Auto-record foreground apps by rules';

  @override
  String get trackingRule => 'Rule';

  @override
  String get newRule => 'New rule';

  @override
  String get editRule => 'Edit rule';

  @override
  String get rulePattern => 'Match pattern';

  @override
  String get ruleKind => 'Match type';

  @override
  String get ruleKindProcess => 'Process name';

  @override
  String get ruleKindTitle => 'Window title';

  @override
  String get ruleActivity => 'Target activity';

  @override
  String get ruleSyncEnabled => 'Sync to cloud';

  @override
  String get ruleSyncHint => 'Whether records from this rule sync to cloud';

  @override
  String get rulePriorityHint => 'Priority: exact > wildcard > title';

  @override
  String get deleteRule => 'Delete rule';

  @override
  String confirmDeleteRule(Object pattern) {
    return 'Delete rule “$pattern”?';
  }

  @override
  String get usageAccess => 'Usage access';

  @override
  String get usageAccessGranted => 'Granted';

  @override
  String get usageAccessNotGranted => 'Not granted';

  @override
  String get usageAccessGuide =>
      'Usage access is required to auto-record foreground apps';

  @override
  String get usageAccessButton => 'Open system settings';

  @override
  String get usageAccessLater => 'Not now';

  @override
  String get bgCaptureCurrentApp => 'Capture current app';

  @override
  String get bgCaptureProcess => 'Capture process';

  @override
  String get bgCaptureTitle => 'Capture window title';

  @override
  String get bgManualHoldBanner =>
      'Auto switching is paused because of manual selection';

  @override
  String get bgManualHoldResume => 'Resume auto switching';

  @override
  String get settingsBgCaptureFailed =>
      'Could not capture the foreground app (try again)';

  @override
  String bgNotifyForeground(String package) {
    return 'Foreground $package (no rule matched)';
  }

  @override
  String get bgGuideWhy => 'Why this permission is needed';

  @override
  String get bgGuideWhyBody =>
      'Auto tracking reads the current foreground app via the system Usage Access setting and switches the running activity by your rules.';

  @override
  String get bgGuidePrivacy =>
      'Privacy: only the foreground app\'s package name is read for local rule matching. Screen contents are never read and no usage data leaves this device.';

  @override
  String get bgGuideNote =>
      'You can grant it later under Settings → Background tracking.';

  @override
  String get trackingWindowsNote =>
      'On Windows, tracking works by detecting the foreground window';

  @override
  String get trackingNotEnabled => 'Background tracking is off';

  @override
  String get closeAppTitle => 'Minimize to tray?';

  @override
  String get closeAppContent =>
      'Minimizing to tray keeps background tracking running';

  @override
  String get minimizeToTray => 'Minimize to tray';

  @override
  String get exitApp => 'Exit app';

  @override
  String get trayCloseRemember => 'Remember my choice, don\'t ask again';

  @override
  String get stillDoingThis => 'Still doing this?';

  @override
  String activityRunningMinutes(Object minutes) {
    return 'Running for $minutes minutes';
  }

  @override
  String get remindLater => 'Remind later';

  @override
  String get continueLabel => 'Continue';

  @override
  String get confirmPreviousPeriod => 'Confirm previous period?';

  @override
  String suspiciousEntryContent(Object time) {
    return 'An activity running since $time is still active';
  }

  @override
  String get keepCurrent => 'Keep current';

  @override
  String get endToNow => 'End now';

  @override
  String updateAvailablePrompt(Object version) {
    return 'Version $version available';
  }

  @override
  String get viewInSettings => 'View';

  @override
  String get themeAppearance => 'Appearance';

  @override
  String get themeModeSystem => 'System';

  @override
  String get themeModeLight => 'Light';

  @override
  String get themeModeDark => 'Dark';

  @override
  String get appearancePending => 'Theme follows the system automatically';

  @override
  String get aiSettings => 'AI Settings';

  @override
  String get aiSettingsHint =>
      'Configure AI key and model (enabled in phase 2)';

  @override
  String get aiKeyLabel => 'AI key';

  @override
  String get aiModelLabel => 'Model';

  @override
  String get aiEndpointLabel => 'Endpoint';

  @override
  String get aiTestConnection => 'Test connection';

  @override
  String get aiClearKey => 'Clear key';

  @override
  String get exportData => 'Export data';

  @override
  String get importData => 'Import data';

  @override
  String get clearAllData => 'Clear all data';

  @override
  String get clearAllDataHint =>
      'Export a backup before clearing local records';

  @override
  String get firstDayOfWeek => 'First day of week';

  @override
  String get timeFormat => 'Time format';

  @override
  String get defaultSessionLength => 'Default session length';

  @override
  String get quickReminder => 'Quick reminder';

  @override
  String get on => 'On';

  @override
  String get off => 'Off';

  @override
  String get monday => 'Monday';

  @override
  String get twelveHour => '12-hour';

  @override
  String get settingsCategories => 'Category management';

  @override
  String get editCategory => 'Edit category';

  @override
  String get deleteCategory => 'Delete category';

  @override
  String get parentCategory => 'Parent category';

  @override
  String get topLevelCategory => 'Top level';

  @override
  String get close => 'Close';

  @override
  String get errorTitle => 'Something went wrong';

  @override
  String get unassignedActivity => 'Unassigned';

  @override
  String get timerAll => 'All';

  @override
  String get timerTodayTotal => 'Today total';

  @override
  String get timerTodaySessions => 'Sessions';

  @override
  String get timerRunning => 'Running';

  @override
  String get timerTapToConfirm => 'Tap again to switch';

  @override
  String get timerTemporaryActivity => 'Temporary';

  @override
  String get timerNewActivity => 'New activity';

  @override
  String get timerInteractionHint =>
      'Click to select, tap again to confirm, double-click to switch, long-press to edit';

  @override
  String get timerNoActivities => 'No activities yet — create one';

  @override
  String get timerCategoryEmpty => 'No activities in this category';

  @override
  String get todayTotalDuration => 'Total time';

  @override
  String get todayFocusDuration => 'Focus';

  @override
  String get todayRestDuration => 'Rest';

  @override
  String get todayVsPrevious => 'vs previous day';

  @override
  String get todayPreviewTitle => 'Timeline preview';

  @override
  String get todayViewFullTimeline => 'View full timeline';

  @override
  String get todayBackToToday => 'Back to today';

  @override
  String get todayStartRecording => 'Start recording';

  @override
  String get todayEmptyDay => 'No records on this day';

  @override
  String get todayCreateCategory => 'New category';

  @override
  String get edit => 'Edit';

  @override
  String get ongoing => 'Ongoing';

  @override
  String get secondaryCategories => 'Secondary categories';

  @override
  String get rootCategory => 'Root category';

  @override
  String get searchActivities => 'Search activities and categories…';

  @override
  String get activityNameRequired => 'Name is required';

  @override
  String get categoryEmptyActivities => 'No activities in this category';

  @override
  String get categoryCreated => 'Category created';

  @override
  String get activityCreated => 'Activity created';

  @override
  String get activityEdited => 'Activity updated';

  @override
  String get categoryDeleted => 'Category deleted — undo available';

  @override
  String get deleteFailed => 'Delete failed';

  @override
  String get createFailed => 'Create failed';

  @override
  String get currentActivity => 'Current';

  @override
  String get active => 'Selected';

  @override
  String get categoryDeleteHint =>
      'This deletes N sub-categories and N activity links (single undo)';

  @override
  String get categoryUpdated => 'Category updated';

  @override
  String get timerStartRecording => 'Start recording';

  @override
  String get timerLoadFailed => 'Failed to load. Try again.';

  @override
  String get todayPrevDay => 'Previous day';

  @override
  String get todayNextDay => 'Next day';

  @override
  String get todayPickDate => 'Pick a date';

  @override
  String get todayClearFilters => 'Clear filters';

  @override
  String get timerQuickSection => 'Quick activities';

  @override
  String get timerAllActivities => 'All activities';

  @override
  String get timerTodayShort => 'Today';

  @override
  String timerGroupCount(Object n) {
    return '$n activities in total';
  }

  @override
  String get timerSwitchHint =>
      'Switch = end current session and start the new one immediately (atomic, no gap); both actions are undoable.';

  @override
  String get entryEditorEdit => 'Edit entry';

  @override
  String get entryEditorNew => 'Add entry';

  @override
  String get entryChangeActivity => 'Change';

  @override
  String get entryStartAt => 'Start';

  @override
  String get entryEndAt => 'End';

  @override
  String get entryKeepRunning => 'Keep running';

  @override
  String get entryNoteHint => 'Note…';

  @override
  String get entryErrEndBeforeStart => 'End must be after start';

  @override
  String get entryErrRunningInFuture =>
      'A running entry cannot be in the future';

  @override
  String get entryWarnOverlap => 'Overlaps existing entries. Save anyway?';

  @override
  String get entryOverlapContinue => 'Save anyway';

  @override
  String get entryHintSplit =>
      'Crosses midnight — will be split into two on save';

  @override
  String get entryEditOps => 'Neighbor actions';

  @override
  String get entryMergePrev => 'Merge previous';

  @override
  String get entryMergeNext => 'Merge next';

  @override
  String get entrySplit => 'Split at time';

  @override
  String get entryExtendNow => 'Extend to now';

  @override
  String get entryDeleteTitle => 'Delete this entry?';

  @override
  String get entryDeleteHint => 'You can undo this via global undo.';

  @override
  String get tlAdd => 'Add entry';

  @override
  String get tlSpanToday => 'Today';

  @override
  String get tlSpanThree => '3 days';

  @override
  String get tlSpanWeek => 'Week';

  @override
  String get tlViewEntries => 'Entries';

  @override
  String get tlViewLogs => 'Logs';

  @override
  String get tlLongest => 'Longest';

  @override
  String get tlAuto => 'Auto';

  @override
  String get tlMerged => 'Merged';

  @override
  String get tlRunningTag => 'Running';

  @override
  String get tlContinueNext => 'Continues next day';

  @override
  String get tlFutureBanner =>
      'No records on future dates yet — that is normal; entries will appear here once recorded.';

  @override
  String get tlLegendAuto => 'Auto';

  @override
  String get tlLegendUnassigned => 'Unassigned';

  @override
  String get tlLegendContinue => 'Next-day';

  @override
  String get tlZoom => 'Zoom';

  @override
  String get tlSegments => 'Segments/day';

  @override
  String get tlNow => 'Now';

  @override
  String get tlAxisTab => 'Timeline';

  @override
  String get tlStripTab => 'Strip';

  @override
  String get tlGroupEntries => 'entries';

  @override
  String get tlLogsEmpty => 'No action logs yet';

  @override
  String tlEntriesCount(Object n) {
    return '$n entries';
  }

  @override
  String get tlSplitPickTime => 'Pick split time';

  @override
  String get tlNoActivity => 'No activity selected';

  @override
  String get logSwitch => 'Switch';

  @override
  String get logStop => 'Stop';

  @override
  String get logEdit => 'Edit';

  @override
  String get logDelete => 'Delete';

  @override
  String get logUndo => 'Undo';

  @override
  String get logRedo => 'Redo';

  @override
  String get logMerge => 'Merge';

  @override
  String get logManual => 'Manual';

  @override
  String get logSplit => 'Split';

  @override
  String get logActivityDelete => 'Delete activity';

  @override
  String get logCategoryCreate => 'Create category';

  @override
  String get logCategoryUpdate => 'Update category';

  @override
  String get logCategoryDelete => 'Delete category';

  @override
  String get logRuleUpdate => 'Rule change';

  @override
  String get logSync => 'Sync';

  @override
  String get stRangeToday => 'Today';

  @override
  String get stRangeYesterday => 'Yesterday';

  @override
  String get stRangeThisWeek => 'This week';

  @override
  String get stRangeLastWeek => 'Last week';

  @override
  String get stRangeCustom => 'Custom';

  @override
  String get stDimActivity => 'Activity';

  @override
  String get stDimTree => 'Category tree';

  @override
  String get stDimBucket => 'Duration buckets';

  @override
  String get stDimCross => 'Category × duration';

  @override
  String get stFilterTitle => 'Category filter';

  @override
  String get stFilterAll => 'All';

  @override
  String get stFilterNone => 'Clear';

  @override
  String get stDailyChart => 'Daily distribution';

  @override
  String get stShareChart => 'Share';

  @override
  String get stDailyDetail => 'Daily detail';

  @override
  String get stLegendOther => 'Other';

  @override
  String get stExcludeAuto => 'Exclude auto entries';

  @override
  String get stExcludeAutoHint =>
      'Background auto entries are excluded from stats — details, charts and aggregate rows share the same filter';

  @override
  String get stAiButton => 'AI summary';

  @override
  String get stAiPhase2 => 'Phase 2';

  @override
  String get stAiGuideTitle => 'AI summary not configured';

  @override
  String get stAiGuideMessage =>
      'Enable and test the model in Settings → AI first. Your data stays local by default.';

  @override
  String get stAiGoSettings => 'Open settings';

  @override
  String get stAiNotNow => 'Not now';

  @override
  String get stEmpty => 'Start recording';

  @override
  String get stEmptyHint =>
      'After a few days of tracking, your time breakdown appears here';

  @override
  String get stBucketShort => '<30m';

  @override
  String get stBucketMedium => '30m–1h';

  @override
  String get stBucketLong => '1–3h';

  @override
  String get stBucketXl => '3h+';

  @override
  String stCountShort(Object n) {
    return '$n entries';
  }

  @override
  String get stPickStart => 'Pick start date';

  @override
  String get stPickEnd => 'Pick end date';

  @override
  String get settingsSecGeneral => 'General';

  @override
  String get settingsSecGeneralSub =>
      'Appearance, time display and global defaults';

  @override
  String get settingsSecBackup => 'Backup & export';

  @override
  String get settingsSecBackupSub =>
      'The only channel for data migration and new-device restore';

  @override
  String get settingsSecReminder => 'Reminders';

  @override
  String get settingsSecReminderSub => 'When to remind, how often, and how';

  @override
  String get settingsSecTimeline => 'Timeline';

  @override
  String get settingsSecTimelineSub => 'Merge threshold for adjacent entries';

  @override
  String get settingsSecSync => 'Cloud sync';

  @override
  String get settingsSecSyncSub =>
      'Two-way sync across devices, local-first and async';

  @override
  String get settingsSecAi => 'AI settings';

  @override
  String get settingsSecAiSub =>
      'Summaries and natural-language logging (phase 2)';

  @override
  String get settingsAiBadge => 'Phase 2';

  @override
  String get settingsSecBackground => 'Background tracking';

  @override
  String get settingsSecBackgroundSub =>
      'Auto track by rules; auto entries are tagged and excludable';

  @override
  String get settingsSecDevice => 'Device interop';

  @override
  String get settingsSecDeviceSub => 'Sync and file exchange within your LAN';

  @override
  String get settingsSecUpdate => 'Updates';

  @override
  String get settingsSecUpdateSub =>
      'Install only after checksum passes · degrade on failure · forced updates cannot be skipped';

  @override
  String get settingsSecAbout => 'About';

  @override
  String get settingsSecAboutSub => 'Version, open-source info and licenses';

  @override
  String get settingsAppearance => 'Appearance';

  @override
  String get settingsAppearanceHint =>
      'Light by default, dark or follow-system available';

  @override
  String get settingsThemeLight => 'Light';

  @override
  String get settingsThemeDark => 'Dark';

  @override
  String get settingsThemeSystem => 'Follow system';

  @override
  String get settingsWeekStart => 'Week starts on';

  @override
  String get settingsWeekStartHint =>
      'Where the Stats page \"this week\" begins';

  @override
  String get settingsWeekMonday => 'Monday';

  @override
  String get settingsWeekSunday => 'Sunday';

  @override
  String get settingsWeekSaturday => 'Saturday';

  @override
  String get settingsTimeFormat => 'Time format';

  @override
  String get settingsTimeFormatHint =>
      'Display format for timeline entries and timer';

  @override
  String get settingsHour12 => '12-hour';

  @override
  String get settingsHour24 => '24-hour';

  @override
  String get settingsDefaultDuration => 'Default duration';

  @override
  String get settingsDefaultDurationHint =>
      'Default length for quick starts like one-off activities';

  @override
  String get settingsQuickReminder => 'Quick reminder';

  @override
  String get settingsQuickReminderHint =>
      'Remind to start tracking at the trigger time (see Reminders)';

  @override
  String settingsMinutesShort(int minutes) {
    return '$minutes min';
  }

  @override
  String get settingsTriggerTime => 'Trigger time';

  @override
  String get settingsTriggerTimeHint =>
      'Remind to start tracking daily at this time';

  @override
  String get settingsDurationThreshold => 'Duration threshold';

  @override
  String get settingsDurationThresholdHint =>
      'Remind once a session runs this long';

  @override
  String get settingsRepeatInterval => 'Repeat interval';

  @override
  String get settingsRepeatIntervalHint =>
      'Re-remind at this interval until the session ends';

  @override
  String get settingsReminderMethod => 'Reminder style';

  @override
  String get settingsMethodDialog => 'Dialog';

  @override
  String get settingsMethodDialogDesc => 'Decision';

  @override
  String get settingsMethodBanner => 'Banner';

  @override
  String get settingsMethodBannerDesc => 'Subtle';

  @override
  String get settingsMethodSilent => 'Silent';

  @override
  String get settingsMethodSilentDesc => 'Nodisturb';

  @override
  String get settingsMergeThreshold => 'Adjacent merge threshold';

  @override
  String get settingsMergeThresholdHint =>
      'Auto-merge when the gap is below this threshold';

  @override
  String get settingsUnassignedNote =>
      'There is exactly one \"Unassigned\" activity. Adjacent unassigned entries on the timeline merge into one continuous record when the gap is below this threshold.';

  @override
  String get settingsExport => 'Export backup';

  @override
  String get settingsExportHint =>
      'Export everything to a single .timetrack.json file';

  @override
  String get settingsExportBtn => 'Export';

  @override
  String get settingsImport => 'Import data';

  @override
  String get settingsImportHint =>
      'Restore from .timetrack.json; imported data merges with existing';

  @override
  String get settingsImportBtn => 'Import';

  @override
  String get settingsDangerTitle => 'Erase all data';

  @override
  String get settingsDangerMessage =>
      'Permanently deletes all local entries, activities and settings. Export a backup first — this cannot be undone.';

  @override
  String get settingsDangerBtn => 'Erase all data';

  @override
  String get settingsWipeDialogTitle => 'Erase all data';

  @override
  String get settingsWipeDialogBody =>
      'This permanently deletes all entries, activities and settings and cannot be undone. Export a backup first to avoid data loss.';

  @override
  String get settingsWipeCancel => 'Cancel';

  @override
  String get settingsWipeExportFirst => 'Export first';

  @override
  String get settingsWipeConfirm => 'Erase anyway';

  @override
  String get settingsWipeDone => 'All data erased';

  @override
  String get settingsWipeFailed => 'Erase failed';

  @override
  String settingsExportDone(String path) {
    return 'Exported to $path';
  }

  @override
  String settingsImportDone(int count) {
    return 'Imported $count records';
  }

  @override
  String settingsOpFailed(String message) {
    return 'Operation failed: $message';
  }

  @override
  String get settingsSyncConfigured => 'Supabase configured';

  @override
  String get settingsSyncNotConfigured => 'Cloud service not configured';

  @override
  String get settingsSyncNotConfiguredHint =>
      'SUPABASE_URL was not injected at build time; the app runs offline';

  @override
  String get settingsSyncOnline => 'Online';

  @override
  String get settingsSyncOffline => 'Offline';

  @override
  String settingsSyncLoggedInAs(String email) {
    return 'Signed in as $email';
  }

  @override
  String get settingsSyncNotLoggedIn => 'Not signed in';

  @override
  String get settingsSyncLastAt => 'Last sync';

  @override
  String get settingsSyncJustNow => 'Just now';

  @override
  String get settingsSyncNever => 'Never';

  @override
  String settingsSyncPulled(int count) {
    return 'Pulled $count';
  }

  @override
  String settingsSyncPushed(int count) {
    return 'Pushed $count';
  }

  @override
  String get settingsSyncNow => 'Sync now';

  @override
  String get settingsSyncSignOut => 'Sign out';

  @override
  String get settingsLoginTitle => 'Sign in';

  @override
  String get settingsLoginSubtitle =>
      'Enter your email and verify with a code to sync to the cloud';

  @override
  String get settingsLoginEmail => 'Email';

  @override
  String get settingsLoginSendCode => 'Send code';

  @override
  String get settingsLoginSending => 'Sending…';

  @override
  String get settingsLoginCodeSent => 'Code sent, check your inbox';

  @override
  String get settingsLoginCode => '6-digit code';

  @override
  String get settingsLoginVerify => 'Verify and sign in';

  @override
  String get settingsLoginVerifying => 'Signing in…';

  @override
  String settingsLoginFailed(String message) {
    return 'Sign-in failed: $message';
  }

  @override
  String get settingsLoginCancel => 'Cancel';

  @override
  String get settingsSignedOut => 'Signed out';

  @override
  String settingsSyncFailed(String message) {
    return 'Sync failed: $message';
  }

  @override
  String get settingsAiPhase2Note =>
      'AI settings arrive in phase 2: API key (secure storage), OpenAI-compatible endpoint/model, test connection and data-transfer disclosure. The Stats page already has a phase-2 entry placeholder.';

  @override
  String get settingsBgWindowsTitle => 'Windows · background resident';

  @override
  String get settingsBgWindowsBody =>
      'Closing the window minimizes to tray by default; tray menu offers show/pause/quit.';

  @override
  String settingsBgDetectorState(String state) {
    return 'Detector: $state';
  }

  @override
  String get settingsBgDetectorRunning => 'running';

  @override
  String get settingsBgDetectorPending => 'pending platform layer (batch 6)';

  @override
  String settingsBgLastMatch(String note) {
    return 'Last match: $note';
  }

  @override
  String get settingsBgMasterSwitch => 'Background auto tracking';

  @override
  String get settingsBgMasterHint =>
      'Track automatically by rules; no entry when nothing matches';

  @override
  String get settingsBgRules => 'Rules';

  @override
  String settingsBgRulesCount(int count) {
    return 'Pattern → activity · $count rules';
  }

  @override
  String get settingsBgNewRule => 'New rule';

  @override
  String get settingsBgEmptyRules =>
      'No rules yet. Create one to auto-track matching processes or window titles.';

  @override
  String get settingsBgKindProcess => 'Process name';

  @override
  String get settingsBgKindTitle => 'Window title';

  @override
  String get settingsBgSyncToggle => 'Cloud sync';

  @override
  String get settingsBgEnabledToggle => 'Enabled';

  @override
  String get settingsBgEdit => 'Edit rule';

  @override
  String get settingsBgDelete => 'Delete rule';

  @override
  String get settingsBgRuleFormTitleNew => 'New rule';

  @override
  String get settingsBgRuleFormTitleEdit => 'Edit rule';

  @override
  String get settingsBgPattern => 'Pattern';

  @override
  String get settingsBgPatternHint =>
      'Process name (e.g. code.exe) or title pattern (e.g. *code*)';

  @override
  String get settingsBgMatchKind => 'Match type';

  @override
  String get settingsBgTargetActivity => 'Target activity';

  @override
  String get settingsBgPickActivity => 'Open activity picker';

  @override
  String get settingsBgSyncThisRule => 'Sync this rule';

  @override
  String get settingsBgPriorityNote =>
      'Priority: exact > wildcard > title. Avoid overly broad patterns to reduce mismatches.';

  @override
  String get settingsBgSave => 'Save';

  @override
  String get settingsBgCancel => 'Cancel';

  @override
  String get settingsBgRuleSaved => 'Rule saved';

  @override
  String get settingsBgRuleDeleted => 'Rule deleted';

  @override
  String get settingsBgFormInvalid =>
      'Enter a pattern and choose a target activity';

  @override
  String get settingsLanHost => 'LAN host';

  @override
  String get settingsLanHostHint =>
      'Let other devices on the LAN connect and sync with a pairing code';

  @override
  String get settingsLanStart => 'Start host';

  @override
  String get settingsLanStop => 'Stop';

  @override
  String get settingsLanRunning => 'Running';

  @override
  String get settingsLanStopped => 'Stopped';

  @override
  String get settingsLanPort => 'Port';

  @override
  String get settingsLanPairingCode => 'Pairing code';

  @override
  String get settingsLanCodeOnce =>
      'Codes are single-use; regenerate after use or expiry';

  @override
  String get settingsLanClient => 'LAN client';

  @override
  String get settingsLanClientHint =>
      'Connect to a host started on another device';

  @override
  String get settingsLanHostInput =>
      'Host address (e.g. 192.168.1.5 or 192.168.1.5:8787)';

  @override
  String get settingsLanCodeInput => '6-digit code';

  @override
  String get settingsLanPair => 'Pair';

  @override
  String settingsLanPairedAs(String name) {
    return 'Paired with $name';
  }

  @override
  String get settingsLanSyncNow => 'Sync now';

  @override
  String get settingsLanManualOnly =>
      'The host starts manually only; there is no auto-start path.';

  @override
  String get settingsLanFileInterop => 'File exchange';

  @override
  String get settingsLanFileInteropHint =>
      'Move data between devices manually via .timetrack.json';

  @override
  String get settingsUpdateCurrent => 'Current version';

  @override
  String get settingsUpdateLatest => 'Latest version';

  @override
  String get settingsUpdateState => 'Status';

  @override
  String get settingsUpdateCheck => 'Check for updates';

  @override
  String get settingsUpdateChecking => 'Checking for updates…';

  @override
  String get settingsUpdateUpToDate => 'Up to date';

  @override
  String get settingsUpdateAvailable => 'Update available';

  @override
  String get settingsUpdateDownload => 'Download';

  @override
  String get settingsUpdateDownloading => 'Downloading…';

  @override
  String get settingsUpdateVerifying => 'Verifying SHA-256…';

  @override
  String get settingsUpdateInstalling => 'Installing…';

  @override
  String get settingsUpdateRestartRequired => 'Restart required';

  @override
  String get settingsUpdateRestartBody =>
      'Installed. It takes effect on next launch';

  @override
  String get settingsUpdateRestartNow => 'Restart now';

  @override
  String get settingsUpdateFailed => 'Update failed';

  @override
  String get settingsUpdateIgnoreVersion => 'Ignore this version';

  @override
  String get settingsUpdateLater => 'Remind later';

  @override
  String get settingsUpdateInstallNote =>
      'Install differs by platform: Windows prompts \"restart to apply\" after checksum passes; Android launches the system installer and guides to settings when unknown-app installs are not allowed.';

  @override
  String get settingsUpdateVerifyNote =>
      'SHA-256 is verified after download; install only when it matches';

  @override
  String get settingsUpdateNoArtifact => 'No update package for this platform';

  @override
  String get settingsUpdateIgnoredDone => 'Version ignored';

  @override
  String get settingsUpdateIdle => 'Ready';

  @override
  String get settingsAboutTagline => 'Offline-first · personal time tracking';

  @override
  String get settingsAboutVersion => 'Current version';

  @override
  String get settingsAboutOpenSource => 'Open source';

  @override
  String get settingsAboutOpenSourceHint =>
      'MIT Licensed. Contributions welcome';

  @override
  String get settingsAboutLicense => 'License';

  @override
  String get settingsAboutLicenseHint =>
      'MIT License · third-party licenses included';

  @override
  String get settingsAboutCheckUpdate => 'Check for updates';

  @override
  String get settingsInstantHint =>
      'All settings apply instantly and persist; pages stay consistent after changes.';

  @override
  String get remOngoingSubtitle => 'Running reminder · Dialog style';

  @override
  String remOngoingBody(String activity, String elapsed) {
    return '\"$activity\" has been recorded for $elapsed. Still going?';
  }

  @override
  String get remQuickTitle => 'Time to start tracking';

  @override
  String get remQuickBody =>
      'Trigger-time reminder: what are you working on? Log it.';

  @override
  String get remDismiss => 'Got it';

  @override
  String bannerOngoingTitle(String duration) {
    return 'Recording for $duration';
  }

  @override
  String bannerOngoingSub(String activity) {
    return '\"$activity\" · Banner style';
  }

  @override
  String get suspiciousTitle => 'Leftover running entry found';

  @override
  String get suspiciousSubtitle => 'Still recording when the app last closed';

  @override
  String get updateAvailableSubtle => 'Silent check — won\'t interrupt you';

  @override
  String get updateIgnoreAction => 'Ignore';

  @override
  String get forcedUpdateTitle => 'Update required';

  @override
  String get forcedUpdateSubtitle => 'This update cannot be skipped';

  @override
  String forcedUpdateBody(String current, String version) {
    return 'Version v$current is no longer supported. Update to v$version to continue — the download will start automatically.';
  }

  @override
  String get forcedUpdateAction => 'Update now';
}
