/// 正式指令定义（声明式配置，单一注册点）。
library;

// 依赖说明：`CommandDefinition` 是零依赖纯类型，定义于 viewmodels/commands/
// （批准计划决策——viewmodels 为最底层纯类型层，constants/utils 均引用它，
// 不构成循环；viewmodels 自身不反向依赖 constants）。

import '../../viewmodels/commands/command_definition.dart';

/// 所有用户操作（UI 按钮/快捷键/深链/未来 AI）经 `utils/command_parser.dart`
/// 解析为 [CommandInvocation] 后由阶段 3 分发器路由——扩展新操作 =
/// 在此注册定义 + 分发器加一个处理分支，不改核心代码（计划铁律 7）。
///
/// 约束（由解析器构造期校验）：
/// - name/aliases 单 token（多词用下划线，如 `category_create`）
/// - requiredOptions/timeOptions ⊆ allowedOptions
/// - 位置参数范围合法

/// 全部指令定义。
final List<CommandDefinition> commandDefinitions = [
  // ---- 计时核心 ----
  CommandDefinition(
    name: 'switch',
    aliases: ['切换', '开始'],
    minPositionalArgs: 1,
    maxPositionalArgs: 1,
    allowedOptions: {'at'},
    timeOptions: {'at'},
    description: '切换到指定活动（可带 --at=时间）',
  ),
  CommandDefinition(
    name: 'stop',
    aliases: ['停止'],
    description: '停止当前活动',
  ),

  // ---- 时间条目编辑 ----
  CommandDefinition(
    name: 'add',
    aliases: ['补记'],
    minPositionalArgs: 1,
    maxPositionalArgs: 1,
    allowedOptions: {'start', 'end', 'note'},
    timeOptions: {'start', 'end'},
    description: '补记时间段：add 活动 --start=15:00 --end=16:00 --note=...',
  ),
  CommandDefinition(
    name: 'split',
    aliases: ['切割'],
    minPositionalArgs: 1,
    maxPositionalArgs: 1,
    allowedOptions: {'at'},
    timeOptions: {'at'},
    description: '切割时间段：split <id> --at=15:30',
  ),
  CommandDefinition(
    name: 'delete',
    aliases: ['删除条目'],
    minPositionalArgs: 1,
    maxPositionalArgs: 1,
    description: '删除时间条目：delete <id>',
  ),
  CommandDefinition(
    name: 'merge',
    aliases: ['合并'],
    minPositionalArgs: 1,
    maxPositionalArgs: 1,
    allowedOptions: {'direction'},
    // 注意：--direction 取值白名单（previous|next）由阶段 3 分发器校验——
    // 解析器只做选项键/时间值校验，不做取值枚举校验。
    description: '与相邻条目合并：merge <id> --direction=previous|next',
  ),

  // ---- 撤销/重做 ----
  CommandDefinition(
    name: 'undo',
    aliases: ['撤销'],
    description: '撤销上一步操作',
  ),
  CommandDefinition(
    name: 'redo',
    aliases: ['重做'],
    description: '重做被撤销的操作',
  ),

  // ---- 同步与互通 ----
  CommandDefinition(
    name: 'sync',
    aliases: ['同步'],
    description: '触发云同步',
  ),
  CommandDefinition(
    name: 'export',
    aliases: ['导出'],
    minPositionalArgs: 0,
    maxPositionalArgs: 1,
    allowedOptions: {'path'},
    description:
        '导出数据：export [<路径>] [--path=<路径>]（二选一；同时给出由分发器报错，优先级约定见分发器）',
  ),
  CommandDefinition(
    name: 'import',
    aliases: ['导入'],
    minPositionalArgs: 1,
    maxPositionalArgs: 1,
    description: '导入数据：import <path>',
  ),

  // ---- 更新 ----
  CommandDefinition(
    name: 'update_check',
    aliases: ['检查更新'],
    description: '检查更新',
  ),
  CommandDefinition(
    name: 'update_install',
    aliases: ['安装更新'],
    description: '下载并安装更新',
  ),

  // ---- 分类（层级） ----
  CommandDefinition(
    name: 'category_create',
    aliases: ['新建分类'],
    minPositionalArgs: 1,
    maxPositionalArgs: 1,
    allowedOptions: {'parent', 'color'},
    description: '新建分类：category_create <名称> [--parent=<id>] [--color=...]',
  ),
  CommandDefinition(
    name: 'category_update',
    aliases: ['修改分类'],
    minPositionalArgs: 1,
    maxPositionalArgs: 1,
    allowedOptions: {'name', 'color', 'parent'},
    description: '修改分类：category_update <id> [--name=...] [--color=...] [--parent=...]',
  ),
  CommandDefinition(
    name: 'category_delete',
    aliases: ['删除分类'],
    minPositionalArgs: 1,
    maxPositionalArgs: 1,
    description: '删除分类（递归软删子孙及 links）：category_delete <id>',
  ),

  // ---- 后台自动记录（模块 2c'） ----
  CommandDefinition(
    name: 'tracking_rule_create',
    aliases: ['新建映射规则'],
    minPositionalArgs: 1,
    maxPositionalArgs: 1,
    allowedOptions: {'kind', 'activity'},
    description:
        '新建映射规则：tracking_rule_create <pattern> --kind=process|title --activity=<活动名>',
  ),
  CommandDefinition(
    name: 'tracking_rule_update',
    aliases: ['修改映射规则'],
    minPositionalArgs: 1,
    maxPositionalArgs: 1,
    allowedOptions: {'kind', 'pattern', 'activity', 'sync'},
    description:
        '修改映射规则：tracking_rule_update <id> [--kind=...] [--pattern=...] [--activity=...] [--sync=true|false]',
  ),
  CommandDefinition(
    name: 'tracking_rule_delete',
    aliases: ['删除映射规则'],
    minPositionalArgs: 1,
    maxPositionalArgs: 1,
    description: '删除映射规则：tracking_rule_delete <id>',
  ),
];
