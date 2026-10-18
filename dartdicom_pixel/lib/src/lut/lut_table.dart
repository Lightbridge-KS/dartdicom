import 'dart:typed_data';

import 'package:dartdicom/dartdicom.dart';

import '../errors.dart';

/// A Modality or VOI LUT as its item holds it (PS3.3 C.11.1, C.11.2): the
/// LUT Descriptor's first mapped value and bits per entry, and the LUT Data
/// entries.
final class LutTable {
  LutTable._(this.firstMapped, this.bits, this.entries);

  /// Reads [item]'s LUT Descriptor and LUT Data. OW LUT Data is in 16-bit
  /// words of the dataset's byte order, [littleEndian]; US data is already
  /// numbers. Throws an [InvalidPixelModule] for a descriptor without three
  /// values, bits per entry outside 8–16, or fewer entries than it declares.
  factory LutTable.of(Dataset item, {required bool littleEndian}) {
    final List<int> descriptor;
    try {
      descriptor = item.getAll(DicomTags.lutDescriptor);
    } on DicomDataException {
      throw InvalidPixelModule(DicomTags.lutDescriptor, 'cannot be read');
    }
    if (descriptor.length != 3) {
      throw InvalidPixelModule(DicomTags.lutDescriptor, 'must hold 3 values');
    }
    // An entry count of 0 means 65536 (PS3.3 C.11.1.1.1).
    final count = descriptor[0] == 0 ? 65536 : descriptor[0];
    final bits = descriptor[2];
    if (bits < 8 || bits > 16) {
      throw InvalidPixelModule(
          DicomTags.lutDescriptor, 'bits per entry must be 8–16');
    }
    final data = _data(item, littleEndian);
    if (data.length < count) {
      throw InvalidPixelModule(DicomTags.lutData,
          'holds fewer entries than (0028,3002) LUTDescriptor declares');
    }
    return LutTable._(descriptor[1], bits,
        Uint16List.fromList(data.sublist(0, count)).asUnmodifiableView());
  }

  /// The stored or modality value that maps to the first entry.
  final int firstMapped;

  /// Bits per entry, 8–16.
  final int bits;

  /// The entries, one per value from [firstMapped] on.
  final Uint16List entries;

  /// The entry for input [x]: inputs below [firstMapped] take the first
  /// entry and inputs past the end the last (PS3.3 C.11.1.1, as pydicom).
  /// A fractional input is truncated toward the entry below it.
  int lookup(double x) {
    final index = (x - firstMapped).floor();
    if (index <= 0) return entries.first;
    if (index >= entries.length) return entries.last;
    return entries[index];
  }
}

List<int> _data(Dataset item, bool littleEndian) {
  final element = item.element(DicomTags.lutData);
  if (element == null) {
    throw InvalidPixelModule(DicomTags.lutData, 'is required in a LUT item');
  }
  try {
    if (element.vr == Vr.US) return item.getInts(DicomTags.lutData);
    final bytes = item.getBytes(DicomTags.lutData) ?? Uint8List(0);
    final words = ByteData.sublistView(bytes);
    final endian = littleEndian ? Endian.little : Endian.big;
    return [
      for (var i = 0; i + 1 < bytes.length; i += 2) words.getUint16(i, endian),
    ];
  } on DicomDataException {
    throw InvalidPixelModule(DicomTags.lutData, 'cannot be read');
  }
}
