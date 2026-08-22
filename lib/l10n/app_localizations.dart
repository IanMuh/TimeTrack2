import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:intl/intl.dart' as intl;

import 'app_localizations_en.dart';
import 'app_localizations_zh.dart';

// ignore_for_file: type=lint

/// Callers can lookup localized strings with an instance of AppLocalizations
/// returned by `AppLocalizations.of(context)`.
///
/// Applications need to include `AppLocalizations.delegate()` in their app's
/// `localizationDelegates` list, and the locales they support in the app's
/// `supportedLocales` list. For example:
///
/// ```dart
/// import 'l10n/app_localizations.dart';
///
/// return MaterialApp(
///   localizationsDelegates: AppLocalizations.localizationsDelegates,
///   supportedLocales: AppLocalizations.supportedLocales,
///   home: MyApplicationHome(),
/// );
/// ```
///
/// ## Update pubspec.yaml
///
/// Please make sure to update your pubspec.yaml to include the following
/// packages:
///
/// ```yaml
/// dependencies:
///   # Internationalization support.
///   flutter_localizations:
///     sdk: flutter
///   intl: any # Use the pinned version from flutter_localizations
///
///   # Rest of dependencies
/// ```
///
/// ## iOS Applications
///
/// iOS applications define key application metadata, including supported
/// locales, in an Info.plist file that is built into the application bundle.
/// To configure the locales supported by your app, you’ll need to edit this
/// file.
///
/// First, open your project’s ios/Runner.xcworkspace Xcode workspace file.
/// Then, in the Project Navigator, open the Info.plist file under the Runner
/// project’s Runner folder.
///
/// Next, select the Information Property List item, select Add Item from the
/// Editor menu, then select Localizations from the pop-up menu.
///
/// Select and expand the newly-created Localizations item then, for each
/// locale your application supports, add a new item and select the locale
/// you wish to add from the pop-up menu in the Value field. This list should
/// be consistent with the languages listed in the AppLocalizations.supportedLocales
/// property.
abstract class AppLocalizations {
  AppLocalizations(String locale)
    : localeName = intl.Intl.canonicalizedLocale(locale.toString());

  final String localeName;

  static AppLocalizations? of(BuildContext context) {
    return Localizations.of<AppLocalizations>(context, AppLocalizations);
  }

  static const LocalizationsDelegate<AppLocalizations> delegate =
      _AppLocalizationsDelegate();

  /// A list of this localizations delegate along with the default localizations
  /// delegates.
  ///
  /// Returns a list of localizations delegates containing this delegate along with
  /// GlobalMaterialLocalizations.delegate, GlobalCupertinoLocalizations.delegate,
  /// and GlobalWidgetsLocalizations.delegate.
  ///
  /// Additional delegates can be added by appending to this list in
  /// MaterialApp. This list does not have to be used at all if a custom list
  /// of delegates is preferred or required.
  static const List<LocalizationsDelegate<dynamic>> localizationsDelegates =
      <LocalizationsDelegate<dynamic>>[
        delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
      ];

  /// A list of this localizations delegate's supported locales.
  static const List<Locale> supportedLocales = <Locale>[
    Locale('en'),
    Locale('zh'),
  ];

  /// No description provided for @appTitle.
  ///
  /// In zh, this message translates to:
  /// **'TimeTrack2'**
  String get appTitle;

  /// No description provided for @appBrand.
  ///
  /// In zh, this message translates to:
  /// **'TimeTrack'**
  String get appBrand;

  /// No description provided for @appSubtitle.
  ///
  /// In zh, this message translates to:
  /// **'时间追踪'**
  String get appSubtitle;

  /// No description provided for @navTimer.
  ///
  /// In zh, this message translates to:
  /// **'计时'**
  String get navTimer;

  /// No description provided for @navToday.
  ///
  /// In zh, this message translates to:
  /// **'今日'**
  String get navToday;

  /// No description provided for @navTimeline.
  ///
  /// In zh, this message translates to:
  /// **'时间线'**
  String get navTimeline;

  /// No description provided for @navStats.
  ///
  /// In zh, this message translates to:
  /// **'统计'**
  String get navStats;

  /// No description provided for @navSettings.
  ///
  /// In zh, this message translates to:
  /// **'设置'**
  String get navSettings;

  /// No description provided for @pagePlaceholder.
  ///
  /// In zh, this message translates to:
  /// **'骨架占位——此区域由后续模块填充'**
  String get pagePlaceholder;

  /// No description provided for @settingsGeneral.
  ///
  /// In zh, this message translates to:
  /// **'通用'**
  String get settingsGeneral;

  /// No description provided for @settingsData.
  ///
  /// In zh, this message translates to:
  /// **'备份与导出'**
  String get settingsData;

  /// No description provided for @settingsReminders.
  ///
  /// In zh, this message translates to:
  /// **'提醒'**
  String get settingsReminders;

  /// No description provided for @settingsTimeline.
  ///
  /// In zh, this message translates to:
  /// **'时间线'**
  String get settingsTimeline;

  /// No description provided for @settingsCloudSync.
  ///
  /// In zh, this message translates to:
  /// **'云同步'**
  String get settingsCloudSync;

  /// No description provided for @settingsInterop.
  ///
  /// In zh, this message translates to:
  /// **'设备互通'**
  String get settingsInterop;

  /// No description provided for @settingsUpdate.
  ///
  /// In zh, this message translates to:
  /// **'版本更新'**
  String get settingsUpdate;

  /// No description provided for @sectionPlaceholder.
  ///
  /// In zh, this message translates to:
  /// **'“{section}”设置分区（骨架占位）'**
  String sectionPlaceholder(Object section);

  /// No description provided for @back.
  ///
  /// In zh, this message translates to:
  /// **'返回'**
  String get back;

  /// No description provided for @loading.
  ///
  /// In zh, this message translates to:
  /// **'加载中…'**
  String get loading;

  /// No description provided for @noData.
  ///
  /// In zh, this message translates to:
  /// **'暂无数据'**
  String get noData;

  /// No description provided for @save.
  ///
  /// In zh, this message translates to:
  /// **'保存'**
  String get save;

  /// No description provided for @cancel.
  ///
  /// In zh, this message translates to:
  /// **'取消'**
  String get cancel;

  /// No description provided for @delete.
  ///
  /// In zh, this message translates to:
  /// **'删除'**
  String get delete;

  /// No description provided for @ok.
  ///
  /// In zh, this message translates to:
  /// **'确定'**
  String get ok;

  /// No description provided for @commandDone.
  ///
  /// In zh, this message translates to:
  /// **'已完成'**
  String get commandDone;

  /// No description provided for @notStartedRecord.
  ///
  /// In zh, this message translates to:
  /// **'未开始记录'**
  String get notStartedRecord;

  /// No description provided for @notRecording.
  ///
  /// In zh, this message translates to:
  /// **'未在记录'**
  String get notRecording;

  /// No description provided for @timerBarGoToTimer.
  ///
  /// In zh, this message translates to:
  /// **'回到计时页'**
  String get timerBarGoToTimer;

  /// No description provided for @timerBarSwitchHint.
  ///
  /// In zh, this message translates to:
  /// **'点击切换活动'**
  String get timerBarSwitchHint;

  /// No description provided for @timerBarSwitch.
  ///
  /// In zh, this message translates to:
  /// **'切换活动'**
  String get timerBarSwitch;

  /// No description provided for @timerBarSwitchUnavailable.
  ///
  /// In zh, this message translates to:
  /// **'切换活动选择器将在后续版本提供'**
  String get timerBarSwitchUnavailable;

  /// No description provided for @undo.
  ///
  /// In zh, this message translates to:
  /// **'撤销'**
  String get undo;

  /// No description provided for @redo.
  ///
  /// In zh, this message translates to:
  /// **'重做'**
  String get redo;

  /// No description provided for @undoHint.
  ///
  /// In zh, this message translates to:
  /// **'撤销上一步操作'**
  String get undoHint;

  /// No description provided for @redoHint.
  ///
  /// In zh, this message translates to:
  /// **'重做上一步操作'**
  String get redoHint;

  /// No description provided for @undoWithLabel.
  ///
  /// In zh, this message translates to:
  /// **'撤销：{label}'**
  String undoWithLabel(Object label);

  /// No description provided for @redoWithLabel.
  ///
  /// In zh, this message translates to:
  /// **'重做：{label}'**
  String redoWithLabel(Object label);

  /// No description provided for @history.
  ///
  /// In zh, this message translates to:
  /// **'历史'**
  String get history;

  /// No description provided for @currentDoing.
  ///
  /// In zh, this message translates to:
  /// **'正在做什么'**
  String get currentDoing;

  /// No description provided for @recording.
  ///
  /// In zh, this message translates to:
  /// **'记录中'**
  String get recording;

  /// No description provided for @notStarted.
  ///
  /// In zh, this message translates to:
  /// **'未开始'**
  String get notStarted;

  /// No description provided for @stop.
  ///
  /// In zh, this message translates to:
  /// **'停止'**
  String get stop;

  /// No description provided for @switchActivity.
  ///
  /// In zh, this message translates to:
  /// **'切换活动'**
  String get switchActivity;

  /// No description provided for @today.
  ///
  /// In zh, this message translates to:
  /// **'今天'**
  String get today;

  /// No description provided for @sessions.
  ///
  /// In zh, this message translates to:
  /// **'会话数'**
  String get sessions;

  /// No description provided for @quickActivity.
  ///
  /// In zh, this message translates to:
  /// **'快捷活动'**
  String get quickActivity;

  /// No description provided for @oneOff.
  ///
  /// In zh, this message translates to:
  /// **'临时'**
  String get oneOff;

  /// No description provided for @newActivity.
  ///
  /// In zh, this message translates to:
  /// **'新增'**
  String get newActivity;

  /// No description provided for @editActivity.
  ///
  /// In zh, this message translates to:
  /// **'编辑活动'**
  String get editActivity;

  /// No description provided for @editTooltip.
  ///
  /// In zh, this message translates to:
  /// **'编辑'**
  String get editTooltip;

  /// No description provided for @stopCurrentActivity.
  ///
  /// In zh, this message translates to:
  /// **'停止当前活动'**
  String get stopCurrentActivity;

  /// No description provided for @currentSession.
  ///
  /// In zh, this message translates to:
  /// **'当前会话'**
  String get currentSession;

  /// No description provided for @confirmSwitch.
  ///
  /// In zh, this message translates to:
  /// **'再次点击确认切换'**
  String get confirmSwitch;

  /// No description provided for @switchToSemantics.
  ///
  /// In zh, this message translates to:
  /// **'切换到 {name}'**
  String switchToSemantics(Object name);

  /// No description provided for @currentActivitySemantics.
  ///
  /// In zh, this message translates to:
  /// **'当前活动：{name}'**
  String currentActivitySemantics(Object name);

  /// No description provided for @confirmSwitchSemantics.
  ///
  /// In zh, this message translates to:
  /// **'确认切换到 {name}'**
  String confirmSwitchSemantics(Object name);

  /// No description provided for @selectDate.
  ///
  /// In zh, this message translates to:
  /// **'选择日期'**
  String get selectDate;

  /// No description provided for @previousDay.
  ///
  /// In zh, this message translates to:
  /// **'前一天'**
  String get previousDay;

  /// No description provided for @nextDay.
  ///
  /// In zh, this message translates to:
  /// **'后一天'**
  String get nextDay;

  /// No description provided for @emptyDayEntries.
  ///
  /// In zh, this message translates to:
  /// **'今日暂无记录'**
  String get emptyDayEntries;

  /// No description provided for @emptyRangeEntries.
  ///
  /// In zh, this message translates to:
  /// **'该时段暂无记录'**
  String get emptyRangeEntries;

  /// No description provided for @emptyDayActions.
  ///
  /// In zh, this message translates to:
  /// **'今日暂无操作'**
  String get emptyDayActions;

  /// No description provided for @emptyRangeActions.
  ///
  /// In zh, this message translates to:
  /// **'该时段暂无操作'**
  String get emptyRangeActions;

  /// No description provided for @addEntry.
  ///
  /// In zh, this message translates to:
  /// **'添加条目'**
  String get addEntry;

  /// No description provided for @entries.
  ///
  /// In zh, this message translates to:
  /// **'条目'**
  String get entries;

  /// No description provided for @actions.
  ///
  /// In zh, this message translates to:
  /// **'日志'**
  String get actions;

  /// No description provided for @singleDay.
  ///
  /// In zh, this message translates to:
  /// **'当天'**
  String get singleDay;

  /// No description provided for @threeDays.
  ///
  /// In zh, this message translates to:
  /// **'三天'**
  String get threeDays;

  /// No description provided for @thisWeek.
  ///
  /// In zh, this message translates to:
  /// **'本周'**
  String get thisWeek;

  /// No description provided for @sevenDays.
  ///
  /// In zh, this message translates to:
  /// **'七天'**
  String get sevenDays;

  /// No description provided for @viewMode.
  ///
  /// In zh, this message translates to:
  /// **'视图模式'**
  String get viewMode;

  /// No description provided for @timeline.
  ///
  /// In zh, this message translates to:
  /// **'时间线'**
  String get timeline;

  /// No description provided for @zoomableTimeline.
  ///
  /// In zh, this message translates to:
  /// **'时间线画布'**
  String get zoomableTimeline;

  /// No description provided for @entryList.
  ///
  /// In zh, this message translates to:
  /// **'条目列表'**
  String get entryList;

  /// No description provided for @entryListHint.
  ///
  /// In zh, this message translates to:
  /// **'按时间排列的详细记录'**
  String get entryListHint;

  /// No description provided for @totalRangeRecords.
  ///
  /// In zh, this message translates to:
  /// **'总时长'**
  String get totalRangeRecords;

  /// No description provided for @longestStreak.
  ///
  /// In zh, this message translates to:
  /// **'最长连续'**
  String get longestStreak;

  /// No description provided for @inProgress.
  ///
  /// In zh, this message translates to:
  /// **'进行中'**
  String get inProgress;

  /// No description provided for @futureDayBanner.
  ///
  /// In zh, this message translates to:
  /// **'“{date}”是未来日期，暂无可记录'**
  String futureDayBanner(Object date);

  /// No description provided for @noDataToVisualize.
  ///
  /// In zh, this message translates to:
  /// **'暂无数据可展示'**
  String get noDataToVisualize;

  /// No description provided for @startRecordingHint.
  ///
  /// In zh, this message translates to:
  /// **'开始记录你的时间吧'**
  String get startRecordingHint;

  /// No description provided for @recordHint.
  ///
  /// In zh, this message translates to:
  /// **'记录从计时页开始'**
  String get recordHint;

  /// No description provided for @switchToRecordHint.
  ///
  /// In zh, this message translates to:
  /// **'去计时页开始记录'**
  String get switchToRecordHint;

  /// No description provided for @stats.
  ///
  /// In zh, this message translates to:
  /// **'统计'**
  String get stats;

  /// No description provided for @statsSubtitle.
  ///
  /// In zh, this message translates to:
  /// **'统计范围：{range}'**
  String statsSubtitle(Object range);

  /// No description provided for @todayLabel.
  ///
  /// In zh, this message translates to:
  /// **'今天'**
  String get todayLabel;

  /// No description provided for @yesterday.
  ///
  /// In zh, this message translates to:
  /// **'昨天'**
  String get yesterday;

  /// No description provided for @lastWeek.
  ///
  /// In zh, this message translates to:
  /// **'上周'**
  String get lastWeek;

  /// No description provided for @customDay.
  ///
  /// In zh, this message translates to:
  /// **'自定义'**
  String get customDay;

  /// No description provided for @statsDimension.
  ///
  /// In zh, this message translates to:
  /// **'统计维度'**
  String get statsDimension;

  /// No description provided for @activityDimension.
  ///
  /// In zh, this message translates to:
  /// **'按活动'**
  String get activityDimension;

  /// No description provided for @primaryCategoryDimension.
  ///
  /// In zh, this message translates to:
  /// **'按主分类'**
  String get primaryCategoryDimension;

  /// No description provided for @durationBucketDimension.
  ///
  /// In zh, this message translates to:
  /// **'按时长区间'**
  String get durationBucketDimension;

  /// No description provided for @categoryDurationDimension.
  ///
  /// In zh, this message translates to:
  /// **'分类×时长'**
  String get categoryDurationDimension;

  /// No description provided for @dailyTotal.
  ///
  /// In zh, this message translates to:
  /// **'每日总计'**
  String get dailyTotal;

  /// No description provided for @dailyTotalHint.
  ///
  /// In zh, this message translates to:
  /// **'范围内逐日累计时长'**
  String get dailyTotalHint;

  /// No description provided for @distributionChartTitle.
  ///
  /// In zh, this message translates to:
  /// **'{range} 时间分布'**
  String distributionChartTitle(Object range);

  /// No description provided for @activityColorLegend.
  ///
  /// In zh, this message translates to:
  /// **'颜色对应活动'**
  String get activityColorLegend;

  /// No description provided for @statsCountTimes.
  ///
  /// In zh, this message translates to:
  /// **' 次'**
  String get statsCountTimes;

  /// No description provided for @settings.
  ///
  /// In zh, this message translates to:
  /// **'设置'**
  String get settings;

  /// No description provided for @settingsSubtitle.
  ///
  /// In zh, this message translates to:
  /// **'应用偏好与数据管理'**
  String get settingsSubtitle;

  /// No description provided for @checkUpdates.
  ///
  /// In zh, this message translates to:
  /// **'检查更新'**
  String get checkUpdates;

  /// No description provided for @openDownloadPage.
  ///
  /// In zh, this message translates to:
  /// **'打开下载页'**
  String get openDownloadPage;

  /// No description provided for @currentVersion.
  ///
  /// In zh, this message translates to:
  /// **'当前版本'**
  String get currentVersion;

  /// No description provided for @latestVersion.
  ///
  /// In zh, this message translates to:
  /// **'最新版本'**
  String get latestVersion;

  /// No description provided for @updateStatusIdle.
  ///
  /// In zh, this message translates to:
  /// **'空闲'**
  String get updateStatusIdle;

  /// No description provided for @updateStatusChecking.
  ///
  /// In zh, this message translates to:
  /// **'检查中…'**
  String get updateStatusChecking;

  /// No description provided for @updateStatusUpToDate.
  ///
  /// In zh, this message translates to:
  /// **'已是最新'**
  String get updateStatusUpToDate;

  /// No description provided for @updateStatusAvailable.
  ///
  /// In zh, this message translates to:
  /// **'有可用更新'**
  String get updateStatusAvailable;

  /// No description provided for @updateStatusFailed.
  ///
  /// In zh, this message translates to:
  /// **'检查失败'**
  String get updateStatusFailed;

  /// No description provided for @syncNow.
  ///
  /// In zh, this message translates to:
  /// **'立即同步'**
  String get syncNow;

  /// No description provided for @syncing.
  ///
  /// In zh, this message translates to:
  /// **'同步中…'**
  String get syncing;

  /// No description provided for @syncStatusCloud.
  ///
  /// In zh, this message translates to:
  /// **'云同步'**
  String get syncStatusCloud;

  /// No description provided for @syncStatusLocal.
  ///
  /// In zh, this message translates to:
  /// **'本地模式'**
  String get syncStatusLocal;

  /// No description provided for @syncStatus.
  ///
  /// In zh, this message translates to:
  /// **'同步状态'**
  String get syncStatus;

  /// No description provided for @syncStatusSynced.
  ///
  /// In zh, this message translates to:
  /// **'已同步'**
  String get syncStatusSynced;

  /// No description provided for @lastSyncNever.
  ///
  /// In zh, this message translates to:
  /// **'从未同步'**
  String get lastSyncNever;

  /// No description provided for @lastSyncAt.
  ///
  /// In zh, this message translates to:
  /// **'上次同步：{time}'**
  String lastSyncAt(Object time);

  /// No description provided for @lastSyncError.
  ///
  /// In zh, this message translates to:
  /// **'上次同步出错：{error}'**
  String lastSyncError(Object error);

  /// No description provided for @signOut.
  ///
  /// In zh, this message translates to:
  /// **'退出登录'**
  String get signOut;

  /// No description provided for @notLoggedIn.
  ///
  /// In zh, this message translates to:
  /// **'未登录'**
  String get notLoggedIn;

  /// No description provided for @loggedIn.
  ///
  /// In zh, this message translates to:
  /// **'已登录'**
  String get loggedIn;

  /// No description provided for @supabaseConfigured.
  ///
  /// In zh, this message translates to:
  /// **'云同步已配置'**
  String get supabaseConfigured;

  /// No description provided for @supabaseNotConfigured.
  ///
  /// In zh, this message translates to:
  /// **'云同步未配置'**
  String get supabaseNotConfigured;

  /// No description provided for @reminderSettings.
  ///
  /// In zh, this message translates to:
  /// **'提醒设置'**
  String get reminderSettings;

  /// No description provided for @reminderSettingsHint.
  ///
  /// In zh, this message translates to:
  /// **'设置运行提醒的时机与方式'**
  String get reminderSettingsHint;

  /// No description provided for @triggerTime.
  ///
  /// In zh, this message translates to:
  /// **'触发时刻'**
  String get triggerTime;

  /// No description provided for @durationLabel.
  ///
  /// In zh, this message translates to:
  /// **'运行时长'**
  String get durationLabel;

  /// No description provided for @interval.
  ///
  /// In zh, this message translates to:
  /// **'重复间隔'**
  String get interval;

  /// No description provided for @method.
  ///
  /// In zh, this message translates to:
  /// **'提醒方式'**
  String get method;

  /// No description provided for @methodDialog.
  ///
  /// In zh, this message translates to:
  /// **'对话框'**
  String get methodDialog;

  /// No description provided for @methodBanner.
  ///
  /// In zh, this message translates to:
  /// **'横幅'**
  String get methodBanner;

  /// No description provided for @methodSilent.
  ///
  /// In zh, this message translates to:
  /// **'静音'**
  String get methodSilent;

  /// No description provided for @minutesFormat.
  ///
  /// In zh, this message translates to:
  /// **'{minutes} 分钟'**
  String minutesFormat(Object minutes);

  /// No description provided for @hoursMinutesFormat.
  ///
  /// In zh, this message translates to:
  /// **'{hours} 小时 {minutes} 分钟'**
  String hoursMinutesFormat(Object hours, Object minutes);

  /// No description provided for @mergeThreshold.
  ///
  /// In zh, this message translates to:
  /// **'合并阈值'**
  String get mergeThreshold;

  /// No description provided for @cloudSync.
  ///
  /// In zh, this message translates to:
  /// **'云同步'**
  String get cloudSync;

  /// No description provided for @cloudSyncHint.
  ///
  /// In zh, this message translates to:
  /// **'登录并同步你的数据'**
  String get cloudSyncHint;

  /// No description provided for @deviceInterop.
  ///
  /// In zh, this message translates to:
  /// **'设备互通'**
  String get deviceInterop;

  /// No description provided for @deviceInteropHint.
  ///
  /// In zh, this message translates to:
  /// **'局域网配对与文件导入导出'**
  String get deviceInteropHint;

  /// No description provided for @versionUpdate.
  ///
  /// In zh, this message translates to:
  /// **'版本更新'**
  String get versionUpdate;

  /// No description provided for @versionUpdateHint.
  ///
  /// In zh, this message translates to:
  /// **'检查并安装应用更新'**
  String get versionUpdateHint;

  /// No description provided for @lanHost.
  ///
  /// In zh, this message translates to:
  /// **'局域网主机'**
  String get lanHost;

  /// No description provided for @connectLanHost.
  ///
  /// In zh, this message translates to:
  /// **'连接主机'**
  String get connectLanHost;

  /// No description provided for @startHost.
  ///
  /// In zh, this message translates to:
  /// **'启动主机'**
  String get startHost;

  /// No description provided for @stopHost.
  ///
  /// In zh, this message translates to:
  /// **'停止主机'**
  String get stopHost;

  /// No description provided for @windowsOnly.
  ///
  /// In zh, this message translates to:
  /// **'仅 Windows 可用'**
  String get windowsOnly;

  /// No description provided for @pairAndSync.
  ///
  /// In zh, this message translates to:
  /// **'配对并同步'**
  String get pairAndSync;

  /// No description provided for @hostAddress.
  ///
  /// In zh, this message translates to:
  /// **'主机地址'**
  String get hostAddress;

  /// No description provided for @pairingCodeInput.
  ///
  /// In zh, this message translates to:
  /// **'配对码'**
  String get pairingCodeInput;

  /// No description provided for @importFile.
  ///
  /// In zh, this message translates to:
  /// **'导入文件'**
  String get importFile;

  /// No description provided for @exportFile.
  ///
  /// In zh, this message translates to:
  /// **'导出文件'**
  String get exportFile;

  /// No description provided for @lanHostStartNote.
  ///
  /// In zh, this message translates to:
  /// **'启动后在局域网内提供同步服务'**
  String get lanHostStartNote;

  /// No description provided for @lanHostWindowsNote.
  ///
  /// In zh, this message translates to:
  /// **'Windows 桌面端作为主机'**
  String get lanHostWindowsNote;

  /// No description provided for @connectLanHostHint.
  ///
  /// In zh, this message translates to:
  /// **'输入主机地址与配对码建立连接'**
  String get connectLanHostHint;

  /// No description provided for @lanHostAndroidNote.
  ///
  /// In zh, this message translates to:
  /// **'主机已运行，等待设备连接'**
  String get lanHostAndroidNote;

  /// No description provided for @pairedWith.
  ///
  /// In zh, this message translates to:
  /// **'已配对：{name}'**
  String pairedWith(Object name);

  /// No description provided for @removePairing.
  ///
  /// In zh, this message translates to:
  /// **'解除配对'**
  String get removePairing;

  /// No description provided for @selectValidActivity.
  ///
  /// In zh, this message translates to:
  /// **'请选择有效的活动'**
  String get selectValidActivity;

  /// No description provided for @start.
  ///
  /// In zh, this message translates to:
  /// **'开始'**
  String get start;

  /// No description provided for @endTime.
  ///
  /// In zh, this message translates to:
  /// **'结束'**
  String get endTime;

  /// No description provided for @note.
  ///
  /// In zh, this message translates to:
  /// **'备注'**
  String get note;

  /// No description provided for @keepRunning.
  ///
  /// In zh, this message translates to:
  /// **'保持运行'**
  String get keepRunning;

  /// No description provided for @closeToSaveHint.
  ///
  /// In zh, this message translates to:
  /// **'关闭开关以设置结束时间'**
  String get closeToSaveHint;

  /// No description provided for @deleteEntry.
  ///
  /// In zh, this message translates to:
  /// **'删除条目'**
  String get deleteEntry;

  /// No description provided for @editEntryTitle.
  ///
  /// In zh, this message translates to:
  /// **'编辑条目'**
  String get editEntryTitle;

  /// No description provided for @addEntryTitle.
  ///
  /// In zh, this message translates to:
  /// **'添加条目'**
  String get addEntryTitle;

  /// No description provided for @createActivityTitle.
  ///
  /// In zh, this message translates to:
  /// **'新建活动'**
  String get createActivityTitle;

  /// No description provided for @persistent.
  ///
  /// In zh, this message translates to:
  /// **'持续'**
  String get persistent;

  /// No description provided for @create.
  ///
  /// In zh, this message translates to:
  /// **'创建'**
  String get create;

  /// No description provided for @split.
  ///
  /// In zh, this message translates to:
  /// **'拆分'**
  String get split;

  /// No description provided for @mergeLeft.
  ///
  /// In zh, this message translates to:
  /// **'与左合并'**
  String get mergeLeft;

  /// No description provided for @mergeRight.
  ///
  /// In zh, this message translates to:
  /// **'与右合并'**
  String get mergeRight;

  /// No description provided for @extendToNow.
  ///
  /// In zh, this message translates to:
  /// **'延伸到当前'**
  String get extendToNow;

  /// No description provided for @mergeConfirm.
  ///
  /// In zh, this message translates to:
  /// **'与「{name}」（{duration}）合并？'**
  String mergeConfirm(Object duration, Object name);

  /// No description provided for @splitEntryTitle.
  ///
  /// In zh, this message translates to:
  /// **'拆分条目'**
  String get splitEntryTitle;

  /// No description provided for @splitPoint.
  ///
  /// In zh, this message translates to:
  /// **'拆分时刻'**
  String get splitPoint;

  /// No description provided for @splitPointError.
  ///
  /// In zh, this message translates to:
  /// **'拆分时刻必须在条目范围内'**
  String get splitPointError;

  /// No description provided for @endMustBeAfterStart.
  ///
  /// In zh, this message translates to:
  /// **'结束时间必须晚于开始时间'**
  String get endMustBeAfterStart;

  /// No description provided for @runningCannotStartFuture.
  ///
  /// In zh, this message translates to:
  /// **'运行中的条目开始时间不能在未来'**
  String get runningCannotStartFuture;

  /// No description provided for @overlapWarning.
  ///
  /// In zh, this message translates to:
  /// **'与既有条目时间重叠'**
  String get overlapWarning;

  /// No description provided for @primaryCategory.
  ///
  /// In zh, this message translates to:
  /// **'主分类'**
  String get primaryCategory;

  /// No description provided for @uncategorized.
  ///
  /// In zh, this message translates to:
  /// **'未分类'**
  String get uncategorized;

  /// No description provided for @categoryName.
  ///
  /// In zh, this message translates to:
  /// **'分类名称'**
  String get categoryName;

  /// No description provided for @categoryColor.
  ///
  /// In zh, this message translates to:
  /// **'分类颜色'**
  String get categoryColor;

  /// No description provided for @createCategory.
  ///
  /// In zh, this message translates to:
  /// **'创建分类'**
  String get createCategory;

  /// No description provided for @newCategory.
  ///
  /// In zh, this message translates to:
  /// **'新建分类'**
  String get newCategory;

  /// No description provided for @deleteCategoryTitle.
  ///
  /// In zh, this message translates to:
  /// **'删除分类'**
  String get deleteCategoryTitle;

  /// No description provided for @confirmDeleteCategory.
  ///
  /// In zh, this message translates to:
  /// **'删除分类「{name}」将同时删除其子分类与关联，确定？'**
  String confirmDeleteCategory(Object name);

  /// No description provided for @name.
  ///
  /// In zh, this message translates to:
  /// **'名称'**
  String get name;

  /// No description provided for @color.
  ///
  /// In zh, this message translates to:
  /// **'颜色'**
  String get color;

  /// No description provided for @sortBy.
  ///
  /// In zh, this message translates to:
  /// **'排序方式'**
  String get sortBy;

  /// No description provided for @sortAscending.
  ///
  /// In zh, this message translates to:
  /// **'升序'**
  String get sortAscending;

  /// No description provided for @sortDescending.
  ///
  /// In zh, this message translates to:
  /// **'降序'**
  String get sortDescending;

  /// No description provided for @recentlyUpdated.
  ///
  /// In zh, this message translates to:
  /// **'最近更新'**
  String get recentlyUpdated;

  /// No description provided for @all.
  ///
  /// In zh, this message translates to:
  /// **'全部'**
  String get all;

  /// No description provided for @retry.
  ///
  /// In zh, this message translates to:
  /// **'重试'**
  String get retry;

  /// No description provided for @errorOccurred.
  ///
  /// In zh, this message translates to:
  /// **'出错了：{message}'**
  String errorOccurred(Object message);

  /// No description provided for @viewFullTimeline.
  ///
  /// In zh, this message translates to:
  /// **'查看完整时间线'**
  String get viewFullTimeline;

  /// No description provided for @topActivities.
  ///
  /// In zh, this message translates to:
  /// **'顶部活动'**
  String get topActivities;

  /// No description provided for @totalTime.
  ///
  /// In zh, this message translates to:
  /// **'总时长'**
  String get totalTime;

  /// No description provided for @focusTime.
  ///
  /// In zh, this message translates to:
  /// **'专注时间'**
  String get focusTime;

  /// No description provided for @breakTime.
  ///
  /// In zh, this message translates to:
  /// **'休息时间'**
  String get breakTime;

  /// No description provided for @dailyAvg.
  ///
  /// In zh, this message translates to:
  /// **'日均'**
  String get dailyAvg;

  /// No description provided for @vsPreviousDay.
  ///
  /// In zh, this message translates to:
  /// **'较前日'**
  String get vsPreviousDay;

  /// No description provided for @vsLastWeek.
  ///
  /// In zh, this message translates to:
  /// **'较上周'**
  String get vsLastWeek;

  /// No description provided for @timeByDay.
  ///
  /// In zh, this message translates to:
  /// **'每日时间'**
  String get timeByDay;

  /// No description provided for @timeByActivity.
  ///
  /// In zh, this message translates to:
  /// **'事项时间'**
  String get timeByActivity;

  /// No description provided for @aiSummary.
  ///
  /// In zh, this message translates to:
  /// **'AI 总结'**
  String get aiSummary;

  /// No description provided for @aiSummaryHint.
  ///
  /// In zh, this message translates to:
  /// **'用一句话总结你的时间记录'**
  String get aiSummaryHint;

  /// No description provided for @aiNotConfigured.
  ///
  /// In zh, this message translates to:
  /// **'配置 AI 密钥后可用'**
  String get aiNotConfigured;

  /// No description provided for @aiGoSettings.
  ///
  /// In zh, this message translates to:
  /// **'去设置'**
  String get aiGoSettings;

  /// No description provided for @aiAskPlaceholder.
  ///
  /// In zh, this message translates to:
  /// **'问问你的时间…'**
  String get aiAskPlaceholder;

  /// No description provided for @aiGenerate.
  ///
  /// In zh, this message translates to:
  /// **'生成总结'**
  String get aiGenerate;

  /// No description provided for @aiRegenerate.
  ///
  /// In zh, this message translates to:
  /// **'重新生成'**
  String get aiRegenerate;

  /// No description provided for @aiSummaryThisWeek.
  ///
  /// In zh, this message translates to:
  /// **'本周总结'**
  String get aiSummaryThisWeek;

  /// No description provided for @aiSummaryToday.
  ///
  /// In zh, this message translates to:
  /// **'今天做了什么'**
  String get aiSummaryToday;

  /// No description provided for @aiSummaryCompare.
  ///
  /// In zh, this message translates to:
  /// **'较上周对比'**
  String get aiSummaryCompare;

  /// No description provided for @aiExecuting.
  ///
  /// In zh, this message translates to:
  /// **'执行中…'**
  String get aiExecuting;

  /// No description provided for @aiResultError.
  ///
  /// In zh, this message translates to:
  /// **'总结生成失败'**
  String get aiResultError;

  /// No description provided for @backgroundTracking.
  ///
  /// In zh, this message translates to:
  /// **'后台记录'**
  String get backgroundTracking;

  /// No description provided for @backgroundTrackingHint.
  ///
  /// In zh, this message translates to:
  /// **'按规则自动记录前台应用'**
  String get backgroundTrackingHint;

  /// No description provided for @trackingRule.
  ///
  /// In zh, this message translates to:
  /// **'规则'**
  String get trackingRule;

  /// No description provided for @newRule.
  ///
  /// In zh, this message translates to:
  /// **'新建规则'**
  String get newRule;

  /// No description provided for @editRule.
  ///
  /// In zh, this message translates to:
  /// **'编辑规则'**
  String get editRule;

  /// No description provided for @rulePattern.
  ///
  /// In zh, this message translates to:
  /// **'匹配模式'**
  String get rulePattern;

  /// No description provided for @ruleKind.
  ///
  /// In zh, this message translates to:
  /// **'匹配类型'**
  String get ruleKind;

  /// No description provided for @ruleKindProcess.
  ///
  /// In zh, this message translates to:
  /// **'进程名'**
  String get ruleKindProcess;

  /// No description provided for @ruleKindTitle.
  ///
  /// In zh, this message translates to:
  /// **'窗口标题'**
  String get ruleKindTitle;

  /// No description provided for @ruleActivity.
  ///
  /// In zh, this message translates to:
  /// **'目标活动'**
  String get ruleActivity;

  /// No description provided for @ruleSyncEnabled.
  ///
  /// In zh, this message translates to:
  /// **'进云同步'**
  String get ruleSyncEnabled;

  /// No description provided for @ruleSyncHint.
  ///
  /// In zh, this message translates to:
  /// **'该规则产生的记录是否参与云同步'**
  String get ruleSyncHint;

  /// No description provided for @rulePriorityHint.
  ///
  /// In zh, this message translates to:
  /// **'匹配优先级：精确 > 通配 > 标题'**
  String get rulePriorityHint;

  /// No description provided for @deleteRule.
  ///
  /// In zh, this message translates to:
  /// **'删除规则'**
  String get deleteRule;

  /// No description provided for @confirmDeleteRule.
  ///
  /// In zh, this message translates to:
  /// **'删除规则「{pattern}」？'**
  String confirmDeleteRule(Object pattern);

  /// No description provided for @usageAccess.
  ///
  /// In zh, this message translates to:
  /// **'使用情况访问'**
  String get usageAccess;

  /// No description provided for @usageAccessGranted.
  ///
  /// In zh, this message translates to:
  /// **'已授权'**
  String get usageAccessGranted;

  /// No description provided for @usageAccessNotGranted.
  ///
  /// In zh, this message translates to:
  /// **'未授权'**
  String get usageAccessNotGranted;

  /// No description provided for @usageAccessGuide.
  ///
  /// In zh, this message translates to:
  /// **'需要“使用情况访问”权限才能自动记录前台应用'**
  String get usageAccessGuide;

  /// No description provided for @usageAccessButton.
  ///
  /// In zh, this message translates to:
  /// **'去系统设置开启'**
  String get usageAccessButton;

  /// No description provided for @usageAccessLater.
  ///
  /// In zh, this message translates to:
  /// **'暂不开启'**
  String get usageAccessLater;

  /// No description provided for @trackingWindowsNote.
  ///
  /// In zh, this message translates to:
  /// **'Windows 端通过检测前台窗口自动记录'**
  String get trackingWindowsNote;

  /// No description provided for @trackingNotEnabled.
  ///
  /// In zh, this message translates to:
  /// **'后台记录未启用'**
  String get trackingNotEnabled;

  /// No description provided for @closeAppTitle.
  ///
  /// In zh, this message translates to:
  /// **'最小化到托盘？'**
  String get closeAppTitle;

  /// No description provided for @closeAppContent.
  ///
  /// In zh, this message translates to:
  /// **'最小化到托盘可继续后台记录'**
  String get closeAppContent;

  /// No description provided for @minimizeToTray.
  ///
  /// In zh, this message translates to:
  /// **'最小化到托盘'**
  String get minimizeToTray;

  /// No description provided for @exitApp.
  ///
  /// In zh, this message translates to:
  /// **'退出应用'**
  String get exitApp;

  /// No description provided for @stillDoingThis.
  ///
  /// In zh, this message translates to:
  /// **'仍在进行这个活动？'**
  String get stillDoingThis;

  /// No description provided for @activityRunningMinutes.
  ///
  /// In zh, this message translates to:
  /// **'已运行 {minutes} 分钟'**
  String activityRunningMinutes(Object minutes);

  /// No description provided for @remindLater.
  ///
  /// In zh, this message translates to:
  /// **'稍后提醒'**
  String get remindLater;

  /// No description provided for @continueLabel.
  ///
  /// In zh, this message translates to:
  /// **'继续'**
  String get continueLabel;

  /// No description provided for @confirmPreviousPeriod.
  ///
  /// In zh, this message translates to:
  /// **'确认上一时段记录？'**
  String get confirmPreviousPeriod;

  /// No description provided for @suspiciousEntryContent.
  ///
  /// In zh, this message translates to:
  /// **'检测到从 {time} 开始的活动仍处于运行状态'**
  String suspiciousEntryContent(Object time);

  /// No description provided for @keepCurrent.
  ///
  /// In zh, this message translates to:
  /// **'保留当前'**
  String get keepCurrent;

  /// No description provided for @endToNow.
  ///
  /// In zh, this message translates to:
  /// **'结束到现在'**
  String get endToNow;

  /// No description provided for @updateAvailablePrompt.
  ///
  /// In zh, this message translates to:
  /// **'发现新版本 {version}'**
  String updateAvailablePrompt(Object version);

  /// No description provided for @viewInSettings.
  ///
  /// In zh, this message translates to:
  /// **'去查看'**
  String get viewInSettings;

  /// No description provided for @themeAppearance.
  ///
  /// In zh, this message translates to:
  /// **'外观'**
  String get themeAppearance;

  /// No description provided for @themeModeSystem.
  ///
  /// In zh, this message translates to:
  /// **'跟随系统'**
  String get themeModeSystem;

  /// No description provided for @themeModeLight.
  ///
  /// In zh, this message translates to:
  /// **'浅色'**
  String get themeModeLight;

  /// No description provided for @themeModeDark.
  ///
  /// In zh, this message translates to:
  /// **'深色'**
  String get themeModeDark;

  /// No description provided for @appearancePending.
  ///
  /// In zh, this message translates to:
  /// **'主题切换随系统自动生效'**
  String get appearancePending;

  /// No description provided for @aiSettings.
  ///
  /// In zh, this message translates to:
  /// **'AI 配置'**
  String get aiSettings;

  /// No description provided for @aiSettingsHint.
  ///
  /// In zh, this message translates to:
  /// **'配置 AI 密钥与模型（二期启用总结能力）'**
  String get aiSettingsHint;

  /// No description provided for @aiKeyLabel.
  ///
  /// In zh, this message translates to:
  /// **'AI 密钥'**
  String get aiKeyLabel;

  /// No description provided for @aiModelLabel.
  ///
  /// In zh, this message translates to:
  /// **'模型'**
  String get aiModelLabel;

  /// No description provided for @aiEndpointLabel.
  ///
  /// In zh, this message translates to:
  /// **'端点'**
  String get aiEndpointLabel;

  /// No description provided for @aiTestConnection.
  ///
  /// In zh, this message translates to:
  /// **'测试连接'**
  String get aiTestConnection;

  /// No description provided for @aiClearKey.
  ///
  /// In zh, this message translates to:
  /// **'清除密钥'**
  String get aiClearKey;

  /// No description provided for @exportData.
  ///
  /// In zh, this message translates to:
  /// **'导出数据'**
  String get exportData;

  /// No description provided for @importData.
  ///
  /// In zh, this message translates to:
  /// **'导入数据'**
  String get importData;

  /// No description provided for @clearAllData.
  ///
  /// In zh, this message translates to:
  /// **'清除全部数据'**
  String get clearAllData;

  /// No description provided for @clearAllDataHint.
  ///
  /// In zh, this message translates to:
  /// **'清除本地记录前，请先导出备份'**
  String get clearAllDataHint;

  /// No description provided for @firstDayOfWeek.
  ///
  /// In zh, this message translates to:
  /// **'每周起始日'**
  String get firstDayOfWeek;

  /// No description provided for @timeFormat.
  ///
  /// In zh, this message translates to:
  /// **'时间格式'**
  String get timeFormat;

  /// No description provided for @defaultSessionLength.
  ///
  /// In zh, this message translates to:
  /// **'默认记录时长'**
  String get defaultSessionLength;

  /// No description provided for @quickReminder.
  ///
  /// In zh, this message translates to:
  /// **'快速提醒'**
  String get quickReminder;

  /// No description provided for @on.
  ///
  /// In zh, this message translates to:
  /// **'开'**
  String get on;

  /// No description provided for @off.
  ///
  /// In zh, this message translates to:
  /// **'关'**
  String get off;

  /// No description provided for @monday.
  ///
  /// In zh, this message translates to:
  /// **'周一'**
  String get monday;

  /// No description provided for @twelveHour.
  ///
  /// In zh, this message translates to:
  /// **'12 小时'**
  String get twelveHour;

  /// No description provided for @settingsCategories.
  ///
  /// In zh, this message translates to:
  /// **'分类管理'**
  String get settingsCategories;

  /// No description provided for @editCategory.
  ///
  /// In zh, this message translates to:
  /// **'编辑分类'**
  String get editCategory;

  /// No description provided for @deleteCategory.
  ///
  /// In zh, this message translates to:
  /// **'删除分类'**
  String get deleteCategory;

  /// No description provided for @parentCategory.
  ///
  /// In zh, this message translates to:
  /// **'父级分类'**
  String get parentCategory;

  /// No description provided for @topLevelCategory.
  ///
  /// In zh, this message translates to:
  /// **'顶级分类'**
  String get topLevelCategory;

  /// No description provided for @close.
  ///
  /// In zh, this message translates to:
  /// **'关闭'**
  String get close;

  /// No description provided for @errorTitle.
  ///
  /// In zh, this message translates to:
  /// **'出错了'**
  String get errorTitle;
}

class _AppLocalizationsDelegate
    extends LocalizationsDelegate<AppLocalizations> {
  const _AppLocalizationsDelegate();

  @override
  Future<AppLocalizations> load(Locale locale) {
    return SynchronousFuture<AppLocalizations>(lookupAppLocalizations(locale));
  }

  @override
  bool isSupported(Locale locale) =>
      <String>['en', 'zh'].contains(locale.languageCode);

  @override
  bool shouldReload(_AppLocalizationsDelegate old) => false;
}

AppLocalizations lookupAppLocalizations(Locale locale) {
  // Lookup logic when only language code is specified.
  switch (locale.languageCode) {
    case 'en':
      return AppLocalizationsEn();
    case 'zh':
      return AppLocalizationsZh();
  }

  throw FlutterError(
    'AppLocalizations.delegate failed to load unsupported locale "$locale". This is likely '
    'an issue with the localizations generation tool. Please file an issue '
    'on GitHub with a reproducible sample app and the gen-l10n configuration '
    'that was used.',
  );
}
