import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

import 'api.dart';
import 'eggs.dart';
import 'items.dart';
import 'store.dart';
import 'strings.dart';
import 'symbols.dart';

/// The status bar takes only icons built into the APK: a symbol newer than it, or not known yet, shows the app's
/// own mark instead of another symbol.
String statusIcon(String? symbol) =>
    bundledSymbols.contains(symbol) ? 'ic_stat_$symbol' : 'ic_launcher_monochrome';

typedef _Session = ({String name, String color, String state});

class SessionNotification {
  SessionNotification._();

  static final instance = SessionNotification._();
  static const _id = 1;
  final _plugin = FlutterLocalNotificationsPlugin();
  Future<bool>? _permission;
  Api? _api;
  String? _symbol;
  List<_Session> _sessions = [];
  Timer? _timer;
  int _tick = 0;
  bool _started = false;
  bool _busy = false;
  bool _pending = false;
  bool _needsRefresh = false;

  AndroidFlutterLocalNotificationsPlugin? get _android =>
      _plugin.resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin>();

  Future<bool> requestPermission() => _permission ??= _initialize();

  Future<bool> _initialize() async {
    if (!Platform.isAndroid) return false;
    try {
      await _plugin.initialize(const InitializationSettings(
        android: AndroidInitializationSettings('ic_launcher_monochrome'),
      ));
      if (await notificationsPermissionRequested()) {
        return await _android?.areNotificationsEnabled() == true;
      }
      final granted = await _android?.requestNotificationsPermission() == true;
      await markNotificationsPermissionRequested();
      return granted;
    } catch (error) {
      debugPrint('Notification initialization failed: $error');
      return false;
    }
  }

  void update(Api api, List<Map<String, dynamic>> sessions) {
    if (!Platform.isAndroid) return;
    final next = sessions
        .map<_Session>((session) => (
              name: '${session['name']}',
              color: '${session['color']}',
              state: '${session['state']}',
            ))
        .toList();
    final symbol = EggCache.symbolOf(api.pc.pin);
    final changed =
        _api != api || _symbol != symbol || !listEquals(_sessions, next);
    if (changed) {
      _tick = 0;
      _api = api;
      _symbol = symbol;
      _sessions = next;
    }
    if (next.any((session) =>
        session.state == 'thinking' || session.state == 'speaking')) {
      _timer ??= Timer.periodic(const Duration(milliseconds: 500), (_) {
        _tick += 4;
        _schedule();
      });
    } else {
      _timer?.cancel();
      _timer = null;
    }
    if (changed || (!_busy && (!_started || _needsRefresh))) _schedule();
  }

  void stop() {
    _timer?.cancel();
    _timer = null;
    _api = null;
    _sessions = [];
    _schedule();
  }

  void _schedule() {
    _pending = true;
    if (!_busy) unawaited(_publish());
  }

  Future<void> _publish() async {
    _busy = true;
    try {
      while (_pending) {
        _pending = false;
        try {
          final api = _api;
          final sessions = _sessions;
          if (api == null) {
            if (_started) await _android?.stopForegroundService();
            _started = false;
            continue;
          }
          if (!await requestPermission()) continue;
          if (api != _api || sessions != _sessions) continue;
          final summary = sessions.isEmpty
              ? S.noSessions
              : sessions
                  .map((session) =>
                      '${session.name} ${S.notificationState(session.state)}')
                  .join(' · ');
          final title = S.notificationTitle(api.pc.name);
          if (!_started) {
            await _android?.startForegroundService(
              _id,
              title,
              summary,
              notificationDetails: _details(null),
              startType: AndroidServiceStartType.startNotSticky,
              foregroundServiceTypes: {
                AndroidServiceForegroundType.foregroundServiceTypeSpecialUse
              },
            );
            _started = true;
          }
          final frames = await Future.wait(sessions.map((session) async {
            try {
              return await EggCache.of(api, session.color);
            } catch (_) {
              return null;
            }
          }));
          if (api != _api || sessions != _sessions) continue;
          final picture =
              sessions.isEmpty ? null : await _draw(sessions, frames, _tick);
          if (api != _api || sessions != _sessions) continue;
          await _plugin.show(_id, title, summary,
              NotificationDetails(android: _details(picture)));
          _needsRefresh = frames.contains(null);
        } catch (error) {
          _needsRefresh = true;
          debugPrint('Session notification failed: $error');
        }
      }
    } finally {
      _busy = false;
    }
  }

  AndroidNotificationDetails _details(Uint8List? picture) =>
      AndroidNotificationDetails(
        'pc_sessions',
        S.notificationChannel,
        icon: statusIcon(_symbol),
        importance: Importance.low,
        priority: Priority.low,
        ongoing: true,
        onlyAlertOnce: true,
        silent: true,
        playSound: false,
        enableVibration: false,
        styleInformation: picture == null
            ? null
            : BigPictureStyleInformation(ByteArrayAndroidBitmap(picture)),
      );

  Future<Uint8List?> _draw(
      List<_Session> sessions, List<EggFrames?> frames, int tick) async {
    const width = 720;
    const height = 240;
    final slot = width / sessions.length;
    final eggSize = (slot - 8).clamp(1.0, 120.0).toDouble();
    final recorder = ui.PictureRecorder();
    final canvas = ui.Canvas(recorder);
    final images = <ui.Image>[];
    try {
      for (var i = 0; i < sessions.length; i++) {
        final session = sessions[i];
        final center = slot * (i + 0.5);
        final bytes = frames[i]?.bytesAt(session.state, tick);
        if (bytes == null) {
          canvas.drawCircle(
              ui.Offset(center, 95),
              eggSize / 4,
              ui.Paint()
                ..color =
                    hexColor(session.color) ?? const ui.Color(0xffd97757));
        } else {
          final codec = await ui.instantiateImageCodec(bytes);
          try {
            final image = (await codec.getNextFrame()).image;
            images.add(image);
            canvas.drawImageRect(
                image,
                ui.Rect.fromLTWH(
                    0, 0, image.width.toDouble(), image.height.toDouble()),
                ui.Rect.fromCenter(
                    center: ui.Offset(center, 95),
                    width: eggSize,
                    height: eggSize),
                ui.Paint()..filterQuality = ui.FilterQuality.medium);
          } finally {
            codec.dispose();
          }
        }
        final label = (ui.ParagraphBuilder(ui.ParagraphStyle(
          textAlign: ui.TextAlign.center,
          maxLines: 2,
          ellipsis: '…',
          fontSize: (slot / 5).clamp(10.0, 28.0).toDouble(),
        ))
              ..pushStyle(ui.TextStyle(
                  color: const ui.Color(0xffffffff),
                  shadows: const [
                    ui.Shadow(
                        color: ui.Color(0xff000000),
                        offset: ui.Offset(0, 2),
                        blurRadius: 4),
                  ]))
              ..addText(session.name))
            .build()
          ..layout(ui.ParagraphConstraints(width: slot));
        canvas.drawParagraph(label, ui.Offset(i * slot, 162));
        label.dispose();
      }
      final picture = recorder.endRecording();
      try {
        final image = await picture.toImage(width, height);
        try {
          final data = await image.toByteData(format: ui.ImageByteFormat.png);
          return data?.buffer
              .asUint8List(data.offsetInBytes, data.lengthInBytes);
        } finally {
          image.dispose();
        }
      } finally {
        picture.dispose();
      }
    } finally {
      if (recorder.isRecording) recorder.endRecording().dispose();
      for (final image in images) {
        image.dispose();
      }
    }
  }
}
