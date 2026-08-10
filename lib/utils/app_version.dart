/// 语义版本（SemVer 2.0.0）：解析、比较（含 pre-release 规则）。
///
/// 用于更新系统版本比较（`update.json` 的 `version` 与本地应用版本）。
/// 老项目语义等价：主.次.修订 + 可选 pre-release + 可选 build 元数据，
/// 比较忽略 build 元数据，pre-release 按 SemVer 规范排序。
library;

/// 语义版本号。
class AppVersion implements Comparable<AppVersion> {
  const AppVersion({
    required this.major,
    required this.minor,
    required this.patch,
    this.prerelease,
    this.buildMetadata,
  }) : assert(major >= 0),
       assert(minor >= 0),
       assert(patch >= 0);

  final int major;
  final int minor;
  final int patch;
  final String? prerelease;
  final String? buildMetadata;

  bool get isPrerelease => prerelease != null && prerelease!.isNotEmpty;

  /// 归一化 prerelease：空串视为 null（`==`/`hashCode`/`toString`/`compareTo`
  /// 统一按此处理，避免空串与 null 在契约中不一致）。
  String? get normalizedPrerelease =>
      (prerelease == null || prerelease!.isEmpty) ? null : prerelease;

  /// 解析 SemVer 字符串（可选 `v` 前缀；严格拒绝前导零）。
  /// 格式非法抛 [FormatException]。
  static AppVersion parse(String value) {
    final match = _pattern.firstMatch(value.trim());
    if (match == null) {
      throw FormatException('Invalid semantic version', value);
    }
    return AppVersion(
      major: int.parse(match.group(1)!),
      minor: int.parse(match.group(2)!),
      patch: int.parse(match.group(3)!),
      prerelease: match.group(4),
      buildMetadata: match.group(5),
    );
  }

  /// 严格 SemVer：主版本号无前导零，pre-release 段数字标识符同样禁前导零。
  static final _pattern = RegExp(
    r'^v?(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)'
    r'(?:-((?:0|[1-9]\d*|\d*[a-zA-Z-][0-9A-Za-z-]*)(?:\.(?:0|[1-9]\d*|\d*[a-zA-Z-][0-9A-Za-z-]*))*))?'
    r'(?:\+([0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*))?$',
  );

  @override
  int compareTo(AppVersion other) {
    final majorCompare = major.compareTo(other.major);
    if (majorCompare != 0) return majorCompare;
    final minorCompare = minor.compareTo(other.minor);
    if (minorCompare != 0) return minorCompare;
    final patchCompare = patch.compareTo(other.patch);
    if (patchCompare != 0) return patchCompare;
    return _comparePrerelease(prerelease, other.prerelease);
  }

  bool operator <(AppVersion other) => compareTo(other) < 0;
  bool operator <=(AppVersion other) => compareTo(other) <= 0;
  bool operator >(AppVersion other) => compareTo(other) > 0;
  bool operator >=(AppVersion other) => compareTo(other) >= 0;

  @override
  String toString() {
    final buffer = StringBuffer('$major.$minor.$patch');
    if (isPrerelease) buffer.write('-$prerelease');
    if (buildMetadata != null && buildMetadata!.isNotEmpty) {
      buffer.write('+$buildMetadata');
    }
    return buffer.toString();
  }

  /// 值相等：比较 major/minor/patch/normalizedPrerelease（build 元数据不影响；
  /// 空串 prerelease 与 null 视为相同，与 compareTo 契约一致）。
  @override
  bool operator ==(Object other) {
    return other is AppVersion &&
        runtimeType == other.runtimeType &&
        major == other.major &&
        minor == other.minor &&
        patch == other.patch &&
        normalizedPrerelease == other.normalizedPrerelease;
  }

  @override
  int get hashCode =>
      Object.hash(runtimeType, major, minor, patch, normalizedPrerelease);
}

/// SemVer pre-release 比较：无 prerelease 的版本更高；数字标识符按数值
/// （用"纯数字"判定 + 长度/字典序，避免符号与溢出误判）、数字 < 字母数字、
/// 其余按字典序、分段依次比较。
int _comparePrerelease(String? left, String? right) {
  final leftEmpty = left == null || left.isEmpty;
  final rightEmpty = right == null || right.isEmpty;
  if (leftEmpty) return rightEmpty ? 0 : 1;
  if (rightEmpty) return -1;

  final leftParts = left.split('.');
  final rightParts = right.split('.');
  final length = leftParts.length < rightParts.length
      ? leftParts.length
      : rightParts.length;
  for (var index = 0; index < length; index += 1) {
    final result = _comparePrereleasePart(leftParts[index], rightParts[index]);
    if (result != 0) return result;
  }
  return leftParts.length.compareTo(rightParts.length);
}

final _numericIdentifierPattern = RegExp(r'^[0-9]+$');

int _comparePrereleasePart(String left, String right) {
  final leftNumeric = _numericIdentifierPattern.hasMatch(left);
  final rightNumeric = _numericIdentifierPattern.hasMatch(right);
  if (leftNumeric && rightNumeric) {
    // 纯数字标识符：长度不同时更长者数值更大（无前导零时等价于数值比较），
    // 长度相同按字典序（即数值序）。避免 int.tryParse 的符号误判与溢出。
    final lengthCompare = left.length.compareTo(right.length);
    return lengthCompare != 0 ? lengthCompare : left.compareTo(right);
  }
  if (leftNumeric) return -1; // 数字标识符 < 字母数字标识符
  if (rightNumeric) return 1;
  return left.compareTo(right);
}
