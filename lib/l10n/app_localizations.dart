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
  /// **'新建活动'**
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

  /// No description provided for @trayCloseRemember.
  ///
  /// In zh, this message translates to:
  /// **'记住我的选择，不再询问'**
  String get trayCloseRemember;

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

  /// No description provided for @unassignedActivity.
  ///
  /// In zh, this message translates to:
  /// **'未分配'**
  String get unassignedActivity;

  /// No description provided for @timerAll.
  ///
  /// In zh, this message translates to:
  /// **'全部'**
  String get timerAll;

  /// No description provided for @timerTodayTotal.
  ///
  /// In zh, this message translates to:
  /// **'今日累计'**
  String get timerTodayTotal;

  /// No description provided for @timerTodaySessions.
  ///
  /// In zh, this message translates to:
  /// **'会话数'**
  String get timerTodaySessions;

  /// No description provided for @timerRunning.
  ///
  /// In zh, this message translates to:
  /// **'运行中'**
  String get timerRunning;

  /// No description provided for @timerTapToConfirm.
  ///
  /// In zh, this message translates to:
  /// **'再击确认切换'**
  String get timerTapToConfirm;

  /// No description provided for @timerTemporaryActivity.
  ///
  /// In zh, this message translates to:
  /// **'临时活动'**
  String get timerTemporaryActivity;

  /// No description provided for @timerNewActivity.
  ///
  /// In zh, this message translates to:
  /// **'新增活动'**
  String get timerNewActivity;

  /// No description provided for @timerInteractionHint.
  ///
  /// In zh, this message translates to:
  /// **'单击选中 · 再击确认 · 双击直接切换 · 长按编辑'**
  String get timerInteractionHint;

  /// No description provided for @timerNoActivities.
  ///
  /// In zh, this message translates to:
  /// **'暂无活动，先创建一个吧'**
  String get timerNoActivities;

  /// No description provided for @timerCategoryEmpty.
  ///
  /// In zh, this message translates to:
  /// **'此分类暂无活动'**
  String get timerCategoryEmpty;

  /// No description provided for @todayTotalDuration.
  ///
  /// In zh, this message translates to:
  /// **'总时长'**
  String get todayTotalDuration;

  /// No description provided for @todayFocusDuration.
  ///
  /// In zh, this message translates to:
  /// **'专注时长'**
  String get todayFocusDuration;

  /// No description provided for @todayRestDuration.
  ///
  /// In zh, this message translates to:
  /// **'休息时长'**
  String get todayRestDuration;

  /// No description provided for @todayVsPrevious.
  ///
  /// In zh, this message translates to:
  /// **'较前日'**
  String get todayVsPrevious;

  /// No description provided for @todayPreviewTitle.
  ///
  /// In zh, this message translates to:
  /// **'时间线预览'**
  String get todayPreviewTitle;

  /// No description provided for @todayViewFullTimeline.
  ///
  /// In zh, this message translates to:
  /// **'查看完整时间线'**
  String get todayViewFullTimeline;

  /// No description provided for @todayBackToToday.
  ///
  /// In zh, this message translates to:
  /// **'回到今天'**
  String get todayBackToToday;

  /// No description provided for @todayStartRecording.
  ///
  /// In zh, this message translates to:
  /// **'开始记录吧'**
  String get todayStartRecording;

  /// No description provided for @todayEmptyDay.
  ///
  /// In zh, this message translates to:
  /// **'该日暂无记录'**
  String get todayEmptyDay;

  /// No description provided for @todayCreateCategory.
  ///
  /// In zh, this message translates to:
  /// **'新建分类'**
  String get todayCreateCategory;

  /// No description provided for @edit.
  ///
  /// In zh, this message translates to:
  /// **'编辑'**
  String get edit;

  /// No description provided for @ongoing.
  ///
  /// In zh, this message translates to:
  /// **'持续'**
  String get ongoing;

  /// No description provided for @secondaryCategories.
  ///
  /// In zh, this message translates to:
  /// **'副分类'**
  String get secondaryCategories;

  /// No description provided for @rootCategory.
  ///
  /// In zh, this message translates to:
  /// **'根分类'**
  String get rootCategory;

  /// No description provided for @searchActivities.
  ///
  /// In zh, this message translates to:
  /// **'搜索活动与分类…'**
  String get searchActivities;

  /// No description provided for @activityNameRequired.
  ///
  /// In zh, this message translates to:
  /// **'名称不能为空'**
  String get activityNameRequired;

  /// No description provided for @categoryEmptyActivities.
  ///
  /// In zh, this message translates to:
  /// **'此分类暂无活动'**
  String get categoryEmptyActivities;

  /// No description provided for @categoryCreated.
  ///
  /// In zh, this message translates to:
  /// **'分类已创建'**
  String get categoryCreated;

  /// No description provided for @activityCreated.
  ///
  /// In zh, this message translates to:
  /// **'活动已创建'**
  String get activityCreated;

  /// No description provided for @activityEdited.
  ///
  /// In zh, this message translates to:
  /// **'活动已更新'**
  String get activityEdited;

  /// No description provided for @categoryDeleted.
  ///
  /// In zh, this message translates to:
  /// **'分类已删除，可撤销'**
  String get categoryDeleted;

  /// No description provided for @deleteFailed.
  ///
  /// In zh, this message translates to:
  /// **'操作失败'**
  String get deleteFailed;

  /// No description provided for @createFailed.
  ///
  /// In zh, this message translates to:
  /// **'创建失败'**
  String get createFailed;

  /// No description provided for @currentActivity.
  ///
  /// In zh, this message translates to:
  /// **'当前'**
  String get currentActivity;

  /// No description provided for @active.
  ///
  /// In zh, this message translates to:
  /// **'已选中'**
  String get active;

  /// No description provided for @categoryDeleteHint.
  ///
  /// In zh, this message translates to:
  /// **'将删除此分类、N 个子分类与 N 个活动的关联（可撤销）'**
  String get categoryDeleteHint;

  /// No description provided for @categoryUpdated.
  ///
  /// In zh, this message translates to:
  /// **'分类已更新'**
  String get categoryUpdated;

  /// No description provided for @timerStartRecording.
  ///
  /// In zh, this message translates to:
  /// **'开始记录'**
  String get timerStartRecording;

  /// No description provided for @timerLoadFailed.
  ///
  /// In zh, this message translates to:
  /// **'数据加载失败，请重试'**
  String get timerLoadFailed;

  /// No description provided for @todayPrevDay.
  ///
  /// In zh, this message translates to:
  /// **'前一天'**
  String get todayPrevDay;

  /// No description provided for @todayNextDay.
  ///
  /// In zh, this message translates to:
  /// **'后一天'**
  String get todayNextDay;

  /// No description provided for @todayPickDate.
  ///
  /// In zh, this message translates to:
  /// **'选择日期'**
  String get todayPickDate;

  /// No description provided for @todayClearFilters.
  ///
  /// In zh, this message translates to:
  /// **'清除筛选'**
  String get todayClearFilters;

  /// No description provided for @timerQuickSection.
  ///
  /// In zh, this message translates to:
  /// **'快捷活动'**
  String get timerQuickSection;

  /// No description provided for @timerAllActivities.
  ///
  /// In zh, this message translates to:
  /// **'全部活动'**
  String get timerAllActivities;

  /// No description provided for @timerTodayShort.
  ///
  /// In zh, this message translates to:
  /// **'今日'**
  String get timerTodayShort;

  /// No description provided for @timerGroupCount.
  ///
  /// In zh, this message translates to:
  /// **'共 {n} 个活动'**
  String timerGroupCount(Object n);

  /// No description provided for @timerSwitchHint.
  ///
  /// In zh, this message translates to:
  /// **'切换 = 结束当前会话并立即开始新活动（原子操作，不留空档）；两种操作均可通过全局撤销恢复。'**
  String get timerSwitchHint;

  /// No description provided for @entryEditorEdit.
  ///
  /// In zh, this message translates to:
  /// **'编辑条目'**
  String get entryEditorEdit;

  /// No description provided for @entryEditorNew.
  ///
  /// In zh, this message translates to:
  /// **'添加条目'**
  String get entryEditorNew;

  /// No description provided for @entryChangeActivity.
  ///
  /// In zh, this message translates to:
  /// **'更换'**
  String get entryChangeActivity;

  /// No description provided for @entryStartAt.
  ///
  /// In zh, this message translates to:
  /// **'开始'**
  String get entryStartAt;

  /// No description provided for @entryEndAt.
  ///
  /// In zh, this message translates to:
  /// **'结束'**
  String get entryEndAt;

  /// No description provided for @entryKeepRunning.
  ///
  /// In zh, this message translates to:
  /// **'保持运行'**
  String get entryKeepRunning;

  /// No description provided for @entryNoteHint.
  ///
  /// In zh, this message translates to:
  /// **'备注…'**
  String get entryNoteHint;

  /// No description provided for @entryErrEndBeforeStart.
  ///
  /// In zh, this message translates to:
  /// **'结束时间必须晚于开始时间'**
  String get entryErrEndBeforeStart;

  /// No description provided for @entryErrRunningInFuture.
  ///
  /// In zh, this message translates to:
  /// **'运行中的条目不能落在将来'**
  String get entryErrRunningInFuture;

  /// No description provided for @entryWarnOverlap.
  ///
  /// In zh, this message translates to:
  /// **'与既有条目时间重叠，仍要保存吗？'**
  String get entryWarnOverlap;

  /// No description provided for @entryOverlapContinue.
  ///
  /// In zh, this message translates to:
  /// **'仍要保存'**
  String get entryOverlapContinue;

  /// No description provided for @entryHintSplit.
  ///
  /// In zh, this message translates to:
  /// **'跨越 0 点，保存后将自动拆分为两条'**
  String get entryHintSplit;

  /// No description provided for @entryEditOps.
  ///
  /// In zh, this message translates to:
  /// **'相邻条目操作'**
  String get entryEditOps;

  /// No description provided for @entryMergePrev.
  ///
  /// In zh, this message translates to:
  /// **'与前一条合并'**
  String get entryMergePrev;

  /// No description provided for @entryMergeNext.
  ///
  /// In zh, this message translates to:
  /// **'与后一条合并'**
  String get entryMergeNext;

  /// No description provided for @entrySplit.
  ///
  /// In zh, this message translates to:
  /// **'按时刻拆分'**
  String get entrySplit;

  /// No description provided for @entryExtendNow.
  ///
  /// In zh, this message translates to:
  /// **'延伸到现在'**
  String get entryExtendNow;

  /// No description provided for @entryDeleteTitle.
  ///
  /// In zh, this message translates to:
  /// **'删除这条记录？'**
  String get entryDeleteTitle;

  /// No description provided for @entryDeleteHint.
  ///
  /// In zh, this message translates to:
  /// **'删除后可通过全局撤销恢复。'**
  String get entryDeleteHint;

  /// No description provided for @tlAdd.
  ///
  /// In zh, this message translates to:
  /// **'添加条目'**
  String get tlAdd;

  /// No description provided for @tlSpanToday.
  ///
  /// In zh, this message translates to:
  /// **'今天'**
  String get tlSpanToday;

  /// No description provided for @tlSpanThree.
  ///
  /// In zh, this message translates to:
  /// **'三天'**
  String get tlSpanThree;

  /// No description provided for @tlSpanWeek.
  ///
  /// In zh, this message translates to:
  /// **'本周'**
  String get tlSpanWeek;

  /// No description provided for @tlViewEntries.
  ///
  /// In zh, this message translates to:
  /// **'条目'**
  String get tlViewEntries;

  /// No description provided for @tlViewLogs.
  ///
  /// In zh, this message translates to:
  /// **'日志'**
  String get tlViewLogs;

  /// No description provided for @tlLongest.
  ///
  /// In zh, this message translates to:
  /// **'最长连续'**
  String get tlLongest;

  /// No description provided for @tlAuto.
  ///
  /// In zh, this message translates to:
  /// **'自动'**
  String get tlAuto;

  /// No description provided for @tlMerged.
  ///
  /// In zh, this message translates to:
  /// **'已合并'**
  String get tlMerged;

  /// No description provided for @tlRunningTag.
  ///
  /// In zh, this message translates to:
  /// **'进行中'**
  String get tlRunningTag;

  /// No description provided for @tlContinueNext.
  ///
  /// In zh, this message translates to:
  /// **'延续至次日'**
  String get tlContinueNext;

  /// No description provided for @tlFutureBanner.
  ///
  /// In zh, this message translates to:
  /// **'未来日期暂无记录——这是正常状态，开始记录后这里会显示条目。'**
  String get tlFutureBanner;

  /// No description provided for @tlLegendAuto.
  ///
  /// In zh, this message translates to:
  /// **'自动'**
  String get tlLegendAuto;

  /// No description provided for @tlLegendUnassigned.
  ///
  /// In zh, this message translates to:
  /// **'未分配'**
  String get tlLegendUnassigned;

  /// No description provided for @tlLegendContinue.
  ///
  /// In zh, this message translates to:
  /// **'延续次日'**
  String get tlLegendContinue;

  /// No description provided for @tlZoom.
  ///
  /// In zh, this message translates to:
  /// **'缩放'**
  String get tlZoom;

  /// No description provided for @tlSegments.
  ///
  /// In zh, this message translates to:
  /// **'分段/日'**
  String get tlSegments;

  /// No description provided for @tlNow.
  ///
  /// In zh, this message translates to:
  /// **'现在'**
  String get tlNow;

  /// No description provided for @tlAxisTab.
  ///
  /// In zh, this message translates to:
  /// **'时间轴'**
  String get tlAxisTab;

  /// No description provided for @tlStripTab.
  ///
  /// In zh, this message translates to:
  /// **'比例条'**
  String get tlStripTab;

  /// No description provided for @tlGroupEntries.
  ///
  /// In zh, this message translates to:
  /// **'条'**
  String get tlGroupEntries;

  /// No description provided for @tlLogsEmpty.
  ///
  /// In zh, this message translates to:
  /// **'暂无操作日志'**
  String get tlLogsEmpty;

  /// No description provided for @tlEntriesCount.
  ///
  /// In zh, this message translates to:
  /// **'{n} 条记录'**
  String tlEntriesCount(Object n);

  /// No description provided for @tlSplitPickTime.
  ///
  /// In zh, this message translates to:
  /// **'选择拆分时刻'**
  String get tlSplitPickTime;

  /// No description provided for @tlNoActivity.
  ///
  /// In zh, this message translates to:
  /// **'未选择活动'**
  String get tlNoActivity;

  /// No description provided for @logSwitch.
  ///
  /// In zh, this message translates to:
  /// **'切换'**
  String get logSwitch;

  /// No description provided for @logStop.
  ///
  /// In zh, this message translates to:
  /// **'停止'**
  String get logStop;

  /// No description provided for @logEdit.
  ///
  /// In zh, this message translates to:
  /// **'编辑'**
  String get logEdit;

  /// No description provided for @logDelete.
  ///
  /// In zh, this message translates to:
  /// **'删除'**
  String get logDelete;

  /// No description provided for @logUndo.
  ///
  /// In zh, this message translates to:
  /// **'撤销'**
  String get logUndo;

  /// No description provided for @logRedo.
  ///
  /// In zh, this message translates to:
  /// **'重做'**
  String get logRedo;

  /// No description provided for @logMerge.
  ///
  /// In zh, this message translates to:
  /// **'合并'**
  String get logMerge;

  /// No description provided for @logManual.
  ///
  /// In zh, this message translates to:
  /// **'手动'**
  String get logManual;

  /// No description provided for @logSplit.
  ///
  /// In zh, this message translates to:
  /// **'拆分'**
  String get logSplit;

  /// No description provided for @logActivityDelete.
  ///
  /// In zh, this message translates to:
  /// **'删除活动'**
  String get logActivityDelete;

  /// No description provided for @logCategoryCreate.
  ///
  /// In zh, this message translates to:
  /// **'新建分类'**
  String get logCategoryCreate;

  /// No description provided for @logCategoryUpdate.
  ///
  /// In zh, this message translates to:
  /// **'更新分类'**
  String get logCategoryUpdate;

  /// No description provided for @logCategoryDelete.
  ///
  /// In zh, this message translates to:
  /// **'删除分类'**
  String get logCategoryDelete;

  /// No description provided for @logRuleUpdate.
  ///
  /// In zh, this message translates to:
  /// **'规则变更'**
  String get logRuleUpdate;

  /// No description provided for @logSync.
  ///
  /// In zh, this message translates to:
  /// **'同步'**
  String get logSync;

  /// No description provided for @stRangeToday.
  ///
  /// In zh, this message translates to:
  /// **'今天'**
  String get stRangeToday;

  /// No description provided for @stRangeYesterday.
  ///
  /// In zh, this message translates to:
  /// **'昨天'**
  String get stRangeYesterday;

  /// No description provided for @stRangeThisWeek.
  ///
  /// In zh, this message translates to:
  /// **'本周'**
  String get stRangeThisWeek;

  /// No description provided for @stRangeLastWeek.
  ///
  /// In zh, this message translates to:
  /// **'上周'**
  String get stRangeLastWeek;

  /// No description provided for @stRangeCustom.
  ///
  /// In zh, this message translates to:
  /// **'自定义'**
  String get stRangeCustom;

  /// No description provided for @stDimActivity.
  ///
  /// In zh, this message translates to:
  /// **'活动'**
  String get stDimActivity;

  /// No description provided for @stDimTree.
  ///
  /// In zh, this message translates to:
  /// **'主分类 · 树聚合'**
  String get stDimTree;

  /// No description provided for @stDimBucket.
  ///
  /// In zh, this message translates to:
  /// **'时长区间'**
  String get stDimBucket;

  /// No description provided for @stDimCross.
  ///
  /// In zh, this message translates to:
  /// **'分类 × 时长'**
  String get stDimCross;

  /// No description provided for @stFilterTitle.
  ///
  /// In zh, this message translates to:
  /// **'分类筛选'**
  String get stFilterTitle;

  /// No description provided for @stFilterAll.
  ///
  /// In zh, this message translates to:
  /// **'全选'**
  String get stFilterAll;

  /// No description provided for @stFilterNone.
  ///
  /// In zh, this message translates to:
  /// **'清空'**
  String get stFilterNone;

  /// No description provided for @stDailyChart.
  ///
  /// In zh, this message translates to:
  /// **'每日分布'**
  String get stDailyChart;

  /// No description provided for @stShareChart.
  ///
  /// In zh, this message translates to:
  /// **'占比分布'**
  String get stShareChart;

  /// No description provided for @stDailyDetail.
  ///
  /// In zh, this message translates to:
  /// **'每日明细'**
  String get stDailyDetail;

  /// No description provided for @stLegendOther.
  ///
  /// In zh, this message translates to:
  /// **'其他'**
  String get stLegendOther;

  /// No description provided for @stExcludeAuto.
  ///
  /// In zh, this message translates to:
  /// **'排除自动条目'**
  String get stExcludeAuto;

  /// No description provided for @stExcludeAutoHint.
  ///
  /// In zh, this message translates to:
  /// **'后台自动记录的条目不参与统计（明细、图表与聚合行同口径生效）'**
  String get stExcludeAutoHint;

  /// No description provided for @stAiButton.
  ///
  /// In zh, this message translates to:
  /// **'AI 总结'**
  String get stAiButton;

  /// No description provided for @stAiPhase2.
  ///
  /// In zh, this message translates to:
  /// **'二期'**
  String get stAiPhase2;

  /// No description provided for @stAiGuideTitle.
  ///
  /// In zh, this message translates to:
  /// **'AI 总结尚未配置'**
  String get stAiGuideTitle;

  /// No description provided for @stAiGuideMessage.
  ///
  /// In zh, this message translates to:
  /// **'需要先在「设置 → AI 配置」中开启并测试模型连接。你的数据仍优先保存在本地。'**
  String get stAiGuideMessage;

  /// No description provided for @stAiGoSettings.
  ///
  /// In zh, this message translates to:
  /// **'去设置'**
  String get stAiGoSettings;

  /// No description provided for @stAiNotNow.
  ///
  /// In zh, this message translates to:
  /// **'暂不'**
  String get stAiNotNow;

  /// No description provided for @stEmpty.
  ///
  /// In zh, this message translates to:
  /// **'开始记录吧'**
  String get stEmpty;

  /// No description provided for @stEmptyHint.
  ///
  /// In zh, this message translates to:
  /// **'记录几天后，这里会呈现你的时间去向'**
  String get stEmptyHint;

  /// No description provided for @stBucketShort.
  ///
  /// In zh, this message translates to:
  /// **'<30 分'**
  String get stBucketShort;

  /// No description provided for @stBucketMedium.
  ///
  /// In zh, this message translates to:
  /// **'30 分–1 时'**
  String get stBucketMedium;

  /// No description provided for @stBucketLong.
  ///
  /// In zh, this message translates to:
  /// **'1–3 时'**
  String get stBucketLong;

  /// No description provided for @stBucketXl.
  ///
  /// In zh, this message translates to:
  /// **'3 时以上'**
  String get stBucketXl;

  /// No description provided for @stCountShort.
  ///
  /// In zh, this message translates to:
  /// **'{n} 次'**
  String stCountShort(Object n);

  /// No description provided for @stPickStart.
  ///
  /// In zh, this message translates to:
  /// **'选择开始日期'**
  String get stPickStart;

  /// No description provided for @stPickEnd.
  ///
  /// In zh, this message translates to:
  /// **'选择结束日期'**
  String get stPickEnd;

  /// No description provided for @settingsSecGeneral.
  ///
  /// In zh, this message translates to:
  /// **'通用'**
  String get settingsSecGeneral;

  /// No description provided for @settingsSecGeneralSub.
  ///
  /// In zh, this message translates to:
  /// **'外观、时间显示与全局默认值'**
  String get settingsSecGeneralSub;

  /// No description provided for @settingsSecBackup.
  ///
  /// In zh, this message translates to:
  /// **'备份与导出'**
  String get settingsSecBackup;

  /// No description provided for @settingsSecBackupSub.
  ///
  /// In zh, this message translates to:
  /// **'数据迁移与新设备恢复的唯一通道'**
  String get settingsSecBackupSub;

  /// No description provided for @settingsSecReminder.
  ///
  /// In zh, this message translates to:
  /// **'提醒'**
  String get settingsSecReminder;

  /// No description provided for @settingsSecReminderSub.
  ///
  /// In zh, this message translates to:
  /// **'何时提醒、多久一次、用什么方式'**
  String get settingsSecReminderSub;

  /// No description provided for @settingsSecTimeline.
  ///
  /// In zh, this message translates to:
  /// **'时间线'**
  String get settingsSecTimeline;

  /// No description provided for @settingsSecTimelineSub.
  ///
  /// In zh, this message translates to:
  /// **'相邻条目自动合并的判定阈值'**
  String get settingsSecTimelineSub;

  /// No description provided for @settingsSecSync.
  ///
  /// In zh, this message translates to:
  /// **'云同步'**
  String get settingsSecSync;

  /// No description provided for @settingsSecSyncSub.
  ///
  /// In zh, this message translates to:
  /// **'多设备数据双向同步，本地优先、异步进行'**
  String get settingsSecSyncSub;

  /// No description provided for @settingsSecAi.
  ///
  /// In zh, this message translates to:
  /// **'AI 配置'**
  String get settingsSecAi;

  /// No description provided for @settingsSecAiSub.
  ///
  /// In zh, this message translates to:
  /// **'总结与自然语言记录（一期仅预留入口位）'**
  String get settingsSecAiSub;

  /// No description provided for @settingsAiBadge.
  ///
  /// In zh, this message translates to:
  /// **'二期'**
  String get settingsAiBadge;

  /// No description provided for @settingsSecBackground.
  ///
  /// In zh, this message translates to:
  /// **'后台记录'**
  String get settingsSecBackground;

  /// No description provided for @settingsSecBackgroundSub.
  ///
  /// In zh, this message translates to:
  /// **'按规则自动计时；自动条目带「自动」标识，可识别、可排除'**
  String get settingsSecBackgroundSub;

  /// No description provided for @settingsSecDevice.
  ///
  /// In zh, this message translates to:
  /// **'设备互通'**
  String get settingsSecDevice;

  /// No description provided for @settingsSecDeviceSub.
  ///
  /// In zh, this message translates to:
  /// **'同一局域网内的设备间同步与文件互通'**
  String get settingsSecDeviceSub;

  /// No description provided for @settingsSecUpdate.
  ///
  /// In zh, this message translates to:
  /// **'版本更新'**
  String get settingsSecUpdate;

  /// No description provided for @settingsSecUpdateSub.
  ///
  /// In zh, this message translates to:
  /// **'下载校验一致才安装 · 失败逐层降级 · 强制更新不可跳过'**
  String get settingsSecUpdateSub;

  /// No description provided for @settingsSecAbout.
  ///
  /// In zh, this message translates to:
  /// **'关于'**
  String get settingsSecAbout;

  /// No description provided for @settingsSecAboutSub.
  ///
  /// In zh, this message translates to:
  /// **'版本、开源信息与许可'**
  String get settingsSecAboutSub;

  /// No description provided for @settingsAppearance.
  ///
  /// In zh, this message translates to:
  /// **'外观'**
  String get settingsAppearance;

  /// No description provided for @settingsAppearanceHint.
  ///
  /// In zh, this message translates to:
  /// **'默认浅色，可切深色或跟随系统'**
  String get settingsAppearanceHint;

  /// No description provided for @settingsThemeLight.
  ///
  /// In zh, this message translates to:
  /// **'浅色'**
  String get settingsThemeLight;

  /// No description provided for @settingsThemeDark.
  ///
  /// In zh, this message translates to:
  /// **'深色'**
  String get settingsThemeDark;

  /// No description provided for @settingsThemeSystem.
  ///
  /// In zh, this message translates to:
  /// **'跟随系统'**
  String get settingsThemeSystem;

  /// No description provided for @settingsWeekStart.
  ///
  /// In zh, this message translates to:
  /// **'每周起始日'**
  String get settingsWeekStart;

  /// No description provided for @settingsWeekStartHint.
  ///
  /// In zh, this message translates to:
  /// **'统计页「本周」从哪天开始'**
  String get settingsWeekStartHint;

  /// No description provided for @settingsWeekMonday.
  ///
  /// In zh, this message translates to:
  /// **'周一'**
  String get settingsWeekMonday;

  /// No description provided for @settingsWeekSunday.
  ///
  /// In zh, this message translates to:
  /// **'周日'**
  String get settingsWeekSunday;

  /// No description provided for @settingsWeekSaturday.
  ///
  /// In zh, this message translates to:
  /// **'周六'**
  String get settingsWeekSaturday;

  /// No description provided for @settingsTimeFormat.
  ///
  /// In zh, this message translates to:
  /// **'时间格式'**
  String get settingsTimeFormat;

  /// No description provided for @settingsTimeFormatHint.
  ///
  /// In zh, this message translates to:
  /// **'时间线条目与计时的显示格式'**
  String get settingsTimeFormatHint;

  /// No description provided for @settingsHour12.
  ///
  /// In zh, this message translates to:
  /// **'12 小时'**
  String get settingsHour12;

  /// No description provided for @settingsHour24.
  ///
  /// In zh, this message translates to:
  /// **'24 小时'**
  String get settingsHour24;

  /// No description provided for @settingsDefaultDuration.
  ///
  /// In zh, this message translates to:
  /// **'默认记录时长'**
  String get settingsDefaultDuration;

  /// No description provided for @settingsDefaultDurationHint.
  ///
  /// In zh, this message translates to:
  /// **'「临时活动」等快捷启动的默认时长'**
  String get settingsDefaultDurationHint;

  /// No description provided for @settingsQuickReminder.
  ///
  /// In zh, this message translates to:
  /// **'快速提醒'**
  String get settingsQuickReminder;

  /// No description provided for @settingsQuickReminderHint.
  ///
  /// In zh, this message translates to:
  /// **'到触发时刻提醒开始记录（见「提醒」分区）'**
  String get settingsQuickReminderHint;

  /// No description provided for @settingsMinutesShort.
  ///
  /// In zh, this message translates to:
  /// **'{minutes} 分钟'**
  String settingsMinutesShort(int minutes);

  /// No description provided for @settingsTriggerTime.
  ///
  /// In zh, this message translates to:
  /// **'触发时刻'**
  String get settingsTriggerTime;

  /// No description provided for @settingsTriggerTimeHint.
  ///
  /// In zh, this message translates to:
  /// **'每日到设定时间后提醒开始记录'**
  String get settingsTriggerTimeHint;

  /// No description provided for @settingsDurationThreshold.
  ///
  /// In zh, this message translates to:
  /// **'持续时长阈值'**
  String get settingsDurationThreshold;

  /// No description provided for @settingsDurationThresholdHint.
  ///
  /// In zh, this message translates to:
  /// **'会话运行达到该时长后触发提醒'**
  String get settingsDurationThresholdHint;

  /// No description provided for @settingsRepeatInterval.
  ///
  /// In zh, this message translates to:
  /// **'重复间隔'**
  String get settingsRepeatInterval;

  /// No description provided for @settingsRepeatIntervalHint.
  ///
  /// In zh, this message translates to:
  /// **'提醒后每隔该时长再次提醒，直到手动结束会话'**
  String get settingsRepeatIntervalHint;

  /// No description provided for @settingsReminderMethod.
  ///
  /// In zh, this message translates to:
  /// **'提醒方式'**
  String get settingsReminderMethod;

  /// No description provided for @settingsMethodDialog.
  ///
  /// In zh, this message translates to:
  /// **'对话框'**
  String get settingsMethodDialog;

  /// No description provided for @settingsMethodDialogDesc.
  ///
  /// In zh, this message translates to:
  /// **'需决策'**
  String get settingsMethodDialogDesc;

  /// No description provided for @settingsMethodBanner.
  ///
  /// In zh, this message translates to:
  /// **'横幅'**
  String get settingsMethodBanner;

  /// No description provided for @settingsMethodBannerDesc.
  ///
  /// In zh, this message translates to:
  /// **'轻打扰'**
  String get settingsMethodBannerDesc;

  /// No description provided for @settingsMethodSilent.
  ///
  /// In zh, this message translates to:
  /// **'静音'**
  String get settingsMethodSilent;

  /// No description provided for @settingsMethodSilentDesc.
  ///
  /// In zh, this message translates to:
  /// **'不打扰'**
  String get settingsMethodSilentDesc;

  /// No description provided for @settingsMergeThreshold.
  ///
  /// In zh, this message translates to:
  /// **'相邻条目合并阈值'**
  String get settingsMergeThreshold;

  /// No description provided for @settingsMergeThresholdHint.
  ///
  /// In zh, this message translates to:
  /// **'间隔小于该阈值时自动合并'**
  String get settingsMergeThresholdHint;

  /// No description provided for @settingsUnassignedNote.
  ///
  /// In zh, this message translates to:
  /// **'系统有且仅有一个「未分配」活动。时间线上与它相邻的未分配条目，在间隔小于该阈值时会自动合并为一条连续记录，避免碎片化。'**
  String get settingsUnassignedNote;

  /// No description provided for @settingsExport.
  ///
  /// In zh, this message translates to:
  /// **'导出备份'**
  String get settingsExport;

  /// No description provided for @settingsExportHint.
  ///
  /// In zh, this message translates to:
  /// **'导出为 .timetrack.json 单个文件，包含全部时间条目、活动与设置'**
  String get settingsExportHint;

  /// No description provided for @settingsExportBtn.
  ///
  /// In zh, this message translates to:
  /// **'导出'**
  String get settingsExportBtn;

  /// No description provided for @settingsImport.
  ///
  /// In zh, this message translates to:
  /// **'导入数据'**
  String get settingsImport;

  /// No description provided for @settingsImportHint.
  ///
  /// In zh, this message translates to:
  /// **'从 .timetrack.json 恢复，导入的数据将与现有数据合并'**
  String get settingsImportHint;

  /// No description provided for @settingsImportBtn.
  ///
  /// In zh, this message translates to:
  /// **'导入'**
  String get settingsImportBtn;

  /// No description provided for @settingsDangerTitle.
  ///
  /// In zh, this message translates to:
  /// **'清除全部数据'**
  String get settingsDangerTitle;

  /// No description provided for @settingsDangerMessage.
  ///
  /// In zh, this message translates to:
  /// **'永久删除本机全部时间条目、活动与设置，且不可撤销。执行前必须先导出备份。'**
  String get settingsDangerMessage;

  /// No description provided for @settingsDangerBtn.
  ///
  /// In zh, this message translates to:
  /// **'清除全部数据'**
  String get settingsDangerBtn;

  /// No description provided for @settingsWipeDialogTitle.
  ///
  /// In zh, this message translates to:
  /// **'清除全部数据'**
  String get settingsWipeDialogTitle;

  /// No description provided for @settingsWipeDialogBody.
  ///
  /// In zh, this message translates to:
  /// **'此操作将永久删除全部时间条目、活动与设置，无法撤销。清除前请先导出备份，以免数据丢失。'**
  String get settingsWipeDialogBody;

  /// No description provided for @settingsWipeCancel.
  ///
  /// In zh, this message translates to:
  /// **'取消'**
  String get settingsWipeCancel;

  /// No description provided for @settingsWipeExportFirst.
  ///
  /// In zh, this message translates to:
  /// **'先导出备份'**
  String get settingsWipeExportFirst;

  /// No description provided for @settingsWipeConfirm.
  ///
  /// In zh, this message translates to:
  /// **'仍然清除'**
  String get settingsWipeConfirm;

  /// No description provided for @settingsWipeDone.
  ///
  /// In zh, this message translates to:
  /// **'已清除全部数据'**
  String get settingsWipeDone;

  /// No description provided for @settingsWipeFailed.
  ///
  /// In zh, this message translates to:
  /// **'清除失败'**
  String get settingsWipeFailed;

  /// No description provided for @settingsExportDone.
  ///
  /// In zh, this message translates to:
  /// **'已导出到 {path}'**
  String settingsExportDone(String path);

  /// No description provided for @settingsImportDone.
  ///
  /// In zh, this message translates to:
  /// **'已导入 {count} 条记录'**
  String settingsImportDone(int count);

  /// No description provided for @settingsOpFailed.
  ///
  /// In zh, this message translates to:
  /// **'操作失败：{message}'**
  String settingsOpFailed(String message);

  /// No description provided for @settingsSyncConfigured.
  ///
  /// In zh, this message translates to:
  /// **'已配置 Supabase'**
  String get settingsSyncConfigured;

  /// No description provided for @settingsSyncNotConfigured.
  ///
  /// In zh, this message translates to:
  /// **'未配置云服务'**
  String get settingsSyncNotConfigured;

  /// No description provided for @settingsSyncNotConfiguredHint.
  ///
  /// In zh, this message translates to:
  /// **'编译期未注入 SUPABASE_URL，应用以离线模式运行'**
  String get settingsSyncNotConfiguredHint;

  /// No description provided for @settingsSyncOnline.
  ///
  /// In zh, this message translates to:
  /// **'在线'**
  String get settingsSyncOnline;

  /// No description provided for @settingsSyncOffline.
  ///
  /// In zh, this message translates to:
  /// **'离线'**
  String get settingsSyncOffline;

  /// No description provided for @settingsSyncLoggedInAs.
  ///
  /// In zh, this message translates to:
  /// **'已登录 {email}'**
  String settingsSyncLoggedInAs(String email);

  /// No description provided for @settingsSyncNotLoggedIn.
  ///
  /// In zh, this message translates to:
  /// **'未登录'**
  String get settingsSyncNotLoggedIn;

  /// No description provided for @settingsSyncLastAt.
  ///
  /// In zh, this message translates to:
  /// **'上次同步'**
  String get settingsSyncLastAt;

  /// No description provided for @settingsSyncJustNow.
  ///
  /// In zh, this message translates to:
  /// **'刚刚'**
  String get settingsSyncJustNow;

  /// No description provided for @settingsSyncNever.
  ///
  /// In zh, this message translates to:
  /// **'从未'**
  String get settingsSyncNever;

  /// No description provided for @settingsSyncPulled.
  ///
  /// In zh, this message translates to:
  /// **'拉取 {count} 条'**
  String settingsSyncPulled(int count);

  /// No description provided for @settingsSyncPushed.
  ///
  /// In zh, this message translates to:
  /// **'推送 {count} 条'**
  String settingsSyncPushed(int count);

  /// No description provided for @settingsSyncNow.
  ///
  /// In zh, this message translates to:
  /// **'立即同步'**
  String get settingsSyncNow;

  /// No description provided for @settingsSyncSignOut.
  ///
  /// In zh, this message translates to:
  /// **'登出'**
  String get settingsSyncSignOut;

  /// No description provided for @settingsLoginTitle.
  ///
  /// In zh, this message translates to:
  /// **'登录'**
  String get settingsLoginTitle;

  /// No description provided for @settingsLoginSubtitle.
  ///
  /// In zh, this message translates to:
  /// **'输入邮箱，通过验证码登录以同步数据到云端'**
  String get settingsLoginSubtitle;

  /// No description provided for @settingsLoginEmail.
  ///
  /// In zh, this message translates to:
  /// **'邮箱'**
  String get settingsLoginEmail;

  /// No description provided for @settingsLoginSendCode.
  ///
  /// In zh, this message translates to:
  /// **'发送验证码'**
  String get settingsLoginSendCode;

  /// No description provided for @settingsLoginSending.
  ///
  /// In zh, this message translates to:
  /// **'发送中…'**
  String get settingsLoginSending;

  /// No description provided for @settingsLoginCodeSent.
  ///
  /// In zh, this message translates to:
  /// **'验证码已发送，请查收邮箱'**
  String get settingsLoginCodeSent;

  /// No description provided for @settingsLoginCode.
  ///
  /// In zh, this message translates to:
  /// **'6 位验证码'**
  String get settingsLoginCode;

  /// No description provided for @settingsLoginVerify.
  ///
  /// In zh, this message translates to:
  /// **'验证并登录'**
  String get settingsLoginVerify;

  /// No description provided for @settingsLoginVerifying.
  ///
  /// In zh, this message translates to:
  /// **'登录中…'**
  String get settingsLoginVerifying;

  /// No description provided for @settingsLoginFailed.
  ///
  /// In zh, this message translates to:
  /// **'登录失败：{message}'**
  String settingsLoginFailed(String message);

  /// No description provided for @settingsLoginCancel.
  ///
  /// In zh, this message translates to:
  /// **'取消'**
  String get settingsLoginCancel;

  /// No description provided for @settingsSignedOut.
  ///
  /// In zh, this message translates to:
  /// **'已登出'**
  String get settingsSignedOut;

  /// No description provided for @settingsSyncFailed.
  ///
  /// In zh, this message translates to:
  /// **'同步失败：{message}'**
  String settingsSyncFailed(String message);

  /// No description provided for @settingsAiPhase2Note.
  ///
  /// In zh, this message translates to:
  /// **'AI 配置将在二期开放：API 密钥（安全存储）、OpenAI 兼容端点/模型、测试连接与数据出境披露。一期统计页已预留 AI 入口引导。'**
  String get settingsAiPhase2Note;

  /// No description provided for @settingsBgWindowsTitle.
  ///
  /// In zh, this message translates to:
  /// **'Windows 版 · 后台驻留'**
  String get settingsBgWindowsTitle;

  /// No description provided for @settingsBgWindowsBody.
  ///
  /// In zh, this message translates to:
  /// **'关闭主窗口时默认最小化到系统托盘；托盘右键菜单可显示主窗口、暂停记录或退出。'**
  String get settingsBgWindowsBody;

  /// No description provided for @settingsBgDetectorState.
  ///
  /// In zh, this message translates to:
  /// **'检测状态：{state}'**
  String settingsBgDetectorState(String state);

  /// No description provided for @settingsBgDetectorRunning.
  ///
  /// In zh, this message translates to:
  /// **'运行中'**
  String get settingsBgDetectorRunning;

  /// No description provided for @settingsBgDetectorPending.
  ///
  /// In zh, this message translates to:
  /// **'待平台层接入（批次 6）'**
  String get settingsBgDetectorPending;

  /// No description provided for @settingsBgLastMatch.
  ///
  /// In zh, this message translates to:
  /// **'最近命中：{note}'**
  String settingsBgLastMatch(String note);

  /// No description provided for @settingsBgMasterSwitch.
  ///
  /// In zh, this message translates to:
  /// **'后台自动记录'**
  String get settingsBgMasterSwitch;

  /// No description provided for @settingsBgMasterHint.
  ///
  /// In zh, this message translates to:
  /// **'按规则自动计时；未匹配任何规则时不产生条目'**
  String get settingsBgMasterHint;

  /// No description provided for @settingsBgRules.
  ///
  /// In zh, this message translates to:
  /// **'规则'**
  String get settingsBgRules;

  /// No description provided for @settingsBgRulesCount.
  ///
  /// In zh, this message translates to:
  /// **'匹配模式 → 目标活动 · 共 {count} 条规则'**
  String settingsBgRulesCount(int count);

  /// No description provided for @settingsBgNewRule.
  ///
  /// In zh, this message translates to:
  /// **'新建规则'**
  String get settingsBgNewRule;

  /// No description provided for @settingsBgEmptyRules.
  ///
  /// In zh, this message translates to:
  /// **'暂无规则。新建规则后，匹配到对应进程或窗口标题时会自动开始计时。'**
  String get settingsBgEmptyRules;

  /// No description provided for @settingsBgKindProcess.
  ///
  /// In zh, this message translates to:
  /// **'进程名'**
  String get settingsBgKindProcess;

  /// No description provided for @settingsBgKindTitle.
  ///
  /// In zh, this message translates to:
  /// **'窗口标题'**
  String get settingsBgKindTitle;

  /// No description provided for @settingsBgSyncToggle.
  ///
  /// In zh, this message translates to:
  /// **'云同步'**
  String get settingsBgSyncToggle;

  /// No description provided for @settingsBgEnabledToggle.
  ///
  /// In zh, this message translates to:
  /// **'启用'**
  String get settingsBgEnabledToggle;

  /// No description provided for @settingsBgEdit.
  ///
  /// In zh, this message translates to:
  /// **'编辑规则'**
  String get settingsBgEdit;

  /// No description provided for @settingsBgDelete.
  ///
  /// In zh, this message translates to:
  /// **'删除规则'**
  String get settingsBgDelete;

  /// No description provided for @settingsBgRuleFormTitleNew.
  ///
  /// In zh, this message translates to:
  /// **'新建规则'**
  String get settingsBgRuleFormTitleNew;

  /// No description provided for @settingsBgRuleFormTitleEdit.
  ///
  /// In zh, this message translates to:
  /// **'编辑规则'**
  String get settingsBgRuleFormTitleEdit;

  /// No description provided for @settingsBgPattern.
  ///
  /// In zh, this message translates to:
  /// **'匹配模式'**
  String get settingsBgPattern;

  /// No description provided for @settingsBgPatternHint.
  ///
  /// In zh, this message translates to:
  /// **'进程名（如 code.exe）或标题模式（如 *微信*）'**
  String get settingsBgPatternHint;

  /// No description provided for @settingsBgMatchKind.
  ///
  /// In zh, this message translates to:
  /// **'匹配类型'**
  String get settingsBgMatchKind;

  /// No description provided for @settingsBgTargetActivity.
  ///
  /// In zh, this message translates to:
  /// **'目标活动'**
  String get settingsBgTargetActivity;

  /// No description provided for @settingsBgPickActivity.
  ///
  /// In zh, this message translates to:
  /// **'打开活动选择器'**
  String get settingsBgPickActivity;

  /// No description provided for @settingsBgSyncThisRule.
  ///
  /// In zh, this message translates to:
  /// **'云同步此规则'**
  String get settingsBgSyncThisRule;

  /// No description provided for @settingsBgPriorityNote.
  ///
  /// In zh, this message translates to:
  /// **'匹配优先级：精确 > 通配 > 标题。请避免过宽的匹配模式以减少误匹配。'**
  String get settingsBgPriorityNote;

  /// No description provided for @settingsBgSave.
  ///
  /// In zh, this message translates to:
  /// **'保存'**
  String get settingsBgSave;

  /// No description provided for @settingsBgCancel.
  ///
  /// In zh, this message translates to:
  /// **'取消'**
  String get settingsBgCancel;

  /// No description provided for @settingsBgRuleSaved.
  ///
  /// In zh, this message translates to:
  /// **'规则已保存'**
  String get settingsBgRuleSaved;

  /// No description provided for @settingsBgRuleDeleted.
  ///
  /// In zh, this message translates to:
  /// **'规则已删除'**
  String get settingsBgRuleDeleted;

  /// No description provided for @settingsBgFormInvalid.
  ///
  /// In zh, this message translates to:
  /// **'请填写匹配模式并选择目标活动'**
  String get settingsBgFormInvalid;

  /// No description provided for @settingsLanHost.
  ///
  /// In zh, this message translates to:
  /// **'LAN 主机'**
  String get settingsLanHost;

  /// No description provided for @settingsLanHostHint.
  ///
  /// In zh, this message translates to:
  /// **'允许局域网内其他设备经配对码连接并同步'**
  String get settingsLanHostHint;

  /// No description provided for @settingsLanStart.
  ///
  /// In zh, this message translates to:
  /// **'启动主机'**
  String get settingsLanStart;

  /// No description provided for @settingsLanStop.
  ///
  /// In zh, this message translates to:
  /// **'停止'**
  String get settingsLanStop;

  /// No description provided for @settingsLanRunning.
  ///
  /// In zh, this message translates to:
  /// **'运行中'**
  String get settingsLanRunning;

  /// No description provided for @settingsLanStopped.
  ///
  /// In zh, this message translates to:
  /// **'已停止'**
  String get settingsLanStopped;

  /// No description provided for @settingsLanPort.
  ///
  /// In zh, this message translates to:
  /// **'端口'**
  String get settingsLanPort;

  /// No description provided for @settingsLanPairingCode.
  ///
  /// In zh, this message translates to:
  /// **'配对码'**
  String get settingsLanPairingCode;

  /// No description provided for @settingsLanCodeOnce.
  ///
  /// In zh, this message translates to:
  /// **'配对码单次有效，过期或使用后需重新生成'**
  String get settingsLanCodeOnce;

  /// No description provided for @settingsLanClient.
  ///
  /// In zh, this message translates to:
  /// **'LAN 客户端'**
  String get settingsLanClient;

  /// No description provided for @settingsLanClientHint.
  ///
  /// In zh, this message translates to:
  /// **'连接其他设备开启的主机'**
  String get settingsLanClientHint;

  /// No description provided for @settingsLanHostInput.
  ///
  /// In zh, this message translates to:
  /// **'主机地址（如 192.168.1.5 或 192.168.1.5:8787）'**
  String get settingsLanHostInput;

  /// No description provided for @settingsLanCodeInput.
  ///
  /// In zh, this message translates to:
  /// **'6 位配对码'**
  String get settingsLanCodeInput;

  /// No description provided for @settingsLanPair.
  ///
  /// In zh, this message translates to:
  /// **'配对'**
  String get settingsLanPair;

  /// No description provided for @settingsLanPairedAs.
  ///
  /// In zh, this message translates to:
  /// **'已配对：{name}'**
  String settingsLanPairedAs(String name);

  /// No description provided for @settingsLanSyncNow.
  ///
  /// In zh, this message translates to:
  /// **'立即同步'**
  String get settingsLanSyncNow;

  /// No description provided for @settingsLanManualOnly.
  ///
  /// In zh, this message translates to:
  /// **'主机仅手动启动，无任何自动开启路径。'**
  String get settingsLanManualOnly;

  /// No description provided for @settingsLanFileInterop.
  ///
  /// In zh, this message translates to:
  /// **'文件互通'**
  String get settingsLanFileInterop;

  /// No description provided for @settingsLanFileInteropHint.
  ///
  /// In zh, this message translates to:
  /// **'通过 .timetrack.json 在设备间手动转移数据'**
  String get settingsLanFileInteropHint;

  /// No description provided for @settingsUpdateCurrent.
  ///
  /// In zh, this message translates to:
  /// **'当前版本'**
  String get settingsUpdateCurrent;

  /// No description provided for @settingsUpdateLatest.
  ///
  /// In zh, this message translates to:
  /// **'最新版本'**
  String get settingsUpdateLatest;

  /// No description provided for @settingsUpdateState.
  ///
  /// In zh, this message translates to:
  /// **'状态'**
  String get settingsUpdateState;

  /// No description provided for @settingsUpdateCheck.
  ///
  /// In zh, this message translates to:
  /// **'检查更新'**
  String get settingsUpdateCheck;

  /// No description provided for @settingsUpdateChecking.
  ///
  /// In zh, this message translates to:
  /// **'正在检查新版本…'**
  String get settingsUpdateChecking;

  /// No description provided for @settingsUpdateUpToDate.
  ///
  /// In zh, this message translates to:
  /// **'已是最新版本'**
  String get settingsUpdateUpToDate;

  /// No description provided for @settingsUpdateAvailable.
  ///
  /// In zh, this message translates to:
  /// **'发现新版本'**
  String get settingsUpdateAvailable;

  /// No description provided for @settingsUpdateDownload.
  ///
  /// In zh, this message translates to:
  /// **'下载更新'**
  String get settingsUpdateDownload;

  /// No description provided for @settingsUpdateDownloading.
  ///
  /// In zh, this message translates to:
  /// **'下载中…'**
  String get settingsUpdateDownloading;

  /// No description provided for @settingsUpdateVerifying.
  ///
  /// In zh, this message translates to:
  /// **'正在校验 SHA-256…'**
  String get settingsUpdateVerifying;

  /// No description provided for @settingsUpdateInstalling.
  ///
  /// In zh, this message translates to:
  /// **'正在安装更新…'**
  String get settingsUpdateInstalling;

  /// No description provided for @settingsUpdateRestartRequired.
  ///
  /// In zh, this message translates to:
  /// **'重启后生效'**
  String get settingsUpdateRestartRequired;

  /// No description provided for @settingsUpdateRestartBody.
  ///
  /// In zh, this message translates to:
  /// **'安装完成，下次启动应用时生效'**
  String get settingsUpdateRestartBody;

  /// No description provided for @settingsUpdateRestartNow.
  ///
  /// In zh, this message translates to:
  /// **'立即重启'**
  String get settingsUpdateRestartNow;

  /// No description provided for @settingsUpdateFailed.
  ///
  /// In zh, this message translates to:
  /// **'更新失败'**
  String get settingsUpdateFailed;

  /// No description provided for @settingsUpdateIgnoreVersion.
  ///
  /// In zh, this message translates to:
  /// **'忽略此版本'**
  String get settingsUpdateIgnoreVersion;

  /// No description provided for @settingsUpdateLater.
  ///
  /// In zh, this message translates to:
  /// **'稍后提醒'**
  String get settingsUpdateLater;

  /// No description provided for @settingsUpdateInstallNote.
  ///
  /// In zh, this message translates to:
  /// **'安装差异：Windows 下载校验通过后提示「重启后生效」，更新在下次启动应用时应用；Android 拉起系统安装器，未授权「安装未知应用」时引导前往系统设置开启。'**
  String get settingsUpdateInstallNote;

  /// No description provided for @settingsUpdateVerifyNote.
  ///
  /// In zh, this message translates to:
  /// **'下载完成后自动校验 SHA-256，校验一致才安装'**
  String get settingsUpdateVerifyNote;

  /// No description provided for @settingsUpdateNoArtifact.
  ///
  /// In zh, this message translates to:
  /// **'当前平台无可用更新包'**
  String get settingsUpdateNoArtifact;

  /// No description provided for @settingsUpdateIgnoredDone.
  ///
  /// In zh, this message translates to:
  /// **'已忽略此版本'**
  String get settingsUpdateIgnoredDone;

  /// No description provided for @settingsUpdateIdle.
  ///
  /// In zh, this message translates to:
  /// **'已就绪'**
  String get settingsUpdateIdle;

  /// No description provided for @settingsAboutTagline.
  ///
  /// In zh, this message translates to:
  /// **'离线优先 · 个人时间追踪'**
  String get settingsAboutTagline;

  /// No description provided for @settingsAboutVersion.
  ///
  /// In zh, this message translates to:
  /// **'当前版本'**
  String get settingsAboutVersion;

  /// No description provided for @settingsAboutOpenSource.
  ///
  /// In zh, this message translates to:
  /// **'开源信息'**
  String get settingsAboutOpenSource;

  /// No description provided for @settingsAboutOpenSourceHint.
  ///
  /// In zh, this message translates to:
  /// **'本项目基于 MIT License 开源，欢迎参与贡献'**
  String get settingsAboutOpenSourceHint;

  /// No description provided for @settingsAboutLicense.
  ///
  /// In zh, this message translates to:
  /// **'许可'**
  String get settingsAboutLicense;

  /// No description provided for @settingsAboutLicenseHint.
  ///
  /// In zh, this message translates to:
  /// **'MIT License · 含第三方依赖许可'**
  String get settingsAboutLicenseHint;

  /// No description provided for @settingsAboutCheckUpdate.
  ///
  /// In zh, this message translates to:
  /// **'检查更新'**
  String get settingsAboutCheckUpdate;

  /// No description provided for @settingsInstantHint.
  ///
  /// In zh, this message translates to:
  /// **'所有设置即时生效并自动保存，更改后相关页面即时一致。'**
  String get settingsInstantHint;

  /// No description provided for @remOngoingSubtitle.
  ///
  /// In zh, this message translates to:
  /// **'运行提醒 · 提醒方式：对话框'**
  String get remOngoingSubtitle;

  /// No description provided for @remOngoingBody.
  ///
  /// In zh, this message translates to:
  /// **'「{activity}」已记录 {elapsed}，是否仍在进行？'**
  String remOngoingBody(String activity, String elapsed);

  /// No description provided for @remQuickTitle.
  ///
  /// In zh, this message translates to:
  /// **'到开始记录的时间了'**
  String get remQuickTitle;

  /// No description provided for @remQuickBody.
  ///
  /// In zh, this message translates to:
  /// **'触发时刻提醒：现在在做什么？记一笔吧。'**
  String get remQuickBody;

  /// No description provided for @remDismiss.
  ///
  /// In zh, this message translates to:
  /// **'知道了'**
  String get remDismiss;

  /// No description provided for @bannerOngoingTitle.
  ///
  /// In zh, this message translates to:
  /// **'已连续记录 {duration}'**
  String bannerOngoingTitle(String duration);

  /// No description provided for @bannerOngoingSub.
  ///
  /// In zh, this message translates to:
  /// **'「{activity}」 · 提醒方式：横幅'**
  String bannerOngoingSub(String activity);

  /// No description provided for @suspiciousTitle.
  ///
  /// In zh, this message translates to:
  /// **'发现遗留运行条目'**
  String get suspiciousTitle;

  /// No description provided for @suspiciousSubtitle.
  ///
  /// In zh, this message translates to:
  /// **'上次退出时仍在记录'**
  String get suspiciousSubtitle;

  /// No description provided for @updateAvailableSubtle.
  ///
  /// In zh, this message translates to:
  /// **'静默检查，不打断当前操作'**
  String get updateAvailableSubtle;

  /// No description provided for @updateIgnoreAction.
  ///
  /// In zh, this message translates to:
  /// **'忽略'**
  String get updateIgnoreAction;

  /// No description provided for @forcedUpdateTitle.
  ///
  /// In zh, this message translates to:
  /// **'需要立即更新'**
  String get forcedUpdateTitle;

  /// No description provided for @forcedUpdateSubtitle.
  ///
  /// In zh, this message translates to:
  /// **'此更新不可跳过'**
  String get forcedUpdateSubtitle;

  /// No description provided for @forcedUpdateBody.
  ///
  /// In zh, this message translates to:
  /// **'当前版本 v{current} 已停止支持。必须更新到 v{version} 后才能继续使用，下载将自动开始。'**
  String forcedUpdateBody(String current, String version);

  /// No description provided for @forcedUpdateAction.
  ///
  /// In zh, this message translates to:
  /// **'立即更新'**
  String get forcedUpdateAction;
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
