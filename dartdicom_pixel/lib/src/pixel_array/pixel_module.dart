import 'package:dartdicom/dartdicom.dart';

/// The Image Pixel module attributes (PS3.3 C.7.6.3) that decoding and
/// display need, read once from a dataset.
final class PixelModule {
  PixelModule._({
    required this.rows,
    required this.columns,
    required this.samplesPerPixel,
    required this.bitsAllocated,
    required this.bitsStored,
    required this.signed,
    required this.photometricInterpretation,
    required this.numberOfFrames,
    required this.rescaleSlope,
    required this.rescaleIntercept,
    required this.pixelPaddingValue,
  });

  /// Reads the module from [ds]. Throws a `MissingElementException` naming
  /// the tag if a required attribute is absent.
  factory PixelModule.of(Dataset ds) {
    final bitsAllocated = ds.require(DicomTags.bitsAllocated);
    return PixelModule._(
      rows: ds.require(DicomTags.rows),
      columns: ds.require(DicomTags.columns),
      samplesPerPixel: ds.get(DicomTags.samplesPerPixel) ?? 1,
      bitsAllocated: bitsAllocated,
      bitsStored: ds.get(DicomTags.bitsStored) ?? bitsAllocated,
      signed: ds.get(DicomTags.pixelRepresentation) == 1,
      photometricInterpretation:
          ds.get(DicomTags.photometricInterpretation) ?? 'MONOCHROME2',
      numberOfFrames: ds.get(DicomTags.numberOfFrames) ?? 1,
      rescaleSlope: ds.get(DicomTags.rescaleSlope) ?? 1,
      rescaleIntercept: ds.get(DicomTags.rescaleIntercept) ?? 0,
      pixelPaddingValue: ds.get(DicomTags.pixelPaddingValue),
    );
  }

  final int rows;
  final int columns;
  final int samplesPerPixel;
  final int bitsAllocated;
  final int bitsStored;
  final bool signed;
  final String photometricInterpretation;
  final int numberOfFrames;
  final double rescaleSlope;
  final double rescaleIntercept;
  final int? pixelPaddingValue;

  /// Bytes per frame.
  int get frameLength => rows * columns * samplesPerPixel * bitsAllocated ~/ 8;
}
