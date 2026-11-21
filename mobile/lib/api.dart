// Talks to the ClaudeMaxxing tray on a PC (lib\mobile.ps1): HTTPS to the addresses the QR listed, accepting only
// the certificate whose SHA-256 the QR carried, with the token pairing gave this phone.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';

/// A paired PC, as saved on the phone.
class Pc {
  Pc({required this.name, required this.hosts, required this.port, required this.pin, required this.token, this.lastHost});

  final String name;
  final List<String> hosts;
  final int port;
  final String pin;
  final String token;
  String? lastHost;

  Map<String, dynamic> toJson() => {'name': name, 'hosts': hosts, 'port': port, 'pin': pin, 'token': token, 'lastHost': lastHost};

  factory Pc.fromJson(Map<String, dynamic> j) => Pc(
        name: j['name'] as String,
        hosts: (j['hosts'] as List).cast<String>(),
        port: j['port'] as int,
        pin: j['pin'] as String,
        token: j['token'] as String,
        lastHost: j['lastHost'] as String?,
      );
}

/// What the QR in Celular holds: cmx://pair?h=<hosts>&p=<port>&f=<sha256>&c=<code>&n=<PC name>.
class PairInfo {
  PairInfo(this.hosts, this.port, this.pin, this.code, this.name);

  final List<String> hosts;
  final int port;
  final String pin;
  final String code;
  final String name;

  static PairInfo? parse(String text) {
    final uri = Uri.tryParse(text.trim());
    if (uri == null || uri.scheme != 'cmx' || uri.host != 'pair') return null;
    final q = uri.queryParameters;
    final hosts = (q['h'] ?? '').split(',').where((h) => h.isNotEmpty).toList();
    final port = int.tryParse(q['p'] ?? '');
    final pin = (q['f'] ?? '').toLowerCase();
    final code = q['c'] ?? '';
    if (hosts.isEmpty || port == null || port < 1 || port > 65535) return null;
    if (!RegExp(r'^[0-9a-f]{64}$').hasMatch(pin) || code.isEmpty) return null;
    return PairInfo(hosts, port, pin, code, q['n'] ?? 'PC');
  }
}

class ApiError implements Exception {
  ApiError(this.status, this.message);
  final int status; // 0: the PC could not be reached
  final String message;
  @override
  String toString() => message;
}

String fingerprint(List<int> der) => sha256.convert(der).toString();

HttpClient _client(String pin) {
  final c = HttpClient()
    ..connectionTimeout = const Duration(seconds: 4)
    ..idleTimeout = const Duration(seconds: 2);
  // A self-signed certificate always fails the normal check: it is taken only when it is the one the QR pinned.
  c.badCertificateCallback = (cert, host, port) => fingerprint(cert.der) == pin;
  return c;
}

/// One request to one address: the decoded JSON, or an ApiError.
Future<dynamic> _send(String pin, String host, int port, String method, String path,
    {Map<String, String>? query, Object? body, List<int>? rawBody, String? token}) async {
  final client = _client(pin);
  try {
    final uri = Uri(scheme: 'https', host: host, port: port, path: path, queryParameters: query);
    final req = await client.openUrl(method, uri).timeout(const Duration(seconds: 6));
    if (token != null) req.headers.set(HttpHeaders.authorizationHeader, 'Bearer $token');
    if (rawBody != null || body != null) {
      final bytes = rawBody ?? utf8.encode(jsonEncode(body));
      req.headers.contentType = rawBody == null ? ContentType.json : ContentType.binary;
      req.contentLength = bytes.length;
      req.add(bytes);
    }
    final res = await req.close().timeout(const Duration(seconds: 30));
    final text = await res.transform(utf8.decoder).join();
    final data = text.isEmpty ? null : jsonDecode(text);
    if (res.statusCode != 200) {
      final msg = data is Map && data['error'] != null ? '${data['error']}' : 'HTTP ${res.statusCode}';
      throw ApiError(res.statusCode, msg);
    }
    return data;
  } on ApiError {
    rethrow;
  } on Object catch (e) {
    throw ApiError(0, e.toString());
  } finally {
    client.close(force: true);
  }
}

/// The first of the PC's addresses that answers /info with the pinned certificate, asking all at once: a PC on
/// several networks (home Wi-Fi, its own hotspot, Tailscale) lists addresses this phone can't reach.
Future<String?> reachable(String pin, List<String> hosts, int port) {
  final found = Completer<String?>();
  var pending = hosts.length;
  if (pending == 0) return Future.value(null);
  for (final host in hosts) {
    _send(pin, host, port, 'GET', '/info').then((_) {
      if (!found.isCompleted) found.complete(host);
    }, onError: (_) {
      if (--pending == 0 && !found.isCompleted) found.complete(null);
    });
  }
  return found.future;
}

/// Pairs with the PC in the QR, through the first address that answers. Returns the PC to save.
Future<Pc> pair(PairInfo info, String deviceName) async {
  final host = await reachable(info.pin, info.hosts, info.port);
  if (host == null) throw ApiError(0, info.hosts.join(', '));
  final data = await _send(info.pin, host, info.port, 'POST', '/pair', body: {'code': info.code, 'device': deviceName});
  return Pc(name: info.name, hosts: info.hosts, port: info.port, pin: info.pin, token: data['token'] as String, lastHost: host);
}

class Api {
  Api(this.pc);
  final Pc pc;

  /// Through the address that answered last; when it stops answering (another network), the others are asked
  /// all at once and the first to answer is used from then on.
  Future<dynamic> call(String method, String path, {Map<String, String>? query, Object? body, List<int>? rawBody}) async {
    final last = pc.lastHost;
    // An upload is sent once, after confirming a reachable address.
    if (last != null && rawBody == null) {
      try {
        return await _send(pc.pin, last, pc.port, method, path, query: query, body: body, rawBody: rawBody, token: pc.token);
      } on ApiError catch (e) {
        if (e.status != 0) rethrow;
      }
    }
    final host = await reachable(pc.pin, pc.hosts, pc.port);
    if (host == null) throw ApiError(0, pc.hosts.join(', '));
    pc.lastHost = host;
    return _send(pc.pin, host, pc.port, method, path, query: query, body: body, rawBody: rawBody, token: pc.token);
  }

  Future<Map<String, dynamic>> state() async => (await call('GET', '/state')) as Map<String, dynamic>;
  Future<Map<String, dynamic>> section(String id) async => (await call('GET', '/section', query: {'id': id})) as Map<String, dynamic>;
  Future<Map<String, dynamic>> action(String section, String id, int? arg) async =>
      (await call('POST', '/action', body: {'section': section, 'id': id, 'arg': arg})) as Map<String, dynamic>;
  Future<Map<String, dynamic>> messages(String session, int after) async =>
      (await call('GET', '/messages', query: {'session': session, 'after': '$after'})) as Map<String, dynamic>;
  Future<void> prompt(String session, String text) => call('POST', '/prompt', body: {'session': session, 'text': text});
  Future<Map<String, dynamic>> eggs(String color) async =>
      (await call('GET', '/eggs', query: {'color': color})) as Map<String, dynamic>;
  Future<void> upload(String session, String name, List<int> bytes, String caption) =>
      call('POST', '/upload', query: {'session': session, 'name': name, 'caption': caption}, rawBody: bytes);
  Future<void> unpair() => call('POST', '/unpair');
}
