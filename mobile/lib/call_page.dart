// The screen of a call (lib/call.dart). Leaving it doesn't hang up.
import 'package:flutter/material.dart';

import 'call.dart';
import 'strings.dart';

class CallPage extends StatelessWidget {
  const CallPage({super.key, required this.color});

  final Color color;

  @override
  Widget build(BuildContext context) {
    final call = Call.instance;
    final theme = Theme.of(context);
    const tall = Size.fromHeight(64);
    return Scaffold(
      appBar: AppBar(title: Text(S.callTitle)),
      body: SafeArea(
        child: ListenableBuilder(
          listenable: call,
          builder: (context, _) {
            final listening = call.phase == CallPhase.listening;
            return Padding(
              padding: const EdgeInsets.all(20),
              child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                Icon(listening ? Icons.mic : call.active ? Icons.call : Icons.call_end, size: 64, color: color),
                const SizedBox(height: 12),
                Text(call.name, textAlign: TextAlign.center, style: theme.textTheme.headlineSmall),
                Semantics(
                  liveRegion: true,
                  child: Text(call.statusText, textAlign: TextAlign.center, style: theme.textTheme.titleMedium),
                ),
                const SizedBox(height: 16),
                Expanded(
                  child: ListView(children: [
                    if (call.heard.isNotEmpty)
                      ListTile(title: Text(call.headset ? S.youHeadset : S.you), subtitle: Text(call.heard)),
                    if (call.said.isNotEmpty) ListTile(title: Text(call.name), subtitle: Text(call.said)),
                  ]),
                ),
                if (call.active) ...[
                  Text(S.callGestures, textAlign: TextAlign.center, style: theme.textTheme.bodySmall),
                  const SizedBox(height: 12),
                  if (call.canAccept) ...[
                    FilledButton.icon(
                      style: FilledButton.styleFrom(minimumSize: tall),
                      onPressed: () => call.press('primary'),
                      icon: const Icon(Icons.check),
                      label: Text(S.accept),
                    ),
                    const SizedBox(height: 8),
                  ],
                  FilledButton.tonalIcon(
                    style: FilledButton.styleFrom(minimumSize: tall),
                    onPressed: () => call.press('talk'),
                    icon: Icon(listening ? Icons.stop : Icons.mic),
                    label: Text(listening ? S.doneTalking : S.talk),
                  ),
                  const SizedBox(height: 8),
                  FilledButton.icon(
                    style: FilledButton.styleFrom(
                      minimumSize: tall,
                      backgroundColor: theme.colorScheme.error,
                      foregroundColor: theme.colorScheme.onError,
                    ),
                    onPressed: () async {
                      final navigator = Navigator.of(context);
                      await call.hangUp();
                      await navigator.maybePop();
                    },
                    icon: const Icon(Icons.call_end),
                    label: Text(S.hangUp),
                  ),
                ],
              ]),
            );
          },
        ),
      ),
    );
  }
}
