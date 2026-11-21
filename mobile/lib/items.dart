// Draws a section the PC described (lib\mobile.ps1: text, caption, row, meter, switch, button, choice, stepper).
// Every action goes back to the PC by the item's id; the PC answers with the section as it is now.
import 'package:flutter/material.dart';

import 'logic.dart';
import 'strings.dart';

typedef OnAction = Future<void> Function(String id, int? arg);

Color? hexColor(String? hex) {
  if (hex == null || !RegExp(r'^#[0-9a-fA-F]{6}$').hasMatch(hex)) return null;
  return Color(int.parse(hex.substring(1), radix: 16) | 0xFF000000);
}

Color toneColor(BuildContext context, String? tone) {
  final scheme = Theme.of(context).colorScheme;
  switch (tone) {
    case 'ok':
      return Colors.green.shade400;
    case 'warn':
      return Colors.orange.shade400;
    case 'error':
      return scheme.error;
    case 'muted':
      return scheme.onSurfaceVariant;
    case 'faint':
      return scheme.onSurfaceVariant.withOpacity(0.6);
    default:
      return scheme.onSurface;
  }
}

class ItemsView extends StatelessWidget {
  const ItemsView({super.key, required this.items, required this.onAction, this.busy = false});

  final List<Map<String, dynamic>> items;
  final OnAction onAction;
  final bool busy;

  @override
  Widget build(BuildContext context) {
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [for (final item in items) _item(context, item)]);
  }

  // An item with 'confirm' (shut down the PC, switch environment) asks here first: nobody may be at the PC to answer.
  Future<void> _run(BuildContext context, Map<String, dynamic> item, int? arg) async {
    final ask = '${item['confirm'] ?? ''}';
    if (ask.isNotEmpty) {
      final yes = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          content: Text(ask),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context, false), child: Text(S.cancel)),
            FilledButton(onPressed: () => Navigator.pop(context, true), child: Text(S.yes)),
          ],
        ),
      );
      if (yes != true) return;
    }
    await onAction('${item['id'] ?? ''}', arg);
  }

  Widget _item(BuildContext context, Map<String, dynamic> item) {
    final theme = Theme.of(context);
    final enabled = item['enabled'] != false && !busy;
    switch (item['t']) {
      case 'caption':
        return Padding(
          padding: const EdgeInsets.fromLTRB(16, 20, 16, 6),
          child: Row(children: [
            Expanded(child: Text('${item['text']}', style: theme.textTheme.labelMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant, letterSpacing: 0.8))),
            if ('${item['right'] ?? ''}'.isNotEmpty)
              Flexible(child: Text('${item['right']}', textAlign: TextAlign.end, style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant))),
          ]),
        );
      case 'text':
        return Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
          child: Text('${item['text']}', style: theme.textTheme.bodyMedium?.copyWith(color: toneColor(context, item['tone'] as String?))),
        );
      case 'row':
        final dot = hexColor(item['color'] as String?);
        return ListTile(
          dense: true,
          leading: dot == null ? null : CircleAvatar(radius: 7, backgroundColor: dot),
          title: Text('${item['label']}', style: TextStyle(color: toneColor(context, item['tone'] as String?))),
          subtitle: '${item['sub'] ?? ''}'.isEmpty ? null : Text('${item['sub']}'),
          trailing: '${item['right'] ?? ''}'.isEmpty ? null : Text('${item['right']}', style: theme.textTheme.bodySmall),
        );
      case 'meter':
        final pct = item['percent'] as num?;
        return Padding(
          padding: const EdgeInsets.fromLTRB(16, 10, 16, 6),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              Expanded(child: Text('${item['label']}', style: theme.textTheme.labelMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant))),
              Text(pct == null ? '–' : '$pct %', style: theme.textTheme.titleLarge),
            ]),
            const SizedBox(height: 6),
            ClipRRect(
              borderRadius: BorderRadius.circular(4),
              child: LinearProgressIndicator(
                value: pct == null ? 0 : (pct / 100).clamp(0, 1).toDouble(),
                minHeight: 8,
                color: pct != null && pct >= 90 ? Colors.orange.shade400 : null,
              ),
            ),
            const SizedBox(height: 4),
            Text('${item['sub'] ?? ''}', style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
          ]),
        );
      case 'switch':
        return SwitchListTile(
          title: Text('${item['label']}'),
          subtitle: '${item['sub'] ?? ''}'.isEmpty ? null : Text('${item['sub']}'),
          value: item['on'] == true,
          onChanged: enabled ? (_) => _run(context, item, null) : null,
        );
      case 'button':
        final onPc = item['pc'] == true;
        // The computer icon says it happens on the PC.
        final label = Text('${item['label']}');
        final icon = Icon(onPc ? Icons.computer : Icons.play_arrow, size: 18);
        return Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
          child: Align(
            alignment: Alignment.centerLeft,
            child: item['accent'] == true
                ? FilledButton.icon(onPressed: enabled ? () => _run(context, item, null) : null, icon: icon, label: label)
                : OutlinedButton.icon(onPressed: enabled ? () => _run(context, item, null) : null, icon: icon, label: label),
          ),
        );
      case 'choice':
        final options = (item['options'] as List).cast<Map<String, dynamic>>();
        final keys = options.map((o) => '${o['k']}').toList();
        final current = '${item['current'] ?? ''}';
        final absolute = item['absolute'] == true;
        return ListTile(
          title: Text('${item['label']}'),
          trailing: DropdownButton<String>(
            value: keys.contains(current) ? current : null,
            hint: absolute ? Text('${options.first['label']}') : null,
            onChanged: enabled
                ? (k) {
                    if (k == null || k == current) return;
                    _run(context, item, choiceStep(keys, current, k, absolute: absolute));
                  }
                : null,
            items: [
              for (final o in options)
                if (!(absolute && '${o['k']}'.isEmpty))
                  DropdownMenuItem(value: '${o['k']}', child: ConstrainedBox(constraints: const BoxConstraints(maxWidth: 180), child: Text('${o['label']}', overflow: TextOverflow.ellipsis))),
            ],
          ),
        );
      case 'stepper':
        return ListTile(
          title: Text('${item['label']}'),
          trailing: Row(mainAxisSize: MainAxisSize.min, children: [
            IconButton(onPressed: enabled ? () => _run(context, item, -1) : null, icon: const Icon(Icons.remove_circle_outline)),
            Text('${item['value']}', style: theme.textTheme.titleMedium),
            IconButton(onPressed: enabled ? () => _run(context, item, 1) : null, icon: const Icon(Icons.add_circle_outline)),
          ]),
        );
    }
    return const SizedBox.shrink();
  }
}
