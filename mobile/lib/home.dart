// One PC: the panel first, then every session open on it, one page each; swipe sideways to go from one to the next.
import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:speech_to_text/speech_to_text.dart';

import 'api.dart';
import 'call.dart';
import 'call_page.dart';
import 'chat.dart';
import 'chat_style.dart';
import 'eggs.dart';
import 'items.dart';
import 'logic.dart';
import 'notify.dart';
import 'strings.dart';
import 'voices.dart';

class HomePager extends StatefulWidget {
  const HomePager({super.key, required this.pc, required this.menu, required this.onRevoked});

  final Pc pc;
  final Widget menu;
  final VoidCallback onRevoked;

  @override
  State<HomePager> createState() => _HomePagerState();
}

class _HomePagerState extends State<HomePager> {
  late Api _api = Api(widget.pc);
  final _pages = PageController();
  Map<String, dynamic>? _state;
  String _error = '';
  int _page = 0;
  Timer? _timer;

  List<Map<String, dynamic>> get _sessions => (_state?['sessions'] as List? ?? []).cast<Map<String, dynamic>>();

  @override
  void initState() {
    super.initState();
    SessionNotification.instance.update(_api, []);
    VoiceStore.instance.open(widget.pc);
    _refresh();
    _timer = Timer.periodic(const Duration(seconds: 3), (_) => _refresh());
  }

  @override
  void didUpdateWidget(HomePager old) {
    super.didUpdateWidget(old);
    if (old.pc != widget.pc) {
      _api = Api(widget.pc);
      SessionNotification.instance.update(_api, []);
      VoiceStore.instance.open(widget.pc);
      _state = null;
      _page = 0;
      if (_pages.hasClients) _pages.jumpToPage(0);
      _refresh();
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    SessionNotification.instance.stop();
    _pages.dispose();
    super.dispose();
  }

  Future<void> _refresh({bool force = false}) async {
    final api = _api;
    try {
      final state = await api.state(refresh: force);
      if (!mounted || api != _api) return;
      final before = _sessions.map((s) => '${s['id']}').toList();
      final after = (state['sessions'] as List? ?? []).map((s) => '${(s as Map)['id']}').toList();
      final page = pageAfterChange(before, after, _page);
      // A PC from before the symbols only has the egg.
      EggCache.use(api.pc.pin, '${state['symbol'] ?? 'egg'}');
      setState(() {
        _state = state;
        _error = '';
        _page = page;
      });
      SessionNotification.instance.update(api, _sessions);
      // The voice notes are saved on the phone as soon as the PC has them, whichever page is open.
      unawaited(VoiceStore.instance.sync(api));
      if (_pages.hasClients && _pages.page?.round() != page) _pages.jumpToPage(page);
    } on ApiError catch (e) {
      if (!mounted || api != _api) return;
      if (e.status == 401) {
        _timer?.cancel();
        SessionNotification.instance.stop();
        widget.onRevoked();
        return;
      }
      setState(() => _error = e.message);
    }
  }

  @override
  Widget build(BuildContext context) {
    final sessions = _sessions;
    final current = _page > 0 && _page <= sessions.length ? sessions[_page - 1] : null;
    final theme = Theme.of(context);
    final small = theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant);
    // The session's statusline under its name: where it runs, then model (effort in subtle italics), context, cost, time.
    final status = current == null ? null : statusParts(current['status']);
    return Scaffold(
      appBar: AppBar(
        toolbarHeight: status == null ? null : 76,
        title: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(current == null ? widget.pc.name : '${current['name']}', overflow: TextOverflow.ellipsis),
          if (status == null)
            Text(current == null ? S.panel : '${current['folder']} · ${widget.pc.name}', style: small)
          else ...[
            Row(children: [
              Icon(Icons.folder_outlined, size: 14, color: small?.color),
              const SizedBox(width: 4),
              Flexible(child: Text(status.place, style: small, maxLines: 1, overflow: TextOverflow.ellipsis)),
            ]),
            Text.rich(
              TextSpan(style: small, children: [
                TextSpan(text: status.model),
                if (status.effort.isNotEmpty)
                  TextSpan(text: '${status.model.isEmpty ? '' : ' '}${status.effort}',
                      style: TextStyle(fontStyle: FontStyle.italic, color: small?.color?.withOpacity(0.65))),
                if (status.run.isNotEmpty) TextSpan(text: '${status.model.isEmpty && status.effort.isEmpty ? '' : ' · '}${status.run}'),
              ]),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ],
        ]),
        actions: [
          IconButton(
            tooltip: S.voiceNotes,
            icon: const Icon(Icons.headphones_outlined),
            onPressed: () => Navigator.of(context).push(MaterialPageRoute<void>(
                builder: (_) => VoiceNotesPage(sessionColor: hexColor('${current?['color']}') ?? theme.colorScheme.primary))),
          ),
          widget.menu,
        ],
      ),
      body: Column(children: [
        if (_error.isNotEmpty)
          MaterialBanner(
            content: Text('${S.offline}: $_error', maxLines: 2, overflow: TextOverflow.ellipsis),
            actions: [TextButton(onPressed: _refresh, child: Text(S.retrying))],
          ),
        Expanded(
          child: _state == null
              ? Center(child: _error.isEmpty ? const CircularProgressIndicator() : Text(S.offline))
              : PageView.builder(
                  controller: _pages,
                  itemCount: 1 + sessions.length,
                  onPageChanged: (p) => setState(() => _page = p),
                  itemBuilder: (context, i) => i == 0
                      ? PanelPage(api: _api, state: _state!, onRefresh: () => _refresh(force: true),
                          onOpenSession: (k) => _pages.animateToPage(k + 1, duration: const Duration(milliseconds: 250), curve: Curves.easeOut))
                      : SessionPage(key: ValueKey((_api.pc.pin, sessions[i - 1]['id'])), api: _api, session: sessions[i - 1], active: _page == i),
                ),
        ),
        _Dots(api: _api, sessions: sessions, page: _page, onTap: (p) => _pages.animateToPage(p, duration: const Duration(milliseconds: 250), curve: Curves.easeOut)),
      ]),
    );
  }
}

class _Dots extends StatelessWidget {
  const _Dots({required this.api, required this.sessions, required this.page, required this.onTap});

  final Api api;
  final List<Map<String, dynamic>> sessions;
  final int page;
  final ValueChanged<int> onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return SafeArea(
      top: false,
      child: SizedBox(
        height: 40,
        child: Center(
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              IconButton(
                tooltip: S.panel,
                visualDensity: VisualDensity.compact,
                onPressed: () => onTap(0),
                icon: Icon(Icons.dashboard_outlined, size: 20, color: page == 0 ? scheme.primary : scheme.onSurfaceVariant),
              ),
              for (var i = 0; i < sessions.length; i++)
                IconButton(
                  key: ValueKey(sessions[i]['id']),
                  tooltip: '${sessions[i]['name']}',
                  visualDensity: VisualDensity.compact,
                  onPressed: () => onTap(i + 1),
                  icon: Egg(api: api, color: '${sessions[i]['color']}',
                    state: '${sessions[i]['state']}', size: page == i + 1 ? 34 : 28),
                ),
            ]),
          ),
        ),
      ),
    );
  }
}

String stateLabel(String state) => state == 'thinking' ? S.thinking : state == 'speaking' ? S.speaking : S.idle;

/// The panel: the plan, the open sessions and the sections of ClaudeMaxxing's side menu.
class PanelPage extends StatelessWidget {
  const PanelPage({super.key, required this.api, required this.state, required this.onOpenSession, required this.onRefresh});

  final Api api;
  final Map<String, dynamic> state;
  final ValueChanged<int> onOpenSession;
  final Future<void> Function() onRefresh;

  Future<void> _endAction(BuildContext context, String id, int? arg) async {
    final messenger = ScaffoldMessenger.of(context);
    try {
      final answer = await api.action('power', id, arg);
      final message = '${answer['message'] ?? ''}';
      if (message.isNotEmpty) messenger.showSnackBar(SnackBar(content: Text(message)));
    } on ApiError catch (e) {
      messenger.showSnackBar(SnackBar(content: Text(e.message)));
    }
    await onRefresh();
  }

  @override
  Widget build(BuildContext context) {
    final plan = state['plan'] as Map<String, dynamic>? ?? {};
    final account = state['account'] as Map<String, dynamic>?;
    final sessions = (state['sessions'] as List? ?? []).cast<Map<String, dynamic>>();
    final sections = (state['sections'] as List? ?? []).cast<Map<String, dynamic>>();
    Map<String, dynamic> meter(String label, dynamic w) =>
        {'t': 'meter', 'label': label, 'percent': w == null ? null : w['percent'], 'sub': w == null ? '' : w['reset']};
    final newSession = state['newSession'] as Map<String, dynamic>?;
    final endItems = (state['endItems'] as List? ?? []).cast<Map<String, dynamic>>();
    return RefreshIndicator(onRefresh: onRefresh, child: ListView(physics: const AlwaysScrollableScrollPhysics(), children: [
      if (newSession != null) NewSessionButton(api: api, item: newSession),
      if (account != null)
        ListTile(
          leading: const Icon(Icons.account_circle_outlined),
          title: Text('${account['title']}'),
          subtitle: '${account['detail']}'.isEmpty ? null : Text('${account['detail']}'),
        ),
      Card(
        margin: const EdgeInsets.fromLTRB(12, 12, 12, 4),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 6),
          child: ItemsView(items: [meter(S.session5h, plan['session']), meter(S.week, plan['weekly'])], onAction: (_, __) async {}),
        ),
      ),
      ItemsView(items: [
        {'t': 'caption', 'text': S.sessions},
      ], onAction: (_, __) async {}),
      if (sessions.isEmpty)
        Padding(padding: const EdgeInsets.symmetric(horizontal: 16), child: Text(S.noSessions)),
      for (var i = 0; i < sessions.length; i++)
        ListTile(
          leading: Egg(api: api, color: '${sessions[i]['color']}', state: '${sessions[i]['state']}'),
          title: Text('${sessions[i]['name']}${'${sessions[i]['role']}'.isEmpty ? '' : ' · ${sessions[i]['role']}'}'),
          subtitle: Text('${sessions[i]['folder']} · ${stateLabel('${sessions[i]['state']}')}'),
          trailing: const Icon(Icons.chevron_right),
          onTap: () => onOpenSession(i),
        ),
      const Divider(height: 24),
      for (final s in sections)
        ListTile(
          title: Text('${s['label']}'),
          trailing: const Icon(Icons.chevron_right),
          onTap: () => Navigator.of(context).push(MaterialPageRoute(
            builder: (_) => SectionScreen(api: api, id: '${s['id']}', title: '${s['label']}'),
          )),
        ),
      // Last and in red: close every session, sign Claude out on the PC (registered under power, lib\mobile.ps1).
      if (endItems.isNotEmpty) ...[
        const Divider(height: 24),
        ItemsView(items: endItems, onAction: (id, arg) => _endAction(context, id, arg)),
      ],
      const SizedBox(height: 24),
    ]));
  }
}

/// First in the panel: a new Claude Code session in one of the PC's recent folders, two taps.
/// The item is Claude Code's Nueva sesion (lib\mobile.ps1): its step is the folder's place in the options.
class NewSessionButton extends StatelessWidget {
  const NewSessionButton({super.key, required this.api, required this.item});

  final Api api;
  final Map<String, dynamic> item;

  Future<void> _pick(BuildContext context) async {
    final options = (item['options'] as List).cast<Map<String, dynamic>>();
    final step = await showModalBottomSheet<int>(
      context: context,
      showDragHandle: true,
      builder: (context) => SafeArea(
        child: ListView(shrinkWrap: true, children: [
          for (var i = 0; i < options.length; i++)
            if ('${options[i]['k']}'.isNotEmpty)
              ListTile(
                leading: const Icon(Icons.folder_outlined),
                title: Text('${options[i]['label']}'),
                subtitle: Text('${options[i]['k']}', maxLines: 1, overflow: TextOverflow.ellipsis),
                onTap: () => Navigator.pop(context, i),
              ),
        ]),
      ),
    );
    if (step == null || !context.mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    try {
      final answer = await api.action('code', '${item['id']}', step);
      final message = '${answer['message'] ?? ''}';
      if (message.isNotEmpty) messenger.showSnackBar(SnackBar(content: Text(message)));
    } on ApiError catch (e) {
      messenger.showSnackBar(SnackBar(content: Text(e.message)));
    }
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 0),
      child: FilledButton.icon(
        style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(52)),
        onPressed: () => _pick(context),
        icon: const Icon(Icons.add),
        label: Text('${item['label']}'),
      ),
    );
  }
}

/// One section of the panel, refreshed every 5 seconds while it is open.
class SectionScreen extends StatefulWidget {
  const SectionScreen({super.key, required this.api, required this.id, required this.title});

  final Api api;
  final String id;
  final String title;

  @override
  State<SectionScreen> createState() => _SectionScreenState();
}

class _SectionScreenState extends State<SectionScreen> {
  List<Map<String, dynamic>>? _items;
  String _error = '';
  bool _busy = false;
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _load();
    _timer = Timer.periodic(const Duration(seconds: 5), (_) {
      if (!_busy) _load();
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  void _show(Map<String, dynamic> section) {
    setState(() {
      _items = (section['items'] as List? ?? []).cast<Map<String, dynamic>>();
      _error = '';
    });
  }

  Future<void> _load() async {
    try {
      final section = await widget.api.section(widget.id);
      if (mounted) _show(section);
    } on ApiError catch (e) {
      if (mounted) setState(() => _error = e.message);
    }
  }

  Future<void> _act(String id, int? arg) async {
    setState(() => _busy = true);
    try {
      final answer = await widget.api.action(widget.id, id, arg);
      if (!mounted) return;
      _show(answer['section'] as Map<String, dynamic>);
      final message = '${answer['message'] ?? ''}';
      if (message.isNotEmpty) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
    } on ApiError catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.message)));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(widget.title), bottom: _busy ? const PreferredSize(preferredSize: Size.fromHeight(2), child: LinearProgressIndicator(minHeight: 2)) : null),
      body: RefreshIndicator(
        onRefresh: _load,
        child: ListView(padding: EdgeInsets.only(bottom: MediaQuery.of(context).padding.bottom), children: [
          if (_error.isNotEmpty) Padding(padding: const EdgeInsets.all(16), child: Text(_error, style: TextStyle(color: Theme.of(context).colorScheme.error))),
          if (_items == null && _error.isEmpty) const Padding(padding: EdgeInsets.all(32), child: Center(child: CircularProgressIndicator())),
          if (_items != null)
            ItemsView(
              items: _items!,
              onAction: _act,
              busy: _busy,
              optionPreview: (symbol, color) => Row(mainAxisSize: MainAxisSize.min, children: [
                Egg(api: widget.api, color: color, symbol: symbol, state: 'idle'),
                const SizedBox(width: 4),
                Egg(api: widget.api, color: color, symbol: symbol, state: 'thinking'),
              ]),
            ),
          const SizedBox(height: 24),
        ]),
      ),
    );
  }
}

/// A session: its conversation, read from the transcript every 2 seconds while the page is on screen, and a box to write.
class SessionPage extends StatefulWidget {
  const SessionPage({super.key, required this.api, required this.session, required this.active});

  final Api api;
  final Map<String, dynamic> session;
  final bool active;

  @override
  State<SessionPage> createState() => _SessionPageState();
}

enum _AttachmentSource { camera, gallery, document, audio }

class _SessionPageState extends State<SessionPage> with AutomaticKeepAliveClientMixin, SingleTickerProviderStateMixin {
  final _scroll = ScrollController();
  final _input = TextEditingController();
  List<Map<String, dynamic>> _items = [];
  int _offset = -1;
  bool _loading = false;
  bool _sending = false;
  bool _attaching = false;
  bool _uploading = false;
  bool _listening = false;
  bool _startingDictation = false;
  late final _micPulse = AnimationController(
    vsync: this, duration: const Duration(milliseconds: 650), lowerBound: 0.8, upperBound: 1,
  );
  static final _speech = SpeechToText();
  static _SessionPageState? _dictating;
  static const _maxAttachmentBytes = 25 * 1024 * 1024;
  Timer? _timer;

  String get _id => '${widget.session['id']}';

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    _poll();
    _sync();
  }

  @override
  void didUpdateWidget(SessionPage old) {
    super.didUpdateWidget(old);
    if (old.active != widget.active) _sync();
    if (_dictating == this && (!widget.active || widget.session['canWrite'] != true)) {
      _cancelDictation();
    }
  }

  void _sync() {
    _timer?.cancel();
    _timer = widget.active ? Timer.periodic(const Duration(seconds: 2), (_) => _poll()) : null;
  }

  @override
  void dispose() {
    _timer?.cancel();
    _cancelDictation();
    _micPulse.dispose();
    _scroll.dispose();
    _input.dispose();
    super.dispose();
  }

  Future<void> _poll() async {
    if (_loading) return;
    _loading = true;
    try {
      final answer = await widget.api.messages(_id, _offset);
      if (!mounted) return;
      final atBottom = !_scroll.hasClients || _scroll.position.pixels >= _scroll.position.maxScrollExtent - 80;
      final added = (answer['items'] as List? ?? []).isNotEmpty || answer['reset'] == true;
      setState(() {
        _items = mergeMessages(_items, answer);
        _offset = (answer['offset'] as num?)?.toInt() ?? _offset;
      });
      if (added && atBottom) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (_scroll.hasClients) _scroll.jumpTo(_scroll.position.maxScrollExtent);
        });
      }
    } on ApiError {
      // The panel's banner says the PC is unreachable.
    } finally {
      _loading = false;
    }
  }

  Future<void> _send() async {
    final text = _input.text.trim();
    if (text.isEmpty || _sending || _attaching || widget.session['canWrite'] != true) return;
    setState(() => _sending = true);
    try {
      await widget.api.prompt(_id, text);
      if (!mounted) return;
      if (_input.text.trim() == text) _input.clear();
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(S.sent), duration: const Duration(seconds: 1)));
      _poll();
    } on ApiError catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.message)));
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  void _showMessage(String message) {
    if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
  }

  // The PC closes the session's terminal; the next poll drops this page.
  Future<void> _close() async {
    final yes = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        content: Text(S.closeSessionAsk('${widget.session['name']}')),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: Text(S.cancel)),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: Text(S.yes)),
        ],
      ),
    );
    if (yes != true) return;
    try {
      await widget.api.close(_id);
    } on ApiError catch (e) {
      _showMessage(e.message);
    }
  }

  Future<void> _attach() async {
    setState(() => _attaching = true);
    try {
      final source = await showModalBottomSheet<_AttachmentSource>(
        context: context,
        builder: (context) => SafeArea(
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            for (final (source, icon, label) in [
              (_AttachmentSource.camera, Icons.photo_camera, S.camera),
              (_AttachmentSource.gallery, Icons.photo_library, S.gallery),
              (_AttachmentSource.document, Icons.description, S.document),
              (_AttachmentSource.audio, Icons.audiotrack, S.audio),
            ])
              ListTile(leading: Icon(icon), title: Text(label),
                onTap: () => Navigator.pop(context, source)),
          ]),
        ),
      );
      if (source == null || !mounted) return;
      final String name;
      final Uint8List bytes;
      if (source == _AttachmentSource.camera || source == _AttachmentSource.gallery) {
        final photo = await ImagePicker().pickImage(
          source: source == _AttachmentSource.camera ? ImageSource.camera : ImageSource.gallery,
          imageQuality: source == _AttachmentSource.camera ? 85 : null,
        );
        if (photo == null) return;
        name = photo.name;
        if (await photo.length() > _maxAttachmentBytes) {
          _showMessage(S.attachmentTooLarge);
          return;
        }
        bytes = await photo.readAsBytes();
      } else {
        final selection = await FilePicker.platform.pickFiles(
          type: source == _AttachmentSource.audio ? FileType.audio : FileType.any,
          withData: true,
        );
        if (selection == null) return;
        final file = selection.files.single;
        name = file.name;
        if (file.size > _maxAttachmentBytes) {
          _showMessage(S.attachmentTooLarge);
          return;
        }
        bytes = file.bytes ?? await File(file.path!).readAsBytes();
      }
      if (bytes.length > _maxAttachmentBytes) {
        _showMessage(S.attachmentTooLarge);
        return;
      }
      if (!mounted || widget.session['canWrite'] != true) return;
      final preview = source == _AttachmentSource.camera || source == _AttachmentSource.gallery ||
          attachmentIcon(name) == Icons.image_outlined;
      var draft = '';
      final caption = await showDialog<String>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text(name),
          scrollable: true,
          content: Column(mainAxisSize: MainAxisSize.min, children: [
            if (preview)
              Image.memory(bytes, height: 180, fit: BoxFit.contain,
                errorBuilder: (_, __, ___) => const Icon(Icons.image_outlined)),
            TextField(onChanged: (value) => draft = value, minLines: 1, maxLines: 3,
              decoration: InputDecoration(labelText: S.caption)),
          ]),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context), child: Text(S.cancel)),
            FilledButton(onPressed: () => Navigator.pop(context, draft.trim()), child: Text(S.send)),
          ],
        ),
      );
      if (caption == null || !mounted || widget.session['canWrite'] != true) return;
      setState(() => _uploading = true);
      await widget.api.upload(_id, name, bytes, caption);
      _showMessage(S.sent);
      if (mounted) _poll();
    } catch (error) {
      _showMessage(S.attachmentError(error));
    } finally {
      if (mounted) {
        setState(() {
          _attaching = false;
          _uploading = false;
        });
      }
    }
  }

  Future<void> _call(Color color) async {
    final call = Call.instance;
    final navigator = Navigator.of(context);
    // One call at a time: with one under way, any session's button shows it.
    if (!call.active) {
      if (_dictating == this) {
        _cancelDictation();
        setState(() {});
      }
      if (!await call.start(widget.api, _id, '${widget.session['name']}')) {
        _showMessage(S.callFailed);
        return;
      }
    }
    if (mounted) await navigator.push(MaterialPageRoute<void>(builder: (_) => CallPage(color: color)));
  }

  void _cancelDictation() {
    if (_dictating != this) return;
    _dictating = null;
    _micPulse.stop();
    _listening = false;
    _startingDictation = false;
    unawaited(_speech.cancel());
  }

  Future<void> _toggleDictation() async {
    if (_listening) {
      try {
        await _speech.stop();
      } catch (_) {
        if (_dictating == this) _finishDictation(failed: true);
      }
      return;
    }
    if (_dictating != null) return;
    _dictating = this;
    setState(() => _startingDictation = true);
    try {
      final available = await _speech.initialize(
        onStatus: (status) {
          if (status == SpeechToText.doneStatus) _dictating?._finishDictation();
        },
        onError: (_) => _dictating?._finishDictation(failed: true),
      );
      if (_dictating != this) return;
      if (!available) {
        _finishDictation(failed: true);
        return;
      }
      // The phone's language, not the recognizer's default (often en-US on a Spanish phone).
      final offered = (await _speech.locales()).map((l) => l.localeId).toList();
      final phoneTag = WidgetsBinding.instance.platformDispatcher.locale.toLanguageTag();
      final locale = pickDictationLocale(offered, phoneTag, (await _speech.systemLocale())?.localeId);      if (_dictating != this) return;
      _micPulse.repeat(reverse: true);
      setState(() => _listening = true);
      await _speech.listen(
        // speech_to_text 6 reads the locale from here, not from the options; Google's recognizer takes es-US, and
        // silently falls back to en-US for es_US.
        localeId: locale?.replaceAll('_', '-'),
        listenOptions: SpeechListenOptions(
          listenMode: ListenMode.dictation,
          partialResults: true,
          cancelOnError: true,
        ),
        onResult: (result) {
          if (_dictating != this) return;
          _input.value = TextEditingValue(text: result.recognizedWords,
            selection: TextSelection.collapsed(offset: result.recognizedWords.length));
        },
      );
    } catch (_) {
      if (_dictating == this) _finishDictation(failed: true);
    } finally {
      if (mounted) setState(() => _startingDictation = false);
    }
  }

  void _finishDictation({bool failed = false}) {
    _dictating = null;
    if (!mounted) return;
    _micPulse.stop();
    setState(() => _listening = false);
    if (failed) _showMessage(S.dictationError);
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final theme = Theme.of(context);
    final color = hexColor('${widget.session['color']}') ?? theme.colorScheme.primary;
    final state = '${widget.session['state']}';
    final canWrite = widget.session['canWrite'] == true;
    return Column(children: [
      Container(
        width: double.infinity,
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
        decoration: BoxDecoration(border: Border(bottom: BorderSide(color: color, width: 3))),
        child: Row(children: [
          Egg(api: widget.api, color: '${widget.session['color']}', state: state),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              '${widget.session['role']}'.isEmpty ? stateLabel(state) : '${widget.session['role']} · ${stateLabel(state)}',
              style: theme.textTheme.bodyMedium,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          ListenableBuilder(
            listenable: Call.instance,
            builder: (context, _) {
              final call = Call.instance;
              final here = call.active && call.session == _id;
              return IconButton(
                tooltip: here ? S.backToCall : canWrite ? S.callSession : S.cannotWrite,
                onPressed: canWrite || here ? () => _call(color) : null,
                icon: Icon(here ? Icons.phone_in_talk : Icons.call_outlined),
                color: here ? color : null,
              );
            },
          ),
          IconButton(
            tooltip: S.chatStyle,
            visualDensity: VisualDensity.compact,
            onPressed: () => showChatStyleSheet(context, color),
            icon: const Icon(Icons.palette_outlined),
          ),
          IconButton(
            tooltip: S.closeSession,
            visualDensity: VisualDensity.compact,
            onPressed: _close,
            icon: const Icon(Icons.close),
          ),
        ]),
      ),
      Expanded(
        child: ValueListenableBuilder<List<VoiceNote>>(
          valueListenable: VoiceStore.instance.notes,
          builder: (context, _, __) => ChatView(
            items: withVoices(_items, [for (final n in VoiceStore.instance.of(_id)) {'role': 'voice', 'at': n.at, 'note': n}]),
            controller: _scroll,
            sessionColor: color,
            emptyText: _offset < 0 ? '' : S.emptyChat,
          ),
        ),
      ),
      if (_uploading)
        LinearProgressIndicator(semanticsLabel: S.uploading),
      SafeArea(
        top: false,
        bottom: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(10, 4, 6, 4),
          child: canWrite
              ? Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
                  IconButton(
                    tooltip: S.attach,
                    onPressed: _attaching || _sending || _startingDictation || _listening ? null : _attach,
                    icon: const Icon(Icons.attach_file),
                  ),
                  Expanded(
                    child: ValueListenableBuilder<ChatStyle>(
                      valueListenable: chatStyle,
                      builder: (context, style, _) => TextField(
                        controller: _input,
                        minLines: 1,
                        maxLines: 5,
                        textInputAction: TextInputAction.newline,
                        style: TextStyle(fontSize: style.fontSize.clamp(14, 22).toDouble()),
                        decoration: InputDecoration(
                          hintText: S.writeHint,
                          filled: true,
                          fillColor: theme.colorScheme.surfaceContainerHighest,
                          border: OutlineInputBorder(borderRadius: BorderRadius.circular(24), borderSide: BorderSide.none),
                          contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                          isDense: true,
                        ),
                      ),
                    ),
                  ),
                  ValueListenableBuilder<TextEditingValue>(
                    valueListenable: _input,
                    builder: (context, value, _) {
                      final mic = _listening || value.text.trim().isEmpty;
                      return IconButton.filled(
                        tooltip: _listening ? S.stopDictation : mic ? S.dictate : S.send,
                        style: _listening ? IconButton.styleFrom(backgroundColor: Colors.red, foregroundColor: Colors.white) : null,
                        onPressed: _sending || _attaching || _startingDictation ? null : mic ? _toggleDictation : _send,
                        icon: _sending
                            ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                            : _listening
                                ? ScaleTransition(scale: _micPulse, child: const Icon(Icons.mic))
                                : Icon(mic ? Icons.mic : Icons.send),
                      );
                    },
                  ),
                ])
              : Text(S.cannotWrite, style: theme.textTheme.bodySmall),
        ),
      ),
    ]);
  }
}
