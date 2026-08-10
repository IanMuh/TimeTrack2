import 'package:flutter_test/flutter_test.dart';
import 'package:timetrack2/viewmodels/update/update_manifest.dart';

/// 64 位小写 hex sha256 fixture（多个用例共用，避免重复内联）。
const _sha256 = 'abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789';

void main() {
  group('UpdateManifest', () {
    test('完整清单解析', () {
      final manifest = UpdateManifest.fromMap({
        'version': '1.2.3',
        'required': true,
        'release_notes': '修复若干问题',
        'windows': {
          'url': 'https://example.com/TimeTrack-windows-1.2.3.zip',
          'sha256': _sha256,
          'size': 12345,
        },
        'android': {
          'url': 'https://example.com/TimeTrack-android-1.2.3.apk',
          'sha256': 'DEF0123456789abcdef0123456789abcdef0123456789abcdef0123456789abc',
          'size': 54321,
        },
      });
      expect(manifest.version, '1.2.3');
      expect(manifest.required, isTrue);
      expect(manifest.releaseNotes, '修复若干问题');
      expect(manifest.windows!.url, contains('1.2.3.zip'));
      expect(manifest.windows!.sha256,
          _sha256,
          reason: 'sha256 归一化为小写');
      expect(manifest.windows!.size, 12345);
      expect(manifest.android!.sha256,
          'def0123456789abcdef0123456789abcdef0123456789abcdef0123456789abc');
      expect(manifest.android!.size, 54321);
    });

    test('sha256 归一化：两端混合大小写与空白、两个平台一致', () {
      final manifest = UpdateManifest.fromMap({
        'version': '1.0.0',
        'windows': {
          'url': 'https://example.com/a.zip',
          'sha256': '  ABCDEF0123456789abcdef0123456789ABCDEF0123456789abcdef0123456789  ',
        },
        'android': {
          'url': 'https://example.com/a.apk',
          'sha256': _sha256,
        },
      });
      expect(manifest.windows!.sha256, manifest.android!.sha256);
      // 全部为小写 hex
      expect(manifest.windows!.sha256, manifest.windows!.sha256.toLowerCase());
    });

    test('缺平台字段 / 显式 null：对应平台为 null', () {
      final missing = UpdateManifest.fromMap({
        'version': '1.0.0',
      });
      expect(missing.windows, isNull);
      expect(missing.android, isNull);
      expect(missing.required, isFalse);
      expect(missing.releaseNotes, '');
      // 显式 null 与缺键行为一致（容错语义）
      final explicitNull = UpdateManifest.fromMap({
        'version': '1.0.0',
        'windows': null,
        'android': null,
      });
      expect(explicitNull.windows, isNull);
      expect(explicitNull.android, isNull);
    });

    test('缺版本 / 非法 SemVer → FormatException（消息含 version）', () {
      expect(
        () => UpdateManifest.fromMap(const {}),
        throwsA(isA<FormatException>()
            .having((e) => e.message, 'message', contains('version'))),
      );
      expect(
        () => UpdateManifest.fromMap({'version': '  '}),
        throwsA(isA<FormatException>()
            .having((e) => e.message, 'message', contains('version'))),
      );
      // 非字符串 version
      expect(
        () => UpdateManifest.fromMap({'version': 123}),
        throwsA(isA<FormatException>()
            .having((e) => e.message, 'message', contains('version'))),
      );
      // 非法 SemVer 格式（快速失败，而非等到语义比较才暴露）
      for (final bad in [
        'abc', '1.2', '1.2.3.4', '1.2.3-beta..1', 'v', '01.2.3', '1.02.3',
        '1.2.03', '1.2.3-01', '1.2.3-', '1.2.3+', '1.2.3-pre..1',
        '1.2.3-pre_1', // 下划线标识符非法
      ]) {
        expect(
          () => UpdateManifest.fromMap({'version': bad}),
          throwsA(isA<FormatException>()
              .having((e) => e.message, 'message', contains('version'))),
          reason: '非法版本 $bad 应被拒绝',
        );
      }
      // 合法 SemVer（含 pre-release+build 组合；数值标识符 0 合法但禁前导零；
      // v 前缀按严格 SemVer 拒绝）
      for (final good in [
        '1.2.3', '1.2.3-pre.1', '1.2.3+build.5',
        '1.2.3-pre.1+build.5', '10.0.0-alpha', '1.2.3-0', '1.2.3-0.1',
        '1.2.3+BUILD',
      ]) {
        expect(
          UpdateManifest.fromMap({'version': good}).version,
          good,
          reason: '合法版本 $good 应通过',
        );
      }
      // v 前缀（如 v1.2.3）不是严格 SemVer，拒绝——避免与 1.2.3 产生两套比较语义
      expect(
        () => UpdateManifest.fromMap({'version': 'v1.2.3'}),
        throwsA(isA<FormatException>()
            .having((e) => e.message, 'message', contains('version'))),
      );
    });

    test('非字符串可选字段：容错回退默认，不抛异常', () {
      final manifest = UpdateManifest.fromMap({
        'version': '1.0.0',
        'required': 'true', // 字符串布尔 → 识别为 true（强制更新不因手写 JSON 丢失）
        'release_notes': 123, // 非字符串 → 空串
        'windows': {
          'url': 'https://example.com/a.zip',
          'sha256': _sha256,
          'size': '123', // 非数字 → null
        },
      });
      expect(manifest.required, isTrue);
      expect(manifest.releaseNotes, '');
      expect(manifest.windows!.size, isNull);
    });

    test('负 size → 回退 null', () {
      final manifest = UpdateManifest.fromMap({
        'version': '1.0.0',
        'windows': {
          'url': 'https://example.com/a.zip',
          'sha256': _sha256,
          'size': -100,
        },
      });
      expect(manifest.windows!.size, isNull);
    });

    test('平台产物缺 url/sha256 / 空对象 / 非对象 / 空白 url → FormatException', () {
      // 缺 url
      expect(
        () => UpdateManifest.fromMap({
          'version': '1.0.0',
          'windows': {'sha256': _sha256},
        }),
        throwsA(isA<FormatException>()
            .having((e) => e.message, 'message', contains('url'))),
      );
      // 缺 sha256
      expect(
        () => UpdateManifest.fromMap({
          'version': '1.0.0',
          'windows': {'url': 'https://example.com/a.zip'},
        }),
        throwsA(isA<FormatException>()
            .having((e) => e.message, 'message', contains('sha256'))),
      );
      // 空对象（url、sha256 都缺）
      expect(
        () => UpdateManifest.fromMap({
          'version': '1.0.0',
          'windows': <String, Object?>{},
        }),
        throwsFormatException,
      );
      // android 变体同样校验
      expect(
        () => UpdateManifest.fromMap({
          'version': '1.0.0',
          'android': {'url': 'https://example.com/a.apk'},
        }),
        throwsFormatException,
      );
      // 平台产物是非对象（字符串/数字）→ 抛错而非静默无更新
      expect(
        () => UpdateManifest.fromMap({
          'version': '1.0.0',
          'windows': 'oops',
        }),
        throwsFormatException,
      );
      expect(
        () => UpdateManifest.fromMap({
          'version': '1.0.0',
          'android': 42,
        }),
        throwsFormatException,
      );
      // 空串/纯空白 url → 抛错（产生无效下载链接前快速失败）
      expect(
        () => UpdateManifest.fromMap({
          'version': '1.0.0',
          'windows': {'url': '', 'sha256': _sha256},
        }),
        throwsA(isA<FormatException>()
            .having((e) => e.message, 'message', contains('url'))),
      );
      expect(
        () => UpdateManifest.fromMap({
          'version': '1.0.0',
          'windows': {'url': '   ', 'sha256': _sha256},
        }),
        throwsA(isA<FormatException>()
            .having((e) => e.message, 'message', contains('url'))),
      );
      // 非 http/https scheme 拒绝
      expect(
        () => UpdateManifest.fromMap({
          'version': '1.0.0',
          'windows': {'url': 'file:///tmp/a.zip', 'sha256': _sha256},
        }),
        throwsA(isA<FormatException>()
            .having((e) => e.message, 'message', contains('url'))),
      );
      // 无主机名 / 畸形链接拒绝
      expect(
        () => UpdateManifest.fromMap({
          'version': '1.0.0',
          'windows': {'url': 'https://', 'sha256': _sha256},
        }),
        throwsA(isA<FormatException>()
            .having((e) => e.message, 'message', contains('url'))),
      );
      expect(
        () => UpdateManifest.fromMap({
          'version': '1.0.0',
          'windows': {'url': 'https:///path', 'sha256': _sha256},
        }),
        throwsA(isA<FormatException>()
            .having((e) => e.message, 'message', contains('url'))),
      );
      expect(
        () => UpdateManifest.fromMap({
          'version': '1.0.0',
          'windows': {'url': 'https://exa mple.com/a.zip', 'sha256': _sha256},
        }),
        throwsA(isA<FormatException>()
            .having((e) => e.message, 'message', contains('url'))),
      );
      // 含凭据（userinfo）的链接拒绝——防止下载日志泄露凭据
      expect(
        () => UpdateManifest.fromMap({
          'version': '1.0.0',
          'windows': {'url': 'https://user:pass@example.com/a.zip', 'sha256': _sha256},
        }),
        throwsA(isA<FormatException>()
            .having((e) => e.message, 'message', contains('url'))),
      );
      // scheme 大小写不敏感：合法 HTTP:// 通过
      final upper = UpdateManifest.fromMap({
        'version': '1.0.0',
        'windows': {'url': 'HTTP://EXAMPLE.com/a.zip', 'sha256': _sha256},
      });
      expect(upper.windows!.url, 'HTTP://EXAMPLE.com/a.zip');
    });

    test('sha256 格式非法（长度/非 hex）→ FormatException', () {
      const tooShort = 'abcdef';
      const notHex = 'zzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzz';
      const url = 'https://example.com/a.zip';
      for (final bad in [tooShort, notHex]) {
        expect(
          () => UpdateManifest.fromMap({
            'version': '1.0.0',
            'windows': {'url': url, 'sha256': bad},
          }),
          throwsA(isA<FormatException>()
              .having((e) => e.message, 'message', contains('sha256'))),
        );
      }
    });

    test('toMap round-trip 全字段（required/release_notes/双平台）', () {
      final manifest = UpdateManifest.fromMap({
        'version': '1.2.3',
        'required': true,
        'release_notes': '修复若干问题',
        'windows': {
          'url': 'https://example.com/a.zip',
          'sha256': 'AbCdEf0123456789abcdef0123456789abcdef0123456789abcdef0123456789',
          'size': 10,
        },
        'android': {
          'url': 'https://example.com/a.apk',
          'sha256': '1234567890abcdef1234567890abcdef1234567890abcdef1234567890abcdef',
          'size': 20,
        },
      });
      final restored = UpdateManifest.fromMap(manifest.toMap());
      expect(restored.version, '1.2.3');
      expect(restored.required, isTrue);
      expect(restored.releaseNotes, '修复若干问题');
      expect(restored.windows!.url, 'https://example.com/a.zip');
      expect(restored.windows!.sha256, _sha256);
      expect(restored.windows!.size, 10);
      expect(restored.android!.sha256, '1234567890abcdef1234567890abcdef1234567890abcdef1234567890abcdef');
      expect(restored.android!.size, 20);
      // toMap 输出直断：sha256 已归一化为小写 64 hex（防序列化污染持久化数据）
      final windowsMap = manifest.toMap()['windows'] as Map<String, Object?>;
      expect(windowsMap['sha256'], _sha256);
      final androidMap = manifest.toMap()['android'] as Map<String, Object?>;
      expect(androidMap['sha256'],
          '1234567890abcdef1234567890abcdef1234567890abcdef1234567890abcdef');
      // 可选字段 null size 的写出方式：round-trip 后保持 null
      final noSize = UpdateManifest.fromMap({
        'version': '1.0.0',
        'windows': {'url': 'https://example.com/a.zip', 'sha256': _sha256},
      });
      expect(noSize.windows!.size, isNull);
      expect(
        UpdateManifest.fromMap(noSize.toMap()).windows!.size,
        isNull,
      );
    });
  });
}
