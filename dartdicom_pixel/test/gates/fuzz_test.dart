// Fuzzing the pixel pipeline (M4 step 7, PRD "untrusted input", I-30): the
// Image Pixel module, the Modality and VOI LUTs, functional groups and DS
// values mutated, and Pixel Data truncated, over the small fixtures. Seeded
// and deterministic, so a failure names the case that reproduces it. Only
// the documented failures may escape: a PixelDataException, or a RangeError
// for an index.
//
// DARTDICOM_FUZZ_CASES sets the cases (`just fuzz` runs more);
// DARTDICOM_FUZZ_SEED moves the starting seed.
@TestOn('vm')
library;

import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:dartdicom/dartdicom.dart';
import 'package:dartdicom_pixel/dartdicom_pixel.dart';
import 'package:test/test.dart';

final _env = Platform.environment;
final _cases = int.tryParse(_env['DARTDICOM_FUZZ_CASES'] ?? '') ?? 2000;
final _firstSeed = int.tryParse(_env['DARTDICOM_FUZZ_SEED'] ?? '') ?? 0;

const _ints = [
  0,
  1,
  2,
  3,
  7,
  8,
  12,
  15,
  16,
  17,
  24,
  31,
  32,
  33,
  64,
  255,
  65535
];
const _doubles = [
  0.0, -0.0, 0.5, 1.0, -1.0, 1e-300, 1e300, -1e300, 65536.0, //
  double.nan, double.infinity, double.negativeInfinity,
];
const _photometrics = [
  'MONOCHROME1', 'MONOCHROME2', 'PALETTE COLOR', 'RGB', 'YBR_FULL', //
  'YBR_FULL_422', 'ZXQV', '',
];
const _functions = ['LINEAR', 'LINEAR_EXACT', 'SIGMOID', 'sigmoid', 'GAMMA'];

void main() {
  final fixtures = [
    for (final dir in [
      '../fixtures/data/synthetic',
      '../fixtures/data/pydicom'
    ])
      for (final f in Directory(dir).listSync().whereType<File>())
        if (f.path.endsWith('.dcm') && f.lengthSync() < 200000) f,
  ]..sort((a, b) => a.path.compareTo(b.path));
  final sources = [for (final f in fixtures) f.readAsBytesSync()];

  test('a mutated pixel pipeline fails only as documented', () {
    final failures = <String>[];
    for (var i = 0; i < _cases; i++) {
      final seed = _firstSeed + i;
      final random = Random(seed);
      final pick = random.nextInt(sources.length);
      final ds = DicomFile.fromBytes(sources[pick]).dataset;
      final how = [
        for (var n = 1 + random.nextInt(3); n > 0; n--) _mutate(ds, random),
      ];
      try {
        _exercise(ds, random);
      } on PixelDataException {
        // The documented refusal.
      } on RangeError {
        // An index past the frames, LUT items or windows.
      } catch (e) {
        failures.add('seed $seed (${fixtures[pick].path.split('/').last}: '
            '${how.join(', ')}): ${e.runtimeType}: $e');
      }
    }
    expect(failures, isEmpty, reason: failures.take(10).join('\n'));
  });
}

/// Everything a viewer does with a dataset's pixels.
void _exercise(Dataset ds, Random random) {
  final px = ds.pixels;
  final all = px.allFrames();
  final f = random.nextInt(px.numberOfFrames + 1); // sometimes past the end
  final frame = px.frame(f);
  frame.toModality();
  all.toModality();
  final voi =
      ds.voi(frame: f, index: random.nextInt(3), preferLut: random.nextBool());
  if (frame.module.isMonochrome) {
    frame.toDisplay();
    frame.toDisplay(voi);
    frame.toDisplay(frame.autoWindow());
  }
  '$frame ${frame.module} $voi';
}

/// Mutates one thing in [ds]; returns what, for the failure message.
String _mutate(Dataset ds, Random random) {
  T any<T>(List<T> from) => from[random.nextInt(from.length)];
  switch (random.nextInt(9)) {
    case 0:
      final tag = any([
        DicomTags.rows, DicomTags.columns, DicomTags.bitsAllocated, //
        DicomTags.bitsStored, DicomTags.pixelRepresentation,
        DicomTags.samplesPerPixel, DicomTags.planarConfiguration,
      ]);
      final value = any(_ints);
      ds.set(tag, value);
      return '${tag.value.toRadixString(16)} = $value';
    case 1:
      final frames = any([0, 1, 2, 3, 1000, 2147483647]);
      ds.set(DicomTags.numberOfFrames, frames);
      return 'frames = $frames';
    case 2:
      ds.set(DicomTags.photometricInterpretation, any(_photometrics));
      return 'photometric';
    case 3:
      final bytes = ds.get(DicomTags.pixelData);
      if (bytes == null) return 'no Pixel Data';
      final end = random.nextInt(bytes.length + 1);
      ds.set(DicomTags.pixelData, Uint8List.sublistView(bytes, 0, end));
      return 'Pixel Data cut at $end';
    case 4:
      final tag = any([DicomTags.rescaleSlope, DicomTags.rescaleIntercept]);
      ds.set(tag, any(_doubles));
      return 'rescale';
    case 5:
      final count = 1 + random.nextInt(2);
      ds
        ..setAll(DicomTags.windowCenter,
            [for (var n = 0; n < count; n++) any(_doubles)])
        ..setAll(DicomTags.windowWidth, [any(_doubles)])
        ..set(DicomTags.voilutFunction, any(_functions));
      return 'window';
    case 6:
      final sequence =
          any([DicomTags.voilutSequence, DicomTags.modalityLutSequence]);
      final descriptor = [any(_ints), any(_ints), any(_ints)];
      final entries = random.nextInt(5);
      final vr = any([Vr.US, Vr.OW]);
      ds.set(
          sequence,
          Sequence([
            Dataset()
              ..setRaw(DicomTags.lutDescriptor, Vr.US,
                  descriptor.sublist(0, 1 + random.nextInt(3)))
              ..setRaw(
                  DicomTags.lutData,
                  vr,
                  vr == Vr.US
                      ? [for (var n = 0; n < entries; n++) any(_ints)]
                      : Uint8List(entries * 2)),
          ]));
      return 'LUT sequence';
    case 7:
      final group = Dataset()
        ..set(
            DicomTags.pixelValueTransformationSequence,
            Sequence([
              Dataset()
                ..set(DicomTags.rescaleSlope, any(_doubles))
                ..set(DicomTags.rescaleIntercept, any(_doubles)),
            ]))
        ..set(
            DicomTags.frameVoilutSequence,
            Sequence([
              Dataset()
                ..setAll(DicomTags.windowCenter, [any(_doubles)])
                ..setAll(DicomTags.windowWidth, [any(_doubles)]),
            ]));
      ds
        ..set(DicomTags.sharedFunctionalGroupsSequence, Sequence([group]))
        ..set(DicomTags.perFrameFunctionalGroupsSequence,
            Sequence([for (var n = random.nextInt(3); n > 0; n--) Dataset()]));
      return 'functional groups';
    default:
      final tag = any([
        DicomTags.rows,
        DicomTags.bitsStored,
        DicomTags.photometricInterpretation,
        DicomTags.pixelData,
        DicomTags.samplesPerPixel,
      ]);
      ds.remove(tag);
      return 'removed ${tag.value.toRadixString(16)}';
  }
}
