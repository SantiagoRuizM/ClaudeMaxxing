// What the sessions' voice said, kept on the phone like WhatsApp voice notes: the PC keeps only its last 100
// (lib\mobile.ps1, /voices and /voice), so every new one is downloaded as soon as the app sees it and stays here,
// in the app's own folder, one per PC, to be played whenever, even after its session closed.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';

import 'api.dart';
import 'chat.dart';
import 'chat_style.dart';
import 'strings.dart';

class VoiceNote {
  VoiceNote({required this.id, required this.at, required this.session, required this.name, required this.text, required this.file, this.ms});

  final String id; // the PC's: <yyyyMMdd-HHmmss-fff>-<session>, so they sort by time
  final String at;
  final String session;
  final String name;
  final String text;
  final String file;
  int? ms;

  Map<String, dynamic> toJson() => {'id': id, 'at': at, 'session': session, 'name': name, 'text': text, 'file': file, 'ms': ms};

  factory VoiceNote.fromJson(Map<String, dynamic> j) => VoiceNote(
        id: '${j['id']}',
        at: '${j['at'] ?? ''}',
        session: '${j['session'] ?? ''}',
        name: '${j['name'] ?? ''}',
        text: '${j['text'] ?? ''}',
        file: '${j['file']}',
        ms: (j['ms'] as num?)?.toInt(),
      );
}

/// The notes of the PC in use, oldest first, saved in <app documents>/voices/<PC>/ (index.json and one mp3 each).
class VoiceStore {
  VoiceStore._();
  static final instance = VoiceStore._();

  final notes = ValueNotifier<List<VoiceNote>>([]);
  Directory? _dir;
  String _pc = '';
  String _cursor = ''; // the newest id downloaded: a note deleted here is not downloaded again
  bool _syncing = false;

  List<VoiceNote> of(String session) => notes.value.where((n) => n.session == session).toList();

  Future<void> open(Pc pc) async {
    final key = pc.pin.substring(0, 16);
    if (key == _pc) return;
    _pc = key;
    notes.value = [];
    _cursor = '';
    final dir = Directory('${(await getApplicationDocumentsDirectory()).path}/voices/$key');
    await dir.create(recursive: true);
    if (_pc != key) return;
    _dir = dir;
    try {
      final index = File('${dir.path}/index.json');
      if (await index.exists()) {
        final list = (jsonDecode(await index.readAsString()) as List).cast<Map<String, dynamic>>();
        notes.value = [for (final j in list) VoiceNote.fromJson(j)].where((n) => File(n.file).existsSync()).toList();
      }
      final cursor = File('${dir.path}/cursor.txt');
      _cursor = await cursor.exists() ? (await cursor.readAsString()).trim() : (notes.value.isEmpty ? '' : notes.value.last.id);
    } on Object {
      notes.value = [];
    }
  }

  Future<void> _save() async {
    final dir = _dir;
    if (dir == null) return;
    final tmp = File('${dir.path}/index.json.tmp');
    await tmp.writeAsString(jsonEncode([for (final n in notes.value) n.toJson()]));
    await tmp.rename('${dir.path}/index.json');
    await File('${dir.path}/cursor.txt').writeAsString(_cursor);
  }

  /// Downloads what the PC said since the last note kept here. One at a time, in order: a failure leaves the rest
  /// for the next try.
  Future<void> sync(Api api) async {
    final dir = _dir;
    if (_syncing || dir == null || _pc != api.pc.pin.substring(0, 16)) return;
    _syncing = true;
    final probe = AudioPlayer();
    try {
      final remote = ((await api.voices(_cursor))['voices'] as List? ?? []).cast<Map<String, dynamic>>();
      for (final v in remote) {
        final id = '${v['id']}';
        if (id.compareTo(_cursor) <= 0 || notes.value.any((n) => n.id == id)) continue;
        final answer = await api.voice(id);
        if (_dir != dir) return; // another PC was picked meanwhile
        final file = File('${dir.path}/$id.mp3');
        await file.writeAsBytes(base64Decode('${answer['audio']}'), flush: true);
        final note = VoiceNote(id: id, at: '${v['at'] ?? ''}', session: '${v['session'] ?? ''}', name: '${v['name'] ?? ''}', text: '${v['text'] ?? ''}', file: file.path);
        // Its length, shown before playing it, as WhatsApp does.
        try {
          await probe.setSource(DeviceFileSource(file.path));
          note.ms = (await probe.getDuration())?.inMilliseconds;
        } on Object {
          // Shown once it plays.
        }
        notes.value = [...notes.value, note]..sort((a, b) => a.id.compareTo(b.id));
        if (id.compareTo(_cursor) > 0) _cursor = id;
        await _save();
      }
    } on Object {
      // Offline or the PC without voice: the panel's banner says so; tried again on the next refresh.
    } finally {
      _syncing = false;
      unawaited(probe.dispose());
    }
  }

  Future<void> remember(VoiceNote note, int ms) async {
    if (note.ms == ms) return;
    note.ms = ms;
    await _save();
  }

  Future<void> delete(VoiceNote note) async {
    if (VoicePlayer.instance.current.value == note.id) await VoicePlayer.instance.stop();
    notes.value = notes.value.where((n) => n.id != note.id).toList();
    await _save();
    try {
      await File(note.file).delete();
    } on Object {
      // Already gone.
    }
  }
}

/// One player for every note: starting one stops the one playing.
class VoicePlayer {
  VoicePlayer._() {
    _player.onPositionChanged.listen((p) => position.value = p);
    _player.onDurationChanged.listen((d) {
      duration.value = d;
      final note = _note;
      if (note != null && d > Duration.zero) VoiceStore.instance.remember(note, d.inMilliseconds);
    });
    _player.onPlayerStateChanged.listen((s) => playing.value = s == PlayerState.playing);
    _player.onPlayerComplete.listen((_) {
      current.value = null;
      position.value = Duration.zero;
      playing.value = false;
    });
  }
  static final instance = VoicePlayer._();

  final _player = AudioPlayer();
  VoiceNote? _note;
  final current = ValueNotifier<String?>(null);
  final position = ValueNotifier<Duration>(Duration.zero);
  final duration = ValueNotifier<Duration>(Duration.zero);
  final playing = ValueNotifier<bool>(false);
  final speed = ValueNotifier<double>(1);

  Future<void> toggle(VoiceNote note) async {
    if (current.value == note.id) {
      playing.value ? await _player.pause() : await _player.resume();
      return;
    }
    await _player.stop();
    _note = note;
    current.value = note.id;
    position.value = Duration.zero;
    duration.value = Duration(milliseconds: note.ms ?? 0);
    await _player.play(DeviceFileSource(note.file));
    await _player.setPlaybackRate(speed.value);
  }

  Future<void> seek(VoiceNote note, double fraction) async {
    if (current.value != note.id) await toggle(note);
    final total = duration.value.inMilliseconds > 0 ? duration.value : Duration(milliseconds: note.ms ?? 0);
    await _player.seek(total * fraction);
  }

  /// 1x, 1.5x, 2x and back, like WhatsApp.
  Future<void> nextSpeed() async {
    speed.value = speed.value == 1 ? 1.5 : speed.value == 1.5 ? 2 : 1;
    if (current.value != null) await _player.setPlaybackRate(speed.value);
  }

  Future<void> stop() async {
    await _player.stop();
    current.value = null;
    position.value = Duration.zero;
  }
}

String clockLabel(Duration d) => '${d.inMinutes}:${(d.inSeconds % 60).toString().padLeft(2, '0')}';

/// A voice note as a chat bubble on Claude's side: play or pause, a bar to move through it, its length or where it
/// is, the speed while it plays, and what it said underneath.
class VoiceBubble extends StatelessWidget {
  const VoiceBubble({super.key, required this.note, required this.palette, required this.size, this.first = true, this.showName = false});

  final VoiceNote note;
  final ChatPalette palette;
  final double size;
  final bool first;
  final bool showName;

  @override
  Widget build(BuildContext context) {
    final player = VoicePlayer.instance;
    final fg = palette.theirsText;
    const r = Radius.circular(18);
    return Align(
      alignment: Alignment.centerLeft,
      child: Container(
        constraints: const BoxConstraints(maxWidth: 340),
        margin: EdgeInsets.only(top: first ? 10 : 3, right: 32),
        padding: const EdgeInsets.fromLTRB(4, 4, 12, 6),
        decoration: BoxDecoration(
          color: palette.theirs,
          borderRadius: BorderRadius.only(topLeft: first ? const Radius.circular(4) : r, topRight: r, bottomLeft: r, bottomRight: r),
        ),
        child: ListenableBuilder(
          listenable: Listenable.merge([player.current, player.position, player.duration, player.playing, player.speed]),
          builder: (context, _) {
            final mine = player.current.value == note.id;
            final total = mine && player.duration.value > Duration.zero ? player.duration.value : Duration(milliseconds: note.ms ?? 0);
            final at = mine ? player.position.value : Duration.zero;
            final fraction = total.inMilliseconds > 0 ? (at.inMilliseconds / total.inMilliseconds).clamp(0.0, 1.0) : 0.0;
            final small = TextStyle(color: fg.withOpacity(0.7), fontSize: size * 0.7);
            return Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
              if (showName && note.name.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.fromLTRB(10, 4, 0, 0),
                  child: Text(note.name, style: TextStyle(color: fg, fontWeight: FontWeight.w700, fontSize: size * 0.85)),
                ),
              Row(children: [
                IconButton(
                  tooltip: mine && player.playing.value ? S.pause : S.play,
                  iconSize: size * 2.2,
                  color: fg,
                  onPressed: () => player.toggle(note),
                  icon: Icon(mine && player.playing.value ? Icons.pause_circle_filled : Icons.play_circle_filled),
                ),
                Expanded(
                  child: SliderTheme(
                    data: SliderTheme.of(context).copyWith(
                      trackHeight: 3,
                      thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 7),
                      overlayShape: SliderComponentShape.noOverlay,
                      activeTrackColor: fg,
                      inactiveTrackColor: fg.withOpacity(0.25),
                      thumbColor: fg,
                    ),
                    child: Slider(value: fraction, onChanged: (v) => player.seek(note, v)),
                  ),
                ),
                if (mine)
                  Padding(
                    padding: const EdgeInsets.only(left: 6),
                    child: ActionChip(
                      visualDensity: VisualDensity.compact,
                      label: Text('${player.speed.value == 1.5 ? '1.5' : player.speed.value.toInt()}×'),
                      onPressed: player.nextSpeed,
                    ),
                  ),
              ]),
              Padding(
                padding: const EdgeInsets.only(left: 12),
                child: Row(children: [
                  Text(clockLabel(mine && at > Duration.zero ? at : total), style: small),
                  const Spacer(),
                  Text(timeLabel(note.at), style: small),
                ]),
              ),
              if (note.text.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.fromLTRB(12, 4, 0, 0),
                  child: SelectableText(note.text, style: TextStyle(color: fg.withOpacity(0.85), fontSize: size * 0.8, height: 1.3)),
                ),
            ]);
          },
        ),
      ),
    );
  }
}

/// Every note kept from this PC, newest first, with who said it; a long press deletes one from the phone.
class VoiceNotesPage extends StatelessWidget {
  const VoiceNotesPage({super.key, required this.sessionColor});

  final Color sessionColor;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(S.voiceNotes)),
      body: ValueListenableBuilder<ChatStyle>(
        valueListenable: chatStyle,
        builder: (context, style, _) {
          final p = style.palette.forSession(sessionColor);
          return ValueListenableBuilder<List<VoiceNote>>(
            valueListenable: VoiceStore.instance.notes,
            builder: (context, notes, _) {
              final list = notes.reversed.toList();
              return Container(
                color: p.background,
                child: list.isEmpty
                    ? Center(child: Padding(padding: const EdgeInsets.all(32), child: Text(S.noVoiceNotes, textAlign: TextAlign.center, style: TextStyle(color: p.muted))))
                    : ListView.builder(
                        padding: const EdgeInsets.fromLTRB(10, 4, 10, 16),
                        itemCount: list.length,
                        itemBuilder: (context, i) {
                          final note = list[i];
                          final day = _day(note.at);
                          final dayBefore = i > 0 ? _day(list[i - 1].at) : null;
                          return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                            if (day != null && day != dayBefore)
                              Center(
                                child: Container(
                                  margin: const EdgeInsets.only(top: 14, bottom: 4),
                                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                                  decoration: BoxDecoration(color: p.theirs, borderRadius: BorderRadius.circular(12)),
                                  child: Text(dayLabel(day, DateTime.now()), style: TextStyle(color: p.muted, fontSize: style.fontSize * 0.75)),
                                ),
                              ),
                            GestureDetector(
                              onLongPress: () => _confirmDelete(context, note),
                              child: VoiceBubble(note: note, palette: p, size: style.fontSize, showName: true),
                            ),
                          ]);
                        },
                      ),
              );
            },
          );
        },
      ),
    );
  }

  static DateTime? _day(String at) {
    final t = DateTime.tryParse(at)?.toLocal();
    return t == null ? null : DateTime(t.year, t.month, t.day);
  }

  Future<void> _confirmDelete(BuildContext context, VoiceNote note) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        content: Text(S.deleteVoiceNote),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: Text(S.cancel)),
          TextButton(onPressed: () => Navigator.pop(context, true), child: Text(S.delete)),
        ],
      ),
    );
    if (ok == true) await VoiceStore.instance.delete(note);
  }
}
