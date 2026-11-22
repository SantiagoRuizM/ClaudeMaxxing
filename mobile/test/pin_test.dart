// The app talks only to the certificate the QR pinned, whatever the device trusts. Real TLS on loopback, with
// certificates made here by openssl (Git for Windows brings it), so that no private key lives in the repo.
import 'dart:convert';
import 'dart:io';

import 'package:claudemaxxing/api.dart';
import 'package:flutter_test/flutter_test.dart';

const _config = '''
[req]
distinguished_name = dn
[dn]
[pc]
keyUsage = critical,digitalSignature,keyEncipherment
extendedKeyUsage = serverAuth
subjectKeyIdentifier = hash
[plain]
[ca]
basicConstraints = critical,CA:TRUE
[leaf]
subjectAltName = IP:127.0.0.1
extendedKeyUsage = serverAuth
''';

String _openssl() {
  for (final path in [r'C:\Program Files\Git\usr\bin\openssl.exe', r'C:\Program Files\Git\mingw64\bin\openssl.exe']) {
    if (Platform.isWindows && File(path).existsSync()) return path;
  }
  return 'openssl';
}

void main() {
  late Directory dir;

  String file(String name) => '${dir.path}${Platform.pathSeparator}$name';
  List<int> pem(String name) => File(file('$name.pem')).readAsBytesSync();
  String pinOf(String name) =>
      fingerprint(base64.decode(const LineSplitter().convert(utf8.decode(pem(name))).where((l) => !l.startsWith('-')).join()));

  void openssl(List<String> args) {
    final result = Process.runSync(_openssl(), args, workingDirectory: dir.path);
    if (result.exitCode != 0) throw StateError('openssl ${args.first}: ${result.stderr}');
  }

  void selfSigned(String name, String subject, String section) => openssl([
        'req', '-x509', '-config', 'test.cnf', '-extensions', section, '-newkey', 'rsa:2048', '-nodes', '-days', '2',
        '-keyout', '$name.key', '-out', '$name.pem', '-subj', '/CN=$subject',
      ]);

  void signed(String name, String issuer) {
    openssl(['req', '-config', 'test.cnf', '-newkey', 'rsa:2048', '-nodes', '-keyout', '$name.key', '-out', '$name.csr', '-subj', '/CN=127.0.0.1']);
    openssl([
      'x509', '-req', '-in', '$name.csr', '-CA', '$issuer.pem', '-CAkey', '$issuer.key', '-set_serial', '7', '-days', '2',
      '-extfile', 'test.cnf', '-extensions', 'leaf', '-out', '$name.pem',
    ]);
  }

  /// A server presenting [chain] with [key], and the requests that got as far as reaching it.
  Future<(HttpServer, List<String>)> serve(List<String> chain, String key) async {
    final context = SecurityContext()
      ..useCertificateChainBytes([for (final name in chain) ...pem(name)])
      ..usePrivateKey(file('$key.key'));
    final server = await HttpServer.bindSecure(InternetAddress.loopbackIPv4, 0, context);
    addTearDown(() => server.close(force: true));
    final seen = <String>[];
    server.listen((request) {
      seen.add(request.uri.path);
      request.response.write('{"token":"t"}');
      request.response.close();
    }, onError: (_) {}); // a refused handshake
    return (server, seen);
  }

  Api apiFor(HttpServer server, String pinned) => Api(
      Pc(name: 'PC', hosts: ['127.0.0.1'], port: server.port, pin: pinOf(pinned), token: 'secret', lastHost: '127.0.0.1'));

  setUpAll(() {
    dir = Directory.systemTemp.createTempSync('cmx-pin-test-');
    File(file('test.cnf')).writeAsStringSync(_config);
    selfSigned('pc', 'ClaudeMaxxing TESTPC', 'pc'); // like the tray's
    selfSigned('loose', 'ClaudeMaxxing LOOSE', 'plain'); // without key-usage limits
    selfSigned('other', 'Other', 'plain');
    selfSigned('ca', 'Test CA', 'ca');
    selfSigned('samename', 'ClaudeMaxxing TESTPC', 'plain');
    selfSigned('samenameloose', 'ClaudeMaxxing LOOSE', 'plain');
    signed('trusted', 'ca');
    signed('forged', 'samename');
    signed('forgedloose', 'samenameloose');
    // This process now trusts the CA, as a phone trusts its system's ones.
    SecurityContext.defaultContext.setTrustedCertificatesBytes(pem('ca'));
  });
  tearDownAll(() => dir.deleteSync(recursive: true));

  test('the pinned certificate is accepted', () async {
    final (server, seen) = await serve(['pc'], 'pc');
    await apiFor(server, 'pc').state();
    expect(seen, ['/state']);
  });

  final refused = <String, (List<String>, String, String)>{
    'another self-signed certificate': (['other'], 'other', 'pc'),
    'a certificate from a CA the device trusts': (['trusted'], 'trusted', 'pc'),
    'another leaf carrying the pinned certificate as its chain': (['forged', 'pc'], 'forged', 'pc'),
    'the same, when the pinned certificate could sign': (['forgedloose', 'loose'], 'forgedloose', 'loose'),
  };
  refused.forEach((name, c) {
    final (chain, key, pinned) = c;
    test('refused, and sent nothing: $name', () async {
      final (server, seen) = await serve(chain, key);
      await expectLater(apiFor(server, pinned).state(), throwsA(isA<ApiError>().having((e) => e.status, 'status', 0)));
      expect(seen, isEmpty);
    });
  });

  test('pairing gives no code to a certificate from a trusted CA', () async {
    final (server, seen) = await serve(['trusted'], 'trusted');
    final info = PairInfo(['127.0.0.1'], server.port, pinOf('pc'), 'code', 'PC');
    await expectLater(pair(info, 'phone'), throwsA(isA<ApiError>()));
    expect(seen, isEmpty);
  });

  test('control: a client with the default trust does accept that CA', () async {
    final (server, seen) = await serve(['trusted'], 'trusted');
    final client = HttpClient();
    addTearDown(() => client.close(force: true));
    await (await (await client.getUrl(Uri.parse('https://127.0.0.1:${server.port}/control'))).close()).drain<void>();
    expect(seen, ['/control']);
  });
}
