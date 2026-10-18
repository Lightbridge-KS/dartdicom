import 'package:dartdicom/dartdicom.dart';

import '../errors.dart';

/// The Image Pixel module attributes (PS3.3 C.7.6.3) that decoding needs,
/// read once from a dataset and checked as pydicom 3.0.2 checks them.
final class PixelModule {
  PixelModule._({
    required this.rows,
    required this.columns,
    required this.samplesPerPixel,
    required this.bitsAllocated,
    required this.bitsStored,
    required this.signed,
    required this.photometricInterpretation,
    required this.planarConfiguration,
    required this.numberOfFrames,
    required this.rescaleSlope,
    required this.rescaleIntercept,
    required this.pixelPaddingValue,
  });

  /// Reads the module from [ds]. Throws an [InvalidPixelModule] naming the
  /// tag if a required attribute is absent or out of range.
  factory PixelModule.of(Dataset ds) {
    final bitsAllocated = _required(ds, DicomTags.bitsAllocated);
    if (bitsAllocated < 1 ||
        bitsAllocated > 64 ||
        (bitsAllocated != 1 && bitsAllocated % 8 != 0)) {
      throw InvalidPixelModule(
          DicomTags.bitsAllocated, 'must be 1 or a multiple of 8, at most 64');
    }
    final bitsStored = _required(ds, DicomTags.bitsStored);
    if (bitsStored < 1 || bitsStored > bitsAllocated) {
      throw InvalidPixelModule(DicomTags.bitsStored,
          'must be at least 1 and at most (0028,0100) BitsAllocated');
    }
    final pixelRepresentation = _required(ds, DicomTags.pixelRepresentation);
    if (pixelRepresentation != 0 && pixelRepresentation != 1) {
      throw InvalidPixelModule(DicomTags.pixelRepresentation, 'must be 0 or 1');
    }
    final samples = _required(ds, DicomTags.samplesPerPixel);
    if (samples != 1 && samples != 3) {
      throw InvalidPixelModule(DicomTags.samplesPerPixel, 'must be 1 or 3');
    }
    final planar =
        samples == 3 ? _required(ds, DicomTags.planarConfiguration) : 0;
    if (planar != 0 && planar != 1) {
      throw InvalidPixelModule(DicomTags.planarConfiguration, 'must be 0 or 1');
    }
    final photometric = _read(ds, DicomTags.photometricInterpretation)?.trim();
    if (photometric == null || photometric.isEmpty) {
      throw InvalidPixelModule(
          DicomTags.photometricInterpretation, 'is required for Pixel Data');
    }
    if (!_photometrics.contains(photometric)) {
      throw InvalidPixelModule(DicomTags.photometricInterpretation,
          'is not a Photometric Interpretation PS3.3 C.7.6.3.1.2 defines');
    }
    // 0 or empty is read as one frame, as pydicom does.
    final frames = _read(ds, DicomTags.numberOfFrames) ?? 0;
    if (frames < 0) {
      throw InvalidPixelModule(DicomTags.numberOfFrames, 'must be at least 1');
    }
    // A rescale needs both attributes, as in pydicom's apply_modality_lut.
    final slope = _finite(ds, DicomTags.rescaleSlope);
    final intercept = _finite(ds, DicomTags.rescaleIntercept);
    final rescale = slope != null && intercept != null;
    return PixelModule._(
      rows: _dimension(ds, DicomTags.rows),
      columns: _dimension(ds, DicomTags.columns),
      samplesPerPixel: samples,
      bitsAllocated: bitsAllocated,
      bitsStored: bitsStored,
      signed: pixelRepresentation == 1,
      photometricInterpretation: photometric,
      planarConfiguration: planar,
      numberOfFrames: frames == 0 ? 1 : frames,
      rescaleSlope: rescale ? slope : 1,
      rescaleIntercept: rescale ? intercept : 0,
      pixelPaddingValue: _read(ds, DicomTags.pixelPaddingValue),
    );
  }

  /// Rows, 1–65535.
  final int rows;

  /// Columns, 1–65535.
  final int columns;

  /// Samples per Pixel: 1 for grayscale and palette, 3 for color.
  final int samplesPerPixel;

  /// Bits Allocated: 1, or a multiple of 8.
  final int bitsAllocated;

  /// Bits Stored, at most [bitsAllocated].
  final int bitsStored;

  /// Whether Pixel Representation is 1 (two's complement).
  final bool signed;

  /// Photometric Interpretation, e.g. `MONOCHROME2`.
  final String photometricInterpretation;

  /// Planar Configuration: 0 (interleaved) or 1 (one plane per sample);
  /// 0 when there is one sample.
  final int planarConfiguration;

  /// Number of Frames, at least 1.
  final int numberOfFrames;

  /// Rescale Slope, or 1 unless both Slope and Intercept are present.
  final double rescaleSlope;

  /// Rescale Intercept, or 0 unless both Slope and Intercept are present.
  final double rescaleIntercept;

  /// Pixel Padding Value, if present.
  final int? pixelPaddingValue;

  /// Whether the image is grayscale (MONOCHROME1 or MONOCHROME2).
  bool get isMonochrome =>
      photometricInterpretation == 'MONOCHROME1' ||
      photometricInterpretation == 'MONOCHROME2';

  /// Samples in one frame.
  int get samplesPerFrame => rows * columns * samplesPerPixel;

  /// Bytes per frame, for Bits Allocated 8 and above.
  int get frameLength => samplesPerFrame * bitsAllocated ~/ 8;

  @override
  String toString() => 'PixelModule($photometricInterpretation, '
      '$bitsAllocated bits allocated)';
}

/// The Photometric Interpretations of PS3.3 C.7.6.3.1.2 (pydicom's list).
const _photometrics = {
  'MONOCHROME1', 'MONOCHROME2', 'PALETTE COLOR', 'RGB', 'HSV', 'ARGB', //
  'CMYK', 'YBR_FULL', 'YBR_FULL_422', 'YBR_PARTIAL_422', 'YBR_PARTIAL_420',
  'YBR_ICT', 'YBR_RCT', 'XYB',
};

int _required(Dataset ds, One<int> tag) =>
    _read(ds, tag) ??
    (throw InvalidPixelModule(tag, 'is required for Pixel Data'));

int _dimension(Dataset ds, One<int> tag) {
  final value = _required(ds, tag);
  if (value < 1 || value > 65535) {
    throw InvalidPixelModule(tag, 'must be 1–65535');
  }
  return value;
}

/// [tag]'s value, or `null` if it is absent. NaN or an infinity (which DS
/// text can spell) is an [InvalidPixelModule].
double? _finite(Dataset ds, One<double> tag) {
  final value = _read(ds, tag);
  if (value != null && !value.isFinite) {
    throw InvalidPixelModule(tag, 'must be a finite number');
  }
  return value;
}

/// [tag]'s value, or `null` if it is absent. A value core can't decode is
/// an [InvalidPixelModule], so pixel failures stay in one sealed tree.
T? _read<T extends Object>(Dataset ds, One<T> tag) {
  try {
    return ds.get(tag);
  } on DicomDataException {
    throw InvalidPixelModule(tag, 'cannot be read as its VR');
  }
}
