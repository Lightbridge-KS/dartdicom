// Native pixel arrays agree with pydicom's (sha256 of its little-endian
// C-order array, after correct_unused_bits), with its dtype and shape.
// VM only: reads the fixtures.
@TestOn('vm')
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:dartdicom/dartdicom.dart';
import 'package:dartdicom_pixel/dartdicom_pixel.dart';
import 'package:test/test.dart';

import '../support/golden.dart';

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
    if (pixels == null || ts == null || ts.encapsulated) continue;
    final path = record['file']! as String;
    final bytes = File('../fixtures/data/$path').readAsBytesSync();
    final ds = DicomFile.fromBytes(bytes).dataset;
    compared++;
    test('$path matches pydicom ${pixels['dtype']} ${pixels['shape']}', () {
      final px = ds.pixels;
      final all = px.allFrames();
      expect(all.dtype.name, pixels['dtype']);
      expect(pydicomShape(all.shape), pixels['shape']);
      expect(sha256.convert(leBytes(all.values, all.dtype)).toString(),
          pixels['sha256']);
      // One frame at a time gives the same values, and so does a view of
      // the whole buffer.
      for (var i = 0; i < px.numberOfFrames; i++) {
        final frame = px.frame(i);
        expect(frame.values, all.frame(i).values, reason: 'frame $i');
        expect(frame.firstFrame, i);
      }
      if (!ts.littleEndian) {
        // I-18 (in-process): rewritten as Little Endian, the frames decode to
        // the same values.
        final le = DicomFile.fromBytes(DicomFile.fromBytes(bytes).toBytes(
                options: const WriteOptions(
                    transferSyntax: TransferSyntaxes.explicitVrLittleEndian)))
            .dataset;
        expect(le.pixels.allFrames().values, all.values);
      }
      expect(
          all.values,
          switch (all.dtype) {
            PixelDtype.int32 => isA<Int32List>(),
            PixelDtype.uint32 => isA<Uint32List>(),
            PixelDtype.int16 => isA<Int16List>(),
            PixelDtype.uint16 => isA<Uint16List>(),
            PixelDtype.int8 => isA<Int8List>(),
            PixelDtype.uint8 => isA<Uint8List>(),
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

  test('every native fixture with pixels is compared', () {
    // 1-bit, 8, 16 and 32 bits, planar and Big Endian included: every
    // fixture but the RLE ones.
    expect(compared, greaterThanOrEqualTo(37));
  });
}
