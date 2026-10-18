// An attribute core can't read as its type is an InvalidPixelModule naming
// that attribute, wherever pixel code reads it (I-30): the Image Pixel
// module, Pixel Data, the functional groups, the Modality LUT and the VOI.
// In memory, so it runs on every platform.
import 'package:dartdicom/dartdicom.dart';
import 'package:dartdicom_pixel/dartdicom_pixel.dart';
import 'package:test/test.dart';

import 'support/datasets.dart';

/// A valid 1 × 2, 16-bit image with [replace] swapped in by tag, plus
/// [extra] elements.
Dataset _image(
    {List<RawElement> replace = const [], List<RawElement> extra = const []}) {
  final elements = <int, RawElement>{
    for (final e in [
      ...pixelModule(rows: 1, columns: 2, bitsAllocated: 16),
      (pixelDataTag, 'OW', [1, 0, 2, 0]),
      ...extra,
      ...replace,
    ])
      e.$1: e,
  };
  return parsed([for (final t in elements.keys.toList()..sort()) elements[t]!]);
}

/// The same element with a VR whose Dart type the tag doesn't take.
RawElement _asText(int tag) => (tag, 'SH', text('x'));

Dataset _item(List<RawElement> elements) => parsed(elements);

final _lutDescriptor = (0x00283002, 'US', [...us(2), ...us(0), ...us(16)]);
final _lutData = (0x00283006, 'OW', [0, 0, 1, 0]);
final _window = [
  (0x00281050, 'DS', text('1')),
  (0x00281051, 'DS', text('10')),
];

void main() {
  void unreadable(String what, Tag tag, void Function() read) {
    test('$what: an InvalidPixelModule naming ${tag.value.toRadixString(16)}',
        () {
      expect(read,
          throwsA(isA<InvalidPixelModule>().having((e) => e.tag, 'tag', tag)));
    });
  }

  group('the Image Pixel module', () {
    unreadable('Rows', DicomTags.rows,
        () => _image(replace: [_asText(0x00280010)]).pixels);
    unreadable(
        'Photometric Interpretation',
        DicomTags.photometricInterpretation,
        () => _image(replace: [(0x00280004, 'US', us(1))]).pixels);
    unreadable('Number of Frames', DicomTags.numberOfFrames,
        () => _image(extra: [_asText(0x00280008)]).pixels);
    unreadable('Pixel Padding Value', DicomTags.pixelPaddingValue,
        () => _image(extra: [_asText(0x00280120)]).pixels);
    unreadable('Pixel Data', DicomTags.pixelData,
        () => _image(replace: [_asText(pixelDataTag)]).pixels.frame(0));
  });

  group('the functional groups', () {
    unreadable(
        'Per-Frame Functional Groups',
        DicomTags.perFrameFunctionalGroupsSequence,
        () =>
            _image(extra: [_asText(0x52009230)]).pixels.frame(0).toModality());
    unreadable(
        'Shared Functional Groups',
        DicomTags.sharedFunctionalGroupsSequence,
        () =>
            _image(extra: [_asText(0x52009229)]).pixels.frame(0).toModality());
    unreadable('a macro in a functional group item',
        DicomTags.pixelValueTransformationSequence, () {
      final ds = _image()
        ..set(
            DicomTags.sharedFunctionalGroupsSequence,
            Sequence([
              _item([_asText(0x00289145)])
            ]));
      ds.pixels.frame(0).toModality();
    });
  });

  group('the Modality LUT', () {
    unreadable(
        'Rescale Slope',
        DicomTags.rescaleSlope,
        () => _image(extra: [
              (0x00281052, 'DS', text('0')),
              _asText(0x00281053),
            ]).pixels.frame(0).toModality());
    unreadable(
        'Modality LUT Sequence',
        DicomTags.modalityLutSequence,
        () =>
            _image(extra: [_asText(0x00283000)]).pixels.frame(0).toModality());
    unreadable('LUT Descriptor', DicomTags.lutDescriptor, () {
      final ds = _image()
        ..set(
            DicomTags.modalityLutSequence,
            Sequence([
              _item([_asText(0x00283002), _lutData])
            ]));
      ds.pixels.frame(0).toModality();
    });
    unreadable('LUT Data', DicomTags.lutData, () {
      final ds = _image()
        ..set(
            DicomTags.modalityLutSequence,
            Sequence([
              _item([_lutDescriptor, _asText(0x00283006)])
            ]));
      ds.pixels.frame(0).toModality();
    });
  });

  group('the VOI', () {
    unreadable('VOI LUT Sequence', DicomTags.voilutSequence,
        () => _image(extra: [_asText(0x00283010)]).voi());
    unreadable(
        'Window Center',
        DicomTags.windowCenter,
        () => _image(extra: [
              _asText(0x00281050),
              (0x00281051, 'DS', text('10')),
            ]).voi());
    unreadable('VOI LUT Function', DicomTags.voilutFunction,
        () => _image(extra: [..._window, (0x00281056, 'US', us(1))]).voi());
  });
}
