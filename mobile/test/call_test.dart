import 'package:claudemaxxing/api.dart';
import 'package:claudemaxxing/call.dart';
import 'package:claudemaxxing/eggs.dart';
import 'package:claudemaxxing/logic.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

class FakeApi extends Api {
  FakeApi() : super(Pc(name: 'PC', hosts: [], port: 1, pin: '', token: ''));

  final sent = <String>[];
  var items = <Map<String, dynamic>>[];
  var sessionState = 'thinking';
  var reset = false;
  var offset = 10;
  ApiError? failSend;
  ApiError? failRead;

  @override
  Future<Map<String, dynamic>> messages(String session, int after) async {
    if (failRead != null) throw failRead!;
    final out = items;
    items = [];
    return {'offset': offset++, 'reset': reset, 'items': out};
  }

  @override
  Future<void> prompt(String session, String text) async {
    if (failSend != null) throw failSend!;
    sent.add(text);
  }

  @override
  Future<Map<String, dynamic>> state({bool refresh = false}) async => {
        'sessions': [
          {'id': 's', 'state': sessionState}
        ]
      };
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  final call = Call.instance;
  late FakeApi api;
  late List<MethodCall> native;

  Future<void> event(String method, [Object? args]) async {
    await messenger.handlePlatformMessage(
        Call.channel.name, const StandardMethodCodec().encodeMethodCall(MethodCall(method, args)), (_) {});
    await Future<void>.delayed(Duration.zero);
  }

  Future<void> said([bool ok = true]) => event('said', {'ok': ok});
  Future<void> heard(String text, [bool ok = true]) => event('heard', {'ok': ok, 'text': text, 'headset': true});
  Future<void> button(String name) => event('button', {'name': name});
  Future<void> session(String role, String text) async {
    api.items = [
      {'role': role, 'text': text}
    ];
    await call.poll();
  }

  /// Up to a proposal being read aloud.
  Future<void> propose() async {
    await said();
    await heard('arregla el login');
    await said();
    await session('assistant', 'Revisé.\n🔊 Propuesta: cambio el login.');
  }

  setUp(() async {
    api = FakeApi();
    native = [];
    messenger.setMockMethodCallHandler(Call.channel, (c) async {
      native.add(c);
      return c.method == 'start' ? true : null;
    });
    expect(await call.start(api, 's', 'Sofía'), isTrue);
    await event('ready');
  });

  tearDown(() => call.hangUp());

  test("the call's notification takes the symbol of its PC", () async {
    String icon() => (native.lastWhere((c) => c.method == 'start').arguments as Map)['icon'] as String;
    expect(icon(), 'ic_launcher_monochrome', reason: 'not known yet');
    call.hangUp();
    EggCache.use('', 'egg');
    expect(await call.start(api, 's', 'Sofía'), isTrue);
    expect(icon(), 'ic_stat_egg');
  });

  test('callReply: the last spoken line, whether proposal or question', () {
    expect(callReply('sigo trabajando'), isNull);
    expect(callReply('🔊 una\ntexto\n**🔊 Listo, `todo` pasa.**')!.text, 'Listo, todo pasa.');
    expect(callReply('🔊 Propuesta: cambio X')!.proposal, isTrue);
    expect(callReply('🔊 Hice la propuesta: X')!.proposal, isFalse);
    expect(callReply('🔊 ¿Sigo?')!.question, isTrue);
  });

  test('talk, hear the proposal, accept it, hear the end', () async {
    expect(call.phase, CallPhase.speaking);
    await said();
    expect(call.phase, CallPhase.listening);
    await heard('arregla el login');
    expect(api.sent.single, '$callNote\n\narregla el login');
    await said();
    await session('assistant', '🔊 Propuesta: cambio el login.');
    await said();
    expect(call.canAccept, isTrue);
    await button('primary');
    expect(api.sent.last, acceptMessage('Propuesta: cambio el login.'));
    await button('primary');
    expect(api.sent.length, 2, reason: 'accepted once');
    await said();
    await session('assistant', '🔊 Listo, pasan los tests.');
    expect(call.said, 'Listo, pasan los tests.');
  });

  test('a proposal is not accepted before it was heard whole', () async {
    await propose();
    await button('primary');
    expect(api.sent.length, 1);
    await said(false);
    expect(call.canAccept, isFalse);
  });

  test('cutting a proposal short to talk does not accept it', () async {
    await propose();
    await button('talk');
    await heard('');
    await said();
    expect(call.canAccept, isFalse);
  });

  test('a newer message takes the proposal off the table', () async {
    await propose();
    await said();
    await session('user', 'mejor otra cosa');
    expect(call.canAccept, isFalse);
    await button('primary');
    expect(api.sent.length, 1);
    expect(call.phase, CallPhase.listening);
  });

  test('a question opens the microphone', () async {
    await said();
    await heard('revisa');
    await said();
    await session('assistant', '🔊 ¿Lo hago en otra rama?');
    await said();
    expect(call.phase, CallPhase.listening);
  });

  test('nothing is sent from silence or a failed dictation', () async {
    await said();
    await heard('');
    await button('talk');
    await heard('media fra', false);
    expect(api.sent, isEmpty);
  });

  test('two taps retry what could not be sent', () async {
    await said();
    api.failSend = ApiError(0, 'offline');
    await heard('hola');
    await said();
    api.failSend = null;
    await button('primary');
    expect(api.sent.single, '$callNote\n\nhola');
  });

  test('a failed acceptance is retried as that acceptance', () async {
    await propose();
    await said();
    api.failSend = ApiError(0, 'offline');
    await button('primary');
    await said();
    api.failSend = null;
    await button('primary');
    expect(api.sent.last, acceptMessage('Propuesta: cambio el login.'));
  });

  test('a phone call pauses it: no button or late dictation sends', () async {
    await said();
    await event('interrupted');
    await heard('lo que dije por telefono');
    await button('primary');
    expect(api.sent, isEmpty);
    expect(call.phase, CallPhase.paused);
    await event('resumed');
    expect(call.phase, CallPhase.speaking);
  });

  test('what comes while listening is read afterwards', () async {
    await said();
    await session('assistant', '🔊 Terminé.');
    expect(call.phase, CallPhase.listening);
    await heard('');
    await said();
    expect(call.said, 'Terminé.');
  });

  test('a rewritten transcript is not read aloud', () async {
    await said();
    await heard('hola');
    await said();
    api.reset = true;
    await session('assistant', '🔊 algo viejo');
    expect(call.said, isNot('algo viejo'));
  });

  test('a turn without its spoken line is still read when the session is idle', () async {
    await said();
    await heard('hola');
    await said();
    await session('assistant', 'Hecho, sin resumen.');
    api.sessionState = 'idle';
    for (var i = 0; i < 8; i++) {
      await call.poll();
    }
    expect(call.said, 'Hecho, sin resumen.');
    expect(call.canAccept, isFalse);
  });

  test('a closed session ends the call after saying so', () async {
    await said();
    api.failRead = ApiError(404, 'unknown session');
    await call.poll();
    await said();
    expect(call.active, isFalse);
    expect(native.last.method, 'stop');
  });
}
