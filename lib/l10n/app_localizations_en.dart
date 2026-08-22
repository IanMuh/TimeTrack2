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
  String get newActivity => 'New';

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
}
