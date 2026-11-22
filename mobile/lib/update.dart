// Tells when a newer APK is published. Only a release build knows its version (--dart-define=APP_VERSION, release.yml).
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';

import 'logic.dart';

const _appVersion = String.fromEnvironment('APP_VERSION');
const _latest = 'https://api.github.com/repos/SantiagoRuizM/ClaudeMaxxing/releases/latest';
const _channel = MethodChannel('claudemaxxing/update');

/// The version of a newer release that has the APK, else null (also without internet: it is asked again later).
Future<String?> findUpdate() async {
  if (_appVersion.isEmpty) return null;
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 15);
  try {
    final request = await client.getUrl(Uri.parse(_latest));
    request.headers.set(HttpHeaders.userAgentHeader, 'ClaudeMaxxing-update');
    final response = await request.close().timeout(const Duration(seconds: 15));
    if (response.statusCode != 200) return null;
    final body = await response.transform(utf8.decoder).join().timeout(const Duration(seconds: 15));
    return apkUpdate(jsonDecode(body), _appVersion);
  } on Exception {
    return null;
  } finally {
    client.close(force: true);
  }
}

/// Opens the download in the browser (the address is fixed in MainActivity). False when nothing could open it.
Future<bool> downloadUpdate() async {
  try {
    return await _channel.invokeMethod<bool>('download') ?? false;
  } on PlatformException {
    return false;
  }
}
