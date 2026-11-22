import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';

import 'api.dart';
import 'items.dart';

class EggFrames {
  EggFrames(this.still, this.thinking, this.speaking, this.interval)
      : stillImage = MemoryImage(still),
        thinkingImages = thinking.map(MemoryImage.new).toList(),
        speakingImages = speaking.map(MemoryImage.new).toList();

  factory EggFrames.fromJson(Map<String, dynamic> json) {
    List<Uint8List> decodeFrames(String key) =>
        (json[key] as List).cast<String>().map(base64Decode).toList();
    return EggFrames(
      base64Decode(json['still'] as String),
      decodeFrames('thinking'),
      decodeFrames('speaking'),
      Duration(milliseconds: json['interval'] as int),
    );
  }

  final Uint8List still;
  final List<Uint8List> thinking, speaking;
  final MemoryImage stillImage;
  final List<MemoryImage> thinkingImages, speakingImages;
  final Duration interval;

  T _frame<T>(
    String state, int tick, T idle, List<T> thinking, List<T> speaking,
  ) {
    if (state == 'thinking' && thinking.isNotEmpty) {
      return thinking[tick % thinking.length];
    }
    if (state == 'speaking' && speaking.isNotEmpty) {
      return speaking[tick % speaking.length];
    }
    return idle;
  }

  Uint8List bytesAt(String state, int tick) =>
      _frame(state, tick, still, thinking, speaking);
  MemoryImage imageAt(String state, int tick) =>
      _frame(state, tick, stillImage, thinkingImages, speakingImages);
}

class EggCache {
  static final _frames = <(String, String, String?), Future<EggFrames>>{};
  static final _symbols = <String, String>{};

  /// Bumped when a PC changes its symbol: whoever shows one drops it and asks again.
  static final changes = ValueNotifier(0);

  static String? symbolOf(String pin) => _symbols[pin];

  /// The symbol the PC says it has now (`/state`), changed there or from a phone.
  static void use(String pin, String symbol) {
    if (_symbols[pin] == symbol) return;
    _symbols[pin] = symbol;
    _frames.removeWhere((key, _) => key.$1 == pin && key.$3 == null);
    changes.value++;
  }

  /// [symbol]: that one, whatever the PC has on (the list of symbols).
  static Future<EggFrames> of(Api api, String color, [String? symbol]) {
    final key = (api.pc.pin, color, symbol);
    return _frames.putIfAbsent(key, () async {
      try {
        return EggFrames.fromJson(await api.eggs(color, symbol));
      } catch (_) {
        _frames.remove(key);
        rethrow;
      }
    });
  }
}

class Egg extends StatefulWidget {
  const Egg({
    super.key,
    required this.api,
    required this.color,
    required this.state,
    this.symbol,
    this.size = 28,
  });

  final Api api;
  final String color, state;
  final String? symbol;
  final double size;

  @override
  State<Egg> createState() => _EggState();
}

class _EggState extends State<Egg> {
  EggFrames? _frames;
  Timer? _timer;
  int _tick = 0;
  bool _loading = false;

  @override
  void initState() {
    super.initState();
    EggCache.changes.addListener(_symbolChanged);
    _load();
  }

  // The one before must not stay on screen while the new one arrives.
  void _symbolChanged() {
    if (widget.symbol != null) return;
    setState(() => _frames = null);
    _sync();
    _load();
  }

  @override
  void didUpdateWidget(Egg oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.api != widget.api ||
        oldWidget.color != widget.color ||
        oldWidget.symbol != widget.symbol) {
      _frames = null;
      _loading = false;
      _sync();
    } else if (oldWidget.state != widget.state) {
      _sync();
    }
    if (_frames == null && !_loading) _load();
  }

  Future<void> _load() async {
    final api = widget.api;
    final color = widget.color;
    final symbol = widget.symbol;
    final change = EggCache.changes.value;
    _loading = true;
    EggFrames? frames;
    try {
      frames = await EggCache.of(api, color, symbol);
    } catch (_) {
      // Keep the colored fallback and retry on the next state refresh.
    }
    if (!mounted || widget.api != api || widget.color != color || widget.symbol != symbol) return;
    // A named symbol is the same whichever is on.
    if (symbol == null && change != EggCache.changes.value) return;
    setState(() {
      _loading = false;
      _frames = frames;
    });
    _sync();
  }

  void _sync() {
    _timer?.cancel();
    _tick = 0;
    final frames = _frames;
    if (frames != null && widget.state != 'idle') {
      _timer = Timer.periodic(frames.interval, (_) => setState(() => _tick++));
    }
  }

  @override
  void dispose() {
    EggCache.changes.removeListener(_symbolChanged);
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final frames = _frames;
    return SizedBox.square(
      dimension: widget.size,
      child: frames == null
          ? Center(
              child: CircleAvatar(
                radius: widget.size / 4,
                backgroundColor:
                    hexColor(widget.color) ?? Theme.of(context).colorScheme.primary,
              ),
            )
          : Image(image: frames.imageAt(widget.state, _tick), gaplessPlayback: true),
    );
  }
}
