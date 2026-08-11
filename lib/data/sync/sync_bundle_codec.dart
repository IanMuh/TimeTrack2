import 'dart:convert';

import 'sync_bundle.dart';

/// SyncBundle 编解码（LAN / 文件互通共用）。
///
/// - encode：2 空格缩进 pretty JSON（明文，含备注/时间戳/设备信息——文档化）
/// - decode：顶层必须对象；`schema_version` 必须在 1..2 否则拒绝（不做迁移）；
///   必填字段校验先于任何写库（解析失败不落库）
class SyncBundleCodec {
  const SyncBundleCodec();

  /// 编码为 pretty JSON 文本（UTF-8）。
  String encode(SyncBundle bundle) {
    return const JsonEncoder.withIndent('  ').convert(bundle.toJson());
  }

  /// 解码：校验 schema_version 与顶层结构；失败抛 [FormatException]。
  SyncBundle decode(String text) {
    final decoded = jsonDecode(text);
    if (decoded is! Map<String, Object?>) {
      throw const FormatException('同步包顶层必须是 JSON 对象');
    }
    final rawVersion = decoded['schema_version'];
    if (rawVersion is! num) {
      throw const FormatException('同步包缺少合法 schema_version');
    }
    final schemaVersion = rawVersion.toInt();
    if (schemaVersion < SyncBundle.minSchemaVersion ||
        schemaVersion > SyncBundle.maxSchemaVersion) {
      throw FormatException(
        '同步包 schema 版本 $schemaVersion 不受支持'
        '（支持 ${SyncBundle.minSchemaVersion}..${SyncBundle.maxSchemaVersion}）',
      );
    }
    return SyncBundle.fromJson(decoded);
  }
}
