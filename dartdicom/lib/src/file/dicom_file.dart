import 'dart:typed_data';

import '../dataset/dataset.dart';
import '../dictionary/dictionary.dart';
import '../errors.dart';
import '../read/parser.dart';
import '../read/read_options.dart';
import '../tag/tags.g.dart';
import '../tag/typed_tag.dart';
import '../uid/implementation.dart';
import '../uid/transfer_syntax.dart';
import '../write/writer.dart';
import 'file_meta.dart';

/// A DICOM Part 10 file: the file meta and the dataset, held as separate
/// parts (PRD C-07).
///
/// ```dart
/// final file = DicomFile.fromBytes(bytes);
/// final ds = file.dataset;
/// ```
final class DicomFile {
  /// A file of [meta] and [dataset]. [preamble], 128 bytes, defaults to
  /// zeros.
  DicomFile(this.meta, this.dataset, {Uint8List? preamble})
      : preamble = preamble ?? Uint8List(128) {
    if (this.preamble.length != 128) {
      throw ArgumentError.value(
          this.preamble.length, 'preamble', 'must be 128 bytes long');
    }
  }

  /// Parses Part 10 [bytes]: from memory, a browser `Blob`, an HTTP body.
  ///
  /// Throws a [DicomParseException] with the offset and tag where reading
  /// stopped if the bytes can't be read.
  factory DicomFile.fromBytes(Uint8List bytes,
      {ReadOptions options = const ReadOptions()}) {
    final (:meta, :dataset) = parsePart10(bytes, options);
    return DicomFile(FileMetaInformation(meta), dataset,
        preamble: Uint8List.fromList(Uint8List.sublistView(bytes, 0, 128)));
  }

  /// The 128-byte preamble: zeros, or application data some files carry
  /// (e.g. a TIFF header). Written back as read.
  final Uint8List preamble;

  /// The file meta information (group 0002).
  final FileMetaInformation meta;

  /// The dataset: everything after the file meta.
  final Dataset dataset;

  /// Encodes the file as Part 10 bytes, in the transfer syntax it was read
  /// in. Untouched elements are copied byte for byte (I-10).
  ///
  /// The meta is derived from the dataset (data §5): the SOP UIDs come
  /// from the dataset, and (0002,0010) is the encoding actually used. Throws
  /// a [DicomWriteException] if the meta and the dataset disagree on a SOP
  /// UID (I-17), or if a value can't be encoded; nothing is written then.
  Uint8List toBytes() {
    final declared = meta.transferSyntaxUid;
    final ts = (declared == null ? null : TransferSyntax.of(declared)) ??
        TransferSyntax.explicitVrLittleEndian;
    final body = encodeDataset(dataset, ts);
    return (BytesBuilder(copy: false)
          ..add(_derivedMeta(ts).toHeaderBytes(preamble: preamble))
          ..add(body))
        .takeBytes();
  }

  FileMetaInformation _derivedMeta(TransferSyntax ts) {
    final derived =
        readDataset(meta.dataset.elements, meta.dataset.transferSyntax);
    void derive(One<String> metaTag, One<String> datasetTag) {
      final fromDataset = dataset.get(datasetTag);
      final fromMeta = derived.get(metaTag);
      if (fromDataset == null) {
        if (fromMeta == null) {
          throw DicomWriteException(
              'the dataset needs ${describeTag(datasetTag)} to write a file',
              tag: datasetTag);
        }
        return;
      }
      if (fromMeta == null) {
        derived.set(metaTag, fromDataset);
      } else if (fromMeta != fromDataset) {
        throw DicomWriteException(
            'the file meta and the dataset disagree on ${describeTag(datasetTag)}; '
            'set ${describeTag(metaTag)} to match, or remove it so it is derived',
            tag: metaTag);
      }
    }

    derive(DicomTags.mediaStorageSopClassUid, DicomTags.sopClassUid);
    derive(DicomTags.mediaStorageSopInstanceUid, DicomTags.sopInstanceUid);
    if (derived.get(DicomTags.transferSyntaxUid) != ts.uid.value) {
      derived.set(DicomTags.transferSyntaxUid, ts.uid.value);
    }
    _setIfAbsent(derived, DicomTags.implementationClassUid,
        dartdicomImplementationClassUid.value);
    _setIfAbsent(derived, DicomTags.implementationVersionName,
        dartdicomImplementationVersionName);
    if (!derived.contains(DicomTags.fileMetaInformationVersion)) {
      derived.set(
          DicomTags.fileMetaInformationVersion, Uint8List.fromList([0, 1]));
    }
    return FileMetaInformation(derived);
  }

  @override
  String toString() =>
      'DicomFile(${meta.transferSyntaxUid?.value ?? 'no transfer syntax'}, '
      '${dataset.length} elements)';
}

void _setIfAbsent(Dataset ds, One<String> tag, String value) {
  if (!ds.contains(tag)) ds.set(tag, value);
}
