import 'dictionary/dictionary.dart';
import 'tag/tag.dart';

/// The base of every exception the dartdicom packages throw.
///
/// It is open so that each package can root its own sealed subtree here
/// (blueprint F30): `DicomDataException` in this package, `DimseException`
/// in `dartdicom_net`. A message names tags and offsets, says what to do
/// next, and never contains an element value (I-9).
abstract base class DicomException implements Exception {
  const DicomException(this.message);

  /// What went wrong and, where there is one, the next move. Never a value.
  final String message;

  @override
  String toString() => message;
}

/// Something wrong with DICOM data itself: unreadable bytes, a missing
/// required element, or a dataset that cannot be written as asked.
///
/// Sealed, so a `switch` over its subtypes is exhaustive.
sealed class DicomDataException extends DicomException {
  const DicomDataException(super.message);
}

/// The bytes cannot be read as DICOM: truncated, malformed, or in an
/// encoding this version doesn't support yet.
final class DicomParseException extends DicomDataException {
  DicomParseException(String problem, {this.offset, this.tag})
      : super('DicomParseException: $problem'
            '${tag == null ? '' : ' at ${describeTag(tag)}'}'
            '${offset == null ? '' : ' (byte offset $offset)'}');

  /// Where in the input the problem was found, if known.
  final int? offset;

  /// The element being read, if known.
  final Tag? tag;
}

/// A required element is absent, from `Dataset.require`.
final class MissingElementException extends DicomDataException {
  MissingElementException(this.tag)
      : super('MissingElementException: ${describeTag(tag)} is required '
            'but absent; use ds.get(...) for optional reads');

  /// The element that was required.
  final Tag tag;
}

/// A dataset or file cannot be written as asked. Nothing was written.
final class DicomWriteException extends DicomDataException {
  DicomWriteException(String problem, {this.tag})
      : super('DicomWriteException: '
            '${tag == null ? '' : '${describeTag(tag)}: '}$problem');

  /// The element that could not be written, if the problem is in one.
  final Tag? tag;
}

/// A deferred value's source changed after it was read: its size or
/// modification time differs (data architecture DA2). The loaded bytes might
/// not be the ones that were parsed, so nothing is returned.
final class SourceChangedException extends DicomDataException {
  SourceChangedException()
      : super('SourceChangedException: the file a deferred value was read '
            'from changed since it was read (size or modification time); '
            'read the file again');
}
