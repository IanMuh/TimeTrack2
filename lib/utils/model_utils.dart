/// 模型序列化辅助：布尔/字符串/整数/时间字段的容错读取。
///
/// 反序列化（fromMap）遵循"缺键容错"：任何字段缺失或类型非法都不抛异常，
/// 而是回退到安全默认值——保证同步包 / 文件互通中遇到缺字段、旧版数据时不崩溃。
/// 例外：语义上必填的字段（如 `id`、`start_at`、`version`）由各模型自行严格校验并抛
/// [FormatException]。
library;

/// 读取布尔字段：兼容 bool、0/1 数字与 null；无法识别时返回 false。
bool readBool(Object? value) {
  if (value is bool) return value;
  if (value is num) return value != 0;
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

/// 读取整数字段：兼容 int、num（截断取整）与 null；无法识别时回退 [fallback]。
int readInt(Object? value, {int fallback = 0}) {
  if (value is int) return value;
  if (value is num) return value.toInt();
  return fallback;
}

/// 读取可空整数字段：兼容 int、num 与 null；无法识别时返回 null。
int? readNullableInt(Object? value) {
  if (value is int) return value;
  if (value is num) return value.toInt();
  return null;
}

/// 读取日期时间字段：仅接受 String（ISO8601，含 UTC），转为本地时区。
///
/// 缺键或值非法时返回 [fallback]（默认 `DateTime.now()`），保持缺键容错。
/// 注意：对于"值非法时必须为 null"的可空字段，请用 [readNullableDateTime]。
DateTime readDateTime(Object? value, {DateTime? fallback}) {
  if (value is String) {
    final parsed = DateTime.tryParse(value);
    if (parsed != null) return parsed.toLocal();
  }
  return fallback ?? DateTime.now();
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
