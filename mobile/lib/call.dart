// A call with a session, hands free: you talk, it goes to the session as a message, and what Claude answers (its 🔊
// line) is read aloud with the phone locked. CallService.kt listens, speaks and gets the headset's buttons; here is
// what each of them means.
import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import 'api.dart';
import 'eggs.dart';
import 'logic.dart';
import 'notify.dart';
import 'strings.dart';

enum CallPhase { off, starting, speaking, listening, sending, ready, paused }

typedef CallReply = ({String text, bool proposal, bool question});

// Claude's, so it is not translated. It goes with the first message of each call.
const callNote = '[Voice call: I am walking with headphones and only hear the line you start with 🔊 at the end of '
    'each turn. My words come from speech recognition. If I ask for a change, check it read-only first and end with '
    '"🔊 Propuesta: " and what you understood, what you will do and the risk, in under 60 words; change nothing until '
    'I accept. If you need an answer, end that line with one question, and do not use question pickers. When you '
    'finish, say there what you did and whether the tests passed. Accepting a proposal never covers a push, a '
    'deploy, a deletion or anything irreversible: for those, ask me to say it in words.]';

String acceptMessage(String proposal) => 'I accept this proposal, go ahead: "$proposal"';

class Call extends ChangeNotifier {
  Call._();
  static final instance = Call._();
  static const channel = MethodChannel('claudemaxxing/call');
  static const _pollEvery = Duration(seconds: 2);
  static const _remindAfter = Duration(minutes: 5);

  CallPhase phase = CallPhase.off;
  String session = '';
  String name = '';
  String said = '';
  String heard = '';
  bool headset = false;
  bool working = false;
  bool failed = false;

  Api? _api;
  Timer? _timer;
  int _generation = 0; // answers of a call that ended are ignored
  int _offset = -1;
  int _ticks = 0;
  int _failedPolls = 0;
  int _idleChecks = 0;
  bool _polling = false;
  bool _noted = false;
  bool _listenNext = false;
  bool _endNext = false;
  bool _readingReply = false;
  bool _proposalHeard = false;
  bool _offline = false;
  DateTime _since = DateTime.now();
  String _lastText = '';
  String? _unsent;
  CallReply? _reply; // the last one read aloud
  CallReply? _queued;

  bool get active => phase != CallPhase.off;
  bool get canAccept => phase == CallPhase.ready && _proposalHeard && _reply?.proposal == true;

  String get statusText => switch (phase) {
        CallPhase.off => failed ? S.callNoVoice : S.callEnded,
        CallPhase.starting => S.callStarting,
        CallPhase.speaking => S.callSpeaking,
        CallPhase.listening => S.callListening,
        CallPhase.sending => S.callSending,
        CallPhase.paused => S.callPaused,
        CallPhase.ready => canAccept ? S.callDecide : working ? S.callWorking : S.callReady,
      };

  /// False when Android didn't give the microphone.
  Future<bool> start(Api api, String id, String sessionName) async {
    if (active) return true;
    final generation = ++_generation;
    _api = api;
    session = id;
    name = sessionName;
    said = heard = _lastText = '';
    headset = working = failed = false;
    _polling = _noted = _listenNext = _endNext = _readingReply = _proposalHeard = _offline = false;
    _ticks = _failedPolls = _idleChecks = 0;
    _offset = -1;
    _unsent = null;
    _reply = _queued = null;
    phase = CallPhase.starting;
    notifyListeners();
    channel.setMethodCallHandler(_event);
    final phoneTag = WidgetsBinding.instance.platformDispatcher.locale.toLanguageTag();
    bool started;
    try {
      started = await channel.invokeMethod<bool>('start', {
            'locale': pickDictationLocale([], phoneTag, 'es-US')?.replaceAll('_', '-'),
            'title': S.callWith(sessionName),
            'status': S.callStarting,
            'channel': S.callChannel,
            'acceptLabel': S.accept,
            'talkLabel': S.talk,
            'hangUpLabel': S.hangUp,
            'icon': statusIcon(EggCache.symbolOf(api.pc.pin)),
          }) ==
          true;
    } on PlatformException {
      started = false;
    } on MissingPluginException {
      started = false;
    }
    if (generation != _generation) return true; // hung up while starting
    if (!started) _end();
    return started;
  }

  Future<void> hangUp() async {
    if (!active) return;
    _end();
    await channel.invokeMethod('stop');
  }

  void _end() {
    _generation++;
    _timer?.cancel();
    _timer = null;
    phase = CallPhase.off;
    notifyListeners();
  }

  void _set(CallPhase next) {
    phase = next;
    _changed();
  }

  void _changed() {
    notifyListeners();
    if (active) unawaited(channel.invokeMethod('status', {'text': statusText, 'accept': canAccept}));
  }

  Future<dynamic> _event(MethodCall call) async {
    if (!active) return;
    final args = call.arguments is Map ? call.arguments as Map : const {};
    switch (call.method) {
      case 'ready':
        if (phase != CallPhase.starting) return;
        _say(S.callHello(name), listen: true);
        // The transcript's end now: only what comes after it is read aloud.
        unawaited(poll());
        _timer = Timer.periodic(_pollEvery, (_) => poll());
      case 'failed':
        failed = true;
        _end();
      case 'said':
        _afterSaying(args['ok'] == true);
      case 'heard':
        await _afterListening(args['ok'] == true, '${args['text'] ?? ''}', args['headset'] == true);
      case 'button':
        await press('${args['name']}');
      case 'interrupted':
        _set(CallPhase.paused);
      case 'resumed':
        if (phase != CallPhase.paused) return;
        final next = _queued ?? _reply;
        _queued = null;
        if (next == null) {
          _say(S.callResumed);
        } else {
          _read(next);
        }
      case 'hangup':
        // The previous call's service may say goodbye after this one started.
        if (phase != CallPhase.starting) _end();
    }
  }

  void _say(String text, {bool listen = false, bool end = false, bool chime = false, bool reply = false}) {
    said = text;
    _listenNext = listen;
    _endNext = end;
    _readingReply = reply;
    _set(CallPhase.speaking);
    unawaited(channel.invokeMethod('say', {'text': text, 'chime': chime}));
  }

  void _read(CallReply reply, {bool chime = false}) {
    _reply = reply;
    _proposalHeard = false;
    _say(reply.proposal ? '${reply.text} ${S.callHowToAccept}' : reply.text,
        listen: reply.question && !reply.proposal, chime: chime, reply: true);
  }

  void _afterSaying(bool ok) {
    if (phase != CallPhase.speaking) return;
    if (_endNext) {
      unawaited(hangUp());
      return;
    }
    // A proposal can only be accepted after it was heard whole.
    if (ok && _readingReply && _reply?.proposal == true) _proposalHeard = true;
    final next = _queued;
    _queued = null;
    if (next != null) {
      _read(next, chime: true);
    } else if (ok && _listenNext) {
      _listen();
    } else {
      _set(CallPhase.ready);
    }
  }

  void _listen() {
    _set(CallPhase.listening);
    unawaited(channel.invokeMethod('listen'));
  }

  Future<void> _afterListening(bool ok, String text, bool fromHeadset) async {
    if (phase != CallPhase.listening) return;
    headset = fromHeadset;
    heard = text.trim();
    if (!ok) {
      _say(S.callHearingFailed);
    } else if (heard.isEmpty) {
      _say(S.callHeardNothing);
    } else {
      await _send(heard, S.callSent(speakable(heard, 220)));
    }
  }

  /// A button of the headset, of the notification or of the screen.
  Future<void> press(String button) async {
    if (!active || phase == CallPhase.starting || phase == CallPhase.paused || phase == CallPhase.sending) return;
    if (phase == CallPhase.listening) {
      if (button != 'replay') await channel.invokeMethod('finish');
    } else if (button == 'talk') {
      _listen();
    } else if (button == 'replay') {
      final last = _reply;
      if (last != null) _read(last);
    } else if (button == 'primary' && phase == CallPhase.ready) {
      if (canAccept) {
        await _send(acceptMessage(_reply!.text), S.callAccepted);
      } else if (_unsent != null) {
        await _send(_unsent!, S.callResent);
      } else {
        _listen();
      }
    }
  }

  Future<void> _send(String text, String confirmation) async {
    final api = _api!;
    final generation = _generation;
    _set(CallPhase.sending);
    try {
      if (_offset < 0) {
        final answer = await api.messages(session, -1);
        if (generation != _generation) return;
        _offset = (answer['offset'] as num?)?.toInt() ?? 0;
      }
      await api.prompt(session, _noted ? text : '$callNote\n\n$text');
      if (generation != _generation) return;
      _noted = true;
      _unsent = null;
      _forgetProposal();
      working = true;
      _since = DateTime.now();
      _idleChecks = 0;
      _lastText = '';
      if (phase == CallPhase.sending) _say(confirmation);
    } on ApiError catch (e) {
      if (generation != _generation) return;
      _unsent = text;
      _forgetProposal(); // so the same two taps retry this, instead of accepting
      if (phase == CallPhase.sending) _say(e.status == 0 ? S.callNotSent : S.callRefused(e.message));
    }
  }

  void _forgetProposal() {
    _proposalHeard = false;
    final reply = _reply;
    if (reply != null && reply.proposal) _reply = (text: reply.text, proposal: false, question: false);
  }

  @visibleForTesting
  Future<void> poll() async {
    if (!active || _polling) return;
    _polling = true;
    final api = _api!;
    final generation = _generation;
    try {
      final before = _offset;
      final answer = await api.messages(session, before);
      if (generation != _generation) return;
      // A send may have set it meanwhile: this answer is then older than that.
      if (_offset != before) return;
      _offset = (answer['offset'] as num?)?.toInt() ?? before;
      // The first answer and a rewritten transcript bring old messages: those are not read aloud.
      if (before >= 0 && !(answer['reset'] == true && before > 0)) {
        for (final item in (answer['items'] as List? ?? []).cast<Map>()) {
          _take('${item['role']}', '${item['text']}');
        }
      }
      _failedPolls = 0;
      if (_offline && phase == CallPhase.ready) {
        _offline = false;
        _say(S.callBack);
      }
      if (working && ++_ticks % 2 == 0) await _checkWork(api, generation);
    } on ApiError catch (e) {
      if (generation != _generation) return;
      if (e.status == 401 || e.status == 404) {
        _timer?.cancel();
        _say(S.callSessionClosed, end: true);
      } else if (++_failedPolls >= 5 && !_offline && phase == CallPhase.ready) {
        _offline = true;
        _say(S.callOffline);
      }
    } finally {
      if (generation == _generation) _polling = false;
    }
  }

  void _take(String role, String text) {
    _idleChecks = 0;
    if (role == 'user') {
      // Something else was asked since: that proposal is no longer the one on the table.
      _lastText = '';
      _forgetProposal();
      final queued = _queued;
      if (queued != null && queued.proposal) _queued = (text: queued.text, proposal: false, question: false);
      _changed();
    } else if (role == 'assistant') {
      _lastText = text;
      final reply = callReply(text);
      if (reply != null) _arrived(reply);
    }
  }

  void _arrived(CallReply reply) {
    working = false;
    _lastText = '';
    if (phase == CallPhase.ready) {
      _read(reply, chime: true);
    } else {
      _queued = reply;
    }
  }

  // A turn can end without its 🔊 line, and a permission can keep it waiting on the PC.
  Future<void> _checkWork(Api api, int generation) async {
    final state = await api.state();
    if (generation != _generation || !working) return;
    final mine = (state['sessions'] as List? ?? []).cast<Map>().where((s) => '${s['id']}' == session);
    if (mine.isEmpty) return;
    _idleChecks = mine.first['state'] == 'idle' ? _idleChecks + 1 : 0;
    if (_idleChecks >= 3 && _lastText.isNotEmpty) {
      // shortcut: the PC cuts a text at 6000 characters, so a longer answer loses its 🔊 line and can't be accepted; send the tail from lib\mobile.ps1 if that happens.
      _arrived((text: speakable(_lastText, 350), proposal: false, question: false));
    } else if (phase == CallPhase.ready && DateTime.now().difference(_since) >= _remindAfter) {
      _since = DateTime.now();
      _say(S.callStillWaiting);
    }
  }
}
