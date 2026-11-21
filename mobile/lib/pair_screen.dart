// Agregar PC: scan the QR that ClaudeMaxxing shows in Celular and pair with that PC.
import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import 'api.dart';
import 'strings.dart';

class PairScreen extends StatefulWidget {
  const PairScreen({super.key});

  @override
  State<PairScreen> createState() => _PairScreenState();
}

class _PairScreenState extends State<PairScreen> {
  final _name = TextEditingController(text: S.defaultDeviceName);
  final _scanner = MobileScannerController(formats: const [BarcodeFormat.qrCode]);
  bool _busy = false;
  String _error = '';

  @override
  void dispose() {
    _scanner.dispose();
    _name.dispose();
    super.dispose();
  }

  Future<void> _onDetect(BarcodeCapture capture) async {
    if (_busy) return;
    final raw = capture.barcodes.map((b) => b.rawValue).whereType<String>().firstOrNull;
    if (raw == null) return;
    final info = PairInfo.parse(raw);
    if (info == null) {
      setState(() => _error = S.notAQr);
      return;
    }
    setState(() {
      _busy = true;
      _error = '';
    });
    try {
      final name = _name.text.trim().isEmpty ? S.defaultDeviceName : _name.text.trim();
      final pc = await pair(info, name);
      if (mounted) Navigator.of(context).pop(pc);
    } on ApiError catch (e) {
      setState(() {
        _busy = false;
        _error = e.status == 401 ? S.codeRefused : S.unreachable(e.message);
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: Text(S.addPc)),
      body: ListView(padding: const EdgeInsets.all(16), children: [
        TextField(controller: _name, decoration: InputDecoration(labelText: S.deviceName, border: const OutlineInputBorder())),
        const SizedBox(height: 16),
        Text(S.scanTitle, style: theme.textTheme.titleMedium),
        const SizedBox(height: 4),
        Text(S.scanHelp, style: theme.textTheme.bodySmall),
        const SizedBox(height: 12),
        AspectRatio(
          aspectRatio: 1,
          child: ClipRRect(
            borderRadius: BorderRadius.circular(16),
            child: Stack(fit: StackFit.expand, children: [
              MobileScanner(controller: _scanner, onDetect: _onDetect),
              if (_busy)
                Container(
                  color: Colors.black54,
                  alignment: Alignment.center,
                  child: Column(mainAxisSize: MainAxisSize.min, children: [
                    const CircularProgressIndicator(),
                    const SizedBox(height: 12),
                    Text(S.pairing, style: const TextStyle(color: Colors.white)),
                  ]),
                ),
            ]),
          ),
        ),
        if (_error.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 12),
            child: Text(_error, style: TextStyle(color: theme.colorScheme.error)),
          ),
      ]),
    );
  }
}
