// I-10 under F41: reading then writing an untouched file in the same
// transfer syntax gives byte-identical output; for Deflated, the same header
// and the same inflated body; a repaired file reaches a fixpoint. VM only:
// reads the fixtures.
@TestOn('vm')
library;

import 'dart:typed_data';

import 'package:dartdicom/dartdicom.dart';
import 'package:dartdicom/io.dart';
import 'package:dartdicom/src/write/writer.dart' show swapWords;
import 'package:test/test.dart';

import '../support/fixtures.dart';

import '../support/f41.dart';

const _zlib = ZLibDeflateCodec();

void main() {
  for (final source in fixtureSet()) {
    final name = fixtureName(source);
    final bytes = source.readAsBytesSync();
    final file = DicomFile.fromBytes(bytes);

    // A few public files carry file meta whose SOP UIDs contradict the
    // dataset's. Reading is lenient; writing is strict, so I-17 refuses them
    // rather than copy the contradiction (data §5).
    if (contradictsSopUids(file)) {
      test('$name has contradicting SOP UIDs, so the write is refused', () {
        expect(file.toBytes, throwsA(isA<DicomWriteException>()));
      });
      continue;
    }

    // F41: Big Endian is read-only, so I-10 doesn't apply. Writing it is
    // refused with the fix named, and the Little Endian rewrite reads back
    // the same elements.
    if (file.meta.transferSyntaxUid == TransferSyntaxes.explicitVrBigEndian) {
      test('$name (Big Endian) is refused as written, and rewrites as LE', () {
        expect(
            file.toBytes,
            throwsA(isA<DicomWriteException>().having((e) => e.message,
                'message', contains('explicitVrLittleEndian'))));
        final le = DicomFile.fromBytes(file.toBytes(
            options: const WriteOptions(
                transferSyntax: TransferSyntaxes.explicitVrLittleEndian)));
        expect(
            le.meta.transferSyntaxUid, TransferSyntaxes.explicitVrLittleEndian);
        // Everything decodes the same; word data swaps (I-18): OW Pixel
        // Data by its Bits Allocated, other binary words (OW LUT Data in a
        // sequence item, say) by their size.
        expect(flatten(le.dataset, skip: {DicomTags.pixelData}),
            _otherOrder(flatten(file.dataset, skip: {DicomTags.pixelData})));
        final be = file.dataset.require(DicomTags.pixelData);
        final int bitsAllocated = file.dataset.require(DicomTags.bitsAllocated);
        expect(le.dataset.require(DicomTags.pixelData),
            swapWords(be, bitsAllocated > 16 ? bitsAllocated ~/ 8 : 2));
      });
      continue;
    }

    test('$name round-trips by F41', () {
      expect(checkF41(file, bytes, deflateCodec: _zlib), isNull);
    });

    test('$name round-trips after every value was read', () {
      final again = DicomFile.fromBytes(bytes);
      void touch(Dataset ds) {
        for (final e in ds.elements) {
          final value = e.value;
          if (value is Sequence) value.forEach(touch);
        }
      }

      touch(again.meta.dataset);
      touch(again.dataset);
      expect(checkF41(again, bytes, deflateCodec: _zlib), isNull);
    });
  }
}

const _wordSizes = {'OW': 2, 'OF': 4, 'OL': 4, 'OD': 8, 'OV': 8};

/// [node], from `flatten`, with its binary word values in the other byte
/// order, as the writer swaps them.
Object _otherOrder(Object node) {
  if (node case [final int tag, final String vr, final Uint8List value]
      when _wordSizes.containsKey(vr)) {
    return [tag, vr, swapWords(value, _wordSizes[vr]!)];
  }
  if (node is List && node is! TypedData) {
    return [for (final child in node) _otherOrder(child as Object)];
  }
  return node;
}
