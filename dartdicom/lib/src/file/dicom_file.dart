import 'dart:typed_data';

import '../dataset/dataset.dart';
import '../dictionary/dictionary.dart';
import '../errors.dart';
import '../read/parser.dart';
import '../read/read_options.dart';
import '../source/byte_source.dart';
import '../tag/tags.g.dart';
import '../tag/typed_tag.dart';
import '../uid/implementation.dart';
import '../uid/transfer_syntax.dart';
import '../write/write_options.dart';
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
          {ReadOptions options = const ReadOptions()}) =>
      DicomFile.fromSource(BytesSource(bytes), options: options);

  /// Parses Part 10 data from [source]: a file (`FileSource`), or any
  /// random-access source. A source that holds only part of the data throws
  /// `NeedMoreBytes` for an async driver to fetch more (design D1).
  ///
  /// Throws a [DicomParseException] with the offset and tag where reading
  /// stopped if the data can't be read.
  factory DicomFile.fromSource(ByteSource source,
      {ReadOptions options = const ReadOptions()}) {
    final (:meta, :dataset, :preamble) = parsePart10(source, options);
    return DicomFile(FileMetaInformation(meta), dataset, preamble: preamble);
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
  Uint8List toBytes({WriteOptions options = const WriteOptions()}) {
    final declared = meta.transferSyntaxUid;
    final ts = (declared == null ? null : TransferSyntax.of(declared)) ??
        TransferSyntax.explicitVrLittleEndian;
    final body = encodeDataset(dataset, ts, deflateCodec: options.deflateCodec);
    return (BytesBuilder(copy: false)
          ..add(_derivedMeta(ts).toHeaderBytes(preamble: preamble))
          ..add(body))
        .takeBytes();
  }

  FileMetaInformation _derivedMeta(TransferSyntax ts) {
    final derived =
        readDataset(meta.dataset.elements, meta.dataset.transferSyntax);

    // A SOP UID is held twice: once in the meta (metaTag) and once in the
    // dataset (from). The dataset is the source; the meta follows it.
    void deriveSopUid(One<String> metaTag, {required One<String> from}) {
      final fromDataset = dataset.get(from);
      final fromMeta = derived.get(metaTag);
      if (fromDataset == null) {
        // Neither has the UID, so the meta has nothing to be derived from.
        if (fromMeta == null) {
          throw DicomWriteException(
              'the dataset needs ${describeTag(from)} to write a file',
              tag: from);
        }
        // Only the meta has it: nothing to check it against, so keep it.
        return;
      }
      if (fromMeta == null) {
        // Only the dataset has it: copy it into the meta.
        derived.set(metaTag, fromDataset);
      } else if (fromMeta != fromDataset) {
        // Both have it and they differ: don't guess which one is right (I-17).
        throw DicomWriteException(
            'the file meta and the dataset disagree on ${describeTag(from)}; '
            'set ${describeTag(metaTag)} to match, or remove it so it is derived',
            tag: metaTag);
      }
    }

    deriveSopUid(DicomTags.mediaStorageSopClassUid,
        from: DicomTags.sopClassUid);
    deriveSopUid(DicomTags.mediaStorageSopInstanceUid,
        from: DicomTags.sopInstanceUid);

    // (0002,0010) names the encoding actually used (I-17), which differs from
    // the meta's when that is missing or unknown and [toBytes] falls back to
    // Explicit VR LE. Set it only when it differs: a set element is
    // re-encoded, an untouched one is copied byte for byte (I-10).
    if (derived.get(DicomTags.transferSyntaxUid) != ts.uid.value) {
      derived.set(DicomTags.transferSyntaxUid, ts.uid.value);
    }
    // The implementation identity is kept as read; dartdicom's fills in only
    // where the meta has none.
    if (!derived.contains(DicomTags.implementationClassUid)) {
      derived.set(DicomTags.implementationClassUid,
          dartdicomImplementationClassUid.value);
    }
    if (!derived.contains(DicomTags.implementationVersionName)) {
      derived.set(DicomTags.implementationVersionName,
          dartdicomImplementationVersionName);
    }
    // The meta version is the two bytes 00H 01H (PS3.10 §7.1).
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
