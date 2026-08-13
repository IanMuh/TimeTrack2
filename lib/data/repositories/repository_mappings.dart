import 'package:drift/drift.dart';

import '../../viewmodels/action_log.dart';
import '../../viewmodels/activity.dart';
import '../../viewmodels/activity_category.dart';
import '../../viewmodels/profile_settings.dart';
import '../../viewmodels/time_entry.dart';
import '../../viewmodels/tracking_rule.dart';
import '../database/app_database.dart'
    hide ProfileSettings; // 表类与 viewmodels 模型重名，此处用模型。

/// 仓储共享基类：Row <-> 领域模型转换（单一转换点）、统一写路径。
///
/// 时间转换约定：库内列存 UTC ISO8601 字符串（字典序=时间序），
/// Row 字段即 String；转换到领域模型时用 viewmodels 的容错读取，
/// 写入时统一 `toUtc().toIso8601String()`。
mixin RepositoryMappings {
  // ---------------------------------------------------------------------------
  // Activity
  // ---------------------------------------------------------------------------

  /// ActivityRow -> Activity（读取时间字符串容错）。
  Activity activityFromRow(ActivityRow row) {
    return Activity(
      id: row.id,
      userId: row.userId,
      name: row.name,
      color: row.color,
      isFavorite: row.isFavorite,
      updatedAt: readUtc(row.updatedAt),
      deletedAt: readNullableUtc(row.deletedAt),
      isUnassigned: row.isUnassigned,
      isOneOff: row.isOneOff,
    );
  }

  /// Activity -> 插入/更新用 companion（写入统一 UTC ISO8601）。
  ActivitiesCompanion activityToCompanion(Activity activity) {
    return ActivitiesCompanion(
      id: Value(activity.id),
      userId: Value(activity.userId),
      name: Value(activity.name),
      color: Value(activity.color),
      isFavorite: Value(activity.isFavorite),
      updatedAt: Value(utcString(activity.updatedAt)),
      deletedAt: Value(activity.deletedAt == null ? null : utcString(activity.deletedAt!)),
      isUnassigned: Value(activity.isUnassigned),
      isOneOff: Value(activity.isOneOff),
    );
  }

  // ---------------------------------------------------------------------------
  // TimeEntry
  // ---------------------------------------------------------------------------

  /// TimeEntryRow -> TimeEntry。
  TimeEntry timeEntryFromRow(TimeEntryRow row) {
    return TimeEntry(
      id: row.id,
      userId: row.userId,
      activityId: row.activityId,
      activityNameSnapshot: row.activityName,
      activityColorSnapshot: row.activityColor,
      startAt: readUtc(row.startAt),
      endAt: readNullableUtc(row.endAt),
      note: row.note,
      deviceId: row.deviceId,
      updatedAt: readUtc(row.updatedAt),
      deletedAt: readNullableUtc(row.deletedAt),
      isAuto: row.isAuto,
    );
  }

  /// TimeEntry -> companion。
  TimeEntriesCompanion timeEntryToCompanion(TimeEntry entry) {
    return TimeEntriesCompanion(
      id: Value(entry.id),
      userId: Value(entry.userId),
      activityId: Value(entry.activityId),
      activityName: Value(entry.activityNameSnapshot),
      activityColor: Value(entry.activityColorSnapshot),
      startAt: Value(utcString(entry.startAt)),
      endAt: Value(entry.endAt == null ? null : utcString(entry.endAt!)),
      note: Value(entry.note),
      deviceId: Value(entry.deviceId),
      updatedAt: Value(utcString(entry.updatedAt)),
      deletedAt: Value(entry.deletedAt == null ? null : utcString(entry.deletedAt!)),
      isAuto: Value(entry.isAuto),
    );
  }

  // ---------------------------------------------------------------------------
  // ActivityCategory / Link
  // ---------------------------------------------------------------------------

  /// ActivityCategoryRow -> ActivityCategory。
  ActivityCategory categoryFromRow(ActivityCategoryRow row) {
    return ActivityCategory(
      id: row.id,
      userId: row.userId,
      name: row.name,
      color: row.color,
      updatedAt: readUtc(row.updatedAt),
      deletedAt: readNullableUtc(row.deletedAt),
      parentId: row.parentId,
    );
  }

  /// ActivityCategory -> companion。
  ActivityCategoriesCompanion categoryToCompanion(ActivityCategory category) {
    return ActivityCategoriesCompanion(
      id: Value(category.id),
      userId: Value(category.userId),
      name: Value(category.name),
      color: Value(category.color),
      updatedAt: Value(utcString(category.updatedAt)),
      deletedAt: Value(category.deletedAt == null ? null : utcString(category.deletedAt!)),
      parentId: Value(category.parentId),
    );
  }

  /// ActivityCategoryLinkRow -> ActivityCategoryLink。
  ActivityCategoryLink linkFromRow(ActivityCategoryLinkRow row) {
    return ActivityCategoryLink(
      id: row.id,
      userId: row.userId,
      activityId: row.activityId,
      categoryId: row.categoryId,
      isPrimary: row.isPrimary,
      sortOrder: row.sortOrder,
      updatedAt: readUtc(row.updatedAt),
      deletedAt: readNullableUtc(row.deletedAt),
    );
  }

  /// ActivityCategoryLink -> companion。
  ActivityCategoryLinksCompanion linkToCompanion(ActivityCategoryLink link) {
    return ActivityCategoryLinksCompanion(
      id: Value(link.id),
      userId: Value(link.userId),
      activityId: Value(link.activityId),
      categoryId: Value(link.categoryId),
      isPrimary: Value(link.isPrimary),
      sortOrder: Value(link.sortOrder),
      updatedAt: Value(utcString(link.updatedAt)),
      deletedAt: Value(link.deletedAt == null ? null : utcString(link.deletedAt!)),
    );
  }

  // ---------------------------------------------------------------------------
  // ProfileSettings / ActionLog
  // ---------------------------------------------------------------------------

  /// ProfileSettingsRow -> ProfileSettings。
  ///
  /// 防御库内损坏数据：timezone 空白/缺失回退当前时区（模型构造函数对空白
  /// 会抛错，读取路径不因一行脏数据崩溃）；数值沿用模型钳制（构造器在
  /// release 下对越界值做兜底前，读取侧先归一）。
  ProfileSettings settingsFromRow(ProfileSettingsRow row) {
    final timezone = row.timezone.trim().isEmpty
        ? DateTime.now().timeZoneName
        : row.timezone;
    return ProfileSettings(
      userId: row.userId,
      reminderMinutes: row.reminderMinutes,
      reminderIntervalMinutes: row.reminderIntervalMinutes,
      reminderMethod: ReminderMethod.fromStorageValue(row.reminderMethod),
      reminderTimeOfDayMinutes: row.reminderTimeOfDayMinutes,
      mergeNeighborThresholdMinutes: row.mergeNeighborThresholdMinutes,
      timezone: timezone,
      updatedAt: readUtc(row.updatedAt),
    );
  }

  /// ProfileSettings -> companion（id 恒 1 单例）。
  ProfileSettingsCompanion settingsToCompanion(ProfileSettings settings) {
    return ProfileSettingsCompanion(
      id: const Value(1),
      userId: Value(settings.userId),
      reminderMinutes: Value(settings.reminderMinutes),
      reminderIntervalMinutes: Value(settings.reminderIntervalMinutes),
      reminderMethod: Value(settings.reminderMethod.storageValue),
      reminderTimeOfDayMinutes: Value(settings.reminderTimeOfDayMinutes),
      mergeNeighborThresholdMinutes: Value(settings.mergeNeighborThresholdMinutes),
      timezone: Value(settings.timezone),
      updatedAt: Value(utcString(settings.updatedAt)),
    );
  }

  /// ActionLogRow -> ActionLog。
  ActionLog actionLogFromRow(ActionLogRow row) {
    return ActionLog(
      id: row.id,
      userId: row.userId,
      actionType: ActionType.fromStorageValue(row.actionType),
      activityId: row.activityId,
      entryId: row.entryId,
      message: row.message,
      occurredAt: readUtc(row.occurredAt),
      deviceId: row.deviceId,
      updatedAt: readUtc(row.updatedAt),
      deletedAt: readNullableUtc(row.deletedAt),
    );
  }

  /// ActionLog -> companion。
  ActionLogsCompanion actionLogToCompanion(ActionLog log) {
    return ActionLogsCompanion(
      id: Value(log.id),
      userId: Value(log.userId),
      actionType: Value(log.actionType.storageValue),
      activityId: Value(log.activityId),
      entryId: Value(log.entryId),
      message: Value(log.message),
      occurredAt: Value(utcString(log.occurredAt)),
      deviceId: Value(log.deviceId),
      updatedAt: Value(utcString(log.updatedAt)),
      deletedAt: Value(log.deletedAt == null ? null : utcString(log.deletedAt!)),
    );
  }

  // ---------------------------------------------------------------------------
  // TrackingRule
  // ---------------------------------------------------------------------------

  /// TrackingRuleRow -> TrackingRule。
  TrackingRule trackingRuleFromRow(TrackingRuleRow row) {
    return TrackingRule(
      id: row.id,
      userId: row.userId,
      pattern: row.pattern,
      matchKind: TrackingRuleMatchKind.fromStorageValue(row.matchKind),
      activityId: row.activityId,
      syncEnabled: row.syncEnabled,
      updatedAt: readUtc(row.updatedAt),
      deletedAt: readNullableUtc(row.deletedAt),
    );
  }

  /// TrackingRule -> companion。
  TrackingRulesCompanion trackingRuleToCompanion(TrackingRule rule) {
    return TrackingRulesCompanion(
      id: Value(rule.id),
      userId: Value(rule.userId),
      pattern: Value(rule.pattern),
      matchKind: Value(rule.matchKind.storageValue),
      activityId: Value(rule.activityId),
      syncEnabled: Value(rule.syncEnabled),
      updatedAt: Value(utcString(rule.updatedAt)),
      deletedAt: Value(rule.deletedAt == null ? null : utcString(rule.deletedAt!)),
    );
  }

  // ---------------------------------------------------------------------------
  // 时间工具
  // ---------------------------------------------------------------------------

  /// 解析库内 UTC ISO8601 字符串为本地 DateTime（返回本地时刻）。
  ///
  /// 严格校验携带时区偏移（`parsed.isUtc`）：无偏移字符串（如
  /// `2026-08-10T04:00:00`）会被 Dart 按本地时间解释，`toLocal()` 原样返回后
  /// 再经 `utcString` 写回会漂移一个时区差，破坏"字典序=时间序"的跨日拆分/
  /// 重叠裁剪/LWW 比较——库内混入无偏移值视为数据损坏直接抛错。
  DateTime readUtc(String value) {
    final parsed = DateTime.tryParse(value);
    if (parsed == null || !parsed.isUtc) {
      throw FormatException('库内时间字段非法（应为带偏移的 UTC ISO8601）：$value');
    }
    return parsed.toLocal();
  }

  /// 解析可空 UTC ISO8601 字符串；null/空白返回 null（与 [readUtc] 同校验）。
  DateTime? readNullableUtc(String? value) {
    if (value == null || value.trim().isEmpty) return null;
    final parsed = DateTime.tryParse(value.trim());
    if (parsed == null || !parsed.isUtc) {
      throw FormatException('库内时间字段非法（应为带偏移的 UTC ISO8601）：$value');
    }
    return parsed.toLocal();
  }

  /// DateTime -> UTC ISO8601 字符串（写入统一格式，**固定 6 位微秒**）。
  ///
  /// 关键不变式："字典序 = 时间序"。Dart 的 `toIso8601String` 小数位宽度不固定
  /// （微秒为 0 时输出 3 位毫秒或省略，非 0 时输出 6 位），混存时 `'Z'(0x5A)`
  /// 会排在 `'.'`(0x2E) 之前导致字典序反转——跨日拆分/重叠裁剪/LWW 的 SQL
  /// 字符串比较都会错。统一补到 6 位微秒（`UTC 偏移恒为 Z`）保证字典序恒等于时间序。
  String utcString(DateTime value) {
    final utc = value.toUtc();
    final iso = utc.toIso8601String(); // 恒形如 ...T00:00:00.123Z / .123456Z / .000Z
    // 小数部分补到 6 位微秒：3 位（毫秒/整秒）补 3 个零，6 位原样。
    // 注：raw string 中 `$` 原样传给正则 = 结束锚点；写 `\$` 反而匹配字面 $（恒不命中）。
    final match = RegExp(r'\.(\d{3})(\d{3})?Z$').firstMatch(iso);
    if (match == null) return iso; // 理论不可达（Dart 恒输出毫秒段）
    final micros = match.group(1)! + (match.group(2) ?? '000');
    return iso.replaceRange(match.start, match.end, '.${micros}Z');
  }
}


