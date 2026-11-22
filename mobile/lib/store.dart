// The paired PCs, in the phone's secure storage (Android Keystore): they hold the tokens.
import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'api.dart';

const _storage = FlutterSecureStorage();

Future<List<Pc>> loadPcs() async {
  final text = await _storage.read(key: 'pcs');
  if (text == null) return [];
  try {
    return (jsonDecode(text) as List).map((e) => Pc.fromJson(e as Map<String, dynamic>)).toList();
  } on Object {
    return [];
  }
}

Future<void> savePcs(List<Pc> pcs) => _storage.write(key: 'pcs', value: jsonEncode(pcs.map((p) => p.toJson()).toList()));

const _notificationsPermissionKey = 'notificationsPermissionRequested';

Future<bool> notificationsPermissionRequested() async =>
    await _storage.read(key: _notificationsPermissionKey) == 'true';

Future<void> markNotificationsPermissionRequested() =>
    _storage.write(key: _notificationsPermissionKey, value: 'true');

// The phone's own choices (the chat's palette and text size).
Future<String?> readSetting(String key) => _storage.read(key: key);

Future<void> writeSetting(String key, String value) => _storage.write(key: key, value: value);
