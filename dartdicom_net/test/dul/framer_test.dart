// PDU framing over arbitrary TCP chunking.
import 'dart:async';
import 'dart:typed_data';

import 'package:dartdicom_net/src/dul/framer.dart';
import 'package:dartdicom_net/src/pdu/pdus.dart';
import 'package:test/test.dart';

Future<List<Uint8List>> _frame(List<List<int>> chunks) =>
    Stream.fromIterable([for (final c in chunks) Uint8List.fromList(c)])
        .transform(const PduFramer())
        .toList();

void main() {
  final a = const ReleaseRq().encode();
  final b = const Abort(source: 2, reason: 2).encode();

  test('one byte at a time', () async {
    expect(
        await _frame([
          for (final x in [...a, ...b]) [x]
        ]),
        [a, b]);
  });

  test('several PDUs in one chunk', () async {
    expect(
        await _frame([
          [...a, ...b, ...a]
        ]),
        [a, b, a]);
  });

  test('a large PDU across many chunks', () async {
    final big = PDataTf([]).encode(); // header only; grow the body:
    final body = Uint8List(200000);
    final pdu = Uint8List.fromList([
      ...big.sublist(0, 2),
      ...(ByteData(4)..setUint32(0, body.length)).buffer.asUint8List(),
      ...body
    ]);
    final chunks = [
      for (var i = 0; i < pdu.length; i += 1000)
        pdu.sublist(i, i + 1000 > pdu.length ? pdu.length : i + 1000),
    ];
    final out = await _frame(chunks);
    expect(out.single.length, pdu.length);
  });

  test('a declared length above the cap is an error', () async {
    expect(
        _frame([
          [0x04, 0x00, 0xFF, 0xFF, 0xFF, 0xFF]
        ]),
        throwsA(isA<FormatException>()));
  });

  test('a connection that closes mid-PDU is an error', () async {
    expect(_frame([a.sublist(0, 7)]), throwsA(isA<FormatException>()));
  });
}
