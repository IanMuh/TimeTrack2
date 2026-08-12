import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// schema.sql 结构测试：不依赖真实 supabase，锁定关键触发器语义与表结构，
/// 防执行计划 #14（云端与本地镜像）与 #3（删除永远赢 + LWW）回归。
///
/// 断言用不区分大小写的正则 + 空白归一化（防格式化工具调空白/大小写误报）。
void main() {
  // 从当前目录向上找 pubspec.yaml 定位项目根（消除对 cwd 的隐式依赖——
  // IDE 单测/CI 子目录运行时也能正确定位）。
  Directory findRoot(Directory dir) {
    if (File('${dir.path}/pubspec.yaml').existsSync()) return dir;
    if (dir.parent.path == dir.path) {
      // 找不到 pubspec.yaml：明确抛错（防静默回退到当前目录掩盖定位失败）。
      throw StateError('未在目录树中找到 pubspec.yaml（从 ${dir.path} 向上查找）');
    }
    return findRoot(dir.parent);
  }

  final schemaFile =
      File('${findRoot(Directory.current).path}/supabase/schema.sql');
  late final String raw;
  late final String schema;
  /// 生产剥离输出（main() 顶部的 late final，供守卫断言校验**生产剥离结果**——
  /// 防守卫用同款正则重新替换造成的恒真断言）。
  late final String withoutLineComments;

  setUpAll(() {
    expect(schemaFile.existsSync(), isTrue,
        reason: '未找到 ${schemaFile.path}（已按 pubspec.yaml 定位项目根）');
    raw = schemaFile.readAsStringSync();
    // 剥离**行首（可含缩进）注释**（`--` 起始的行）：函数体内的 `--`（如
    // 字符串/文本常量）是 SQL 语法的一部分，不能剥离；本文件注释均为行首
    // 整行（含 2 空格缩进者——防残留注释中的关键字骗过正向断言/击穿负向断言）。
    // 注意：行注释剥离在块注释剥离**之前**、无词法感知——若未来 schema 引入
    // `/* ... */` 块注释，须保证行注释不误剥离块注释内的 `--`；**字符串字面量
    // 场景**（跨行字符串的第二物理行以 `--` 开头，如
    // `msg := 'line one\n-- line two';`）同样会被误剥离——该行会被当注释剥掉，
    // 后续断言基于被篡改的 schema 文本运行。当前 schema 无块注释、无跨行
    // 字符串字面量（已核实 78 处匹配行均为真实注释），功能正常；扩展时须
    // 重评估（见下方字符串字面量守卫断言）。
    withoutLineComments =
        raw.replaceAll(RegExp(r'^[ \t]*--[^\n]*', multiLine: true), '');
    final withoutBlockComments = withoutLineComments
        .replaceAll(RegExp(r'/\*[\s\S]*?\*/'), '');
    // 空白归一化（空白细节不参与语义锁定），断言正则大小写不敏感。
    schema = withoutBlockComments.replaceAll(RegExp(r'\s+'), ' ');
  });

  group('注释剥离前置守卫', () {
    test('schema 无跨行字符串/标识符续行以 `--` 开头（剥离安全）', () {
      // 行注释剥离无词法感知——若未来函数体/普通语句引入**跨行字符串或跨行
      // 引号标识符**（其第二物理行以 `--` 开头），该行会被误当注释剥掉、
      // 后续断言基于被篡改文本运行。本守卫用**跨行状态机**扫描（替代旧版
      // "仅上一行引号奇偶"启发式）：维护 单引号字符串 / 双引号标识符 / 美元
      // 引用块 三个跨行词法状态，某行若处于**未闭合字符串/标识符**的续行
      // 起点且以 `--` 开头 → 标记可疑（该文本是内容、非注释，生产剥离会误删）。
      // **为何不把 $$ 块内所有 `--` 行视为可疑**：PL/pgSQL 函数体内的 `--`
      // 行是**真实 SQL 注释**（当前 schema 6 个函数体共 13 处），生产剥离移除
      // 它们是正确行为；只有**未闭合字符串/标识符**的续行 `--` 才是内容。
      // **美元引用块无特殊解析**：`$$...$$` 函数体仍是普通 SQL 文本——其中的
      // `'`/`"`/`--` 语义与外部一致（故统一按同一状态机扫描，仅额外识别
      // `$$`/`$tag$` 定界符以便注释说明），字符串内的 `$$` 不会被误当定界符
      //（单引号状态优先）。
      // **已知盲区（非完整词法）**：`E'...\'...'` 反斜杠转义字符串未处理
      //（`\'` 会被当作字符串闭合）；`U&'...'` 等 Unicode 转义前缀未处理。
      // 当前 schema 无这些形态（下方有自校验负向断言锁定，防静默引入）。
      // 本守卫是"未来演化早期预警"而非完整词法校验——引入上述形态时须
      // 升级扫描。
      var inSingle = false; // 单引号字符串内（跨行）
      var inDouble = false; // 双引号标识符内（跨行）
      var inDollar = false; // 美元引用块内（仅配对计数/结束平衡校验用）
      var suspicious = 0;
      // 定界符/转义形态正则：**循环外构造一次**（防逐字符路径重复分配）。
      final dollarRe = RegExp(r'\$[A-Za-z0-9_]*\$');
      final lines = raw.split('\n');
      for (final line in lines) {
        final isContinuation = inSingle || inDouble;
        if (isContinuation && line.trimLeft().startsWith('--')) {
          suspicious += 1;
        }
        // 逐字符推进词法状态（字符串/标识符内的 `--` 是内容、不识别注释）。
        for (var i = 0; i < line.length; i++) {
          final ch = line[i];
          if (inSingle) {
            if (ch == "'") {
              // `''` 转义对是 SQL 单引号字面量（不闭合）。
              if (i + 1 < line.length && line[i + 1] == "'") {
                i += 1;
              } else {
                inSingle = false;
              }
            }
            continue;
          }
          if (inDouble) {
            if (ch == '"') {
              // `""` 转义对（标识符内双引号字面量）。
              if (i + 1 < line.length && line[i + 1] == '"') {
                i += 1;
              } else {
                inDouble = false;
              }
            }
            continue;
          }
          // 普通代码段：`--` 注释起点后本行剩余为注释（忽略其中引号）。
          if (ch == '-' && i + 1 < line.length && line[i + 1] == '-') {
            break;
          }
          if (ch == "'") {
            inSingle = true;
          } else if (ch == '"') {
            inDouble = true;
          } else if (ch == r'$') {
            final m = dollarRe.matchAsPrefix(line, i);
            if (m != null) {
              inDollar = !inDollar; // 切换（裸 `$$` 或 `$tag$`）
              i += m.end - 1;
            }
          }
        }
      }
      expect(suspicious, 0,
          reason: '无跨行字符串/标识符续行以 `--` 开头（注释剥离不会误伤）');
      // **美元引用闭合平衡（r49）**：`inDollar` 若在扫描中只为装饰则属写后即弃
      // 死变量——改为**结束态校验**：扫描结束时美元引用定界符必须配对闭合
      //（当前 schema 7 对 `$$` 全部配对且均不在字符串内，可安全断言；未来
      // 引入未闭合 `$$` 会在此失败而非静默）。
      expect(inDollar, isFalse,
          reason: '美元引用定界符必须配对闭合（扫描结束态平衡）');
      // **盲区形态自校验（r49，r50 收窄+限定范围）**：`E'` / `U&'` 反斜杠/
      // Unicode 转义字符串是状态机盲区——若未来 schema 引入它们，扫描会静默
      // 失效（suspicious 恒 0）。负向断言锁定当前 schema 无这些形态（只匹配
      // PostgreSQL 盲区前缀 `E'` 与 `U&'`——r50 收窄掉 `[EU]&?'` 对 `U'`/
      // `E&'` 等非盲区形态的误匹配）。**作用范围限定到剥离注释后的代码文本**
      // [withoutLineComments]（r50）——注释/说明文本中出现 `E'`/`U&'` 字样
      // 与剥离逻辑无关、不得误报；仅代码形态引入时本断言先失败、提示须升级
      // 扫描。**大小写不敏感（r51）**：PostgreSQL 的 `E'`/`U&'` 前缀大小写
      // 不敏感（`e'...'`、`u&'...'` 同为合法盲区形态）——仅匹配大写会漏掉
      // 小写引入。
      final escapePrefixes = RegExp(r"\bE'|\bU&'", caseSensitive: false);
      expect(
        escapePrefixes.allMatches(withoutLineComments).isEmpty,
        isTrue,
        reason: 'schema 代码无 E\'\'/U&\'（含小写）转义字符串前缀（状态机盲区形态未引入）',
      );
      // 结束状态平衡：顶层语句不应残留未闭合字符串/标识符（$$ 块由闭合
      // 定界符平衡；未闭合字符串在末尾行会遗留 inSingle=true——值仅为文档
      // 意图，不用于断言，避免词法盲区造成误报）。
      // 行首注释确实存在（剥离正则生效，非空转）。
      expect(
        RegExp(r'^[ \t]*--[^\n]*', multiLine: true).allMatches(raw).length,
        greaterThanOrEqualTo(1),
        reason: 'schema 含行首注释',
      );
      // **缩进注释存在性（r50）**：`[ \t]*` 增强的回归防护依赖 schema 中存在
      // **带缩进**的行首注释（函数体内 13 处）——显式锁定其存在，防未来格式化
      // 把注释全部改顶格后 `[ \t]*` 增强失去意义（生产剥离正则回退为 `^--`
      // 时守卫仍通过）。
      expect(
        RegExp(r'^[ \t]+--[^\n]*', multiLine: true).allMatches(raw).length,
        greaterThanOrEqualTo(1),
        reason: 'schema 必须存在带缩进的行首注释（否则 [ \\t]* 增强无回归防护意义）',
      );
      // **剥离能力直接校验（生产剥离输出）**：带缩进的 `[ \t]*--` 注释必须
      // 全部被**生产剥离逻辑**移除——防剥离正则回退为 `^--` 时函数体内 13
      // 处缩进注释残留进 schema（其文本含 deleted_at/updated_at/greatest 等
      // 断言关键字会污染正向/负向断言），而上方"列首注释存在"断言仍通过。
      // 直接断言 [withoutLineComments]（setUpAll 生产输出），非重新替换。
      expect(
        RegExp(r'^[ \t]*--[^\n]*', multiLine: true).hasMatch(
          withoutLineComments,
        ),
        isFalse,
        reason: '行首注释（含缩进）必须全部被生产剥离逻辑移除',
      );
    });
  });

  /// 正则匹配（大小写不敏感）。
  bool has(String pattern) =>
      RegExp(pattern, caseSensitive: false).hasMatch(schema);

  group('supabase/schema.sql 表结构', () {
    test('6 张业务表齐全（与本地 drift 镜像）', () {
      for (final table in [
        'activities',
        'activity_categories',
        'activity_category_links',
        'time_entries',
        'action_logs',
        'profile_settings',
      ]) {
        expect(
          has('CREATE TABLE IF NOT EXISTS $table'
              r'( |\))'),
          isTrue,
          reason: '缺少表 $table');
      }
    });

    test('核心列逐表校验：user_id(uuid)/updated_at/deleted_at，分类表含 parent_id', () {
      // 逐表捕获 CREATE TABLE 列块，在块内断言关键列——防"某张表丢列、另一
      // 张表保留该列"时全 schema 子串搜索误通过。
      final tables = <String, List<String>>{
        'activities': ['user_id', 'updated_at', 'deleted_at'],
        'activity_categories': ['user_id', 'updated_at', 'deleted_at'],
        'activity_category_links': ['user_id', 'updated_at', 'deleted_at'],
        'time_entries': ['user_id', 'updated_at', 'deleted_at'],
        'action_logs': ['user_id', 'updated_at', 'deleted_at'],
        // profile_settings 无 deleted_at（配置不软删）
        'profile_settings': ['user_id', 'updated_at'],
      };
      for (final entry in tables.entries) {
        final table = entry.key;
        // 捕获列块（CREATE TABLE ... ( 到 ) 之间的内容）
        final block = RegExp(
          'CREATE TABLE IF NOT EXISTS $table \\(([^;]*)\\)',
          caseSensitive: false,
        ).firstMatch(schema);
        expect(block, isNotNull, reason: '表 $table 的 CREATE 定义缺失');
        final columns = block!.group(1)!.toUpperCase();
        for (final column in entry.value) {
          // 词边界匹配（防 owner_user_id 之类的子串误判为存在 user_id）。
          expect(
            RegExp(r'\b' + RegExp.escape(column.toUpperCase()) + r'\b')
                .hasMatch(columns),
            isTrue,
            reason: '$table 缺列 $column',
          );
        }
      }
      // user_id 必须为 uuid（与 auth.users(id)/auth.uid() 类型一致，
      // text→uuid 外键无法建、RLS text=uuid 比较会失败）——逐表校验。
      for (final table in tables.keys) {
        final block = RegExp(
          'CREATE TABLE IF NOT EXISTS $table \\(([^;]*)\\)',
          caseSensitive: false,
        ).firstMatch(schema)!.group(1)!;
        expect(
          RegExp(r'USER_ID\s+UUID', caseSensitive: false).hasMatch(block),
          isTrue,
          reason: '$table 的 user_id 应为 uuid（匹配 auth.uid()）',
        );
      }
      // parent_id 自引用外键（仅 activity_categories 需要）
      final categoryBlock = RegExp(
        r'CREATE TABLE IF NOT EXISTS ACTIVITY_CATEGORIES \(([^;]*)\)',
        caseSensitive: false,
      ).firstMatch(schema)!.group(1)!;
      expect(
        RegExp(r'PARENT_ID TEXT REFERENCES ACTIVITY_CATEGORIES\(ID\)',
                caseSensitive: false)
            .hasMatch(categoryBlock),
        isTrue,
        reason: 'activity_categories 需 parent_id 自引用外键',
      );
      // profile_settings 不软删（无 deleted_at——与本地 drift 镜像一致，
      // 配置行不参与软删体系）：负向断言防误加。
      final settingsBlock = RegExp(
        r'CREATE TABLE IF NOT EXISTS PROFILE_SETTINGS \(([^;]*)\)',
        caseSensitive: false,
      ).firstMatch(schema)!.group(1)!;
      expect(
        RegExp(r'\bDELETED_AT\b', caseSensitive: false).hasMatch(settingsBlock),
        isFalse,
        reason: 'profile_settings 不应有 deleted_at（配置不软删）',
      );
    });
  });

  group('触发器：分类递归软删（删除永远赢 + LWW）', () {
    test('触发器定义挂载：ON activity_categories + FOR EACH ROW + EXECUTE FUNCTION', () {
      // [^;]* 限定单条语句内匹配（防跨语句假阳性）。
      // **FOR EACH ROW 必须显式锁定**：PostgreSQL 省略该子句时默认为
      // FOR EACH STATEMENT，函数体内引用 NEW 会在运行时直接报错，逐行递归
      // 级联软删彻底失效（schema 当前所有触发器都带 FOR EACH ROW）。
      // 注：`FOR ROW` 与 `FOR EACH ROW` 语义等价（EACH 可省略，都是行级），
      // 但项目统一书写 `FOR EACH ROW`——此处锁定完整写法（防混用风格漂移）。
      expect(
        has(r'CREATE TRIGGER TRG_ACTIVITY_CATEGORY_SOFT_DELETE AFTER UPDATE OF '
            r'DELETED_AT ON ACTIVITY_CATEGORIES [^;]*FOR EACH ROW [^;]*'
            r'EXECUTE FUNCTION SOFT_DELETE_ACTIVITY_CATEGORY_CHILDREN\(\)'),
        isTrue,
        reason: '递归软删函数必须被触发器挂载（FOR EACH ROW 逐行级联）',
      );
      // 递归逻辑限定在目标函数体内（负向前瞻拒绝跨定界符）：
      // WITH RECURSIVE + CTE 种子（WHERE PARENT_ID = NEW.ID）+ 递归分支 UNION
      // + 递归分支引用 TREE（JOIN TREE t ON ... 才真正穿透多层子孙）。
      // 注意顺序：种子 SELECT 的 WHERE 在 UNION **之前**。
      const withinFunction = r'(?:(?!\$[A-Za-z0-9_]*\$)[\s\S])*?';
      expect(
        has(
          // 锚定到函数**定义**（CREATE OR REPLACE FUNCTION——`EXECUTE FUNCTION`
          // 调用处不匹配此前缀），防文本片段来自触发器挂载语句时假通过。
          r'CREATE (?:OR REPLACE )?FUNCTION SOFT_DELETE_ACTIVITY_CATEGORY_CHILDREN\(\)'
          r'[\s\S]*?\$[A-Za-z0-9_]*\$' '$withinFunction'
          r'WITH RECURSIVE TREE AS \( ' '$withinFunction'
          r'WHERE PARENT_ID = NEW\.ID' '$withinFunction'
          r'UNION( ALL)? ' '$withinFunction'
          r'JOIN TREE T ON ' '$withinFunction'
          r'\$[A-Za-z0-9_]*\$',
        ),
        isTrue,
        reason: '递归删除函数体内必须保留 WITH RECURSIVE 递归 CTE'
            '（种子 WHERE PARENT_ID = NEW.ID + UNION 防环 + JOIN TREE 递归穿透）',
      );
    });

    test('子孙 updated_at 用 greatest(自身, 父行) 保持 LWW 传播（限定函数体）', () {
      // 通用美元引用定界符（$function$ / $$ 等）成对圈定函数体，并用
      // 负向前瞻 `(?:(?!\$[A-Za-z0-9_]*\$)[\s\S])*?` 拒绝跨过定界符——
      // 防目标文本在函数体之外（如其他函数）时仍匹配成功。
      // 同时接受两种等价写法：CASE WHEN ... THEN ... ELSE ... 或 GREATEST(...)。
      // 注意：本测试的 `within`（不排除分号，跨语句匹配可行——UPDATED_AT 赋值
      // 与 CASE/GREATEST 表达式可跨语句片段）与"递归写回"测试的 `within`
      //（排除分号，限定 SET→WHERE 同语句）**语义不同**，故各自独立命名不共享。
      const within = r'(?:(?!\$[A-Za-z0-9_]*\$)[\s\S])*?';
      final lwwPattern =
          r'(?:WHEN UPDATED_AT > PARENT_TS THEN UPDATED_AT' '$within'
          r'ELSE PARENT_TS'
              r'|GREATEST\(UPDATED_AT, PARENT_TS\)'
              r'|GREATEST\(PARENT_TS, UPDATED_AT\)'
              r')';
      expect(
        has(
          r'CREATE (?:OR REPLACE )?FUNCTION SOFT_DELETE_ACTIVITY_CATEGORY_CHILDREN\(\)'
          r'[\s\S]*?\$[A-Za-z0-9_]*\$' '$within'
          r'UPDATED_AT = ' '$within'
          '$lwwPattern' '$within'
          r'\$[A-Za-z0-9_]*\$',
        ),
        isTrue,
        reason: '递归删除函数内必须保留 LWW（greatest）传播且赋值给 updated_at'
            '（SET ... updated_at = ... 写回列，防仅残留不写回的计算表达式）',
      );
    });

    test('递归写回：SET deleted_at 实际执行（非仅残留计算表达式）', () {
      // 锁定函数体内的实际写回语句 `UPDATE activity_categories
      // SET deleted_at = parent_ts ... WHERE id = descendant.id`——只断言
      // WITH RECURSIVE/UPDATED_AT 赋值片段可能落在死代码里而级联从不写回。
      // 通用美元引用定界符（$function$ / $$ 等）成对圈定函数体，负向前瞻
      // 拒绝跨过定界符（防目标文本在其他函数中时仍匹配成功）：
      // - 前导（DECLARE/BEGIN 等，含分号）与尾部（; END LOOP; END;）用
      //   `withinTail`（仅禁定界符）；
      // - SET → WHERE 必须落在**同一条 UPDATE 语句内**，用 `within`
      //   （额外禁分号——防 SET 与 WHERE 分属两条语句时假通过）。
      const within = r'(?:(?!\$[A-Za-z0-9_]*\$|;)[\s\S])*?';
      const withinTail = r'(?:(?!\$[A-Za-z0-9_]*\$)[\s\S])*?';
      const withinLoop = r'(?:(?!\$[A-Za-z0-9_]*\$|\bEND\b LOOP\b)[\s\S])*?';
      // LOOP→UPDATE 区间额外禁止 `END LOOP`（**词边界**，与显式关键字
      // `\bEND\b LOOP\b` 一致）：把 UPDATE 真正锚定在该 LOOP...END LOOP 块内——
      // 防"前一个 LOOP + 跨过其 END LOOP + UPDATE + 后一个 END LOOP"的假匹配
      //（写回被移出循环时测试仍通过）；词边界防含 "END LOOP" 子串的标识符/
      // 字符串字面量误命中。
      // **脆弱面声明**：负向前瞻禁止跨越**任意** `END LOOP` 且 `\bLOOP\b`
      // 锚定函数体内**首个** LOOP——未来若在写回 UPDATE 之前新增嵌套内层循环
      //（写回仍正确位于外层 LOOP 内），正则会因跨内层 END LOOP 整体失配而
      // 误报失败（当前 schema 为单循环结构故通过）；引入多层循环时须同步
      // 调整本锚定。**函数体捕获组（r48）**：整个函数体作为 group(1) 圈出，
      // 供下方写回计数断言**限定在函数体内**统计（防 schema 其他函数/文本
      // 含同语句片段时计数误报）。
      final writeBackRe = RegExp(
        // 锚定到函数**定义**（`CREATE (?:OR REPLACE )?FUNCTION`——`EXECUTE
        // FUNCTION` 调用处不匹配此前缀，防文本片段来自触发器挂载语句时假通过；
        // OR REPLACE 为风格可选项，等价写法 CREATE FUNCTION 同样成立，正则
        // 容忍两者，仅区分"定义"与"调用点"）。
        // **LOOP ... END LOOP 显式锚定**：descendant 在 DECLARE 顶层声明
        //（整个函数体可见），若重构把写回移到 END LOOP 之后，函数仍能
        // CREATE 编译（仅运行时 record 未赋值报错）——锚定 LOOP 边界才能
        // 真正锁定"逐行 LOOP 写回"语义（防级联失效回归）。
        // 关键字加 `\b` 词边界：防未来引入 LOOP_/SET_ 等前缀同名标识符
        // 或字符串字面量时子串假匹配（与同文件 FOR (DELETE|ALL)\b 一致）。
        r'CREATE (?:OR REPLACE )?FUNCTION SOFT_DELETE_ACTIVITY_CATEGORY_CHILDREN\(\)'
        r'[\s\S]*?\$[A-Za-z0-9_]*\$' '(' '$withinTail'
        r'\bLOOP\b' '$withinLoop'
        r'\bUPDATE\b ACTIVITY_CATEGORIES\b[^;]*\bSET\b DELETED_AT\s*=\s*PARENT_TS\b'
            '$within'
        r'\bWHERE\b ID = DESCENDANT\.ID\b[^;]*' '$withinTail'
        r'\bEND\b LOOP\b' '$withinTail'
        r')' r'\$[A-Za-z0-9_]*\$',
        caseSensitive: false,
      );
      // **书写风格锁定声明（r50）**：本正则要求写回语句的字面形态
      // `SET deleted_at = parent_ts ... WHERE id = descendant.id`（无表别名、
      // 无 CASE/GREATEST 包装）——这是**有意锁定当前书写风格**，非纯语义
      // 断言（与同文件 LWW 测试显式容忍等价写法的风格不同，因为这里还依赖
      // 上述 LOOP 结构锚定）。语义等价但词法不同的重构（表加别名 `ac.id`、
      // `deleted_at = greatest(...)` 包装等）会误报失败——届时须同步调整
      // 本正则与计数断言，而非静默改 schema。
      final writeBackMatch = writeBackRe.firstMatch(schema);
      expect(
        writeBackMatch,
        isNotNull,
        reason: '递归删除函数内必须实际执行 SET deleted_at 写回'
            '（WHERE id = descendant.id 逐行 LOOP 写回，SET 与 WHERE 同语句，'
            '写回锚定在 LOOP...END LOOP 块内）',
      );
      // **词法盲区说明 + 构造性防护（出现次数断言，r48 收窄到函数体）**：
      // 正则无法区分真实 UPDATE 语句与函数体内字符串字面量——**出现次数
      // 断言**：写回文本在**已匹配的函数体（group 1）**中必须**恰好出现
      // 1 次**（当前函数体内无 RAISE/字符串常量含此文本；若未来加入
      // `RAISE NOTICE '...SET deleted_at = parent_ts...'` 类文本，计数变 2
      // 使断言失败——构造性拒绝**新增**字符串字面量假通过）。**范围收窄
      // （r48）**：限定函数体统计，schema 其他函数/语句含同文本不再误报。
      // **防护范围（如实声明）**：若未来把真实写回**替换**为含同文本的字面量
      //（计数仍为 1），本断言无法检出（LOOP 锚定正向断言会命中字面量内部）——
      // 该场景由"写回锚定在 LOOP...END LOOP 块内 + WITH RECURSIVE 递归
      // CTE"断言约束（字面量文本不含这些结构）。
      expect(
        RegExp(
          r'\bUPDATE\b ACTIVITY_CATEGORIES\b[^;]*\bSET\b DELETED_AT\s*=\s*PARENT_TS\b',
          caseSensitive: false,
        ).allMatches(writeBackMatch!.group(1)!),
        hasLength(1),
        reason: '函数体内 SET deleted_at = parent_ts 写回必须恰好出现 1 次'
            '（防字符串字面量/死代码假匹配；= 两侧空白容错——空白归一化'
            '不补空格，deleted_at=parent_ts 等价写法不得误失败）',
      );
    });

    test('关联表级联软删（分类删除传播到 links）且触发器挂载', () {
      expect(has(r'SOFT_DELETE_CATEGORY_LINKS'), isTrue);
      expect(has(r'UPDATE ACTIVITY_CATEGORY_LINKS'), isTrue);
      expect(has(r'WHERE CATEGORY_ID = NEW\.ID AND DELETED_AT IS NULL'), isTrue);
      expect(has(r'EXECUTE FUNCTION SOFT_DELETE_CATEGORY_LINKS\(\)'), isTrue,
          reason: 'links 级联函数必须被触发器挂载');
    });

    test('活动软删级联 links（r52，与分类级联对称）', () {
      // 活动软删后指向它的活跃 link 行残留会：(1) 同步持续分发已失效关联；
      // (2) 残留 link 被本地更新推送时 validate_link_ref 因活动已软删而报错、
      // 阻塞同步——须与分类级联对称地软删活动 links（本地 deleteActivity 只
      // 软删活动本身，不清理 links）。
      expect(has(r'SOFT_DELETE_ACTIVITY_LINKS'), isTrue);
      expect(has(r'WHERE ACTIVITY_ID = NEW\.ID AND DELETED_AT IS NULL'), isTrue);
      // **双路径分别锚定（r53）**：UPDATE 路径（AFTER UPDATE OF deleted_at）
      // 与 INSERT 路径（AFTER INSERT，云同步直插已删行）各须挂载一次——只查
      // 出现次数 ≥1 会在未来删掉其中一个触发器时静默通过。
      // **单语句限定（r54）**：用 `[^;]*` 把匹配收窄到单条 CREATE TRIGGER
      // 语句内——`[\s\S]*` 贪婪匹配会跨语句命中最后一次出现的
      // `EXECUTE FUNCTION SOFT_DELETE_ACTIVITY_LINKS()`（即另一路径的调用），
      // 未来误删其中一个触发器的 `EXECUTE FUNCTION` 子句时断言仍假绿。
      expect(
        has(r'AFTER UPDATE OF DELETED_AT ON ACTIVITIES [^;]*'
            r'EXECUTE FUNCTION SOFT_DELETE_ACTIVITY_LINKS\(\)'),
        isTrue,
        reason: '活动 links 级联 UPDATE 路径必须挂载',
      );
      expect(
        has(r'AFTER INSERT ON ACTIVITIES [^;]*'
            r'EXECUTE FUNCTION SOFT_DELETE_ACTIVITY_LINKS\(\)'),
        isTrue,
        reason: '活动 links 级联 INSERT 路径必须挂载',
      );
    });

    test('递归软删嵌套触发守卫（r52：pg_trigger_depth）', () {
      // 深层分类树（几十~上百层）下无守卫会逐层嵌套触发、每层重扫完整子树
      //（O(n·d) 重复扫描，可能触发 stack depth limit）——顶层调用已处理整棵
      // 子树，嵌套调用（本函数级联 UPDATE 子孙再次触发）须直接返回。
      // **范围限定（r53）**：把函数体（`$$` 定界符之间）提取后在其中断言
      // 守卫——裸 `[\s\S]*` 贪婪匹配可跨出本函数、命中 schema 后续任意位置
      //（未来其他函数引入同文本时会误绿）。
      final fnMatch = RegExp(
        r'CREATE (?:OR REPLACE )?FUNCTION SOFT_DELETE_ACTIVITY_CATEGORY_CHILDREN\(\)'
        r'[\s\S]*?\$[A-Za-z0-9_]*\$([\s\S]*?)\$[A-Za-z0-9_]*\$',
        caseSensitive: false,
      ).firstMatch(schema);
      expect(fnMatch, isNotNull, reason: '递归软删函数定义存在');
      expect(
        RegExp(r'PG_TRIGGER_DEPTH\(\)\s*>\s*1', caseSensitive: false)
            .hasMatch(fnMatch!.group(1)!),
        isTrue,
        reason: '递归软删函数体内必须带 pg_trigger_depth()>1 嵌套守卫',
      );
    });

    test('assert_ref_exists 显式归属校验（r52：user_id = auth.uid()）', () {
      // 引用存在性校验不得只依赖 RLS 隐式过滤（SECURITY DEFINER/service_role
      // 旁路/RLS 配置演进时跨用户引用会写入成功）——动态 SQL 须显式限定
      // 当前用户（防跨用户引用；无 auth 上下文路径恒拒绝，属显式行为）。
      expect(
        has(r"WHERE ID = \$1 AND DELETED_AT IS NULL AND USER_ID = AUTH\.UID\(\)"),
        isTrue,
        reason: 'assert_ref_exists 动态 SQL 必须显式校验 user_id = auth.uid()',
      );
    });
  });

  group('RLS 与外键校验', () {
    test('6 表逐一启用 RLS', () {
      for (final table in [
        'activities',
        'activity_categories',
        'activity_category_links',
        'time_entries',
        'action_logs',
        'profile_settings',
      ]) {
        expect(has("ALTER TABLE $table ENABLE ROW LEVEL SECURITY"), isTrue,
            reason: '$table 未启用 RLS');
      }
    });

    test('6 表逐一有 SELECT/INSERT/UPDATE 策略且绑定 auth.uid()', () {
      // 按命令类型拆分（FOR SELECT/INSERT/UPDATE）；**不建 FOR DELETE**——
      // 物理删除会绕过级联软删产生悬挂引用，破坏"删除永远赢"。
      for (final table in [
        'activities',
        'activity_categories',
        'activity_category_links',
        'time_entries',
        'action_logs',
        'profile_settings',
      ]) {
        // **标识符转义（r53）**：表名/策略名经 RegExp.escape 后插入正则——
        // 当前标识符均为字母/下划线不触发元字符，但未来引入含 `.`/`+`/`(`
        // 等元字符的标识符时，未转义插值会静默改变断言语义（如 `.` 匹配
        // 任意字符）。
        final t = RegExp.escape(table);
        // SELECT：USING 绑定
        expect(
          has("CREATE POLICY ${RegExp.escape('${table}_SELECT_OWN')} ON $t [^;]*"
              "FOR SELECT TO AUTHENTICATED [^;]*"
              r'USING \(USER_ID = AUTH\.UID\(\)\)[^;]*'),
          isTrue,
          reason: '$table 缺 SELECT 策略（USING 绑定 auth.uid()）',
        );
        // INSERT：WITH CHECK 绑定
        expect(
          has("CREATE POLICY ${RegExp.escape('${table}_INSERT_OWN')} ON $t [^;]*"
              "FOR INSERT TO AUTHENTICATED [^;]*"
              r'WITH CHECK \(USER_ID = AUTH\.UID\(\)\)[^;]*'),
          isTrue,
          reason: '$table 缺 INSERT 策略（WITH CHECK 绑定 auth.uid()）',
        );
        // UPDATE：USING + WITH CHECK 绑定
        expect(
          has("CREATE POLICY ${RegExp.escape('${table}_UPDATE_OWN')} ON $t [^;]*"
              "FOR UPDATE TO AUTHENTICATED [^;]*"
              r'USING \(USER_ID = AUTH\.UID\(\)\) [^;]*'
              r'WITH CHECK \(USER_ID = AUTH\.UID\(\)\)[^;]*'),
          isTrue,
          reason: '$table 缺 UPDATE 策略（USING + WITH CHECK 绑定）',
        );
        // 禁止任何 FOR DELETE / FOR ALL（ALL 隐含 DELETE）策略——防物理删除
        // 绕过软删体系（不只查固定命名 _DELETE_OWN）。
        // `\b` 词边界防 `FOR ALLOW` 类前缀被 `FOR ALL` 误匹配（假失败）。
        expect(
          has("CREATE POLICY [^;]* ON $t [^;]*"
              r'FOR (DELETE|ALL)\b[^;]*'),
          isFalse,
          reason: '$table 不应有任何物理删除策略（软删体系禁物理删除）',
        );
      }
    });

    test('外键校验函数定义且被触发器体调用（3 个校验触发器挂载）', () {
      // 函数定义存在
      for (final fn in [
        'ASSERT_REF_EXISTS',
        'VALIDATE_TIME_ENTRY_REF',
        'VALIDATE_LINK_REF',
        'VALIDATE_CATEGORY_PARENT_REF',
      ]) {
        expect(has("FUNCTION $fn\\("), isTrue, reason: '缺少函数 $fn');
      }
      // 调用点：assert_ref_exists 必须被**每个校验函数体**实际调用（PERFORM ...
      // 限定在各自函数体内（负向前瞻拒绝跨过定界符），防"某函数丢调用、
      // 另一函数重复调用"总数仍达标。注：函数名部分用普通字符串插值（$fn）。
      for (final fn in [
        'VALIDATE_TIME_ENTRY_REF',
        'VALIDATE_LINK_REF',
        'VALIDATE_CATEGORY_PARENT_REF',
      ]) {
        expect(
          has('FUNCTION $fn\\(\\)' // 插值函数名 + 正则转义括号
              r'[\s\S]*?\$[A-Za-z0-9_]*\$'
              r'(?:(?!\$[A-Za-z0-9_]*\$)[\s\S])*?'
              'PERFORM ASSERT_REF_EXISTS'
              r'(?:(?!\$[A-Za-z0-9_]*\$)[\s\S])*?'
              r'\$[A-Za-z0-9_]*\$'),
          isTrue,
          reason: '$fn 必须实际调用 assert_ref_exists',
        );
      }
      // 校验触发器挂载到表（[^;]* 限定单条语句；必须逐行校验新插入/更新行
      // → 显式锁定 FOR EACH ROW——省略默认 FOR EACH STATEMENT 会失效）。
      expect(
        has(r'CREATE TRIGGER TRG_TIME_ENTRIES_REF_CHECK [^;]*'
            r'FOR EACH ROW [^;]*'
            r'EXECUTE FUNCTION VALIDATE_TIME_ENTRY_REF\(\)'),
        isTrue,
        reason: 'time_entries 引用校验触发器必须挂载（FOR EACH ROW）',
      );
      expect(
        has(r'CREATE TRIGGER TRG_ACTIVITY_CATEGORY_LINKS_REF_CHECK [^;]*'
            r'FOR EACH ROW [^;]*'
            r'EXECUTE FUNCTION VALIDATE_LINK_REF\(\)'),
        isTrue,
        reason: 'links 引用校验触发器必须挂载（FOR EACH ROW）',
      );
      expect(
        has(r'CREATE TRIGGER TRG_ACTIVITY_CATEGORIES_PARENT_REF_CHECK [^;]*'
            r'FOR EACH ROW [^;]*'
            r'EXECUTE FUNCTION VALIDATE_CATEGORY_PARENT_REF\(\)'),
        isTrue,
        reason: '分类 parent 引用校验触发器必须挂载（FOR EACH ROW）',
      );
    });
  });

  group('增量索引', () {
    test('6 表 (user_id, updated_at) 增量索引齐全（表名与列组合绑定）', () {
      const indexTables = {
        'idx_activities_sync': 'activities',
        'idx_activity_categories_sync': 'activity_categories',
        'idx_activity_category_links_sync': 'activity_category_links',
        'idx_time_entries_sync': 'time_entries',
        'idx_action_logs_sync': 'action_logs',
        'idx_profile_settings_sync': 'profile_settings',
      };
      for (final entry in indexTables.entries) {
        expect(
          has("CREATE INDEX IF NOT EXISTS ${entry.key} "
              "ON ${entry.value} \\(USER_ID, UPDATED_AT\\)"),
          isTrue,
          reason: '索引 ${entry.key} 必须绑定 ${entry.value}(user_id, updated_at)',
        );
      }
    });
  });
}
