import '../../utils/model_utils.dart';

/// 更新清单类型（纯类型，零 Flutter 依赖）。
///
/// 对应仓库根 `update.json`（raw.githubusercontent 拉取，规避 Releases API
/// 60 req/h 限额）。容错约定：
/// - 语义必填字段（version、平台产物 url/sha256）非法时抛 [FormatException]（快速失败）；
/// - 可选字段（required/releaseNotes/size）缺键或类型非法回退默认。
///
/// 注意：公开 const 构造函数不做运行时校验（const 限制），请一律通过
/// [UpdateManifest.fromMap] 构造；直接构造需自行保证 version/sha256/url 合法。
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

  /// SemVer 格式（允许可选 `v` 前缀；pre-release/build 段按 `.` 分段，
  /// 每段非空且仅含 `[0-9A-Za-z-]`——拒绝连续点/空标识符/尾点）。
  static final _versionPattern = RegExp(
    r'^v?\d+\.\d+\.\d+'
    r'(?:-([0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*))?'
    r'(?:\+([0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*))?$',
  );

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
    final trimmed = version.trim();
    if (!_versionPattern.hasMatch(trimmed)) {
      throw FormatException(
        'UpdateManifest.fromMap: version 不是合法 SemVer：$trimmed',
      );
    }
    return UpdateManifest(
      version: trimmed,
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
    final url = _normalizeUrl(value['url']);
    final sha256 = _normalizeSha256(value['sha256']);
    // size 非负校验：负字节数回退 null（与可选字段容错语义一致）。
    final size = readNullableInt(value['size']);
    return UpdatePlatformArtifact(
      url: url,
      sha256: sha256,
      size: size != null && size >= 0 ? size : null,
    );
  }

  /// url 校验：trim 后必须为非空 http/https 链接（防 file://、相对路径等）。
  static String _normalizeUrl(Object? value) {
    if (value is! String) {
      throw const FormatException('UpdateManifest: 平台产物缺 url');
    }
    final trimmed = value.trim();
    if (trimmed.isEmpty || !trimmed.startsWith('http://') && !trimmed.startsWith('https://')) {
      throw FormatException('UpdateManifest: url 非法（应为 http/https 链接）：$trimmed');
    }
    return trimmed;
  }

  /// SHA-256 归一化：小写 hex（64 字符），非法格式抛错（快速失败，避免下载后校验才发现）。
  static String _normalizeSha256(Object? value) {
    if (value is! String || value.trim().isEmpty) {
      throw const FormatException('UpdateManifest: 平台产物缺 sha256');
    }
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
