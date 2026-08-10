import '../../utils/model_utils.dart';

/// 更新清单类型（纯类型，零 Flutter 依赖）。
///
/// 对应仓库根 `update.json`（raw.githubusercontent 拉取，规避 Releases API
/// 60 req/h 限额）。容错约定：
/// - 语义必填字段（version、平台产物 url/sha256）非法时抛 [FormatException]（快速失败）；
/// - 可选字段（required/releaseNotes/size）缺键或类型非法回退默认。
/// - 值相等：按 version/required/releaseNotes/双平台产物比较（判断"远端清单相对
///   本地缓存是否有变化"）。
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

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is UpdateManifest &&
          runtimeType == other.runtimeType &&
          version == other.version &&
          required == other.required &&
          releaseNotes == other.releaseNotes &&
          windows == other.windows &&
          android == other.android;

  @override
  int get hashCode => Object.hash(version, required, releaseNotes, windows, android);

  /// 严格 SemVer 格式：主版本号禁止前导零（`(0|[1-9]\d*)`），pre-release 段数字
  /// 标识符同样禁止前导零，build 段为 `[0-9A-Za-z-]` 点分段。**不允许 `v` 前缀**。
  static final _versionPattern = RegExp(
    r'^(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)'
    r'(?:-((?:0|[1-9]\d*|\d*[a-zA-Z-][0-9A-Za-z-]*)(?:\.(?:0|[1-9]\d*|\d*[a-zA-Z-][0-9A-Za-z-]*))*))?'
    r'(?:\+([0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*))?$',
  );

  /// SHA-256：64 位小写 hex。
  static final _sha256Pattern = RegExp(r'^[0-9a-f]{64}$');

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
      windows: _artifactFromMap('windows', map['windows']),
      android: _artifactFromMap('android', map['android']),
    );
  }

  /// 解析平台产物：null 表示该平台未提供；非 null 非 Map 视为非法清单抛错
  /// （不静默当成"无更新"，避免掩盖远端数据损坏）。异常消息携带平台名便于定位。
  static UpdatePlatformArtifact? _artifactFromMap(
    String platform,
    Object? value,
  ) {
    if (value == null) return null;
    if (value is! Map<String, Object?>) {
      throw FormatException(
        'UpdateManifest: $platform 平台产物必须是对象',
      );
    }
    final url = _normalizeUrl(platform, value['url']);
    final sha256 = _normalizeSha256(platform, value['sha256']);
    // size 非负校验：负字节数回退 null（与可选字段容错语义一致）。
    final size = readNullableInt(value['size']);
    return UpdatePlatformArtifact(
      url: url,
      sha256: sha256,
      size: size != null && size >= 0 ? size : null,
    );
  }

  /// url 校验：trim 后必须为可解析的 http/https 链接（含主机名），
  /// scheme 大小写不敏感（Uri.tryParse 归一化）。拒绝 file://、相对路径、
  /// 无主机名、含空白字符、含凭据等畸形链接——快速失败，避免下载阶段才暴露
  /// （注：Uri.tryParse 会宽容编码内嵌空格为 %20，故需先显式拒绝空白）。
  static String _normalizeUrl(String platform, Object? value) {
    if (value is! String) {
      throw FormatException('UpdateManifest: $platform 平台产物缺 url');
    }
    final trimmed = value.trim();
    final uri = Uri.tryParse(trimmed);
    final scheme = uri?.scheme.toLowerCase();
    if (trimmed.isEmpty ||
        trimmed.contains(RegExp(r'\s')) ||
        uri == null ||
        uri.userInfo.isNotEmpty ||
        (scheme != 'http' && scheme != 'https') ||
        uri.host.isEmpty) {
      throw FormatException(
        'UpdateManifest: $platform 平台 url 非法（应为 http/https 链接）：$trimmed',
      );
    }
    return trimmed;
  }

  /// SHA-256 归一化：小写 hex（64 字符），非法格式抛错（快速失败，避免下载后校验才发现）。
  static String _normalizeSha256(String platform, Object? value) {
    if (value is! String || value.trim().isEmpty) {
      throw FormatException('UpdateManifest: $platform 平台产物缺 sha256');
    }
    final normalized = value.trim().toLowerCase();
    if (!_sha256Pattern.hasMatch(normalized)) {
      throw FormatException(
        'UpdateManifest: $platform 平台 sha256 非法（应为 64 位 hex）',
      );
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

  /// 值相等：按 url/sha256/size 比较。
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is UpdatePlatformArtifact &&
          runtimeType == other.runtimeType &&
          url == other.url &&
          sha256 == other.sha256 &&
          size == other.size;

  @override
  int get hashCode => Object.hash(url, sha256, size);

  Map<String, Object?> toMap() {
    return {
      'url': url,
      'sha256': sha256,
      'size': size,
    };
  }
}
