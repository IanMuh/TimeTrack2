import 'package:flutter_test/flutter_test.dart';
import 'package:timetrack2/utils/app_version.dart';

void main() {
  group('AppVersion.parse', () {
    test('合法版本解析', () {
      expect(AppVersion.parse('1.2.3').toString(), '1.2.3');
      expect(AppVersion.parse('v1.2.3').toString(), '1.2.3', reason: 'v 前缀容忍');
      expect(AppVersion.parse('1.2.3-pre.1').toString(), '1.2.3-pre.1');
      expect(AppVersion.parse('1.2.3+build.5').toString(), '1.2.3+build.5');
      expect(
        AppVersion.parse('1.2.3-pre.1+build.5').toString(),
        '1.2.3-pre.1+build.5',
      );
      expect(AppVersion.parse('10.0.0-alpha').major, 10);
      // 组件直接断言（防 toString 往返掩盖字段错位）
      final parsed = AppVersion.parse('1.2.3-pre.1+build.5');
      expect(parsed.major, 1);
      expect(parsed.minor, 2);
      expect(parsed.patch, 3);
      expect(parsed.prerelease, 'pre.1');
      expect(parsed.buildMetadata, 'build.5');
    });

    test('非法版本抛 FormatException', () {
      for (final bad in [
        '', 'abc', '1.2', '1.2.3.4', '1.2.3-beta..1', '01.2.3', '1.02.3',
        '1.2.03', '1.2.3-01', '1.2.3-', '1.2.3+', '1.2.3-pre_1',
        '1.2.3-pre..1',
      ]) {
        expect(() => AppVersion.parse(bad), throwsFormatException,
            reason: '$bad 应被拒绝');
      }
    });

    test('容忍首尾空白（与老项目一致，先 trim 再校验）', () {
      expect(AppVersion.parse(' 1.2.3 ').toString(), '1.2.3');
      expect(() => AppVersion.parse('   '), throwsFormatException,
          reason: '纯空白 trim 后应为非法');
      // SemVer 边界：纯 0 数字标识符合法（仅前导零非法）；build 元数据允许前导零
      expect(AppVersion.parse('1.0.0-0').toString(), '1.0.0-0');
      expect(AppVersion.parse('1.2.3+build.01').toString(), '1.2.3+build.01');
    });
  });

  group('AppVersion 比较（SemVer 规则）', () {
    AppVersion v(String s) => AppVersion.parse(s);

    test('主版本优先，其次次版本、修订', () {
      expect(v('2.0.0') > v('1.9.9'), isTrue);
      expect(v('1.10.0') > v('1.9.0'), isTrue);
      expect(v('1.2.3') > v('1.2.2'), isTrue);
      expect(v('1.2.3') == v('1.2.3'), isTrue);
      expect(v('1.2.3') == v('1.2.3+build'), isTrue,
          reason: 'build 元数据不影响比较/相等');
    });

    test('pre-release 规则', () {
      // 无 prerelease > 有 prerelease
      expect(v('1.0.0') > v('1.0.0-alpha'), isTrue);
      expect(v('1.0.0-alpha') < v('1.0.0'), isTrue);
      // 数字标识符按数值比较
      expect(v('1.0.0-2') > v('1.0.0-10'), isFalse,
          reason: '数字按数值而非字典序：2 < 10');
      expect(v('1.0.0-2') < v('1.0.0-10'), isTrue,
          reason: '数字按数值而非字典序：2 < 10');
      // 符号不被误判为数字（`-1` 是字母数字标识符，非负数）
      expect(v('1.0.0-0') < v('1.0.0--0'), isTrue,
          reason: '数字标识符 0 优先级低于字母数字标识符 -0');
      // 超大数字标识符（超出 int 范围）按数值比较
      expect(v('1.0.0-99999999999999999999') <
          v('1.0.0-1000000000000000000000'), isTrue);
      // 数字 < 字母数字标识符
      expect(v('1.0.0-1') < v('1.0.0-a'), isTrue);
      // 字母数字按字典序
      expect(v('1.0.0-alpha') < v('1.0.0-beta'), isTrue);
      // 标识符更多则更大（1.0.0-alpha.1 > 1.0.0-alpha）
      expect(v('1.0.0-alpha.1') > v('1.0.0-alpha'), isTrue);
      // 等长逐段比较
      expect(v('1.0.0-alpha.beta') < v('1.0.0-beta.alpha'), isTrue);
    });

    test('操作符', () {
      expect(v('1.0.0') <= v('1.0.0'), isTrue);
      expect(v('1.0.0') >= v('1.0.0'), isTrue);
      expect(v('1.0.1') >= v('1.0.0'), isTrue);
      expect(v('1.0.0-pre') < v('1.0.0'), isTrue);
    });
  });

  group('AppVersion 值相等', () {
    test('同版本相等、build 不影响', () {
      expect(AppVersion.parse('1.2.3'), AppVersion.parse('1.2.3'));
      expect(AppVersion.parse('1.2.3') == AppVersion.parse('1.2.3+b1'), isTrue);
      expect(AppVersion.parse('1.2.3-pre') == AppVersion.parse('1.2.3'), isFalse);
      expect(
        AppVersion.parse('1.2.3').hashCode,
        AppVersion.parse('1.2.3').hashCode,
      );
      // == 相等时必须 hashCode 一致（build 被两者忽略）
      expect(
        AppVersion.parse('1.2.3').hashCode,
        AppVersion.parse('1.2.3+b1').hashCode,
      );
    });
  });
}
