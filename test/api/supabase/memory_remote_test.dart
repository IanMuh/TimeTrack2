import 'package:flutter_test/flutter_test.dart';

import 'memory_remote.dart';

/// MemoryRemote 直接行为测试（不经过引擎）：锁定 mock 的关键新语义——
/// 严格模式默认归属注入、seedUnowned 宽松模式/运行时保护、深拷贝隔离、
/// 默认 pageSize、归属过滤——防 mock 语义偏离真网关掩盖生产缺陷。
void main() {
  /// 基准时间戳（测试行统一使用，语义明确为 UTC——防 20+ 处硬编码
  /// 字面量漂移；LWW 关键字段的时区语义清晰）。
  const t0 = '2026-08-11T10:00:00.000000Z';

  /// 自基准起第 [i] 分钟的 UTC 时间戳（行序列用）。
  /// **固定 6 位微秒格式**：与云端存储格式/项目不变量
  /// "字典序=时间序"（utcString）一致——toIso8601String 在微秒为 0 时省略
  /// 小数位（3 位毫秒），同一表内混用 3 位/6 位格式会削弱"mock 与真网关
  /// 格式语义一致"的锁定（若排序/过滤回归为字典序比较，混合格式无法暴露）。
  String tsMinutes(int i) {
    // 补零到固定 6 位微秒（与云端 utcString 格式一致）：toIso8601String 在
    // **毫秒和微秒均为 0 时完全省略小数部分**——本基准 t0 微秒为 0、偏移为
    // 整分钟，恒走 `replaceFirst('Z', '.000000Z')` 分支；`iso.contains('.')`
    // 分支仅在其他调用方传入非整秒基准时可达（防御保留，防格式漂移）。
    final iso = DateTime.parse(t0)
        .add(Duration(minutes: i))
        .toUtc()
        .toIso8601String();
    if (iso.contains('.')) {
      return iso.replaceAllMapped(
        RegExp(r'\.(\d{3})(\d{3})?Z$'),
        (m) => '.${m[1]}${m[2] ?? '000'}Z',
      );
    }
    return iso.replaceFirst('Z', '.000000Z');
  }

  group('seed 默认归属与严格模式', () {
    test('seed 无 user_id 的行注入 defaultSeedUserId（严格模式默认归属）', () async {
      final remote = MemoryRemote();
      remote.seed('activities', {
        'id': 'a1',
        'name': 'x',
        'color': 0,
        'updated_at': t0,
      });

      final page = await remote.fetchRowsSince(
        table: 'activities',
        userId: MemoryRemote.defaultSeedUserId,
      );
      expect(page.rows.single['user_id'], MemoryRemote.defaultSeedUserId,
          reason: '默认归属 = defaultSeedUserId（引擎单用户约定）');
      // 其他 userId 过滤下不可见（默认严格模式）
      final other = await remote.fetchRowsSince(
        table: 'activities',
        userId: 'other-user',
      );
      expect(other.rows, isEmpty, reason: '严格模式归属过滤');
    });

    test('显式带 user_id 的行原样保留（跨用户隔离依赖）', () async {
      final remote = MemoryRemote();
      remote.seed('activities', {
        'id': 'a1',
        'user_id': 'other-user',
        'name': 'x',
        'color': 0,
        'updated_at': t0,
      });
      final page = await remote.fetchRowsSince(
        table: 'activities',
        userId: 'other-user',
      );
      expect(page.rows.single['user_id'], 'other-user');
      // 负向断言：默认用户（defaultSeedUserId）查不到该行（跨用户隔离，
      // 严格模式归属过滤——防 mock 退化为"所有用户都能看到"）。
      final denied = await remote.fetchRowsSince(
        table: 'activities',
        userId: MemoryRemote.defaultSeedUserId,
      );
      expect(denied.rows, isEmpty, reason: '严格模式负向隔离');
    });

    test('seed 显式 user_id: null 的行同样注入默认归属（r49 补锁）', () async {
      // seed 文档承诺"行无 user_id（**含显式置 null**）时注入
      // defaultSeedUserId"——若实现回归为以 `containsKey('user_id')` 区分
      //（显式 null 不注入、静默构造无主行），既有用例（缺键/非 null 两形态）
      // 全部通过而 mock 语义偏离：该行在严格过滤下对所有用户不可见（幽灵行）。
      final remote = MemoryRemote();
      remote.seed('activities', {
        'id': 'a1',
        'user_id': null, // 显式置 null：仍应注入默认归属
        'name': 'x',
        'color': 0,
        'updated_at': t0,
      });
      final page = await remote.fetchRowsSince(
        table: 'activities',
        userId: MemoryRemote.defaultSeedUserId,
      );
      expect(page.rows.single['user_id'], MemoryRemote.defaultSeedUserId,
          reason: '显式 null user_id 仍注入默认归属（文档承诺）');
    });
  });

  group('seedUnowned（真正的无主行）', () {
    test('宽松模式可见；严格模式显式拒绝（运行时保护）', () async {
      final loose = MemoryRemote()..allowUnownedRows = true;
      loose.seedUnowned('activities', {
        'id': 'u1',
        'name': 'x',
        'color': 0,
        'updated_at': t0,
      });
      // 无主行在宽松模式下对任意用户可见（模拟遗留历史数据）——
      // 用两个不同 userId 复核（防实现退化为仅默认用户可见）。
      for (final userId in [MemoryRemote.defaultSeedUserId, 'another-user']) {
        final page = await loose.fetchRowsSince(
          table: 'activities',
          userId: userId,
        );
        expect(page.rows.single['user_id'], isNull,
            reason: '行仍无归属（userId=$userId）');
      }

      // 严格模式（默认）下 seedUnowned 抛 StateError（构造无主行无意义）
      final strict = MemoryRemote();
      expect(
        () => strict.seedUnowned('activities', {
          'id': 'u2',
          'name': 'x',
          'color': 0,
          'updated_at': t0,
        }),
        throwsStateError,
      );
      // **单行原子性**：抛错后不得写入任何行（防"先落行再抛错"回归
      //——严格模式下无主行对 fetch 本就不可见，无状态断言会漏检）。
      expect(strict.tables['activities']?['u2'], isNull,
          reason: '严格模式下 seedUnowned 抛错后不得写入任何行');
    });

    test('宽松模式不放松其他隔离语义（已归属行仍按 user_id 过滤 / seed 仍注入归属）', () async {
      // 宽松模式（allowUnownedRows=true）**只**放宽无主行的可见性；两条
      // 语义不得被一并放宽（防 mock 把宽松模式错误实现为"所有行对所有用户
      // 可见"或"seed 不再注入归属"时被静默掩盖）：
      final loose = MemoryRemote()..allowUnownedRows = true;
      // 1) seed 无 user_id 的行**仍注入** defaultSeedUserId（seed 不读开关）
      loose.seed('activities', {
        'id': 'owned-1',
        'name': 'x',
        'color': 0,
        'updated_at': t0,
      });
      final defaultUser = await loose.fetchRowsSince(
        table: 'activities',
        userId: MemoryRemote.defaultSeedUserId,
      );
      expect(defaultUser.rows.single['user_id'], MemoryRemote.defaultSeedUserId,
          reason: '宽松模式下 seed 仍注入默认归属');
      // 2) 已归属行（user_id='u1'）对另一用户（'u2'）仍不可见
      loose.seed('activities', {
        'id': 'owned-2',
        'user_id': 'u1',
        'name': 'x',
        'color': 0,
        'updated_at': t0,
      });
      final other = await loose.fetchRowsSince(
        table: 'activities',
        userId: 'u2',
      );
      // 本场景确定性为空（owned-1/owned-2 均被过滤）——直接断言 isEmpty
      // 锁定完整行为（防宽松模式泄漏其它未来新增行时仅负向断言漏检）。
      expect(other.rows, isEmpty,
          reason: '宽松模式下已归属行对 u2 不可见（本场景确定性为空）');
    });

    test('携带 user_id 拒绝；缺 id 拒绝', () {
      final loose = MemoryRemote()..allowUnownedRows = true;
      expect(
        () => loose.seedUnowned('activities', {
          'id': 'u1',
          'user_id': 'someone',
          'name': 'x',
          'color': 0,
          'updated_at': t0,
        }),
        throwsArgumentError,
        reason: '无主行不应携带 user_id',
      );
      expect(
        () => loose.seedUnowned('activities', {
          'name': 'x',
          'color': 0,
          'updated_at': t0,
        }),
        throwsArgumentError,
        reason: '缺行身份（id）拒绝',
      );
    });
  });

  group('深拷贝隔离', () {
    test('seed/upsert/fetch 返回独立副本（改原 Map 不影响 mock 状态）', () async {
      final remote = MemoryRemote();
      final seedMap = <String, Object?>{
        'id': 'a1',
        'name': 'x',
        'color': 0,
        'updated_at': t0,
      };
      remote.seed('activities', seedMap);
      seedMap['name'] = 'changed-after-seed'; // 外部改动
      expect(
        (await remote.fetchRowsSince(
              table: 'activities',
              userId: MemoryRemote.defaultSeedUserId,
            ))
            .rows
            .single['name'],
        'x',
        reason: 'seed 深拷贝隔离（外部改原 Map 不污染 mock）',
      );

      // upsert 写路径：传入行后续被外部修改，不影响已写入的 mock 状态
      final upsertRow = <String, Object?>{
        'id': 'a2',
        'name': 'y',
        'color': 0,
        'updated_at': tsMinutes(60),
      };
      await remote.upsertRows(
        table: 'activities',
        userId: MemoryRemote.defaultSeedUserId,
        rows: [upsertRow],
      );
      upsertRow['name'] = 'mutated-after-upsert';
      expect(
        (await remote.fetchRowsSince(
              table: 'activities',
              userId: MemoryRemote.defaultSeedUserId,
            ))
            .rows
            .singleWhere((r) => r['id'] == 'a2')['name'],
        'y',
        reason: 'upsert 深拷贝隔离（外部改原 Map 不污染 mock）',
      );

      // fetch 返回副本：改返回结果不影响 mock 内部
      final fetched = await remote.fetchRowsSince(
        table: 'activities',
        userId: MemoryRemote.defaultSeedUserId,
      );
      // 显式定位目标行（不依赖排序顺序——first 隐式依赖默认升序，若 mock
      // 排序变更会静默命中另一行、失去对目标行的隔离性覆盖）。
      fetched.rows.firstWhere((r) => r['id'] == 'a1')['name'] = 'mutated';
      final again = await remote.fetchRowsSince(
        table: 'activities',
        userId: MemoryRemote.defaultSeedUserId,
      );
      expect(
        again.rows.firstWhere((r) => r['id'] == 'a1')['name'],
        'x',
        reason: 'fetch 返回独立副本',
      );

      // **返回列表容器层级隔离（r48）**：现有断言只改返回行的 Map 内容——若
      // fetchRowsSince 回归为"行 Map 已深拷贝、但列表容器共享内部视图"，改动
      // 列表本身（remove/clear）会污染 mock 内部、后续拉取丢行。
      final containerProbe = await remote.fetchRowsSince(
        table: 'activities',
        userId: MemoryRemote.defaultSeedUserId,
      );
      containerProbe.rows.removeWhere((r) => r['id'] == 'a1');
      final afterListMutation = await remote.fetchRowsSince(
        table: 'activities',
        userId: MemoryRemote.defaultSeedUserId,
      );
      expect(
        afterListMutation.rows.any((r) => r['id'] == 'a1'),
        isTrue,
        reason: '修改返回列表容器不得影响 mock 内部（a1 仍存在）',
      );
    });

    test('upsert 合并覆盖已存在行（merge 语义 + 刷新 updated_at → 进入 since 增量窗口）', () async {
      // 增量同步的正确性依赖"upsert 刷新 updated_at 使行进入增量窗口"——
      // 若 mock 退化为合并/不刷新时间戳，引擎同步结果会失真而现有测试不报。
      final remote = MemoryRemote();
      remote.seed('activities', {
        'id': 'a1',
        'name': 'old',
        'color': 0,
        'updated_at': t0,
      });
      final firstPull = await remote.fetchRowsSince(
        table: 'activities',
        userId: MemoryRemote.defaultSeedUserId,
        since: DateTime.parse(t0),
      );
      expect(firstPull.rows.single['name'], 'old', reason: '初始值（等于 since 返回）');

      // upsert 覆盖已存在行：payload 中的字段被替换（含 updated_at 刷新），
      // **未传入的字段保留原值**（与真网关 PostgREST merge-duplicates 语义
      // 一致——ON CONFLICT DO UPDATE 仅更新 payload 出现的列；防"推送部分
      // 字段行时 mock 丢弃字段而生产不会"掩盖字段丢失类缺陷）。
      await remote.upsertRows(
        table: 'activities',
        userId: MemoryRemote.defaultSeedUserId,
        rows: [
          {
            'id': 'a1',
            'name': 'new',
            'updated_at': tsMinutes(120),
            // 注意：不传 color（验证未传字段保留）
          },
        ],
      );
      final replaced = await remote.fetchRowsSince(
        table: 'activities',
        userId: MemoryRemote.defaultSeedUserId,
      );
      expect(replaced.rows.single['name'], 'new',
          reason: 'upsert 覆盖 payload 传入字段（merge 语义）');
      expect(replaced.rows.single['color'], 0,
          reason: 'upsert 未传入字段保留原值（merge 语义）');

      // 刷新后的行可被 since=旧时间戳的增量拉取捕获（进入增量窗口）
      final incremental = await remote.fetchRowsSince(
        table: 'activities',
        userId: MemoryRemote.defaultSeedUserId,
        since: DateTime.parse(t0),
      );
      expect(incremental.rows.single['updated_at'], tsMinutes(120),
          reason: '刷新后 updated_at 使行进入增量窗口');
    });

    test('fetch 返回独立副本（含嵌套 List/Map 递归深拷贝）', () async {
      final remote = MemoryRemote();
      remote.seed('activities', {
        'id': 'a1',
        'name': 'x',
        'color': 0,
        'updated_at': t0,
        // 嵌套结构：深拷贝须隔离到嵌套层（Map.of 只做顶层拷贝会共享引用）。
        'nested': {'list': [1, 2, 3], 'map': {'k': 'v'}},
      });
      final fetched = await remote.fetchRowsSince(
        table: 'activities',
        userId: MemoryRemote.defaultSeedUserId,
      );
      final nested =
          fetched.rows.single['nested'] as Map<String, Object?>;
      // 修改嵌套值（顶层 + 深层——**原地修改**：替换外层副本的 'map' 键引用
      // 无法暴露嵌套 Map 共享引用回归，须改内部键值，与 List 原地修改一致）。
      (nested['list'] as List)[0] = 99;
      (nested['map'] as Map<String, Object?>)['k'] = 'mutated';

      final again = await remote.fetchRowsSince(
        table: 'activities',
        userId: MemoryRemote.defaultSeedUserId,
      );
      final againNested =
          again.rows.single['nested'] as Map<String, Object?>;
      expect((againNested['list'] as List)[0], 1,
          reason: '嵌套 List 深拷贝隔离（修改返回结果不污染 mock）');
      expect((againNested['map'] as Map)['k'], 'v',
          reason: '嵌套 Map 深拷贝隔离');
    });

    test('非 JSON 序列化值（嵌套 DateTime）在深拷贝时显式失败（fail-fast）', () async {
      final remote = MemoryRemote();
      // updated_at 合法（String）→ 通过行校验；嵌套 DateTime 无 toJson 且
      // JSON 不可编码 → 命中 _deepCopy 的 fail-fast。
      // **来源区分**：深拷贝 fail-fast 抛 FormatException（JSON 相关失败
      // 的自然类型）、行校验抛 ArgumentError——按异常类型区分两条路径，
      // 不依赖错误文案（防实现措辞调整导致误报）。
      expect(
        () => remote.seed('activities', {
          'id': 'a1',
          'name': 'x',
          'color': 0,
          'updated_at': t0,
          'nested': DateTime(2026, 8, 11), // 非 JSON 可编码
        }),
        throwsFormatException,
        reason: '嵌套 DateTime 触发深拷贝 fail-fast（FormatException）',
      );
      // **seed 失败原子性（r48）**：深拷贝 fail-fast 后不得写入任何行——若
      // seed 回归为"先落行再深拷贝失败"，抛错仍发生而本断言缺失会静默通过
      //（下方批量 upsert 原子性用例不覆盖该路径）。
      expect(
        remote.tables['activities']?['a1'],
        isNull,
        reason: 'seed 深拷贝失败后不得写入任何行（失败无副作用）',
      );
      // 行校验路径独立覆盖：updated_at 非字符串（如 DateTime）在行校验拒绝
      //（抛 ArgumentError，先于深拷贝发生）。
      // **区分修正**：dart:core 的 FormatException `implements
      // ArgumentError`——`throwsArgumentError` 对深拷贝路径抛出的 FormatException
      // 同样匹配；用显式 catch 分支锁定"ArgumentError 且非 FormatException"
      //（若行校验缺失/顺序调换，深拷贝的 FormatException 会在此 fail）。
      try {
        remote.seed('activities', {
          'id': 'a2',
          'name': 'x',
          'color': 0,
          'updated_at': DateTime(2026, 8, 11),
        });
        fail('应抛 ArgumentError');
      } on FormatException {
        fail('行校验路径不得抛 FormatException（仅深拷贝 fail-fast 抛）');
      } on ArgumentError {
        // 预期：行校验 ArgumentError
      }

      // **批量 upsert 原子性**：任一行不可序列化 → 整体不落任何行
      //（防"先全量校验再写"不变量回归为"写时逐行校验"的部分写入——注释
      // 承诺"真网关同 chunk 失败是整请求 4xx 不落任何行"）。
      final badRow = <String, Object?>{
        'id': 'bad',
        'name': 'x',
        'color': 0,
        'updated_at': t0,
        'nested': DateTime(2026, 8, 11), // 不可序列化
      };
      await expectLater(
        // **await 等待 Future 完成**：当前实现无 await、同步段抛错；
        // 用 await expectLater 消除"未来引入 await 时立即读表早于 Future
        // 完成、部分写入被掩盖"的时序脆弱性。
        remote.upsertRows(
          table: 'activities',
          userId: MemoryRemote.defaultSeedUserId,
          rows: [
            {'id': 'good-a', 'name': 'y', 'color': 0, 'updated_at': t0},
            badRow,
          ],
        ),
        throwsFormatException,
        reason: '批量 upsert 含不可序列化行 → 整体抛错（不部分写入）',
      );
      expect(
        // 空安全取值：表映射不存在时 `?['good-a']` 为 null——"表不存在"与
        // "行不存在"统一视为未写入（不耦合建表时机，原子性语义不变）。
        remote.tables['activities']?['good-a'],
        isNull,
        reason: '校验失败后其他可序列化行不得被写入（原子性）',
      );
    });
  });

  group('since 增量过滤与排序（与真网关 gte/order 对齐）', () {
    test('since 过滤：早于游标的行不返回，等于/晚于返回（gte 闭区间）', () async {
      final remote = MemoryRemote();
      remote.seed('activities', {
        'id': 'old',
        'name': '早',
        'color': 0,
        'updated_at': t0,
      });
      remote.seed('activities', {
        'id': 'equal',
        'name': '等于',
        'color': 0,
        'updated_at': tsMinutes(60),
      });
      remote.seed('activities', {
        'id': 'new',
        'name': '晚',
        'color': 0,
        'updated_at': tsMinutes(120),
      });
      final since = DateTime.parse(tsMinutes(60));
      final page = await remote.fetchRowsSince(
        table: 'activities',
        userId: MemoryRemote.defaultSeedUserId,
        since: since,
      );
      final ids = page.rows.map((r) => r['id']).toList();
      expect(ids, isNot(contains('old')), reason: '早于 since 不返回');
      // 排序：按 updated_at 升序（次级 id 升序）——精确有序列表断言已涵盖
      // 集合包含（`containsAll` 冗余，删去防两处不同步）。
      expect(ids, ['equal', 'new'], reason: 'updated_at 升序');
    });

    test('排序主键 anti-aligned：id 字典序与时间序相反仍按时间升序（r48 补锁）', () async {
      // **主键排序回归暴露（r48）**：本文件既有数据集 id 字典序与 updated_at
      // 时间序**完全同向**（'a' 早 / 'z' 晚）——若 mock 排序从 (updated_at, id)
      // 回归为仅按 id（或按 id 优先），既有断言仍全部通过、'updated_at 升序'
      // 核心契约未被任何用例锁定。构造 anti-aligned 数据集（id 大者时间早、
      // id 小者时间晚），使"按 id 排"与"按时间排"产生可区分的不同顺序。
      final remote = MemoryRemote();
      remote.seed('activities', {
        'id': 'z-early',
        'name': '时间早但 id 大',
        'color': 0,
        'updated_at': t0,
      });
      remote.seed('activities', {
        'id': 'a-late',
        'name': '时间晚但 id 小',
        'color': 0,
        'updated_at': tsMinutes(120),
      });
      final page = await remote.fetchRowsSince(
        table: 'activities',
        userId: MemoryRemote.defaultSeedUserId,
      );
      final ids = page.rows.map((r) => r['id']).toList();
      expect(ids, ['z-early', 'a-late'],
          reason: '主键必须按 updated_at 升序（id 字典序相反时仍按时间排）');
    });

    test('since 晚于全部行 → 空增量窗口（rows 空 + hasMore=false）', () async {
      // 增量同步最常见场景：远端无新增数据，since 晚于所有行——返回空页
      // 且 hasMore=false（防 mock 在"since 过滤后 rows 为空 → start 越界"
      // 分支回归时漏检）。
      final remote = MemoryRemote();
      remote.seed('activities', {
        'id': 'old',
        'name': '早',
        'color': 0,
        'updated_at': t0,
      });
      final page = await remote.fetchRowsSince(
        table: 'activities',
        userId: MemoryRemote.defaultSeedUserId,
        since: DateTime.parse(tsMinutes(120)), // 晚于全部行
      );
      expect(page.rows, isEmpty, reason: 'since 晚于全部行 → 空窗口');
      expect(page.hasMore, isFalse, reason: '空窗口 hasMore=false');
    });

    test('since 过滤 + 分页组合：过滤后跨页并集覆盖窗口内行、不含窗口外行', () async {
      // **组合场景**：同步引擎 _pullTable 每次调用同时传 since +
      // pageSize + page——"先分页后过滤"或"since 过滤后未重置 start 偏移"
      // 类回归会在此暴露（拆开测 since/分页的用例全部通过）。
      final remote = MemoryRemote();
      // 窗口外：早于 since（10:00）
      remote.seed('activities', {
        'id': 'outside-1',
        'name': '窗口外早',
        'color': 0,
        'updated_at': t0,
      });
      remote.seed('activities', {
        'id': 'outside-2',
        'name': '窗口外早2',
        'color': 0,
        'updated_at': tsMinutes(30),
      });
      // 窗口内：>= since（60:00），4 行分 2 页（pageSize=2）
      for (var i = 0; i < 4; i++) {
        remote.seed('activities', {
          'id': 'in-$i',
          'name': '窗口内$i',
          'color': 0,
          'updated_at': tsMinutes(60 + i),
        });
      }
      final since = DateTime.parse(tsMinutes(60));
      final seen = <String>[];
      var lastHasMore = true;
      var pagesUsed = 0;
      for (var page = 0; page < 3; page++) {
        pagesUsed += 1;
        final result = await remote.fetchRowsSince(
          table: 'activities',
          userId: MemoryRemote.defaultSeedUserId,
          since: since,
          pageSize: 2,
          page: page,
        );
        for (final row in result.rows) {
          seen.add(row['id']! as String);
        }
        lastHasMore = result.hasMore;
        if (!result.hasMore) break;
      }
      // **翻页终态锁定**：窗口内 4 行 pageSize=2 恰需 3 页（含 1 次
      // 空页请求结束）——防"空页仍返回 hasMore=true"的终止条件回归被组合
      // 用例漏检（循环上限会自然截断、seen 断言仍通过）。
      expect(lastHasMore, isFalse, reason: '翻页结束后的空页 hasMore=false');
      expect(pagesUsed, 3, reason: '窗口内 4 行恰需 3 页（含空页结束请求）');
      // 跨页并集恰好覆盖窗口内 4 行（不重叠）
      expect(seen, ['in-0', 'in-1', 'in-2', 'in-3'],
          reason: '过滤后跨页并集覆盖全部窗口内行且不重叠');
      expect(seen, isNot(contains('outside-1')),
          reason: '窗口外行（早于 since）不得出现');
      expect(seen, isNot(contains('outside-2')),
          reason: '窗口外行（早于 since）不得出现');
    });

    test('同时间戳行按次级键（id）排序，跨页不丢/重行', () async {
      final remote = MemoryRemote();
      // 3 行同一 updated_at：按 id 升序稳定排序（次级键防同时间戳乱序）
      for (final id in ['b', 'a', 'c']) {
        remote.seed('activities', {
          'id': id,
          'name': id,
          'color': 0,
          'updated_at': t0,
        });
      }
      final page = await remote.fetchRowsSince(
        table: 'activities',
        userId: MemoryRemote.defaultSeedUserId,
        pageSize: 2,
        page: 0,
      );
      expect(page.rows.map((r) => r['id']).toList(), ['a', 'b'],
          reason: '同时间戳按 id 升序');
      expect(page.hasMore, isTrue, reason: '满页 hasMore');
      // 第 2 页：剩余行不重叠、并集覆盖全部（跨页不丢/重行）
      final page1 = await remote.fetchRowsSince(
        table: 'activities',
        userId: MemoryRemote.defaultSeedUserId,
        pageSize: 2,
        page: 1,
      );
      expect(page1.rows.map((r) => r['id']).toList(), ['c'],
          reason: '第 2 页剩余行');
      expect(page1.hasMore, isFalse,
          reason: '第 2 页取完后 hasMore=false');
      final all = [...page.rows, ...page1.rows].map((r) => r['id']).toList();
      expect(all, ['a', 'b', 'c'], reason: '两页并集覆盖全部且不重叠');
    });

    test('末页恰好满页（总行数为 pageSize 整数倍）→ hasMore=true，下一页空页 → false', () async {
      // 契约（与真网关一致）：总行数恰为 pageSize 整数倍时末页恰好满页仍
      // 返回 hasMore=true（上层多一次空页请求以结束）；下一页空页 hasMore=false。
      // 若 mock 的 hasMore 回归为 `end < rows.length`（末页满页时判 false），
      // 上层引擎会少翻一页——本用例守护该契约。
      final remote = MemoryRemote();
      for (final id in ['a', 'b', 'c', 'd']) {
        remote.seed('activities', {
          'id': id,
          'name': id,
          'color': 0,
          'updated_at': t0,
        });
      }
      final page0 = await remote.fetchRowsSince(
        table: 'activities',
        userId: MemoryRemote.defaultSeedUserId,
        pageSize: 2,
        page: 0,
      );
      expect(page0.rows.map((r) => r['id']).toList(), ['a', 'b']);
      expect(page0.hasMore, isTrue, reason: '第 1 页满页 → hasMore=true');
      final page1 = await remote.fetchRowsSince(
        table: 'activities',
        userId: MemoryRemote.defaultSeedUserId,
        pageSize: 2,
        page: 1,
      );
      expect(page1.rows.map((r) => r['id']).toList(), ['c', 'd']);
      expect(page1.hasMore, isTrue,
          reason: '末页恰好满页 → hasMore 仍为 true（多一次空页请求结束）');
      final page2 = await remote.fetchRowsSince(
        table: 'activities',
        userId: MemoryRemote.defaultSeedUserId,
        pageSize: 2,
        page: 2,
      );
      expect(page2.rows, isEmpty,
          reason: '空页请求返回空行');
      expect(page2.hasMore, isFalse, reason: '下一页空页 → hasMore=false');
    });
  });

  group('默认 pageSize 与校验', () {
    test('省略 pageSize 时单页取全（默认值行为验证）', () async {
      // MemoryRemote.defaultPageSize 静态引用接口常量（结构上不可能偏离，
      // 恒真断言无意义——已删）；此处锁定**行为**：省略 pageSize 时 mock
      // 用默认值（30 行 < 999 单页取全；若 mock 默认值偏离为更小值会触发
      // 分页/hasMore 语义偏差）。
      final remote = MemoryRemote();
      // 30 行数据 + 不指定 pageSize：单页全部返回。
      for (var i = 0; i < 30; i++) {
        remote.seed('activities', {
          'id': 'a$i',
          'name': 'x$i',
          'color': 0,
          'updated_at': tsMinutes(i), // 时间辅助函数（无 >1439 行小时溢出风险）
        });
      }
      final page = await remote.fetchRowsSince(
        table: 'activities',
        userId: MemoryRemote.defaultSeedUserId,
      );
      expect(page.rows, hasLength(30), reason: '默认 pageSize 单页取全');
      expect(page.hasMore, isFalse,
          reason: '默认 pageSize 单页取全后 hasMore=false');
    });

    test('pageSize 非法（0/负/超上限）与 page 负数显式拒绝', () async {
      final remote = MemoryRemote();
      // **边界自适配（r49）**：非法上界用 `defaultPageSize + 1`（语义即
      // "超上限"）而非裸字面量 999/1000——mock 校验硬编码上限（memory_remote
      // 内部 `> 999` 拒绝），若生产上限调整而 mock 未同步，旧用例用相同
      // 字面量会静默通过、无法检出 mock 与生产漂移；自适配写法使测试随
      // 接口常量演进并暴露漂移。
      for (final bad in [0, -1, MemoryRemote.defaultPageSize + 1]) {
        await expectLater(
          remote.fetchRowsSince(
              table: 'activities', userId: 'u', pageSize: bad),
          throwsArgumentError,
          reason: 'pageSize=$bad 拒绝',
        );
      }
      await expectLater(
        remote.fetchRowsSince(table: 'activities', userId: 'u', page: -1),
        throwsArgumentError,
        reason: 'page<0 拒绝',
      );
      // 合法边界：pageSize=defaultPageSize（恰为上限/默认）与 page=0（默认）
      // 正常执行。
      final ok = await remote.fetchRowsSince(
        table: 'activities',
        userId: 'u',
        pageSize: MemoryRemote.defaultPageSize,
        page: 0,
      );
      expect(ok.rows, isEmpty,
          reason: '合法边界（pageSize=上限、page=0）正常返回空页');
    });
  });
}
