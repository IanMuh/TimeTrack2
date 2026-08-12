import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:timetrack2/api/supabase/remote_tables.dart';

/// 内存版远程表（mock 网关）：按表存 `id → row`，模拟分页/since 过滤/排序。
///
/// 说明：行按 id 全局存储（未按 userId 二级隔离）——跨用户隔离由真网关的
/// `eq('user_id', ...)` 过滤 + 云端 RLS 保证，引擎单用户测试不依赖该维度；
/// 若需验证跨用户场景，请扩展为 `tables[table][userId][id]` 结构。
///
/// 所有入/出数据做**递归深拷贝**（json round-trip）：行内嵌套 List/Map 字段
/// 不与调用方共享引用——测试修改嵌套值不会无提示污染 mock 内部状态
/// （与真网关"JSON 反序列化独立副本"语义一致，防绕过写路径）。
class MemoryRemote implements RemoteTableGateway {
  final Map<String, Map<String, Map<String, Object?>>> tables = {};

  /// 默认分页大小：引用接口单一事实来源 [RemoteTableGateway.defaultPageSize]
  ///（与真网关上限一致）——防 mock 默认值偏离生产导致省略 pageSize 的测试
  /// 行为失真、防跨文件字面量漂移。
  static const defaultPageSize = RemoteTableGateway.defaultPageSize;

  /// 调用日志：`pull:<table>` / `push:<table>` / `updated_at:<table>`。
  final List<String> callLog = <String>[];

  /// 拉取调用明细（表 / since / page），供分页与增量语义断言。
  final List<({String table, DateTime? since, int page})> pullLog = [];

  /// 抛出异常（模拟网络故障）：设非 null 时下次调用抛该异常。
  Object? nextError;

  /// 是否放行缺失 user_id 的无主行（**默认 false = 严格模式**，与真网关一致：
  /// PostgREST `eq('user_id', userId)` 对 NULL 永不匹配，无主行对所有用户
  /// 不可见、也不可被 upsert 覆盖——防"漏注入 user_id / 无主行泄漏"类缺陷
  /// 在测试中通过、到生产才暴露）。
  ///
  /// 宽松模式（true）仅用于显式模拟"远端遗留无归属行"的历史数据场景，
  /// 须在构造后显式开启。
  bool allowUnownedRows = false;

  /// 严格模式默认归属用户（**单一事实来源**）：seed 未显式带 user_id 的行
  /// 注入该值，使远端行默认归属被拉取用户（引擎单用户测试约定用户；
  /// CloudHarness.userId 引用此常量，防两处魔数漂移）。
  /// 仅注入**合法非空**值——独立字面量，不经过 SyncStatusStore 的 userId
  /// 校验（那是存储层对调用方 bug 的判定，此处是测试 fixture 自身语义）。
  static const defaultSeedUserId = 'user-1';

  /// 递归深拷贝（json round-trip）：行内嵌套 List/Map 不与调用方共享引用，
  /// 防测试改嵌套值无提示污染 mock 内部状态（与真网关 JSON 反序列化
  /// 独立副本语义一致，防绕过写路径）。行内容必须 JSON 可序列化——DateTime/
  /// Duration/自定义对象（无 toJson）在此抛 **FormatException**（与行校验的
  /// ArgumentError 天然区分：测试据此分辨"行校验先失败"与"深拷贝 fail-fast"，
  /// 不依赖错误文案）。**边界说明（r34 修正）**：Map 键中**仅 int 键**被
  /// jsonEncode 静默字符串化；double/bool/null/对象键会抛
  /// JsonUnsupportedObjectError（转入 FormatException）；带 `toJson()` 的对象
  /// 值被静默序列化为普通 Map——测试行数据应只用 JSON 原生类型，嵌套自定义
  /// 对象/非 int 字符串键属测试数据反模式。
  static Map<String, Object?> _deepCopy(Map<String, Object?> row) {
    try {
      return jsonDecode(jsonEncode(row)) as Map<String, Object?>;
    } on JsonUnsupportedObjectError catch (e, st) {
      // 仅收窄到"JSON 不可序列化"：JsonUnsupportedObjectError 覆盖 DateTime/
      // Duration/无 toJson 对象与**循环引用**（JsonCyclicError 是其子类——
      // 已实测确认）——保留原始堆栈（Error.throwWithStackTrace）：值内嵌
      // 对象的 toString 等编程错误（抛 TypeError）不被误判为序列化失败、
      // 掩盖真实根因。
      Error.throwWithStackTrace(
        FormatException(
          '行内容必须 JSON 可序列化（嵌套值含 DateTime/Duration/自定义对象/'
          '循环引用等不可序列化值会在此失败）：$row（原因：$e）',
        ),
        st,
      );
    }
  }

  /// 是否配置表：无 id 列、以 user_id 作主键——行身份判定/错误文案/无主行
  /// 拒绝在 seed、_validateRowBasics、injectUnownedRow、upsertRows 多处复用
  /// 本判定。
  /// **镜像说明（r36，r50 修正措辞）**：字面量 `'profile_settings'` 是对
  /// `RemoteTables.profileSettings`（cloud_sync_engine.dart 的单一事实来源）
  /// 的**有意镜像**——mock 位于测试层，按依赖方向不反向引生产引擎常量
  ///（引擎常量在 cloud_sync_engine 包，本 mock 只 import 纯接口
  /// remote_tables.dart；引引擎常量需新增跨包依赖、非循环依赖问题）。表名
  /// 变更时须与本判定同步（同 `_isSettingsTable` 内部判定点唯一）。
  static bool _isSettingsTable(String table) => table == 'profile_settings';

  /// 行身份键（r53）：常规表取 `id`、profile_settings 取 `user_id`（无 id 列）——
  /// 缺失/非 String 抛带行内容的 FormatException（防直接注入 tables 的畸形行
  /// 在排序路径抛裸 TypeError，与本 mock fail-fast 风格一致）。
  static String _identityKey(Map<String, Object?> row) {
    final key = row['id'] ?? row['user_id'];
    if (key is! String) {
      throw FormatException('行身份键缺失或非 String（行内容：$row）');
    }
    return key;
  }

  /// 公共行校验（seed / seedUnowned 共用，单一事实来源防两处漂移）：
  /// - `updated_at` 必须为可解析字符串（LWW 关键字段）；
  /// - 行身份非空（[id]：常规表 id；profile_settings 无 id 列则按 user_id）。
  /// 文案不绑定具体入口（seed/seedUnowned 共用，报错指出缺失项即可）。
  static void _validateRowBasics(
    String table,
    Map<String, Object?> row,
    String? id,
  ) {
    if (row['updated_at'] is! String ||
        DateTime.tryParse(row['updated_at']! as String) == null) {
      throw ArgumentError('行必须携带可解析的 updated_at（行内容：$row）');
    }
    if (id == null) {
      throw ArgumentError(
        '$table 行必须携带 ${_isSettingsTable(table) ? 'user_id' : 'id'}'
        '（行内容：$row）',
      );
    }
  }

  void seed(String table, Map<String, Object?> row) {
    // **user_id 类型校验（r29，r30 前置到身份解析之前）**：非 null 但非
    // String 的 user_id（如 int）若静默入库，fetchRowsSince 的
    // `rowUser != userId`（String）恒成立 → 行对所有用户不可见（seed 成功但
    // 拉不回来）——fail-fast 显式拒绝（带行内容；**须先于身份解析**，否则
    // profile_settings 路径的 `as String?` 强转会先抛无上下文的裸 TypeError）。
    final rawUser = row['user_id'];
    if (rawUser != null && rawUser is! String) {
      throw ArgumentError('user_id 必须为 String 或 null（行内容：$row）');
    }
    // **空串/纯空白 user_id 拒绝（r48）**：`''` 是 String，会通过上方类型
    // 校验却成为"seed 成功但永远拉不回来"的幽灵行（fetchRowsSince 的
    // `rowUser != userId` 值比较对任何真实 userId 恒成立、对 null 语义也不
    // 匹配）——与 fail-fast 意图（防静默构造不可见行）一致地显式拒绝。
    if (rawUser is String && rawUser.trim().isEmpty) {
      throw ArgumentError('user_id 不能为空串/纯空白（行内容：$row）');
    }
    // 行身份：常规表必须携带 id（**缺 id 直接拒绝**——若回退到 user_id 作
    // 键，同一 user_id 下多行互相覆盖、数据静默丢失，与 mock fail-fast 哲学
    // 不符）；profile_settings 无 id 键，以 user_id 作主键（允许无 id）。
    // 类型说明：`as String?` 强转在判空之前——非 String 行身份（如数字 id）
    // 抛原生 TypeError（fail-fast，测试数据反模式显式暴露）；空值由
    // _validateRowBasics 校验（null 拒绝）。
    final isSettings = _isSettingsTable(table);
    final id = isSettings ? (rawUser) as String? : (row['id']) as String?;
    _validateRowBasics(table, row, id);
    // **严格模式归属补填**：行无 user_id（含显式置 null）时注入
    // [defaultSeedUserId]——引擎单用户测试的远端行默认归属被拉取用户（真网关
    // 远端行必带 user_id；注入使 seed 语义与生产一致，且默认严格过滤下测试
    // 直接通过）。显式带非 null user_id 的行原样保留（跨用户隔离用例依赖）。
    // **注意**：若测试以非 [defaultSeedUserId] 的身份调用 syncNow，seed 行
    // 必须显式携带该身份的 user_id，否则默认归属不匹配会被过滤；**真正的
    // 无主行（user_id 为 null）请用 [seedUnowned]**（seed 恒注入默认归属，
    // 无法构造无主行）。
    // **边界**：既无 id 又无 user_id 的行（profile_settings 单例按 user_id
    // 作主键）在此抛错（行身份缺失）——与真网关该表无 id 列的行为一致。
    final owned = rawUser == null
        ? {...row, 'user_id': defaultSeedUserId}
        : row;
    // **失败无副作用（r42）**：先计算深拷贝副本再写入——`a[i] = b` 先求值
    // 左侧接收器（putIfAbsent 插入空表）再求值右侧（_deepCopy 可能抛）；
    // 副本先行保证不可序列化行抛错时 mock 状态零变化（与 upsertRows 的
    // "先全量校验再写"原子性语义一致）。
    final copy = _deepCopy(owned);
    tables.putIfAbsent(table, () => {})[id as String] = copy;
  }

  /// 构造**真正的无主行**（user_id 为 null，不注入默认归属）：仅配合
  /// [allowUnownedRows] = true 宽松模式使用（模拟远端遗留无归属行的历史数据
  /// 场景，供宽松模式的可见/认领语义测试）。
  ///
  /// **不能走 [seed]**：seed 对 `user_id == null` 的行会注入 [defaultSeedUserId]
  ///（严格模式默认归属）——这里显式绕过注入逻辑，直接以 null 归属落行。
  /// **运行时保护**：默认严格模式（[allowUnownedRows] = false）下无主行对
  /// 所有用户不可见（与真网关 eq 对 NULL 永不匹配一致），调用本方法是无
  /// 效数据——显式抛错提示先开启宽松模式（防静默造出永不生效的测试数据）。
  void seedUnowned(String table, Map<String, Object?> row) {
    if (!allowUnownedRows) {
      throw StateError(
        'seedUnowned 需先设置 allowUnownedRows = true（严格模式下无主行'
        '对所有用户不可见，构造它没有意义）',
      );
    }
    injectUnownedRow(table, row);
  }

  /// 严格模式下的无主行显式注入（测试专用）：与 [seedUnowned] 走**同一
  /// 数据构造路径**（复用 [_validateRowBasics] 行校验 + [_deepCopy] 深拷贝），
  /// 但**不要求** [allowUnownedRows] = true。
  ///
  /// **实际用途（r25 修正）**：用于**严格模式下端到端验证无主行被网关过滤**
  /// ——默认严格模式（allowUnownedRows=false）下 [fetchRowsSince] 在 mock
  /// 网关层就过滤掉 user_id==null 的行，因此注入的无主行**不会抵达引擎**
  ///（该用例断言"无主行不被拉回本地"）。**注意**：本方法**无法**模拟
  /// "网关漏过滤、无主行抵达引擎"的场景（mock 网关层恒过滤，需自定义
  /// 不过滤的网关实现才能构造该场景）——按此文档构造"网关泄漏"测试会
  /// 得到空断言/无法解释的失败。
  void injectUnownedRow(String table, Map<String, Object?> row) {
    if (row['user_id'] != null) {
      throw ArgumentError('无主行不应携带 user_id（行内容：$row）');
    }
    // profile_settings 无 id 列、无主行 user_id 必为 null → 该表**无任何身份
    // 键**可定位无主行（永远不可见）——给出专用错误（通用文案会让测试作者
    // 误去补 user_id，而补了又触发上面的报错）。
    if (_isSettingsTable(table)) {
      throw ArgumentError(
        'profile_settings 无 id 列且无主行 user_id 必须为 null——该表无法'
        '承载无主行（无身份键，永不可见），请改用有 id 列的表（行内容：$row）',
      );
    }
    // 无主行恒无 user_id（否则就是有主行）→ 行身份只可能是 id；"seed 用
    // id??user_id 双身份"的规则不适用（user_id 必 null），故此处仅校验 id。
    _validateRowBasics(table, row, row['id'] as String?);
    final id = row['id'];
    // **显式 `user_id: null`（r37）**：与真网关 PostgREST select 恒返回该列
    //（值为 null）的行形态一致——防后续出现 containsKey('user_id') 依赖时
    // mock（缺键）与真网关（null 键）静默分叉。
    final owned = {...row, 'user_id': null};
    // 失败无副作用（与 seed 一致）：副本先行，不可序列化行抛错时零状态变化。
    final copy = _deepCopy(owned);
    tables.putIfAbsent(table, () => {})[id as String] = copy;
  }

  /// 记录在远端存在但未在本地 mock 中的行（fetchRemoteUpdatedAt 用）。
  /// [idKey] 与 fetchRemoteUpdatedAt 的 idKey 对齐（profile_settings 用 user_id）；
  /// [userId] **必填**（与真网关 eq('user_id') 一致——无主行会被任意用户
  /// 看到，掩盖跨用户数据泄漏类缺陷）。
  void seedRemoteOnly(String table, String id, DateTime updatedAt,
      {String idKey = 'id', required String userId}) {
    tables.putIfAbsent(table, () => {})[id] = {
      idKey: id,
      'user_id': userId,
      'updated_at': updatedAt.toUtc().toIso8601String(),
    };
  }

  /// 注入条件失败：设非 null 时，**指定调用序号**（从 0 计）的网关调用抛该异常
  /// （模拟"拉取中途/推送阶段失败"；序号按 callLog 计数）。
  Object? failOnCallIndex;
  int _callCount = 0;

  /// 重置调用计数 + 清除失败钩子（防残留钩子在下个测试误触发）。
  void resetCallCount() {
    _callCount = 0;
    failOnCallIndex = null;
    failOnCall = null;
    nextError = null;
  }

  @override
  Future<RemoteRowsPage> fetchRowsSince({
    required String table,
    required String userId,
    DateTime? since,
    int pageSize = defaultPageSize, // 与接口默认值/真网关上限一致（防 mock 默认值偏离）
    int page = 0,
  }) async {
    // 与真网关对齐：非法 pageSize 显式抛错（而非 assert——release 下剥离）。
    if (pageSize < 1) {
      throw ArgumentError.value(pageSize, 'pageSize', '必须为正数');
    }
    if (pageSize > 999) {
      // 与真网关上限（_remoteMaxPageSize=999）对齐——mock 放行 1000 会让测试
      // 通过而生产抛 ArgumentError（假阳性）。
      throw ArgumentError.value(pageSize, 'pageSize', '不能超过 999');
    }
    if (page < 0) {
      throw ArgumentError.value(page, 'page', '不能为负数');
    }
    callLog.add('pull:$table');
    pullLog.add((table: table, since: since, page: page));
    _maybeThrow('pull:$table#$page');
    final rows = (tables[table]?.values ?? const <Map<String, Object?>>[])
        .where((row) {
      // 行内容校验（防直接注入 tables 绕过 seed/upsertRows 校验）：缺
      // updated_at 或不可解析时抛明确错误（与真网关 fail-stop 风格对齐）。
      final rawAt = row['updated_at'];
      if (rawAt is! String || DateTime.tryParse(rawAt) == null) {
        throw FormatException('[$table] 行缺少可解析的 updated_at：$row');
      }
      // 与真网关 .eq('user_id', userId) 严格过滤一致：按值判定归属
      //（toMap 恒含 user_id 键但值可能为 null=无主；null 视为无主行按
      // allowUnownedRows 开关；非 null 他人值排除——防跨用户泄漏）。
      final rowUser = row['user_id'];
      if (rowUser != null && rowUser != userId) return false;
      if (rowUser == null && !allowUnownedRows) return false;
      final updatedAt = DateTime.parse(rawAt);
      if (since == null) return true;
      return !updatedAt.isBefore(since);
    }).toList()
      ..sort((a, b) {
        // 按 instant 比较（防混入不同时区格式时字典序失真）；
        // 次级唯一键（与真网关 order('updated_at').order(tieBreakKey) 一致）。
        final aAt = DateTime.parse(a['updated_at']! as String);
        final bAt = DateTime.parse(b['updated_at']! as String);
        final byAt = aAt.compareTo(bAt);
        if (byAt != 0) return byAt;
        // **身份键显式校验（r53）**：身份键（常规表 id / profile_settings
        // user_id）缺失或非 String 时抛带行内容的 FormatException（与上方
        // updated_at 的 fail-stop 一致）——直接绕过 seed/upsertRows 注入
        // `tables` 的畸形行会产生裸 TypeError，与本 mock 的 fail-fast 风格
        // 不符（增加测试数据构造错误的排查成本）。行已过归属过滤、user_id
        // 为 null 时常规表仍可读 id（无主行场景）。
        final aId = _identityKey(a);
        final bId = _identityKey(b);
        return aId.compareTo(bId);
      });
    final start = page * pageSize;
    if (start >= rows.length) {
      return RemoteRowsPage(rows: const [], hasMore: false);
    }
    final end = (start + pageSize) < rows.length ? start + pageSize : rows.length;
    // hasMore 语义与真网关一致：末页恰好满页时返回 true（触发一次多余空页
    // 请求以结束），忠实模拟契约。
    // 每行**递归深拷贝**（真网关返回 JSON 反序列化的独立副本——防调用方
    // 原地修改 mock 内部状态绕过写路径，含嵌套字段）。
    final pageRows =
        rows.sublist(start, end).map(_deepCopy).toList();
    return RemoteRowsPage(
      rows: pageRows,
      hasMore: pageRows.length == pageSize,
    );
  }

  @override
  Future<Map<String, DateTime>> fetchRemoteUpdatedAt({
    required String table,
    required String userId,
    required List<String> ids,
    String idKey = 'id',
  }) async {
    callLog.add('updated_at:$table');
    _maybeThrow('updated_at:$table');
    final result = <String, DateTime>{};
    for (final id in ids) {
      // 按 idKey 匹配行 + 按 userId 过滤（与真网关 eq('user_id') + inFilter
      // 一致；防跨用户数据存在时误报本用户不存在的行）。与 fetchRowsSince 的
      // 过滤规则完全对齐（含 allowUnownedRows 严格模式）。
      final row = tables[table]?.values
          .where((r) => r[idKey] == id)
          .where((r) {
            // 与 fetchRowsSince 过滤规则完全对齐（含 allowUnownedRows 严格模式）。
            final rowUser = r['user_id'];
            if (rowUser != null && rowUser != userId) return false;
            if (rowUser == null && !allowUnownedRows) return false;
            return true;
          })
          .firstOrNull;
      if (row != null) {
        // 与真网关 fail-stop 语义一致：updated_at 缺失/类型异常/不可解析
        // 抛明确错误（防调用方把"缺该 id"误判为"远端无此行"而推旧覆盖新、
        // LWW 数据静默丢失）。
        final rawAt = row['updated_at'];
        if (rawAt is! String || DateTime.tryParse(rawAt) == null) {
          throw FormatException(
            '[$table] 行 $id 的 updated_at 缺失或无法解析：$rawAt',
          );
        }
        final parsed = DateTime.parse(rawAt).toUtc();
        // 应用远端时间戳偏差（模拟"拉取后、推送检查时远端被并发更新"）。
        final bias = updatedAtBias[id];
        result[id] = bias == null ? parsed : parsed.add(bias);
      }
    }
    return result;
  }

  /// upsert 前钩子：在 fetchRemoteUpdatedAt 之后、写入之前被调用（模拟"拉取后、
  /// 推送前远端被并发更新"的竞态窗口——_pushTable 的跳过分支唯一可达路径）。
  void Function(String table, String userId)? onBeforePush;

  /// 最近一次 upsert 写入的行身份（断言推送跳过分支用）。
  final List<String> lastPushedIds = [];

  /// **最近一次 upsert 收到的原始推送负载副本（注入 user_id 之前）**：真网关
  /// 对每个推送行强制注入 user_id，使"远端行归属"断言无法区分"引擎 _withUserId
  /// 认领路径生效"与"网关注入兜底"——本字段记录引擎**实际发送**的行，测试
  /// 据此断言引擎补填了当前用户归属（真正守护认领路径，见
  /// cloud_sync_engine_test 宽松模式用例）。
  /// **成功路径语义（r48）**：仅在整批 upsert 校验通过并写入后填充（与
  /// [lastPushedIds] 成对）——失败路径保持清空，"最近一次**成功** upsert 的
  /// 负载"语义不含部分数据。
  /// **按表拆分视图（r50）**：[lastPushedRawRowsByTable] 是**按表拆分**的记录
  ///（`table → 该表最近一次成功 upsert 的原始负载`）——消除"某表是每轮同步
  /// 最后一个非空推送表"的顺序依赖（见 cloud_sync_engine_test 认领用例注释）；
  /// 两个视图共用同一底层记录（不是两份副本）。
  /// **跨轮次保留边界（r51）**：本视图只在该表**再次被 push** 时才
  /// remove/替换该表记录——其他表 push（含失败）不清除本表记录。因此
  /// `isNotEmpty` 类断言只能证明"该表**曾经**推送过"，不能证明"**本轮**推送
  /// 了"（本轮未推时读到的是上一轮残留）。轮次级断言须配合
  /// [callLog] 的 `push:<table>` 计数或 [lastPushedIds] 交叉验证。
  final List<Map<String, Object?>> lastPushedRawRows = [];
  final Map<String, List<Map<String, Object?>>> lastPushedRawRowsByTable = {};

  /// 远端时间戳偏差（id → 时差）：fetchRemoteUpdatedAt 返回存储值 + 偏差——
  /// 模拟"拉取后、推送检查时远端被并发更新"（跳过分支 `remoteAt.isAfter`
  /// 唯一可触发的构造）。
  final Map<String, Duration> updatedAtBias = {};

  @override
  Future<void> upsertRows({
    required String table,
    required String userId,
    required List<Map<String, Object?>> rows,
  }) async {
    callLog.add('push:$table');
    lastPushedIds.clear(); // 语义："本次调用尚未写入任何行"（失败路径也清空）
    lastPushedRawRows.clear(); // 同步清空原始负载记录（与 lastPushedIds 成对）
    // 按表视图只清**当前表**的记录（不清其他表）——"每表最近一次成功 upsert
    // 的负载"语义使断言不依赖"该表是最后一个非空推送表"的顺序（r50）。
    lastPushedRawRowsByTable.remove(table);
    _maybeThrow('push:$table');
    onBeforePush?.call(table, userId);
    final target = tables.putIfAbsent(table, () => {});

    // 先对全部行做完整校验（防"先写 A 再抛 B"的部分写入——真网关同 chunk
    // 失败是整请求 4xx 不落任何行；mock 应与之对齐）。
    // 三元组：id / 合并副本（深拷贝产物）/ 注入前原始负载副本（r48 起随
    // prepared 保存，写入循环整批成功后一并落 lastPushedRawRows）。
    final prepared = <(String, Map<String, Object?>, Map<String, Object?>)>[];
    for (final row in rows) {
      // 与真网关一致：强制注入 user_id；**显式要求 updated_at 存在且可解析**
      //（真网关不会补齐——静默补会让"调用方漏传 updated_at"的 bug 在测试
      // 通过而在真实链路才暴露）。
      if (row['updated_at'] is! String ||
          DateTime.tryParse(row['updated_at']! as String) == null) {
        throw ArgumentError('upsertRows: 行必须携带可解析的 updated_at（行内容：$row）');
      }
      // 注入前原始负载的**递归深拷贝**（Map.of 浅拷贝会让调用方改嵌套字段时
      // 无提示改变已记录负载、守护"引擎补填 user_id"的断言失真）——与合并
      // 副本一并存入 prepared，**写入循环（整批校验通过后）才记录到
      // lastPushedRawRows**：防批次中途失败时残留前 N-1 行的部分记录（与
      // lastPushedIds"失败路径保持清空"的成对语义一致）。
      final rawCopy = _deepCopy(row);
      final owned = {...row, 'user_id': userId};
      // 行身份（r50 对齐 seed 的 fail-fast）：常规表**必须携带 id**——本方法
      // 已强制注入 `user_id = userId`，若用 `id ?? user_id` 静默回退，任何缺
      // id 的常规表行都会被键到当前 userId 下，再叠加 merge 语义与同键既有
      // 行做字段级合并，比整行覆盖更隐蔽地静默损坏数据（与 seed 拒绝缺 id
      // 行的 fail-fast 哲学一致，防 mock 放行真网关必拒的畸形行）。
      final isSettings = _isSettingsTable(table);
      final id = isSettings
          ? (owned['user_id'] as String?)
          : (owned['id'] as String?);
      if (id == null) {
        throw ArgumentError(
          'upsertRows: ${isSettings ? 'profile_settings' : '常规表'} 行必须携带'
          ' ${isSettings ? 'user_id' : 'id'}（行内容：$row）',
        );
      }
      // 归属校验（写入前统一检查，防部分写入）：
      // - 目标行归属他人 → 拒绝覆盖（与 fetch 严格过滤对齐，模拟 RLS 拒绝）；
      // - 严格模式下目标行为无主行（user_id 为 null）→ 拒绝认领（防任意用户
      //   覆盖无主行，与 fetch 严格模式过滤对称）。
      // 注：id 在 null 检查后已提升为非空 String（r50 起类型收窄）。
      final existing = target[id];
      final existingUser = existing?['user_id'];
      // 按值判定（非 String 的 user_id 也是归属冲突——类型漏洞防直接注入
      // tables 绕过校验）。
      final claimedConflict =
          existing != null && existingUser != null && existingUser != userId;
      final unownedConflict =
          existing != null && existingUser == null && !allowUnownedRows;
      if (claimedConflict || unownedConflict) {
        throw StateError(
          'upsertRows: 目标行 $id 归属冲突（${existingUser ?? '无主'}），拒绝覆盖',
        );
      }
      // **JSON 可序列化校验前移（r45）**：`_deepCopy`（含 jsonEncode 失败）
      // 必须在 prepared 循环内执行——防"A 可序列化已写入、B 不可序列化才抛"
      // 的部分写入（与注释"先全量校验再写"承诺一致）。**合并副本一并纳入
      // 首轮校验**：同一批次内无 await，两轮读到的 existing 值一致——写入
      // 循环只做落库、不再可能抛错（防写入阶段部分写入）。
      // 复用上方归属校验已读取的 [existing]（同一行，无重复读取）。
      final merged = existing == null ? owned : {...existing, ...owned};
      // **一次深拷贝（r47 #3）**：prepared 循环的 `_deepCopy(merged)` 同时承担
      // "校验合并副本可序列化"与"生成写入副本"两个职责，返回值存入 prepared、
      // 写入循环直接复用——原实现校验后丢弃副本、写入循环再拷一次（同一行
      // 两次 json round-trip，大批次下无谓开销）。
      prepared.add((id, _deepCopy(merged), rawCopy));
    }
    for (final (id, mergedCopy, rawCopy) in prepared) {
      // **merge 语义（与真网关一致）**：真网关用 PostgREST
      // `resolution=merge-duplicates`（ON CONFLICT DO UPDATE 仅更新 payload
      // 中出现的列，未传字段在云端保留原值）——mock 同样只覆盖传入字段，
      // 保留已存在行的未传字段（防"推送部分字段行时 mock 丢弃字段而生产
      // 不会"掩盖字段丢失类缺陷）。mergedCopy 为 prepared 循环的深拷贝产物
      //（无外部引用、无内部状态共享），直接落库——防外部改原 Map 影响 mock
      // 状态，且不再重复深拷贝。
      target[id] = mergedCopy;
      lastPushedIds.add(id);
      // **成功路径才记录原始负载（r48）**：写入循环仅在整批校验通过后执行
      // ——失败路径 lastPushedRawRows 与 lastPushedIds 一样保持清空（防"最近
      // 一次成功 upsert 的负载"语义读到误导性部分数据）。
      // **按表视图（r50）**：与扁平列表共用同一记录（行副本），测试按表断言
      // 认领负载时不依赖"该表是最后一个非空推送表"的顺序假设。
      lastPushedRawRows.add(rawCopy);
      lastPushedRawRowsByTable
          .putIfAbsent(table, () => [])
          .add(rawCopy);
    }
  }

  /// 语义化失败钩子：设非 null 时，**操作描述匹配**的网关调用抛异常
  ///（如 'pull:activities#1' = activities 第 1 页拉取、'push:activities' =
  /// activities 推送）——不依赖裸调用序号，防引擎调用顺序变化时失败点
  /// 静默移位。
  String? failOnCall;

  void _maybeThrow(String call) {
    final error = nextError;
    if (error != null) {
      nextError = null;
      failOnCallIndex = null; // 互斥：nextError 触发时清除序号钩子
      failOnCall = null; // **r52**：同步清除语义钩子——保持三钩子互斥
      //（防 nextError 触发后 failOnCall 仍有效、后续匹配调用再次抛错，
      // "一次性失败"语义失效）。
      _callCount += 1; // 与 callLog 计数对齐（防 failOnCallIndex 相对偏移）
      throw error;
    }
    if (failOnCall != null && call == failOnCall) {
      failOnCall = null; // 单次生效
      failOnCallIndex = null; // **r52**：命中语义钩子同样清除序号钩子（互斥）
      _callCount += 1; // **r52**：与 callLog 计数对齐——防与 failOnCallIndex
      // 同时设置时序号钩子比预期晚一次触发（相对偏移，与 nextError 分支一致）。
      throw Exception('mock 条件失败（操作 $call）');
    }
    final indexError = failOnCallIndex;
    final isTarget = indexError != null && _callCount == indexError;
    _callCount += 1;
    if (isTarget) {
      failOnCallIndex = null; // 单次生效
      throw Exception('mock 条件失败（调用序号 ${_callCount - 1}）');
    }
  }
}

/// 校验推送顺序（先拉后推）：**所有**拉取早于首个推送。
void expectPullBeforePush(List<String> log) {
  var firstPush = -1;
  var lastPull = -1;
  for (var i = 0; i < log.length; i++) {
    if (log[i].startsWith('pull:')) lastPull = i;
    if (log[i].startsWith('push:') && firstPush == -1) firstPush = i;
  }
  // **无推送即失败（r53）**：若引擎回归为"只拉不推"，无 push 时直接 return
  // 会让"先拉后推"契约空真通过——有拉取则必须存在推送（推送为空表的场景
  // 由调用侧另行构造，本函数只守护顺序契约本身）。
  expect(firstPush, isNot(-1), reason: '同步必须存在推送（拉取后）:$log');
  expect(lastPull, isNot(-1), reason: '推送之前必须存在拉取：$log');
  expect(lastPull, lessThan(firstPush),
      reason: '所有拉取必须早于首个推送：$log');
}
