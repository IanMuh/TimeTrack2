/// 编译期配置读取（--dart-define 注入，运行时读取）。
///
/// 安全约定（计划第 19 条）：
/// - 默认值指向公开地址（本仓库 raw.githubusercontent），可被 `--dart-define` 覆盖；
/// - SUPABASE_URL / SUPABASE_ANON_KEY 等密钥类配置同样走此通道，但**不入库**；
/// - AI key 永不入编译参数（二期用 flutter_secure_storage 存）。
library;

class AppBuildConfig {
  AppBuildConfig._();

  // ---------------------------------------------------------------------------
  // 已声明的 dart-define 键
  // ---------------------------------------------------------------------------

  /// 云同步配置（supabase）。未提供时应用完全离线运行（与老项目一致）。
  static const supabaseUrlKey = 'SUPABASE_URL';
  static const supabaseAnonKeyKey = 'SUPABASE_ANON_KEY';

  /// 更新清单 URL 注入键（默认指向本仓库 raw.githubusercontent，可覆盖）。
  static const updateManifestUrlKey = 'UPDATE_MANIFEST_URL';

  /// 已注入的编译期配置值（**const 上下文**读取——`String.fromEnvironment`
  /// 仅在 const 上下文（编译期）解析 dart-define；非 const 调用恒返回默认值，
  /// 运行时动态 key 无法解析，故每个已知键声明为 const 字段后直接引用）。
  static const supabaseUrl = String.fromEnvironment(supabaseUrlKey, defaultValue: '');
  static const supabaseAnonKey = String.fromEnvironment(supabaseAnonKeyKey, defaultValue: '');
  static const updateManifestUrl =
      String.fromEnvironment(updateManifestUrlKey, defaultValue: '');

  /// 是否已注入云同步配置（SUPABASE_URL + ANON_KEY 均非空）。
  ///
  /// 未配置时应用完全离线运行（老项目语义）；由后端工厂决定用
  /// NoopSyncBackend（api/supabase/sync_backend.dart）。
  static bool isSupabaseConfigured() =>
      supabaseUrl.isNotEmpty && supabaseAnonKey.isNotEmpty;

  /// 解析布尔字符串（纯函数，可独立单测）。
  ///
  /// - 空串/纯空白 → [defaultValue]（未注入）
  /// - `true`/`1`/`yes`（忽略大小写与首尾空白）→ true
  /// - `false`/`0`/`no`（忽略大小写与首尾空白）→ false
  /// - 其他无法识别的非空值 → [defaultValue]
  static bool parseBool(String raw, {required bool defaultValue}) {
    final normalized = raw.trim().toLowerCase();
    if (normalized.isEmpty) return defaultValue;
    if (normalized == 'true' || normalized == '1' || normalized == 'yes') {
      return true;
    }
    if (normalized == 'false' || normalized == '0' || normalized == 'no') {
      return false;
    }
    return defaultValue;
  }
}
