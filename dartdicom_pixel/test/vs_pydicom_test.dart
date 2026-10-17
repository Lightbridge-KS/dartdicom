// Native pixel arrays agree with pydicom's (sha256 of its little-endian
// C-order array, after correct_unused_bits). VM only: reads the fixtures.
@TestOn('vm')
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:dartdicom/dartdicom.dart';
import 'package:dartdicom_pixel/dartdicom_pixel.dart';
import 'package:test/test.dart';

void main() {
  final goldens = Directory('../fixtures/data/golden')
      .listSync(recursive: true)
      .whereType<File>()
      .where((f) => f.path.endsWith('.json'))
      .toList()
    ..sort((a, b) => a.path.compareTo(b.path));
  var compared = 0;

  for (final golden in goldens) {
    final record =
        jsonDecode(golden.readAsStringSync()) as Map<String, Object?>;
    final pixels = record['pixels'] as Map<String, Object?>?;
    final ts = TransferSyntax.of(Uid(record['transfer_syntax']! as String));
    if (pixels == null || ts == null || !ts.littleEndian || ts.encapsulated) {
      continue;
    }
    final path = record['file']! as String;
    final ds =
        DicomFile.fromBytes(File('../fixtures/data/$path').readAsBytesSync())
            .dataset;
    final m = ds.pixels.module;
    if ((m.bitsAllocated != 8 && m.bitsAllocated != 16) ||
        (ds.get(DicomTags.planarConfiguration) ?? 0) != 0) {
      continue;
    }
    compared++;
    test('$path matches pydicom ${pixels['dtype']} ${pixels['shape']}', () {
      final out = BytesBuilder();
      for (var i = 0; i < ds.pixels.numberOfFrames; i++) {
        final values = ds.pixels.frame(i).values;
        final data = ByteData(values.length * m.bitsAllocated ~/ 8);
        for (final (j, v) in values.indexed) {
          if (m.bitsAllocated == 8) {
            data.setUint8(j, v & 0xFF);
          } else {
            data.setUint16(j * 2, v & 0xFFFF, Endian.little);
          }
        }
        out.add(data.buffer.asUint8List());
      }
      expect(sha256.convert(out.takeBytes()).toString(), pixels['sha256']);
      expect(
          ds.pixels.frame(0).values,
          switch ((m.bitsAllocated, m.signed)) {
            (16, true) => isA<Int16List>(),
            (16, false) => isA<Uint16List>(),
            (_, true) => isA<Int8List>(),
            _ => isA<Uint8List>(),
          });
    });
  }

  test('an aligned 16-bit frame is a zero-copy view of Pixel Data', () {
    final ds = DicomFile.fromBytes(
            File('../fixtures/data/pydicom/CT_small.dcm').readAsBytesSync())
        .dataset;
    final values = ds.pixels.frame(0).values as Int16List;
    final before = values[0];
    ds.require(DicomTags.pixelData)[0] ^= 0x01;
    expect(values[0], isNot(before)); // the earlier frame sees the write
  });

  test('the corpus has native 16-bit fixtures to compare', () {
    expect(compared, greaterThanOrEqualTo(8));
  });
}
