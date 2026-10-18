import 'package:dartdicom/dartdicom.dart';

/// Pixel Data this package can't turn into numbers or a picture.
///
/// Sealed, so a `switch` over its subtypes is exhaustive. It roots under
/// core's [DicomException] (blueprint F30). A message names the tag and says
/// what to do next; it never contains a value (I-9).
sealed class PixelDataException extends DicomException {
  const PixelDataException(super.message);
}

/// The pixels are in an encoding this version can't decode or display: a
/// compressed transfer syntax, a Bits Allocated other than 1, 8, 16 or 32,
/// YBR_FULL_422, or color for display.
final class UnsupportedPixelEncoding extends PixelDataException {
  UnsupportedPixelEncoding(String problem, {this.tag, this.transferSyntax})
      : super('UnsupportedPixelEncoding: '
            '${tag == null ? '' : '${_describe(tag)} '}$problem');

  /// The attribute whose value this version doesn't support, if one.
  final Tag? tag;

  /// The transfer syntax, when that is what isn't supported.
  final Uid? transferSyntax;
}

/// An Image Pixel, Modality LUT or VOI LUT attribute is missing or invalid,
/// or Pixel Data doesn't hold the frames the module declares.
final class InvalidPixelModule extends PixelDataException {
  InvalidPixelModule(this.tag, String problem)
      : super('InvalidPixelModule: ${_describe(tag)} $problem');

  /// The attribute that is missing or invalid.
  final Tag tag;
}

/// Reads that keep pixel failures in one sealed tree (I-30): a value core
/// can't read as its tag's type is an [InvalidPixelModule] naming the tag,
/// never core's [DicomDataException]. Not exported.
extension AttributeReads on Dataset {
  /// [tag]'s value, or `null` if it is absent or empty.
  T? attribute<T extends Object>(One<T> tag) =>
      readAttribute(tag, () => get(tag));

  /// Every value of [tag], or an empty list if it is absent or empty.
  List<T> attributes<T extends Object>(Many<T> tag) =>
      readAttribute(tag, () => getAll(tag));
}

/// What [read] returns, with a value core can't read turned into an
/// [InvalidPixelModule] naming [tag]: for reads [AttributeReads] doesn't
/// cover.
T readAttribute<T>(Tag tag, T Function() read) {
  try {
    return read();
  } on DicomDataException {
    throw InvalidPixelModule(tag, 'cannot be read as its VR');
  }
}

/// `(0028,0010) Rows`: the number and the keyword, never a value.
String _describe(Tag tag) {
  String hex(int n) => n.toRadixString(16).padLeft(4, '0').toUpperCase();
  final label = '(${hex(tag.group)},${hex(tag.element)})';
  final keyword = Dictionary.standard.entry(tag)?.keyword ?? '';
  return keyword.isEmpty ? label : '$label $keyword';
}
