/// 编译期配置读取（--dart-define 注入，运行时读取）。
///
/// 安全约定（计划第 19 条）：
/// - 默认值指向公开地址（本仓库 raw.githubusercontent），可被 `--dart-define` 覆盖；
/// - SUPABASE_URL / SUPABASE_ANON_KEY 等密钥类配置同样走此通道，但**不入库**；
/// - AI key 永不入编译参数（二期用 flutter_secure_storage 存）。
library;

class AppBuildConfig {
  AppBuildConfig._();

  /// 读取 String 型 dart-define；未提供时返回 [defaultValue]。
  static String getString(String key, {required String defaultValue}) {
    // dart-define 在编译期注入，运行时读取（const 无法用运行时参数，故用 String.fromEnvironment 的非 const 形式）。
    final fromEnv = String.fromEnvironment(key);
    return fromEnv.isEmpty ? defaultValue : fromEnv;
  }

  /// 读取 bool 型 dart-define；未提供时返回 [defaultValue]。
  ///
  /// 识别 `true`/`1`/`yes`（忽略大小写）为真，`false`/`0`/`no` 为假；
  /// 无法识别的非空值回退 [defaultValue]（避免 `TRUE`/`1.0` 等被静默误判）。
  static bool getBool(String key, {required bool defaultValue}) {
    final raw = String.fromEnvironment(key);
    if (raw.isEmpty) return defaultValue;
    final normalized = raw.trim().toLowerCase();
    if (normalized == 'true' || normalized == '1' || normalized == 'yes') {
      return true;
    }
    if (normalized == 'false' || normalized == '0' || normalized == 'no') {
      return false;
    }
    return defaultValue;
  }

  // ---------------------------------------------------------------------------
  // 已声明的 dart-define 键
  // ---------------------------------------------------------------------------

  /// 云同步配置（supabase）。未提供时应用完全离线运行（与老项目一致）。
  static const supabaseUrlKey = 'SUPABASE_URL';
  static const supabaseAnonKeyKey = 'SUPABASE_ANON_KEY';

  /// 更新清单 URL（默认指向本仓库 raw.githubusercontent，可覆盖）。
  static const updateManifestUrlKey = 'UPDATE_MANIFEST_URL';
}
