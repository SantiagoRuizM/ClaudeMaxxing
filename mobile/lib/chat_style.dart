// The chat's look, chosen on the phone (Estilo del chat): a palette and the text size, kept between runs.
// Every palette keeps its text at 4.5:1 or more against its bubble.
import 'package:flutter/material.dart';

import 'store.dart';
import 'strings.dart';

class ChatPalette {
  const ChatPalette(this.id, this.es, this.en,
      {required this.background, required this.mine, required this.mineText, required this.theirs, required this.theirsText, required this.muted});

  final String id;
  final String es;
  final String en;
  final Color background;
  final Color mine;
  final Color mineText;
  final Color theirs;
  final Color theirsText;
  final Color muted;

  String get name => t(es, en);

  /// "Color de la sesión": my bubbles take the session's color, with whichever of black or white reads on it.
  ChatPalette forSession(Color color) => id != 'session'
      ? this
      : ChatPalette(id, es, en,
          background: background, theirs: theirs, theirsText: theirsText, muted: muted,
          mine: color, mineText: color.computeLuminance() > 0.18 ? Colors.black : Colors.white);
}

const chatPalettes = [
  ChatPalette('claude', 'Claude', 'Claude', background: Color(0xFF262624), mine: Color(0xFFB4532F), mineText: Colors.white,
      theirs: Color(0xFF3A3936), theirsText: Color(0xFFF5F4EE), muted: Color(0xFFA3A19A)),
  ChatPalette('session', 'Color de la sesión', 'Session color', background: Color(0xFF262624), mine: Color(0xFFB4532F), mineText: Colors.white,
      theirs: Color(0xFF3A3936), theirsText: Color(0xFFF5F4EE), muted: Color(0xFFA3A19A)),
  ChatPalette('paper', 'Papel', 'Paper', background: Color(0xFFF5F4EE), mine: Color(0xFFB4532F), mineText: Colors.white,
      theirs: Colors.white, theirsText: Color(0xFF1F1E1D), muted: Color(0xFF6B6A64)),
  ChatPalette('night', 'Noche', 'Night', background: Color(0xFF0F172A), mine: Color(0xFF2563EB), mineText: Colors.white,
      theirs: Color(0xFF1E293B), theirsText: Color(0xFFE2E8F0), muted: Color(0xFF94A3B8)),
  ChatPalette('forest', 'Bosque', 'Forest', background: Color(0xFF0E1A14), mine: Color(0xFF2F7D5B), mineText: Colors.white,
      theirs: Color(0xFF1F3028), theirsText: Color(0xFFE3EFE7), muted: Color(0xFF8FA89A)),
  ChatPalette('ocean', 'Océano', 'Ocean', background: Color(0xFFE6EFF6), mine: Color(0xFF0B6E99), mineText: Colors.white,
      theirs: Colors.white, theirsText: Color(0xFF102A43), muted: Color(0xFF52677D)),
  ChatPalette('grape', 'Uva', 'Grape', background: Color(0xFF1A1325), mine: Color(0xFF7C3AED), mineText: Colors.white,
      theirs: Color(0xFF2C2240), theirsText: Color(0xFFEDE7F6), muted: Color(0xFFA89BBF)),
  ChatPalette('contrast', 'Alto contraste', 'High contrast', background: Colors.black, mine: Color(0xFFFFD400), mineText: Colors.black,
      theirs: Color(0xFF1F1F1F), theirsText: Colors.white, muted: Color(0xFFD0D0D0)),
];

const chatFontMin = 12.0;
const chatFontMax = 28.0;

class ChatStyle {
  const ChatStyle(this.palette, this.fontSize);

  final ChatPalette palette;
  final double fontSize;
}

final chatStyle = ValueNotifier(ChatStyle(chatPalettes.first, 15));

Future<void> loadChatStyle() async {
  try {
    final id = await readSetting('chatPalette');
    final size = double.tryParse(await readSetting('chatFontSize') ?? '') ?? 15;
    chatStyle.value = ChatStyle(chatPalettes.firstWhere((p) => p.id == id, orElse: () => chatPalettes.first),
        size.clamp(chatFontMin, chatFontMax).toDouble());
  } on Object {
    // Unreadable storage: the default look.
  }
}

/// A pinch or the slider moves with save: false and saves once at the end.
void setChatStyle({ChatPalette? palette, double? fontSize, bool save = true}) {
  final now = chatStyle.value;
  chatStyle.value = ChatStyle(palette ?? now.palette, (fontSize ?? now.fontSize).clamp(chatFontMin, chatFontMax).toDouble());
  if (save) saveChatStyle();
}

Future<void> saveChatStyle() async {
  final now = chatStyle.value;
  await writeSetting('chatPalette', now.palette.id);
  await writeSetting('chatFontSize', now.fontSize.toStringAsFixed(1));
}
