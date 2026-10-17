// I-11 on the M1 slice: every element of every Little Endian fixture agrees
// with pydicom's reading of it (fixtures/data/golden/, from `fixtures
// golden`). VM only: it reads the fixtures from disk.
@TestOn('vm')
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:dartdicom/dartdicom.dart';
import 'package:test/test.dart';

/// What M1 reads: Implicit and Explicit VR Little Endian, including the
/// encapsulated (compressed) syntaxes; not Deflated or Big Endian yet.
bool _readable(String uid) {
  final ts = TransferSyntax.of(Uid(uid));
  return ts != null && ts.littleEndian && !ts.deflated;
}

void main() {
  final goldens = Directory('../fixtures/data/golden')
      .listSync(recursive: true)
      .whereType<File>()
      .where((f) => f.path.endsWith('.json'))
      .toList()
    ..sort((a, b) => a.path.compareTo(b.path));

  test('the golden corpus is there', () => expect(goldens, isNotEmpty));

  for (final golden in goldens) {
    final record =
        jsonDecode(golden.readAsStringSync()) as Map<String, Object?>;
    final path = record['file'] as String;
    final bytes = File('../fixtures/data/$path').readAsBytesSync();

    if (!_readable(record['transfer_syntax']! as String)) {
      test('$path: an unsupported transfer syntax is a clear parse error', () {
        expect(
            () => DicomFile.fromBytes(bytes),
            throwsA(isA<DicomParseException>().having(
                (e) => e.message, 'message', contains('not supported'))));
      });
      continue;
    }

    test('$path agrees with pydicom', () {
      final file = DicomFile.fromBytes(bytes);
      _expectElements(
          record['meta']! as List<Object?>, file.meta.dataset, 'meta');
      _expectElements(record['dataset']! as List<Object?>, file.dataset, '');
    });
  }
}

void _expectElements(List<Object?> golden, Dataset ds, String where) {
  final ours = ds.elements.toList();
  expect([
    for (final e in ours) _hex(e.tag)
  ], [
    for (final g in golden) (g! as Map)['tag']
  ], reason: 'tags in $where');
  for (final (i, e) in ours.indexed) {
    final g = golden[i]! as Map<String, Object?>;
    final at = '$where ${g['tag']}';
    expect(e.vr.code, g['vr'], reason: 'VR of $at');
    _expectValue(g['value'], e.value, at);
  }
}

void _expectValue(Object? golden, Object ours, String at) {
  switch (ours) {
    case Sequence():
      final items = (golden! as Map)['items'] as List<Object?>;
      expect(ours.length, items.length, reason: 'items of $at');
      for (final (i, item) in ours.indexed) {
        _expectElements(items[i]! as List<Object?>, item, '$at[$i]');
      }
    case Uint8List():
      final g = golden! as Map;
      if (g.containsKey('bytes')) {
        expect(_hexBytes(ours), g['bytes'], reason: at);
      } else {
        expect(ours.length, g['bytes_len'], reason: 'length of $at');
        expect(sha256.convert(ours).toString(), g['sha256'], reason: at);
      }
    case List():
      if (ours.isEmpty) {
        expect(golden, anyOf('', isNull, isEmpty), reason: at);
      } else if (ours.length == 1) {
        expect(_plain(ours.single), golden, reason: at);
      } else {
        expect(ours.map(_plain).toList(), golden, reason: at);
      }
    default:
      fail('unexpected value type ${ours.runtimeType} at $at');
  }
}

/// Our value as pydicom's golden JSON spells it.
Object? _plain(Object? v) => switch (v) {
      final BigInt b => b.toInt(),
      _ => v,
    };

String _hex(Tag t) => t.value.toRadixString(16).padLeft(8, '0').toUpperCase();

String _hexBytes(Uint8List b) =>
    b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();
