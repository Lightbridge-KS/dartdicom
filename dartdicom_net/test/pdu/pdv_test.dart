// Characterization through PDataTf/Pdu, before and after PDV codec extraction.
import 'dart:typed_data';

import 'package:dartdicom_net/src/pdu/pdv.dart' as implementation;
import 'package:dartdicom_net/src/pdu/pdus.dart';
import 'package:test/test.dart';

Uint8List _envelope(List<int> body) => Uint8List.fromList([
      4,
      0,
      0,
      0,
      body.length >> 8 & 255,
      body.length & 255,
      ...body,
    ]);

void main() {
  test('pdus.dart re-exports the same PDV type and constructor', () {
    expect(identical(Pdv, implementation.Pdv), isTrue);
    expect(identical(Pdv.new, implementation.Pdv.new), isTrue);
  });

  test('all control bytes preserve the two flags and ignore reserved bits', () {
    for (var header = 0; header <= 255; header++) {
      final bytes = _envelope([0, 0, 0, 3, 17, header, 0xA5]);
      final pdu = Pdu.decode(bytes) as PDataTf;
      final pdv = pdu.pdvs.single;
      expect(pdv.contextId, 17);
      expect(pdv.isCommand, header & 1 != 0);
      expect(pdv.isLast, header & 2 != 0);
      expect(pdv.data, [0xA5]);
      expect(pdu.encode(), _envelope([0, 0, 0, 3, 17, header & 3, 0xA5]));
      expect(
          pdu.summary,
          'P-DATA-TF ctx 17 ${header & 1 != 0 ? 'command' : 'dataset'}'
          '${header & 2 != 0 ? ' last' : ''} 1 B');
      expect(pdu.toString(), 'P-DATA-TF(1 PDVs)');
    }
  });

  test('multiple fragments keep order, empty data, and context byte extremes',
      () {
    final bytes = _envelope([
      0,
      0,
      0,
      3,
      0,
      1,
      0xAA,
      0,
      0,
      0,
      2,
      255,
      2,
      0,
      0,
      0,
      4,
      3,
      3,
      0xBB,
      0xCC,
    ]);
    final pdu = Pdu.decode(bytes) as PDataTf;
    expect(pdu.pdvs.map((p) => p.contextId), [0, 255, 3]);
    expect(pdu.pdvs.map((p) => p.data.toList()), <List<int>>[
      [0xAA],
      [],
      [0xBB, 0xCC]
    ]);
    expect(pdu.pdvs.map((p) => (p.isCommand, p.isLast)),
        [(true, false), (false, true), (true, true)]);
    expect(pdu.encode(), bytes);
  });

  test('an empty P-DATA-TF retains its existing empty-list behavior', () {
    final bytes = _envelope([]);
    final pdu = Pdu.decode(bytes) as PDataTf;
    expect(pdu.pdvs, isEmpty);
    expect(pdu.encode(), bytes);
  });

  test('constructors retain mutable payload and fragment list identity', () {
    final payload = Uint8List.fromList([0xAA]);
    final pdv = Pdv(1, payload, isCommand: true, isLast: true);
    final pdvs = [pdv];
    final pdu = PDataTf(pdvs);
    expect(pdv.data, same(payload));
    expect(pdu.pdvs, same(pdvs));
    payload[0] = 0xBB;
    expect(pdu.encode(), _envelope([0, 0, 0, 3, 1, 3, 0xBB]));
    pdvs.clear();
    expect(pdu.encode(), _envelope([]));
  });

  test('decoded payloads remain mutable zero-copy views at nonzero offsets',
      () {
    final bytes = _envelope([0, 0, 0, 4, 1, 3, 0xAA, 0xBB]);
    final backing = Uint8List(bytes.length + 16)
      ..setRange(16, 16 + bytes.length, bytes);
    final view = Uint8List.sublistView(backing, 16);
    final pdu = Pdu.decode(view) as PDataTf;
    final pdv = pdu.pdvs.single;
    expect(pdv.data.offsetInBytes, 16 + 12);
    backing[16 + 12] = 0xCC;
    expect(pdv.data, [0xCC, 0xBB]);
    pdv.data[1] = 0xDD;
    expect(backing[16 + 13], 0xDD);
    expect(pdu.encode(), _envelope([0, 0, 0, 4, 1, 3, 0xCC, 0xDD]));
    pdu.pdvs.clear(); // Decoding does not freeze the fragment collection.
    expect(pdu.encode(), _envelope([]));
  });

  test('short PDV lengths are checked before reading context or flags', () {
    for (final length in [0, 1]) {
      expect(
          () => Pdu.decode(_envelope([0, 0, 0, length])),
          throwsA(isA<FormatException>().having(
              (e) => e.message, 'message', 'a PDV is shorter than 2 bytes')));
    }
  });

  test('truncated length, context, flags, or payload keep the bounds error',
      () {
    for (final body in [
      [0], [0, 0], [0, 0, 0],
      [0, 0, 0, 2],
      [0, 0, 0, 2, 1],
      [0, 0, 0, 3, 1, 3],
      [0, 0, 0, 2, 1, 3, 0], // next PDV's length is truncated
    ]) {
      expect(
          () => Pdu.decode(_envelope(body)),
          throwsA(isA<FormatException>().having(
              (e) => e.message, 'message', 'PDU field runs past its end')));
    }
  });
}
