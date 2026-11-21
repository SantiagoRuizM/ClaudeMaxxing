import 'dart:convert';
import 'dart:typed_data';

import 'package:claudemaxxing/api.dart';
import 'package:claudemaxxing/eggs.dart';
import 'package:claudemaxxing/logic.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final pin = 'ab' * 32;

  group('PairInfo.parse', () {
    test('reads the QR of Celular', () {
      final info = PairInfo.parse('cmx://pair?h=192.168.1.5,100.64.0.9&p=47830&f=$pin&c=0123456789abcdef&n=MY%20PC')!;
      expect(info.hosts, ['192.168.1.5', '100.64.0.9']);
      expect(info.port, 47830);
      expect(info.pin, pin);
      expect(info.code, '0123456789abcdef');
      expect(info.name, 'MY PC');
    });
    test('refuses other QRs and broken ones', () {
      expect(PairInfo.parse('https://example.com'), isNull);
      expect(PairInfo.parse('cmx://pair?h=&p=47830&f=$pin&c=x'), isNull);
      expect(PairInfo.parse('cmx://pair?h=1.2.3.4&p=99999&f=$pin&c=x'), isNull);
      expect(PairInfo.parse('cmx://pair?h=1.2.3.4&p=47830&f=short&c=x'), isNull);
      expect(PairInfo.parse('cmx://pair?h=1.2.3.4&p=47830&f=$pin'), isNull);
    });
  });

  group('pageAfterChange', () {
    test('keeps the session on screen when others open or close', () {
      expect(pageAfterChange(['a', 'b', 'c'], ['b', 'c'], 2), 1);
      expect(pageAfterChange(['a', 'b'], ['x', 'a', 'b'], 2), 3);
    });
    test('goes back to the panel when the session closed', () {
      expect(pageAfterChange(['a', 'b'], ['a'], 2), 0);
    });
    test('the panel stays the panel', () {
      expect(pageAfterChange(['a'], [], 0), 0);
    });
  });

  group('mergeMessages', () {
    final one = {'role': 'user', 'text': '1'};
    final two = {'role': 'assistant', 'text': '2'};
    test('appends new lines', () {
      expect(mergeMessages([one], {'reset': false, 'items': [two]}), [one, two]);
    });
    test('replaces everything after a reset', () {
      expect(mergeMessages([one], {'reset': true, 'items': [two]}), [two]);
    });
    test('keeps the last ones only', () {
      final many = List.generate(5, (i) => {'text': '$i'});
      expect(mergeMessages(many, {'items': <Map<String, dynamic>>[]}, max: 3).map((m) => m['text']), ['2', '3', '4']);
    });
  });

  test('choiceStep: relative steps, or the place in the list', () {
    expect(choiceStep(['1', '2', '4'], '2', '4'), 1);
    expect(choiceStep(['1', '2', '4'], '4', '1'), -2);
    expect(choiceStep(['', 'C:/a', 'C:/b'], '', 'C:/b', absolute: true), 2);
  });

  test('egg frames decode and cycle for each active state', () {
    final frames = EggFrames.fromJson({
      'interval': 120,
      'still': base64Encode([0]),
      'thinking': List.generate(9, (i) => base64Encode([i + 1])),
      'speaking': List.generate(8, (i) => base64Encode([i + 11])),
    });
    expect(frames.interval, const Duration(milliseconds: 120));
    expect(frames.bytesAt('idle', 241), Uint8List.fromList([0]));
    expect(frames.bytesAt('thinking', 8), [9]);
    expect(frames.bytesAt('thinking', 9), [1]);
    expect(frames.bytesAt('speaking', 7), [18]);
    expect(frames.bytesAt('speaking', 8), [11]);
    expect(frames.imageAt('speaking', 8).bytes, same(frames.bytesAt('speaking', 8)));
  });

  test('attachment lines show only file names and preserve the remaining text', () {
    final parts = splitAttachments([
      'Caption',
      '',
      r'[phone attachment] C:\uploads\20261120-204500-foto.jpg',
      '[phone attachment] /uploads/meeting notes.pdf',
      'Mention [phone attachment] in text',
      '[phone attachment]',
    ].join('\r\n'));
    expect(parts.textLines, ['Caption', '', 'Mention [phone attachment] in text', '[phone attachment]']);
    expect(parts.attachments, ['foto.jpg', 'meeting notes.pdf']);
    expect(splitAttachments('Plain message').attachments, isEmpty);
  });

  test('pickDictationLocale: the phone language, not the recognizer default', () {
    expect(pickDictationLocale(['en_US', 'es_ES', 'es_CO'], 'es-CO', 'en_US'), 'es_CO');
    expect(pickDictationLocale(['en_US', 'es_ES'], 'es-CO', 'en_US'), 'es_ES');
    expect(pickDictationLocale(['en_US'], 'es-CO', 'en_US'), 'es-CO');
    expect(pickDictationLocale([], 'es-CO', null), 'es-CO');
    expect(pickDictationLocale([], 'und', 'en_US'), 'en_US');
  });

  test('a saved PC round-trips', () {
    final pc = Pc(name: 'PC', hosts: ['10.0.0.2'], port: 47830, pin: pin, token: 't' * 64, lastHost: '10.0.0.2');
    final back = Pc.fromJson(pc.toJson());
    expect([back.name, back.hosts, back.port, back.pin, back.token, back.lastHost], [pc.name, pc.hosts, pc.port, pc.pin, pc.token, pc.lastHost]);
  });
}
