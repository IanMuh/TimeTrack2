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

  setUpAll(() {
    expect(schemaFile.existsSync(), isTrue,
        reason: '未找到 ${schemaFile.path}（已按 pubspec.yaml 定位项目根）');
    raw = schemaFile.readAsStringSync();
    // 仅剥离**行首**注释（`--` 起始的行）：函数体内的 `--`（如字符串/文本
    // 常量）是 SQL 语法的一部分，不能剥离；本文件注释均为行首整行。
    final withoutLineComments =
        raw.replaceAll(RegExp(r'^--[^\n]*', multiLine: true), '');
    final withoutBlockComments = withoutLineComments
        .replaceAll(RegExp(r'/\*[\s\S]*?\*/'), '');
    // 空白归一化（空白细节不参与语义锁定），断言正则大小写不敏感。
    schema = withoutBlockComments.replaceAll(RegExp(r'\s+'), ' ');
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
    test('触发器定义挂载：ON activity_categories + EXECUTE FUNCTION', () {
      // [^;]* 限定单条语句内匹配（防跨语句假阳性）
      expect(
        has(r'CREATE TRIGGER TRG_ACTIVITY_CATEGORY_SOFT_DELETE AFTER UPDATE OF '
            r'DELETED_AT ON ACTIVITY_CATEGORIES [^;]*EXECUTE FUNCTION '
            r'SOFT_DELETE_ACTIVITY_CATEGORY_CHILDREN\(\)'),
        isTrue,
        reason: '递归软删函数必须被触发器挂载',
      );
      // 递归逻辑限定在目标函数体内（负向前瞻拒绝跨定界符）：
      // WITH RECURSIVE + CTE 种子（WHERE PARENT_ID = NEW.ID）+ 递归分支 UNION
      // + 递归分支引用 TREE（JOIN TREE t ON ... 才真正穿透多层子孙）。
      // 注意顺序：种子 SELECT 的 WHERE 在 UNION **之前**。
      const withinFunction = r'(?:(?!\$[A-Za-z0-9_]*\$)[\s\S])*?';
      expect(
        has(
          r'FUNCTION SOFT_DELETE_ACTIVITY_CATEGORY_CHILDREN\(\)'
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
      const within = r'(?:(?!\$[A-Za-z0-9_]*\$)[\s\S])*?';
      final lwwPattern =
          r'(?:WHEN UPDATED_AT > PARENT_TS THEN UPDATED_AT' '$within'
          r'ELSE PARENT_TS'
              r'|GREATEST\(UPDATED_AT, PARENT_TS\)'
              r'|GREATEST\(PARENT_TS, UPDATED_AT\)'
              r')';
      expect(
        has(
          r'FUNCTION SOFT_DELETE_ACTIVITY_CATEGORY_CHILDREN\(\)'
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

    test('关联表级联软删（分类删除传播到 links）且触发器挂载', () {
      expect(has(r'SOFT_DELETE_CATEGORY_LINKS'), isTrue);
      expect(has(r'UPDATE ACTIVITY_CATEGORY_LINKS'), isTrue);
      expect(has(r'WHERE CATEGORY_ID = NEW\.ID AND DELETED_AT IS NULL'), isTrue);
      expect(has(r'EXECUTE FUNCTION SOFT_DELETE_CATEGORY_LINKS\(\)'), isTrue,
          reason: 'links 级联函数必须被触发器挂载');
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
        // SELECT：USING 绑定
        expect(
          has("CREATE POLICY ${table}_SELECT_OWN ON $table [^;]*"
              "FOR SELECT TO AUTHENTICATED [^;]*"
              r'USING \(USER_ID = AUTH\.UID\(\)\)[^;]*'),
          isTrue,
          reason: '$table 缺 SELECT 策略（USING 绑定 auth.uid()）',
        );
        // INSERT：WITH CHECK 绑定
        expect(
          has("CREATE POLICY ${table}_INSERT_OWN ON $table [^;]*"
              "FOR INSERT TO AUTHENTICATED [^;]*"
              r'WITH CHECK \(USER_ID = AUTH\.UID\(\)\)[^;]*'),
          isTrue,
          reason: '$table 缺 INSERT 策略（WITH CHECK 绑定 auth.uid()）',
        );
        // UPDATE：USING + WITH CHECK 绑定
        expect(
          has("CREATE POLICY ${table}_UPDATE_OWN ON $table [^;]*"
              "FOR UPDATE TO AUTHENTICATED [^;]*"
              r'USING \(USER_ID = AUTH\.UID\(\)\) [^;]*'
              r'WITH CHECK \(USER_ID = AUTH\.UID\(\)\)[^;]*'),
          isTrue,
          reason: '$table 缺 UPDATE 策略（USING + WITH CHECK 绑定）',
        );
        // 禁止任何 FOR DELETE / FOR ALL（ALL 隐含 DELETE）策略——防物理删除
        // 绕过软删体系（不只查固定命名 _DELETE_OWN）。
        expect(
          has("CREATE POLICY [^;]* ON $table [^;]*"
              r'FOR (DELETE|ALL)[^;]*'),
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
      // 校验触发器挂载到表（[^;]* 限定单条语句，防跨语句假阳性）
      expect(
        has(r'CREATE TRIGGER TRG_TIME_ENTRIES_REF_CHECK [^;]*'
            r'EXECUTE FUNCTION VALIDATE_TIME_ENTRY_REF\(\)'),
        isTrue,
        reason: 'time_entries 引用校验触发器必须挂载',
      );
      expect(
        has(r'CREATE TRIGGER TRG_ACTIVITY_CATEGORY_LINKS_REF_CHECK [^;]*'
            r'EXECUTE FUNCTION VALIDATE_LINK_REF\(\)'),
        isTrue,
        reason: 'links 引用校验触发器必须挂载',
      );
      expect(
        has(r'CREATE TRIGGER TRG_ACTIVITY_CATEGORIES_PARENT_REF_CHECK [^;]*'
            r'EXECUTE FUNCTION VALIDATE_CATEGORY_PARENT_REF\(\)'),
        isTrue,
        reason: '分类 parent 引用校验触发器必须挂载',
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
