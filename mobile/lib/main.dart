// ClaudeMaxxing for the phone: pairs with the ClaudeMaxxing tray on a Windows PC by QR and shows its panel and its
// open Claude Code sessions. See README > Phone app, and lib\mobile.ps1 in the repo for the PC side.
import 'package:flutter/material.dart';

import 'api.dart';
import 'chat_style.dart';
import 'home.dart';
import 'notify.dart';
import 'pair_screen.dart';
import 'store.dart';
import 'strings.dart';
import 'update.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await loadChatStyle();
  runApp(const ClaudeMaxxingApp());
}

// Claude's orange, the accent of the PC window too.
const _accent = Color(0xFFD97757);

class ClaudeMaxxingApp extends StatelessWidget {
  const ClaudeMaxxingApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'ClaudeMaxxing',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(colorSchemeSeed: _accent, brightness: Brightness.light, useMaterial3: true),
      darkTheme: ThemeData(colorSchemeSeed: _accent, brightness: Brightness.dark, useMaterial3: true),
      home: const Root(),
    );
  }
}

class Root extends StatefulWidget {
  const Root({super.key});

  @override
  State<Root> createState() => _RootState();
}

class _RootState extends State<Root> with WidgetsBindingObserver {
  List<Pc>? _pcs;
  int _current = 0;
  DateTime? _updateCheckedAt;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      SessionNotification.instance.requestPermission();
      _checkUpdate();
    });
    loadPcs().then((pcs) => setState(() => _pcs = pcs));
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  // The app can stay alive for days behind its notification: also on coming back to it, every 6 hours at most.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _checkUpdate();
  }

  Future<void> _checkUpdate() async {
    final last = _updateCheckedAt;
    if (last != null && DateTime.now().difference(last) < const Duration(hours: 6)) return;
    _updateCheckedAt = DateTime.now();
    final version = await findUpdate();
    if (version == null || !mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    messenger.clearMaterialBanners();
    messenger.showMaterialBanner(MaterialBanner(
      content: Text(S.updateAvailable(version)),
      actions: [
        TextButton(onPressed: messenger.hideCurrentMaterialBanner, child: Text(S.updateLater)),
        FilledButton(
          onPressed: () async {
            if (await downloadUpdate()) {
              messenger.hideCurrentMaterialBanner();
            } else {
              messenger.showSnackBar(SnackBar(content: Text(S.updateFailed)));
            }
          },
          child: Text(S.updateDownload),
        ),
      ],
    ));
  }

  Future<void> _add() async {
    final pc = await Navigator.of(context).push<Pc>(MaterialPageRoute(builder: (_) => const PairScreen()));
    if (pc == null) return;
    final pcs = [...?_pcs?.where((p) => p.pin != pc.pin), pc];
    await savePcs(pcs);
    setState(() {
      _pcs = pcs;
      _current = pcs.length - 1;
    });
  }

  Future<void> _forget(Pc pc, {bool tellPc = true}) async {
    if (tellPc) {
      try {
        await Api(pc).unpair();
      } on ApiError {
        // Unreachable: the PC keeps the device until it is revoked there.
      }
    }
    final pcs = [...?_pcs?.where((p) => p != pc)];
    await savePcs(pcs);
    setState(() {
      _pcs = pcs;
      _current = 0;
    });
  }

  @override
  Widget build(BuildContext context) {
    final pcs = _pcs;
    if (pcs == null) return const Scaffold(body: Center(child: CircularProgressIndicator()));
    if (pcs.isEmpty) return _Welcome(onAdd: _add);
    final pc = pcs[_current.clamp(0, pcs.length - 1)];
    final menu = PopupMenuButton<String>(
      icon: const Icon(Icons.computer),
      onSelected: (v) {
        if (v == '+') {
          _add();
        } else if (v == '-') {
          _forget(pc);
        } else {
          setState(() => _current = int.parse(v));
        }
      },
      itemBuilder: (_) => [
        for (var i = 0; i < pcs.length; i++) CheckedPopupMenuItem(value: '$i', checked: pcs[i] == pc, child: Text(pcs[i].name)),
        const PopupMenuDivider(),
        PopupMenuItem(value: '+', child: Text(S.addPc)),
        PopupMenuItem(value: '-', child: Text(S.forget)),
      ],
    );
    return HomePager(
      pc: pc,
      menu: menu,
      onRevoked: () {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(S.revoked)));
        _forget(pc, tellPc: false);
      },
    );
  }
}

class _Welcome extends StatelessWidget {
  const _Welcome({required this.onAdd});

  final VoidCallback onAdd;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(mainAxisAlignment: MainAxisAlignment.center, crossAxisAlignment: CrossAxisAlignment.start, children: [
            ClipRRect(borderRadius: BorderRadius.circular(20), child: Image.asset('assets/logo.png', width: 88, height: 88)),
            const SizedBox(height: 24),
            Text('ClaudeMaxxing', style: theme.textTheme.headlineMedium),
            const SizedBox(height: 8),
            Text(S.welcome, style: theme.textTheme.titleMedium),
            const SizedBox(height: 8),
            Text(S.welcomeHelp, style: theme.textTheme.bodyMedium),
            const SizedBox(height: 32),
            FilledButton.icon(onPressed: onAdd, icon: const Icon(Icons.qr_code_scanner), label: Text(S.addPc)),
          ]),
        ),
      ),
    );
  }
}
