/// 指令分发器（模块 3d①，铁律 7 统一通道落位）：UI/快捷键/深链/AI 收敛
/// 到同一分发入口——`[CommandInvocation]` → 各 store 既有写路径。
///
/// 设计：
/// - **路由表**：按指令名分发到各 store handler（扩展新操作 = 注册指令 +
///   加一个分支，不改核心）；
/// - **领域映射**：解析器产出文本 args/options——`switch 学习` 的 args 是
///   活动名，须经 [ActivityRepository] 查名→id（重名歧义返回明确失败）；
///   时间类选项已被 parser 归一化为 `HH:MM`，此处还原为今日该时刻；
/// - **统一返回 [CommandResult]**（Success/Failure 带明确原因）；未知指令名
///   返回"未注册指令"失败（铁律 7 扩展点）。
library;

import 'package:uuid/uuid.dart';

import '../data/database/app_database.dart' hide ProfileSettings;
import '../data/interop/file_interop_service.dart';
import '../data/repositories/activity_repository.dart';
import '../viewmodels/activity.dart';
import '../utils/result.dart';
import '../viewmodels/commands/command_invocation.dart';
import '../viewmodels/tracking_rule.dart';
import 'category_store.dart';
import 'command_contracts.dart';
import 'timer_store.dart';
import 'tracking_store.dart';
import 'undo_store.dart';

/// 指令分发器。
class CommandDispatcher {
  CommandDispatcher({
    required this.undo,
    required this.timer,
    required this.sync,
    required this.update,
    required this.category,
    required this.tracking,
    required this.activities,
    required this.fileInterop,
    required this.database,
  });

  final UndoStore undo;
  final TimerStore timer;
  final SyncNowProvider sync;
  final UpdateActions update;
  final CategoryStore category;
  final TrackingStore tracking;
  final ActivityRepository activities;
  final FileInteropService fileInterop;
  final AppDatabase database;

  /// 分发一条指令到对应 store 写路径；统一返回 [CommandResult]。
  ///
  /// 任何 handler 契约外异常被收敛为失败（不逃逸）；时间类选项（parser 已
  /// 归一化为 HH:MM）还原为今日该时刻。
  Future<CommandResult> dispatch(CommandInvocation invocation) async {
    try {
      return await _route(invocation);
    } catch (e) {
      // 契约外异常收敛（防 AI/深链等调用方被未处理异步异常打断）。
      return CommandFailure('指令执行异常：${e.runtimeType}');
    }
  }

  Future<CommandResult> _route(CommandInvocation invocation) async {
    switch (invocation.name) {
      // ---- 计时核心 ----
      case 'switch':
        final activityId = await _resolveActivityId(invocation.args.first);
        if (activityId == null) {
          return CommandFailure(_lastIdError ?? '活动名解析失败');
        }
        final result = await timer.switchToActivity(activityId);
        return _fromAppResult(result, successMessage: '已切换到活动');
      case 'stop':
        final result = await timer.stopRunning();
        return _fromAppResult(result, successMessage: '已停止当前活动');
      case 'add':
        final addActivityId = await _resolveActivityId(invocation.args.first);
        if (addActivityId == null) {
          return CommandFailure(_lastIdError ?? '活动名解析失败');
        }
        final start = _todayAt(invocation.options['start']);
        final end = _todayAt(invocation.options['end']);
        if (start == null || end == null) {
          return const CommandFailure('补记需要 --start 与 --end（HH:MM）');
        }
        final result = await timer.addEntry(
          activityId: addActivityId,
          startAt: start,
          endAt: end,
          note: invocation.options['note'] ?? '',
        );
        return _fromAppResult(result, successMessage: '已补记时间段');
      case 'split':
        final at = _todayAt(invocation.options['at']);
        if (at == null) return const CommandFailure('切割需要 --at（HH:MM）');
        final result = await timer.splitEntry(
          entryId: invocation.args.first,
          splitAt: at,
        );
        return _fromAppResult(result, successMessage: '已切割时间段');
      case 'merge':
        final direction = invocation.options['direction'];
        if (direction != 'previous' && direction != 'next') {
          return const CommandFailure('合并需要 --direction=previous|next');
        }
        final result = await timer.mergeWithNeighbor(
          entryId: invocation.args.first,
          mergePrevious: direction == 'previous',
        );
        return _fromAppResult(result, successMessage: '已合并时间段');
      case 'delete':
        final result = await timer.deleteEntry(invocation.args.first);
        return _fromAppResult(result, successMessage: '已删除时间段');

      // ---- 撤销/重做 ----
      case 'undo':
        final result = await undo.undo();
        return _fromAppResult(result, successMessage: '已撤销');
      case 'redo':
        final result = await undo.redo();
        return _fromAppResult(result, successMessage: '已重做');

      // ---- 同步与互通 ----
      case 'sync':
        final result = await sync.syncNow();
        return _fromAppResult(result, successMessage: '同步完成');
      case 'export':
        final deviceId = await _deviceId();
        if (deviceId == null) return const CommandFailure('读取设备标识失败');
        final path = invocation.options['path'] ??
            (invocation.args.isEmpty ? null : invocation.args.first);
        final result = await fileInterop.export(
          sourceDeviceId: deviceId,
          path: path,
        );
        return _fromAppResult(result, successMessage: '导出完成');
      case 'import':
        final path = invocation.options['path'] ??
            (invocation.args.isEmpty ? null : invocation.args.first);
        if (path == null) {
          return const CommandFailure('导入需要 <路径> 或 --path=<路径>');
        }
        final result = await fileInterop.import(path: path);
        return _fromAppResult(result, successMessage: '导入完成');

      // ---- 更新 ----
      case 'update_check':
        final result = await update.check();
        return _fromAppResult(result, successMessage: '更新检查完成');
      case 'update_install':
        final result = await update.install();
        return _fromAppResult(result, successMessage: '更新安装完成');

      // ---- 分类 ----
      case 'category_create':
        final parent = invocation.options['parent'];
        final color = int.tryParse(invocation.options['color'] ?? '');
        final result = await category.createCategory(
          name: invocation.args.first,
          color: color ?? 0xff0f766e,
          parentId: parent,
        );
        return _fromAppResult(result, successMessage: '已新建分类');
      case 'category_delete':
        final result = await category.deleteCategory(invocation.args.first);
        return _fromAppResult(result, successMessage: '已删除分类');

      // ---- 后台自动记录 ----
      case 'tracking_rule_create':
        final activityName = invocation.options['activity'];
        if (activityName == null) {
          return const CommandFailure('新建映射规则需要 --activity=<活动名>');
        }
        final ruleActivityId = await _resolveActivityId(activityName);
        if (ruleActivityId == null) {
          return CommandFailure(_lastIdError ?? '活动名解析失败');
        }
        final rule = TrackingRule(
          id: const Uuid().v4(),
          pattern: invocation.args.first,
          matchKind: _matchKind(invocation.options['kind']),
          activityId: ruleActivityId,
          updatedAt: DateTime.now(),
        );
        final result = await tracking.saveRule(rule);
        return _fromAppResult(result, successMessage: '已新建映射规则');
      case 'tracking_rule_delete':
        final rule = await tracking.rules.ruleById(invocation.args.first);
        if (rule == null) return const CommandFailure('映射规则不存在');
        final result = await tracking.deleteRule(rule);
        return _fromAppResult(result, successMessage: '已删除映射规则');

      default:
        return CommandFailure('未注册指令：${invocation.name}');
    }
  }

  // ---------------------------------------------------------------------------
  // 内部
  // ---------------------------------------------------------------------------

  /// 最近一次活动名解析失败原因（[dispatch] 内判空时读取）。
  String? _lastIdError;

  /// 解析活动名→id（全量未删活动按名精确匹配；重名歧义/不存在明确失败，
  /// 失败原因写 [_lastIdError] 并返回 null）。
  Future<String?> _resolveActivityId(String name) async {
    final trimmed = name.trim();
    if (trimmed.isEmpty) {
      _lastIdError = '活动名不能为空';
      return null;
    }
    final result = await activities.activities();
    if (result case AppFailure<List<Activity>> failure) {
      _lastIdError = failure.message;
      return null;
    }
    final matches = result.requireValue().where((a) => a.name == trimmed);
    final list = matches.toList();
    if (list.isEmpty) {
      _lastIdError = '活动不存在：$name';
      return null;
    }
    if (list.length > 1) {
      _lastIdError = '活动名重名歧义（${list.length} 个）';
      return null;
    }
    return list.first.id;
  }

  /// `HH:MM`（parser 已归一化）→ 今日该时刻；null = 缺失/非法。
  DateTime? _todayAt(String? hhmm) {
    if (hhmm == null) return null;
    final parts = hhmm.split(':');
    if (parts.length != 2) return null;
    final hour = int.tryParse(parts[0]);
    final minute = int.tryParse(parts[1]);
    if (hour == null || minute == null || hour < 0 || hour > 23 ||
        minute < 0 || minute > 59) {
      return null;
    }
    final now = DateTime.now();
    return DateTime(now.year, now.month, now.day, hour, minute);
  }

  TrackingRuleMatchKind _matchKind(String? value) {
    return switch (value) {
      'title' => TrackingRuleMatchKind.title,
      _ => TrackingRuleMatchKind.process,
    };
  }

  /// 读取设备标识（app_metadata `device_id` 键；缺失时生成并持久化——
  /// 与 TimeEntryRepository 语义一致）。
  Future<String?> _deviceId() async {
    final row = await (database.select(database.appMetadata)
          ..where((t) => t.key.equals('device_id')))
        .getSingleOrNull();
    if (row != null) return row.value;
    final id = const Uuid().v4();
    await (database.into(database.appMetadata).insert(
      AppMetadataCompanion.insert(key: 'device_id', value: id),
    ));
    return id;
  }

  /// 通用 AppResult → CommandResult（成功带 message，失败带原因）。
  CommandResult _fromAppResult(
    AppResult<dynamic> result, {
    required String successMessage,
  }) {
    return result.fold(
      onSuccess: (_) => CommandSuccess(message: successMessage),
      onFailure: (f) => CommandFailure(f.message),
    );
  }
}
