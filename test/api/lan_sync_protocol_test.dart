import 'package:flutter_test/flutter_test.dart';
import 'package:timetrack2/api/lan/lan_sync_protocol.dart';

void main() {
  group('isPrivateNetworkHost（私网白名单）', () {
    test('允许：localhost / 回环 / .local / 私网段（含网络地址与 IPv6 边界）', () {
      // localhost 与本机回环
      expect(isPrivateNetworkHost('localhost'), isTrue);
      expect(isPrivateNetworkHost('127.0.0.1'), isTrue);
      expect(isPrivateNetworkHost('127.255.255.255'), isTrue);
      expect(isPrivateNetworkHost('::1'), isTrue);
      // mDNS 主机名（大小写归一 + FQDN 尾点）
      expect(isPrivateNetworkHost('mypc.local'), isTrue);
      expect(isPrivateNetworkHost('MYPC.LOCAL'), isTrue, reason: '大小写归一');
      expect(isPrivateNetworkHost('mypc.local.'), isTrue,
          reason: 'FQDN 尾点放行（剥尾点后判定）');
      // IPv4 私网段（含网络地址本身）
      expect(isPrivateNetworkHost('10.0.0.0'), isTrue);
      expect(isPrivateNetworkHost('10.0.0.1'), isTrue);
      expect(isPrivateNetworkHost('10.255.255.255'), isTrue);
      expect(isPrivateNetworkHost('172.16.0.0'), isTrue);
      expect(isPrivateNetworkHost('172.16.0.1'), isTrue);
      expect(isPrivateNetworkHost('172.31.255.255'), isTrue);
      expect(isPrivateNetworkHost('192.168.0.0'), isTrue);
      expect(isPrivateNetworkHost('192.168.1.5'), isTrue);
      expect(isPrivateNetworkHost('192.168.255.255'), isTrue);
      // 链路本地
      expect(isPrivateNetworkHost('169.254.10.10'), isTrue);
      // IPv6 链路本地 / ULA（含 /10、/7 掩码边界）
      expect(isPrivateNetworkHost('fe80::1'), isTrue);
      expect(isPrivateNetworkHost('febf::1'), isTrue, reason: 'fe80::/10 上界');
      expect(isPrivateNetworkHost('fc00::1'), isTrue);
      expect(isPrivateNetworkHost('fdff::1'), isTrue, reason: 'fc00::/7 上界');
      expect(isPrivateNetworkHost('FD12:3456::1'), isTrue, reason: '大小写归一');
      // IPv6 回环等价形式（非字面量 ::1）
      expect(isPrivateNetworkHost('::0:1'), isTrue, reason: '::1 缩写变体');
      expect(isPrivateNetworkHost('0:0:0:0:0:0:0:1'), isTrue,
          reason: '完整展开的回环地址');
      // IPv4 映射地址（双栈系统解析主机名时可能出现）
      expect(isPrivateNetworkHost('::ffff:127.0.0.1'), isTrue);
      expect(isPrivateNetworkHost('::ffff:192.168.1.5'), isTrue);
      // IPv6 zone id（链路本地常带接口名；InternetAddress.tryParse 对带 zone 的
      // 串返回 null → 拒绝。锁定"拒绝"预期：真实 LAN 接入用方括号无 zone 形式）。
      expect(isPrivateNetworkHost('fe80::1%en0'), isFalse,
          reason: 'zone id 形式拒绝（不解析）');
    });

    test('拒绝：公网 IP / 非 .local 主机名 / IPv6 掩码外 / IPv4 映射公网 / 空输入', () {
      expect(isPrivateNetworkHost('8.8.8.8'), isFalse);
      expect(isPrivateNetworkHost('1.1.1.1'), isFalse);
      expect(isPrivateNetworkHost('172.32.0.1'), isFalse, reason: '172.32 超出 /12');
      expect(isPrivateNetworkHost('172.15.0.1'), isFalse, reason: '172.15 低于 /12');
      expect(isPrivateNetworkHost('192.169.0.1'), isFalse, reason: '192.169 非 192.168');
      expect(isPrivateNetworkHost('11.0.0.1'), isFalse);
      expect(isPrivateNetworkHost('example.com'), isFalse);
      expect(isPrivateNetworkHost('mypc.lan'), isFalse, reason: '非 .local 主机名拒绝');
      expect(isPrivateNetworkHost('fe00::1'), isFalse, reason: 'fe80::/10 之外');
      expect(isPrivateNetworkHost('f800::1'), isFalse, reason: 'fc00::/7 之外');
      expect(isPrivateNetworkHost('2001:db8::1'), isFalse);
      expect(isPrivateNetworkHost('::ffff:8.8.8.8'), isFalse,
          reason: 'IPv4 映射的公网地址拒绝');
      expect(isPrivateNetworkHost('::ffff:172.32.0.1'), isFalse,
          reason: 'IPv4 映射的 172.32 超出 /12');
      // 2001:db8::ffff:192.168.1.5：全局 IPv6 但 bytes[10..11] 恰为 ff:ff——
      // 必须因前 80 位非全零而被拒绝（防 IPv4 映射误判放行公网地址）。
      expect(isPrivateNetworkHost('2001:db8::ffff:192.168.1.5'), isFalse,
          reason: '非标准前缀的 IPv6 不得误判为私网');
      expect(isPrivateNetworkHost(''), isFalse);
      expect(isPrivateNetworkHost('   '), isFalse);
      expect(isPrivateNetworkHost('.'), isFalse, reason: '仅尾点 → 剥后为空');
    });
  });

  group('normalizeLanInput（主机输入归一化）', () {
    test('裸 IP/主机名', () {
      expect(normalizeLanInput('192.168.1.5'), ('192.168.1.5', null));
      expect(normalizeLanInput('mypc.local'), ('mypc.local', null));
    });

    test('带端口 / scheme / 尾斜杠', () {
      expect(normalizeLanInput('192.168.1.5:9000'), ('192.168.1.5', 9000));
      expect(
        normalizeLanInput('http://192.168.1.5:8787/'),
        ('192.168.1.5', 8787),
      );
      expect(normalizeLanInput('http://mypc.local'), ('mypc.local', null));
      expect(normalizeLanInput('http://mypc.local:9999/x'), ('mypc.local', 9999));
    });

    test('IPv6（方括号带端口 / 裸 IPv6）', () {
      expect(normalizeLanInput('[fe80::1]:9000'), ('fe80::1', 9000));
      expect(normalizeLanInput('[fe80::1]'), ('fe80::1', null));
      expect(normalizeLanInput('fe80::1'), ('fe80::1', null), reason: '裸 IPv6 整体为主机');
      expect(normalizeLanInput('::1'), ('::1', null));
    });

    test('IPv6 与 scheme/端口/路径组合', () {
      expect(
        normalizeLanInput('http://[fe80::1]:9000/'),
        ('fe80::1', 9000),
      );
      expect(normalizeLanInput('http://[::1]:8787/'), ('::1', 8787));
      expect(
        normalizeLanInput('http://[fd00::1]/health'),
        ('fd00::1', null),
        reason: 'IPv6 无端口 + 路径',
      );
      // 无路径带 query：剥离 ? 后端口不被污染
      expect(normalizeLanInput('http://192.168.1.5:8787?x=1'), ('192.168.1.5', 8787));
      expect(normalizeLanInput('mypc.local?x=1'), ('mypc.local', null),
          reason: 'query 不拼进主机名');
    });

    test('userinfo 严格拒绝（正反两组，防白名单绕过）', () {
      // 正：任何 '@' 一律拒绝
      expect(normalizeLanInput('http://user:pass@192.168.1.5:8787/'), isNull);
      expect(normalizeLanInput('http://8.8.8.8@192.168.1.5:8787/'), isNull);
      expect(normalizeLanInput('192.168.1.5:8787@evil.com'), isNull);
      expect(normalizeLanInput('http://evil.com@192.168.1.5/'), isNull);
      // 反：若实现将来改为从 '@' 某侧提取主机，这些用例会失败（锁定"整体拒绝"）
      expect(normalizeLanInput('192.168.1.5@8.8.8.8:8787'), isNull);
    });

    test('非法输入', () {
      expect(normalizeLanInput(''), isNull);
      expect(normalizeLanInput('   '), isNull);
      expect(normalizeLanInput('http://'), isNull, reason: '剥离 scheme 后变空');
      expect(normalizeLanInput('//192.168.1.5'), isNull, reason: '剥离路径后变空');
      expect(normalizeLanInput('192.168.1.5:'), isNull, reason: '端口为空');
      expect(normalizeLanInput('192.168.1.5:abc'), isNull, reason: '端口非数字');
      expect(normalizeLanInput('[fe80::1'), isNull, reason: 'IPv6 括号不闭合');
    });

    test('端口范围/格式越界 → null（1..65535 且纯数字）', () {
      expect(normalizeLanInput('192.168.1.5:0'), isNull, reason: '端口 0');
      expect(normalizeLanInput('192.168.1.5:65536'), isNull, reason: '端口超上界');
      expect(normalizeLanInput('192.168.1.5:-1'), isNull, reason: '负端口');
      expect(normalizeLanInput('192.168.1.5:+80'), isNull, reason: '符号前缀');
      expect(normalizeLanInput('192.168.1.5:0x50'), isNull, reason: '十六进制');
      expect(normalizeLanInput('[fe80::1]:0'), isNull, reason: 'IPv6 端口 0');
      expect(normalizeLanInput('[fe80::1]:65536'), isNull, reason: 'IPv6 端口越界');
    });

    test('仅接受 http:// scheme（https 等拒绝，防明文静默降级）', () {
      expect(normalizeLanInput('https://192.168.1.5:8787/'), isNull);
      expect(normalizeLanInput('ftp://192.168.1.5'), isNull);
      expect(normalizeLanInput('ws://192.168.1.5'), isNull);
    });

    test('scheme 前缀歧义（r 复审锁定）：host:port 放行 / 多冒号 scheme 前缀拒绝', () {
      // 单 label 主机 + 端口：`localhost`/`myserver` 匹配 scheme 前缀正则但不
      // 是 scheme——走 host:port 分支正常放行。
      expect(normalizeLanInput('localhost:9000'), ('localhost', 9000));
      expect(normalizeLanInput('myserver:9000'), ('myserver', 9000));
      // 多冒号非 http scheme 前缀（缺 `//`）：可能被误判为裸 IPv6 放行——拒绝
      //（防明文静默降级的核心场景）。
      expect(normalizeLanInput('https:192.168.1.5:9000'), isNull);
      // 单冒号 `https:9000` 与 `myserver:9000` 形态不可区分（同为"单 label+
      // 端口"，归一化层不做私网校验）——按 host:port 放行，由调用方
      // isPrivateNetworkHost('https')==false 拒绝（'https' 非私网主机）。
      expect(normalizeLanInput('https:9000'), ('https', 9000));
      // IPv6 形态不受 scheme 前缀拒绝影响。
      expect(normalizeLanInput('fe80::1'), ('fe80::1', null));
    });

    test('歧义输入：大写 scheme 放行 / userinfo 拒绝 / query·fragment 剥离', () {
      // 大写 scheme：实现先 toLowerCase，HTTP:// 等同 http://
      expect(
        normalizeLanInput('HTTP://192.168.1.5:8787/'),
        ('192.168.1.5', 8787),
      );
      // userinfo：`user:pass@host` 会被当作"裸 IPv6"整体主机 → 非法 host 结构
      // （含 '@'，白名单必拒），归一化层明确拒绝而非放行。
      expect(normalizeLanInput('http://user:pass@192.168.1.5:8787/'), isNull);
      // query/fragment：路径剥离后不携带
      expect(
        normalizeLanInput('http://192.168.1.5:8787/path?x=1#frag'),
        ('192.168.1.5', 8787),
      );
      // 裸 IPv6 尾部端口歧义：`fe80::1:9000` 多冒号 → 整体视为主机（不拆端口）
      expect(normalizeLanInput('fe80::1:9000'), ('fe80::1:9000', null));
    });

    test('归一化输出 → 白名单组合链路（FQDN 尾点等）', () {
      // 尾点主机名原样输出，且能通过白名单校验
      final withTrailingDot = normalizeLanInput('mypc.local.');
      expect(withTrailingDot, ('mypc.local.', null));
      expect(isPrivateNetworkHost(withTrailingDot!.$1), isTrue);
      // 尾点 + 端口
      final withPort = normalizeLanInput('mypc.local.:9000');
      expect(withPort, ('mypc.local.', 9000));
      expect(isPrivateNetworkHost(withPort!.$1), isTrue);
      // scheme + 尾斜杠
      final viaHttp = normalizeLanInput('http://mypc.local./');
      expect(viaHttp, ('mypc.local.', null));
      expect(isPrivateNetworkHost(viaHttp!.$1), isTrue);
    });
  });

  group('响应包络解析', () {
    test('okEnvelope：data 中的 ok 键不覆盖成功标记（协议一致性）', () {
      final envelope = okEnvelope(const {'ok': false, 'token': 'x'});
      expect(envelope['ok'], isTrue,
          reason: '成功包络的 ok 恒为 true（parseEnvelope 依赖该判定）');
      expect(envelope['token'], 'x');
      // 该包络必须被 parseEnvelope 判为成功
      expect(parseEnvelope(envelope)['token'], 'x');
    });

    test('statusCode 映射表格驱动：全部错误码与 parseEnvelope 推导一致', () {
      // 逐码断言 httpStatusFor 映射（防个别码错配导致调用方分流失效）。
      const expectedStatus = {
        LanSyncErrorCode.invalidRequest: 400,
        LanSyncErrorCode.invalidCode: 401,
        LanSyncErrorCode.codeExpired: 401,
        LanSyncErrorCode.unauthorized: 401,
        LanSyncErrorCode.payloadTooLarge: 413,
        LanSyncErrorCode.rateLimited: 429,
        LanSyncErrorCode.serverError: 500,
        LanSyncErrorCode.network: null,
        LanSyncErrorCode.timeout: null,
      };
      for (final entry in expectedStatus.entries) {
        expect(httpStatusFor(entry.key), entry.value,
            reason: '${entry.key.name} 映射错误');
        // parseEnvelope 推导与 httpStatusFor 一致（经 wire value 反查）。
        if (entry.key == LanSyncErrorCode.network ||
            entry.key == LanSyncErrorCode.timeout) {
          continue; // 客户端侧错误不会出现在响应包络里
        }
        expect(
          () => parseEnvelope({
            'ok': false,
            'error': {'code': entry.key.wireValue, 'message': 'x'},
          }),
          throwsA(isA<LanSyncException>()
              .having((e) => e.statusCode, 'statusCode', entry.value)),
          reason: '${entry.key.name} 经包络推导的 statusCode 错误',
        );
      }
    });

    test('errorEnvelope → parseEnvelope 协议一致性（服务端生成可被客户端解析）', () {
      const code = LanSyncErrorCode.invalidCode;
      final envelope = errorEnvelope(code, '配对码无效');
      expect(envelope['ok'], isFalse);
      expect(
        (envelope['error'] as Map<String, Object?>)['code'],
        code.wireValue,
      );
      expect(
        (envelope['error'] as Map<String, Object?>)['message'],
        '配对码无效',
      );
      // 客户端解析该包络能得到一致错误
      expect(
        () => parseEnvelope(envelope),
        throwsA(isA<LanSyncException>()
            .having((e) => e.code, 'code', code)
            .having((e) => e.message, 'message', '配对码无效')),
      );
    });

    test('ok 类型严格性：非布尔真值不被判为成功', () {
      // 实现用 == true 严格比较；若回归成 truthy 判定，ok:1 会被误判成功。
      for (final badOk in [1, 'true', '1', true]) {
        // true 是合法成功；其余必须判失败
        if (badOk is bool && badOk) continue;
        expect(
          () => parseEnvelope({'ok': badOk}),
          throwsA(isA<LanSyncException>()
              .having((e) => e.code, 'code', LanSyncErrorCode.serverError)),
          reason: 'ok=$badOk 不应被误判为成功',
        );
      }
    });

    test('畸形包络类型严格性：error:null / code·message 非字符串 / 顶层 null·字符串', () {
      expect(
        () => parseEnvelope(const {'ok': false, 'error': null}),
        throwsA(isA<LanSyncException>()
            .having((e) => e.code, 'code', LanSyncErrorCode.serverError)
            .having((e) => e.message, 'message', 'LAN 主机返回错误')),
      );
      expect(
        () => parseEnvelope(const {
          'ok': false,
          'error': {'code': 123, 'message': 'x'},
        }),
        throwsA(isA<LanSyncException>()
            .having((e) => e.code, 'code', LanSyncErrorCode.serverError)),
      );
      expect(
        () => parseEnvelope(const {
          'ok': false,
          'error': {'code': 'invalid_code', 'message': [1, 2]},
        }),
        throwsA(isA<LanSyncException>()
            .having((e) => e.code, 'code', LanSyncErrorCode.invalidCode)
            .having((e) => e.message, 'message', 'LAN 主机返回错误')),
      );
      // 无 error 字段 / error 为数组
      expect(
        () => parseEnvelope(const {'ok': false}),
        throwsA(isA<LanSyncException>()
            .having((e) => e.code, 'code', LanSyncErrorCode.serverError)),
      );
      expect(
        () => parseEnvelope(const {
          'ok': false,
          'error': [1, 2],
        }),
        throwsA(isA<LanSyncException>()
            .having((e) => e.code, 'code', LanSyncErrorCode.serverError)),
      );
      // 顶层 null / 字符串 / 数字
      expect(() => parseEnvelope(null), throwsA(isA<LanSyncException>()));
      expect(() => parseEnvelope('str'), throwsA(isA<LanSyncException>()));
      expect(() => parseEnvelope(42), throwsA(isA<LanSyncException>()));
    });

    test('ok=true 返回数据；ok=false 抛带错误码异常', () {
      final data = parseEnvelope({
        'ok': true,
        'token': 'abc',
      });
      expect(data['token'], 'abc');

      expect(
        () => parseEnvelope(const {
          'ok': false,
          'error': {'code': 'invalid_code', 'message': '配对码无效'},
        }),
        throwsA(isA<LanSyncException>()
            .having((e) => e.code, 'code', LanSyncErrorCode.invalidCode)
            .having((e) => e.message, 'message', '配对码无效')),
      );
    });

    test('顶层非对象 → invalidRequest；未知错误码回退 serverError', () {
      expect(
        () => parseEnvelope([1, 2]),
        throwsA(isA<LanSyncException>()
            .having((e) => e.code, 'code', LanSyncErrorCode.invalidRequest)),
      );
      expect(
        () => parseEnvelope(const {
          'ok': false,
          'error': {'code': 'unknown_code', 'message': 'x'},
        }),
        throwsA(isA<LanSyncException>()
            .having((e) => e.code, 'code', LanSyncErrorCode.serverError)),
      );
    });

    test('畸形包络回退：缺 ok / error 非对象 / 缺 code / 缺 message', () {
      // 缺 ok 字段 → 失败 + serverError + 默认消息
      expect(
        () => parseEnvelope(const {'data': 1}),
        throwsA(isA<LanSyncException>()
            .having((e) => e.code, 'code', LanSyncErrorCode.serverError)
            .having((e) => e.message, 'message', 'LAN 主机返回错误')),
      );
      // error 非对象（字符串）
      expect(
        () => parseEnvelope(const {'ok': false, 'error': 'oops'}),
        throwsA(isA<LanSyncException>()
            .having((e) => e.code, 'code', LanSyncErrorCode.serverError)),
      );
      // 缺 error.code → 消息保留、错误码回退 serverError
      expect(
        () => parseEnvelope(const {
          'ok': false,
          'error': {'message': '只有消息'},
        }),
        throwsA(isA<LanSyncException>()
            .having((e) => e.code, 'code', LanSyncErrorCode.serverError)
            .having((e) => e.message, 'message', '只有消息')),
      );
      // 缺 error.message → 错误码保留、消息回退默认
      expect(
        () => parseEnvelope(const {
          'ok': false,
          'error': {'code': 'invalid_code'},
        }),
        throwsA(isA<LanSyncException>()
            .having((e) => e.code, 'code', LanSyncErrorCode.invalidCode)
            .having((e) => e.message, 'message', 'LAN 主机返回错误')),
      );
    });
  });
}
