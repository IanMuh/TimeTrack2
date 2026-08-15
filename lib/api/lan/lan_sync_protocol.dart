/// LAN 同步协议：端点、错误码、响应包络与主机名校验（纯函数可单测）。
///
/// 传输：dart:io HttpServer/HttpClient + JSON 对象（UTF-8）。
/// 端点：`GET /health`（连通性）、`POST /pair`（配对换 token）、
/// `POST /sync`（Bearer token 鉴权，全量 bundle 对等交换）。
/// 响应包络统一 `{"ok": true, ...}` / `{"ok": false, "error": {...}}`。
/// 超时 8s（`AppConstants.lanRequestTimeout`）；请求/响应体上限
/// `AppConstants.lanMaxPayloadBytes`（防内存耗尽）。
library;

import 'dart:io';

/// LAN 同步端点路径。
abstract final class LanSyncEndpoints {
  static const health = '/health';
  static const pair = '/pair';
  static const sync = '/sync';

  /// Authorization 头名与 Bearer 前缀。
  static const authorizationHeader = 'Authorization';
  static const bearerPrefix = 'Bearer ';
}

/// LAN 同步错误码（协议级）。[LanSyncException.statusCode] 为对应的
/// HTTP 状态码；`network`/`timeout` 为客户端侧错误，无 HTTP 状态。
///
/// `wireValue` 为线上传输值（snake_case，与项目存储键约定一致），
/// 由 [LanSyncErrorCode.fromWireValue] 反查。
enum LanSyncErrorCode {
  /// 请求非法（JSON 解析失败、缺字段等）→ 400。
  invalidRequest('invalid_request'),

  /// 配对码错误 → 401。
  invalidCode('invalid_code'),

  /// 配对码过期 → 401。
  codeExpired('code_expired'),

  /// 未授权（token 缺失/非法）→ 401。
  unauthorized('unauthorized'),

  /// 请求体超过大小上限 → 413。
  payloadTooLarge('payload_too_large'),

  /// 限流 → 429。
  rateLimited('rate_limited'),

  /// 服务器内部错误 → 500。
  serverError('server_error'),

  /// 客户端网络错误（连接失败/中断）→ 无 HTTP 状态。
  network('network'),

  /// 客户端超时 → 无 HTTP 状态。
  timeout('timeout');

  const LanSyncErrorCode(this.wireValue);

  final String wireValue;

  /// 反查错误码；未知值回退 [LanSyncErrorCode.serverError]（跨版本兼容：
  /// 旧主机可能返回新码，客户端不认识时不崩溃；交互影响见
  /// [LanSyncException.statusCode] 文档）。
  static LanSyncErrorCode fromWireValue(String value) {
    return LanSyncErrorCode.values.firstWhere(
      (code) => code.wireValue == value,
      orElse: () => LanSyncErrorCode.serverError,
    );
  }
}

/// LAN 同步错误码 → HTTP 状态码（无 HTTP 语义的客户端侧错误为 null）。
int? httpStatusFor(LanSyncErrorCode code) {
  return switch (code) {
    LanSyncErrorCode.invalidRequest => HttpStatus.badRequest,
    LanSyncErrorCode.invalidCode => HttpStatus.unauthorized,
    LanSyncErrorCode.codeExpired => HttpStatus.unauthorized,
    LanSyncErrorCode.unauthorized => HttpStatus.unauthorized,
    LanSyncErrorCode.payloadTooLarge => HttpStatus.requestEntityTooLarge,
    LanSyncErrorCode.rateLimited => HttpStatus.tooManyRequests,
    LanSyncErrorCode.serverError => HttpStatus.internalServerError,
    LanSyncErrorCode.network || LanSyncErrorCode.timeout => null,
  };
}

/// LAN 同步异常（协议错误；客户端解析响应/服务器处理失败时抛出/返回）。
class LanSyncException implements Exception {
  const LanSyncException(this.code, this.message, {this.statusCode});

  final LanSyncErrorCode code;
  final String message;

  /// 服务器侧错误对应的 HTTP 状态；`network`/`timeout` 为 null。
  final int? statusCode;

  @override
  String toString() => 'LanSyncException(${code.name}): $message';
}

/// 成功包络：`{"ok": true, ...data}`。
///
/// `ok` 放展开之后：`data` 中若含 `ok` 键不会覆盖成功标记（协议一致性：
/// 成功包络的 `ok` 恒为 `true`，`parseEnvelope` 才可依赖该字段判定）。
Map<String, Object?> okEnvelope([Map<String, Object?> data = const {}]) {
  return {...data, 'ok': true};
}

/// 错误包络：`{"ok": false, "error": {"code", "message"}}`。
Map<String, Object?> errorEnvelope(LanSyncErrorCode code, String message) {
  return {
    'ok': false,
    'error': {'code': code.wireValue, 'message': message},
  };
}

/// 解析响应包络：`ok == true` 返回**整个包络**（含 `ok` 键——调用方按需取
/// 业务字段，勿把返回值整体当业务 data 序列化，`ok` 会被一并带出）；
/// 否则抛 [LanSyncException]（错误码/消息取自包络 `error` 字段；缺省回退
/// [LanSyncErrorCode.serverError]；[LanSyncException.statusCode] 由错误码经
/// [httpStatusFor] 推导，调用方可据 401（需重新配对）/429（退避）分流——
/// 未知新错误码回退 serverError 语义，客户端将按"服务器内部错误"处理，
/// 这是跨版本兼容的取舍）。
///
/// 同时校验顶层必须是 JSON 对象（防"非包络"响应被误当成功）。
Map<String, Object?> parseEnvelope(Object? decoded) {
  if (decoded is! Map<String, Object?>) {
    throw const LanSyncException(
      LanSyncErrorCode.invalidRequest,
      'LAN 主机响应不是 JSON 对象',
      statusCode: HttpStatus.badRequest,
    );
  }
  if (decoded['ok'] == true) return decoded;
  final error = decoded['error'];
  final message = error is Map<String, Object?> && error['message'] is String
      ? error['message'] as String
      : 'LAN 主机返回错误';
  final rawCode = error is Map<String, Object?> ? error['code'] : null;
  final code = rawCode is String
      ? LanSyncErrorCode.fromWireValue(rawCode)
      : LanSyncErrorCode.serverError;
  throw LanSyncException(code, message, statusCode: httpStatusFor(code));
}

// ---------------------------------------------------------------------------
// 私网白名单（客户端手动输入 IP 的准入校验）
// ---------------------------------------------------------------------------

/// 校验主机名是否为允许的 LAN 主机（纯函数，可单测）。
///
/// 允许：`localhost` / `::1`（含 IPv6 回环等价形式 `::0:1` 等）、`.local` 结尾
/// mDNS 主机名（含 FQDN 尾点 `mypc.local.`，先剥尾点再判定）、IPv4 私网段
/// （10/8、172.16-31/12、192.168/16、127/8 回环、169.254/16 链路本地）、
/// IPv6 链路本地（fe80::/10）与 ULA（fc00::/7）、IPv4 映射地址（::ffff:a.b.c.d
/// 且 a.b.c.d 为私网——双栈系统解析主机名时可能出现）。
/// 其余一律拒绝——公网 IP 与非 `.local` 主机名不可作为 LAN 同步对端
/// （防误连公网主机）。
bool isPrivateNetworkHost(String host) {
  var normalized = host.trim().toLowerCase();
  if (normalized.isEmpty) return false;
  // FQDN 尾点（`mypc.local.`）：剥离后再判定，与无尾点形式一致放行。
  if (normalized.endsWith('.')) {
    normalized = normalized.substring(0, normalized.length - 1);
    if (normalized.isEmpty) return false;
  }
  if (normalized == 'localhost' || normalized == '::1') return true;
  if (normalized.endsWith('.local')) return true;

  final address = InternetAddress.tryParse(normalized);
  if (address == null) return false; // 非 IP 的非 .local 主机名 → 拒绝
  if (address.type == InternetAddressType.IPv4) {
    final octets = address.rawAddress;
    return _isPrivateIpv4(octets[0], octets[1], octets[2], octets[3]);
  }
  // IPv6
  final bytes = address.rawAddress;
  final first16 = (bytes[0] << 8) | bytes[1];
  if ((first16 & 0xffc0) == 0xfe80) return true; // fe80::/10 链路本地
  if ((first16 & 0xfe00) == 0xfc00) return true; // fc00::/7 ULA
  // ::1 回环的等价形式（前 15 字节全 0、末字节 1：`::0:1`、`0:0:...:1` 等）。
  if (bytes.take(15).every((b) => b == 0) && bytes[15] == 1) return true;
  // IPv4 映射地址 ::ffff:a.b.c.d（标准格式：**前 80 位全零** + bytes[10..11] ==
  // ff:ff + 后 4 字节为 IPv4）。只查 bytes[10..11] 会把 2001:db8::ffff:192.168.1.5
  // 这类全局 IPv6 误判为私网——必须校验前 80 位全零。
  if (bytes.take(10).every((b) => b == 0) &&
      bytes[10] == 0xff &&
      bytes[11] == 0xff) {
    return _isPrivateIpv4(bytes[12], bytes[13], bytes[14], bytes[15]);
  }
  return false;
}

/// IPv4 四段私网判定（回环/链路本地/10/8/172.16-31/12/192.168/16 均视为私网）。
bool _isPrivateIpv4(int a, int b, int c, int d) {
  if (a == 10) return true; // 10.0.0.0/8
  if (a == 172 && b >= 16 && b <= 31) return true; // 172.16.0.0/12
  if (a == 192 && b == 168) return true; // 192.168.0.0/16
  if (a == 127) return true; // 127.0.0.0/8 回环
  if (a == 169 && b == 254) return true; // 169.254.0.0/16 链路本地
  return false;
}

/// 归一化用户输入的 LAN 主机：去掉 scheme/路径/尾随斜杠，拆出内嵌端口。
///
/// 返回 `(host, port?)`；输入非法（空/结构错误/端口越界/非 http scheme）
/// 返回 null。
/// 支持：裸 IP/主机名（`192.168.1.5`）、带端口（`192.168.1.5:9000`）、
/// 带 `http://` scheme（`http://192.168.1.5:8787/`）、方括号 IPv6
/// （`[fe80::1]:9000`）。裸 IPv6（多冒号、非方括号，如 `fe80::1`）整体视为主机。
///
/// 安全约束：
/// - **仅接受 `http://` scheme**——显式输入 `https://` 等一律返回 null，
///   不做明文静默降级（LAN 明文协议，伪装 https 只会误导用户对传输安全的预期）。
/// - **本函数只做归一化，不做私网校验**：`8.8.8.8` 等公网主机原样返回。
///   调用方必须对返回值的主机再经 `isPrivateNetworkHost` 校验，并（对主机名）
///   对解析后的真实 IP 二次校验，方可发起连接——避免同步数据/token 发往公网。
(String, int?)? normalizeLanInput(String raw) {
  var text = raw.trim().toLowerCase();
  if (text.isEmpty) return null;

  final schemeIndex = text.indexOf('://');
  if (schemeIndex >= 0) {
    if (schemeIndex == 0 || text.substring(0, schemeIndex) != 'http') {
      return null; // 拒绝 https/ftp 等其他 scheme，防明文静默降级
    }
    text = text.substring(schemeIndex + 3);
  } else if (text.startsWith('http:')) {
    // **缺 `//` 的 scheme 前缀（r 修复）**：`http:192.168.1.5:9000` 会被
    // 下方冒号计数误判为 `host:port:…`（或裸 IPv6）原样放行——显式剥离
    // `http:` 前缀，使其与 `http://` 形态走同一归一化路径。
    text = text.substring('http:'.length);
  } else if (_schemePrefixRe.hasMatch(text) &&
      ':'.allMatches(text).length >= 2 &&
      !_isIpv6Like(text) &&
      !_schemePrefixHasDot(text)) {
    // 其它 scheme 前缀（https:/ftp:/ws: 等）明确拒绝（防明文静默降级）。
    // **仅多冒号形态（r 复审修正）**：单冒号 `localhost:9000` 的 `localhost`
    // 同样匹配 scheme 正则，但属合法 host:port（走下方 colonCount==1 分支）——
    // 只有 ≥2 冒号（`https:192.168.1.5:9000`）才可能被误判为裸 IPv6 放行，
    // 须拒绝。**两类排除**：
    // - **裸 IPv6**（`fe80::1` 的 `fe80:` 匹配 scheme 正则但属合法主机）；
    // - **含点前缀**（`mypc.local:9000` 的 `mypc.local` 是 FQDN 主机名）。
    return null;
  }
  // 截断到路径/query/fragment 中最早出现的位置（`/`、`?`、`#` 任一即停）。
  var endIndex = -1;
  for (final marker in ['/', '?', '#']) {
    final index = text.indexOf(marker);
    if (index >= 0 && (endIndex < 0 || index < endIndex)) endIndex = index;
  }
  if (endIndex >= 0) text = text.substring(0, endIndex);
  if (text.isEmpty) return null; // 剥离 scheme/路径/query 后变空 → 非法
  // userinfo（user:pass@host）不是合法主机结构：明确拒绝，防被当作裸 IPv6
  // 整体主机而绕过校验。
  if (text.contains('@')) return null;

  // 方括号 IPv6（[addr] 或 [addr]:port）
  if (text.startsWith('[')) {
    final close = text.indexOf(']');
    if (close < 0) return null;
    final host = text.substring(1, close);
    if (host.isEmpty) return null;
    final rest = text.substring(close + 1);
    if (rest.isEmpty) return (host, null);
    if (!rest.startsWith(':')) return null;
    final port = _parseLanPort(rest.substring(1));
    return port == null ? null : (host, port);
  }

  final colonCount = ':'.allMatches(text).length;
  if (colonCount == 1) {
    // host:port（裸 IPv6 恒 ≥2 个冒号，不会误拆）
    final separator = text.lastIndexOf(':');
    final host = text.substring(0, separator);
    final port = _parseLanPort(text.substring(separator + 1));
    if (host.isEmpty) return null;
    return port == null ? null : (host, port);
  }
  if (colonCount > 1) return (text, null); // 裸 IPv6 整体为主机
  return (text, null);
}

/// 纯数字端口正则（复用，防每次解析重新编译）。
final _lanPortRe = RegExp(r'^[0-9]+$');

/// scheme 前缀正则（RFC 3986 scheme 字符集；用于识别 `https:`/`ftp:` 等
/// 非 http scheme 前缀）。
final _schemePrefixRe = RegExp(r'^[a-z][a-z0-9+.-]*:');

/// 是否为**裸 IPv6 形态**（非方括号、含多个冒号，如 `fe80::1`）——scheme
/// 前缀判定须排除（`fe80:` 匹配 scheme 正则但属合法 IPv6 主机）。
/// **收紧判定（r 复审修正）**：IPv6 字面量只含十六进制数字与冒号——`https:
/// 192.168.1.5:9000` 虽含 2 冒号但含 `s/t/p` 与点号，不是 IPv6，须按 scheme
/// 前缀拒绝。
bool _isIpv6Like(String text) {
  final colonCount = ':'.allMatches(text).length;
  return colonCount >= 2 &&
      !text.startsWith('[') &&
      _ipv6CharsRe.hasMatch(text);
}

/// 裸 IPv6 字符合法集（十六进制数字 + 冒号 + 可能的 IPv4 尾段点）。
final _ipv6CharsRe = RegExp(r'^[0-9a-f:.]+$');

/// scheme 前缀是否含点（`mypc.local.` 的 `mypc.local` 是 FQDN 尾点主机名而非
/// scheme——RFC 3986 scheme 为无点的单 label）。
bool _schemePrefixHasDot(String text) {
  final colon = text.indexOf(':');
  if (colon < 0) return false;
  return text.substring(0, colon).contains('.');
}

/// 解析端口：严格 1..65535 且纯数字（拒绝 `+80`、`0x50`、空串、负数、
/// `65536` 越界）。
int? _parseLanPort(String raw) {
  if (raw.isEmpty || !_lanPortRe.hasMatch(raw)) return null;
  final port = int.tryParse(raw);
  if (port == null || port < 1 || port > 65535) return null;
  return port;
}
