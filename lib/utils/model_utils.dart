/// 模型序列化辅助：布尔/字符串/整数/时间字段的容错读取。
///
/// 反序列化（fromMap）遵循"缺键容错"：非必填字段缺失或类型非法都不抛异常，
/// 而是回退到安全默认值——保证同步包 / 文件互通中遇到缺字段、旧版数据时不崩溃。
/// 例外：
/// - 语义必填字段（`id`、`start_at`、`updated_at`、`occurred_at`、`version`）由各模型
///   严格校验并抛 [FormatException]，**绝不伪造时间戳**（避免损坏数据被误判为"刚刚更新"
///   而在 LWW 冲突中胜出，或被 `toMap` 写回污染原始数据）。
/// - 时间读取：需要默认值时显式传 `fallback`；不传且缺键/非法 → 抛 [FormatException]。
library;

/// 读取布尔字段：兼容 bool、有限数字（0/1）、`'true'`/`'false'`（忽略大小写/空白）与 null。
/// 非有限数字（NaN/±Infinity）与无法识别的值一律回退 false。
bool readBool(Object? value) {
  if (value is bool) return value;
  if (value is num && value.isFinite) return value != 0;
  if (value is String) {
    final text = value.trim().toLowerCase();
    if (text == 'true') return true;
    if (text == 'false') return false;
  }
  return false;
}

/// 读取字符串字段：非 String 值（含 null）回退 [fallback]（默认空串）。
String readString(Object? value, {String fallback = ''}) {
  return value is String ? value : fallback;
}

/// 读取可空字符串字段：非 String 值（含 null）返回 null。
String? readNullableString(Object? value) {
  return value is String ? value : null;
}

/// 读取整数字段：兼容 int、num（向零截断取整）与 null；无法识别或非有限数
/// （NaN/±Infinity）回退 [fallback]。
int readInt(Object? value, {int fallback = 0}) {
  if (value is int) return value;
  if (value is num && value.isFinite) return value.toInt();
  return fallback;
}

/// 读取可空整数字段：兼容 int、num 与 null；无法识别或非有限数返回 null。
int? readNullableInt(Object? value) {
  if (value is int) return value;
  if (value is num && value.isFinite) return value.toInt();
  return null;
}

/// 读取日期时间字段：仅接受 String（ISO8601，含 UTC），转为本地时区。
///
/// 缺键、非 String 或不可解析时：显式传了 [fallback] 则回退之；否则抛
/// [FormatException]——**默认绝不回退当前时间**，防止伪造时间戳污染同步/冲突判定。
DateTime readDateTime(Object? value, {DateTime? fallback}) {
  if (value is String) {
    final parsed = DateTime.tryParse(value);
    if (parsed != null) return parsed.toLocal();
  }
  if (fallback != null) return fallback;
  throw const FormatException('readDateTime: 时间字段缺失或非法');
}

/// 读取可空日期时间字段：null / 非 String / 不可解析的值一律返回 null，
/// 绝不伪造时间戳——避免把损坏数据误判为"已删除/运行中"。
DateTime? readNullableDateTime(Object? value) {
  if (value is String) {
    final parsed = DateTime.tryParse(value);
    return parsed?.toLocal();
  }
  return null;
}
