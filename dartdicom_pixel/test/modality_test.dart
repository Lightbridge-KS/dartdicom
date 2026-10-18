// The Modality LUT on in-memory data (every platform): a rescale or a
// table, and each frame's own from its functional groups (blueprint F44).
import 'dart:typed_data';

import 'package:dartdicom/dartdicom.dart';
import 'package:dartdicom_pixel/dartdicom_pixel.dart';
import 'package:test/test.dart';

import 'support/datasets.dart';

/// A LUT item: [descriptor] and [entries] as US values.
Dataset _lutItem(List<int> descriptor, List<int> entries) => Dataset()
  ..setRaw(DicomTags.lutDescriptor, Vr.US, descriptor)
  ..setRaw(DicomTags.lutData, Vr.US, entries);

Matcher _invalid(Tag tag) =>
    throwsA(isA<InvalidPixelModule>().having((e) => e.tag, 'tag', tag));

void main() {
  group('rescale', () {
    test('applies slope, then intercept', () {
      final f =
          image16([0, 1, 1000], slope: 2, intercept: -1024).pixels.frame(0);
      expect(f.toModality(), [-1024, -1022, 976]);
    });

    test('needs both attributes, as in pydicom', () {
      final f =
          image16([0, 1024], signed: false, intercept: -1024).pixels.frame(0);
      expect(f.toModality(), [0, 1024]);
    });

    test('a slope that is not finite is an InvalidPixelModule', () {
      final ds = parsed([
        (0x00281052, 'DS', text('0')),
        (0x00281053, 'DS', text('Infinity')),
        ...pixelModule(rows: 1, columns: 2, bitsAllocated: 8),
        (pixelDataTag, 'OB', [1, 2]),
      ]);
      expect(() => ds.pixels.frame(0).toModality(),
          _invalid(DicomTags.rescaleSlope));
    });
  });

  test('a rescale that overflows a double has no automatic window', () {
    // Found by the fuzz: 30000 × 1e305 is past a double's range.
    final frame =
        image16([0, 30000], slope: 1e305, intercept: 0).pixels.frame(0);
    expect(frame.toModality().last, double.infinity);
    expect(frame.autoWindow, _invalid(DicomTags.rescaleSlope));
    // 0 is ((0 + 0.5) / 99 + 0.5) × 255 = 128.8; infinity is white.
    expect(frame.toDisplay(VoiWindow(0, 100)).gray, [129, 255]);
  });

  group('Modality LUT Sequence', () {
    Dataset withTable(Dataset item, {List<int> values = const [0, 1, 2, 3]}) =>
        image16(values, signed: false, slope: 3, intercept: 7)
          ..set(DicomTags.modalityLutSequence, Sequence([item]));

    test('wins over the rescale; clamps below and above the table', () {
      // First mapped 1, four entries: 0 → entry 0, 5 → the last entry.
      final ds = withTable(_lutItem([4, 1, 16], [100, 200, 300, 400]),
          values: [0, 1, 2, 4, 5]);
      expect(ds.pixels.frame(0).toModality(), [100, 100, 200, 400, 400]);
    });

    test('a 12-bit table works (pydicom takes only 8 or 16)', () {
      final ds = withTable(_lutItem([2, 0, 12], [4095, 0]), values: [0, 1]);
      expect(ds.pixels.frame(0).toModality(), [4095, 0]);
    });

    test('an entry count of 0 means 65536', () {
      final entries = List.generate(65536, (i) => 65535 - i);
      final ds = withTable(_lutItem([0, 0, 16], entries), values: [0, 65535]);
      expect(ds.pixels.frame(0).toModality(), [65535, 0]);
    });

    test('OW LUT Data is read in the dataset\'s byte order', () {
      final ds = parsed([
        ...pixelModule(
            rows: 1, columns: 2, bitsAllocated: 16, endian: Endian.big),
        (
          0x00283000,
          'SQ',
          [
            ...[0xFF, 0xFE, 0xE0, 0x00, 0, 0, 0, 30], // item, 30 bytes
            ...[0x00, 0x28, 0x30, 0x02, 0x55, 0x53, 0, 6], // (0028,3002) US
            ...us(2, Endian.big), ...us(0, Endian.big), ...us(16, Endian.big),
            ...[0x00, 0x28, 0x30, 0x06, 0x4F, 0x57, 0, 0, 0, 0, 0, 4], // OW
            ...[0x12, 0x34, 0xAB, 0xCD],
          ]
        ),
        (pixelDataTag, 'OW', [0, 0, 0, 1]),
      ], endian: Endian.big);
      expect(ds.pixels.frame(0).toModality(), [0x1234, 0xABCD]);
    });

    test('a short table, or a bad descriptor, is an InvalidPixelModule', () {
      for (final (item, tag) in [
        (_lutItem([4, 0, 16], [1, 2]), DicomTags.lutData),
        (_lutItem([4, 0], [1, 2, 3, 4]), DicomTags.lutDescriptor),
        (_lutItem([4, 0, 7], [1, 2, 3, 4]), DicomTags.lutDescriptor),
        (_lutItem([4, 0, 17], [1, 2, 3, 4]), DicomTags.lutDescriptor),
        (
          Dataset()..setRaw(DicomTags.lutDescriptor, Vr.US, [1, 0, 16]),
          DicomTags.lutData
        ),
      ]) {
        expect(
            () => withTable(item).pixels.frame(0).toModality(), _invalid(tag));
      }
    });
  });

  group('functional groups', () {
    Dataset rescale(String slope, String intercept) => Dataset()
      ..set(DicomTags.rescaleSlope, double.parse(slope))
      ..set(DicomTags.rescaleIntercept, double.parse(intercept));

    Dataset group(Dataset? transformation) => transformation == null
        ? Dataset()
        : (Dataset()
          ..set(DicomTags.pixelValueTransformationSequence,
              Sequence([transformation])));

    // Three 1×1 frames of stored value 10; the top level says ×100.
    Dataset enhanced({required List<Dataset> perFrame, Dataset? shared}) =>
        image16([10, 10, 10], slope: 100, intercept: 0)
          ..set(DicomTags.columns, 1)
          ..set(DicomTags.numberOfFrames, 3)
          ..set(DicomTags.perFrameFunctionalGroupsSequence, Sequence(perFrame))
          ..set(DicomTags.sharedFunctionalGroupsSequence,
              Sequence([group(shared)]));

    test('a frame\'s own item, else the shared one, wins over the top level',
        () {
      final ds = enhanced(
          perFrame: [group(null), group(rescale('2', '1')), group(null)],
          shared: rescale('1', '-1024'));
      final all = ds.pixels.allFrames();
      expect(all.toModality(), [-1014, 21, -1014]);
      expect(ds.pixels.frame(1).toModality(), [21]);
    });

    test(
        'a whole item wins: no slope from one level and intercept from another',
        () {
      // The shared item has only an intercept, so it is the identity, not
      // a mix with the top level's slope.
      final ds = enhanced(
          perFrame: [group(null), group(null), group(null)],
          shared: Dataset()..set(DicomTags.rescaleIntercept, -1024.0));
      expect(ds.pixels.frame(0).toModality(), [10]);
    });

    test('fewer per-frame items than frames fall back to the shared item', () {
      final ds = enhanced(
          perFrame: [group(rescale('2', '0'))], shared: rescale('3', '0'));
      expect(ds.pixels.allFrames().toModality(), [20, 30, 30]);
    });

    test('with no functional groups, the top level holds the rescale', () {
      final ds = image16([10], slope: 100, intercept: 0);
      expect(ds.pixels.frame(0).toModality(), [1000]);
    });
  });
}
