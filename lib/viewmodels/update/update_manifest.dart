import '../../utils/model_utils.dart';

/// 更新清单类型（纯类型，零 Flutter 依赖）。
///
/// 对应仓库根 `update.json`（raw.githubusercontent 拉取，规避 Releases API
/// 60 req/h 限额）。容错约定：语义必填字段（version、平台产物 url/sha256）非法时抛
/// [FormatException]；可选字段（required/releaseNotes/size）缺键或类型非法回退默认。
class UpdateManifest {
  const UpdateManifest({
    required this.version,
    this.required = false,
    this.releaseNotes = '',
    this.windows,
    this.android,
  });

  /// 清单版本号（SemVer 字符串，如 `1.2.3` / `1.2.3-pre.1`）；
  /// 语义比较由 `utils/app_version.dart` 完成。
  final String version;

  /// 强制更新：true 时不可跳过。
  final bool required;
  final String releaseNotes;

  /// 各平台产物；缺平台则对应平台不可更新。
  final UpdatePlatformArtifact? windows;
  final UpdatePlatformArtifact? android;

  Map<String, Object?> toMap() {
    return {
      'version': version,
      'required': required ? 1 : 0,
      'release_notes': releaseNotes,
      'windows': windows?.toMap(),
      'android': android?.toMap(),
    };
  }

  static UpdateManifest fromMap(Map<String, Object?> map) {
    final version = map['version'];
    if (version is! String || version.trim().isEmpty) {
      throw const FormatException('UpdateManifest.fromMap: version 缺失或非法');
    }
    return UpdateManifest(
      version: version.trim(),
      required: readBool(map['required']),
      releaseNotes: readString(map['release_notes']),
      windows: _artifactFromMap(map['windows']),
      android: _artifactFromMap(map['android']),
    );
  }

  /// 解析平台产物：null 表示该平台未提供；非 null 非 Map 视为非法清单抛错
  /// （不静默当成"无更新"，避免掩盖远端数据损坏）。
  static UpdatePlatformArtifact? _artifactFromMap(Object? value) {
    if (value == null) return null;
    if (value is! Map<String, Object?>) {
      throw const FormatException('UpdateManifest: 平台产物必须是对象');
    }
    final url = value['url'];
    final sha256 = value['sha256'];
    if (url is! String || url.isEmpty || sha256 is! String || sha256.isEmpty) {
      throw const FormatException('UpdateManifest: 平台产物缺 url 或 sha256');
    }
    return UpdatePlatformArtifact(
      url: url,
      sha256: _normalizeSha256(sha256),
      size: readNullableInt(value['size']),
    );
  }

  /// SHA-256 归一化：小写 hex（64 字符），非法格式抛错（快速失败，避免下载后校验才发现）。
  static String _normalizeSha256(String value) {
    final normalized = value.trim().toLowerCase();
    if (!RegExp(r'^[0-9a-f]{64}$').hasMatch(normalized)) {
      throw FormatException('UpdateManifest: sha256 非法（应为 64 位 hex）');
    }
    return normalized;
  }
}

/// 单平台更新产物：下载地址 + SHA-256（hex，小写归一）+ 可选字节数。
class UpdatePlatformArtifact {
  const UpdatePlatformArtifact({
    required this.url,
    required this.sha256,
    this.size,
  });

  final String url;
  final String sha256;
  final int? size;

  Map<String, Object?> toMap() {
    return {
      'url': url,
      'sha256': sha256,
      'size': size,
    };
  }
}
