import 'dart:convert';
import 'dart:typed_data';

import '../dataset/dataset.dart';
import '../tag/tags.g.dart';
import '../uid/implementation.dart';
import '../uid/transfer_syntax.dart';
import '../uid/uid.dart';
import '../write/writer.dart';

/// The File Meta Information of a Part 10 file: group 0002, always in
/// Explicit VR Little Endian (PS3.10 §7.1).
///
/// A typed view over a group-0002 [Dataset]. The writer derives it from the
/// dataset on every write (data §5); [toHeaderBytes] encodes it on its own,
/// so a sink can store received bytes behind it unchanged.
final class FileMetaInformation {
  /// A view over [dataset], which holds group 0002 elements only.
  FileMetaInformation(this.dataset);

  /// File meta for one instance, as a Storage SCP or a retrieve writes it:
  /// the version, the SOP UIDs, the transfer syntax of the bytes that will
  /// follow, dartdicom's implementation identity, and the AE title of the
  /// peer that sent it.
  factory FileMetaInformation.forInstance({
    required Uid sopClassUid,
    required Uid sopInstanceUid,
    required Uid transferSyntax,
    String? sourceAeTitle,
  }) {
    final ds = Dataset()
      ..set(DicomTags.fileMetaInformationVersion, Uint8List.fromList([0, 1]))
      ..set(DicomTags.mediaStorageSopClassUid, sopClassUid.value)
      ..set(DicomTags.mediaStorageSopInstanceUid, sopInstanceUid.value)
      ..set(DicomTags.transferSyntaxUid, transferSyntax.value)
      ..set(DicomTags.implementationClassUid,
          dartdicomImplementationClassUid.value)
      ..set(DicomTags.implementationVersionName,
          dartdicomImplementationVersionName);
    if (sourceAeTitle != null) {
      ds.set(DicomTags.sourceApplicationEntityTitle, sourceAeTitle);
    }
    return FileMetaInformation(ds);
  }

  /// The group 0002 elements.
  final Dataset dataset;

  /// (0002,0002) Media Storage SOP Class UID.
  Uid? get mediaStorageSopClassUid =>
      _uid(dataset.get(DicomTags.mediaStorageSopClassUid));

  /// (0002,0003) Media Storage SOP Instance UID.
  Uid? get mediaStorageSopInstanceUid =>
      _uid(dataset.get(DicomTags.mediaStorageSopInstanceUid));

  /// (0002,0010) Transfer Syntax UID: how the dataset that follows is
  /// encoded.
  Uid? get transferSyntaxUid => _uid(dataset.get(DicomTags.transferSyntaxUid));

  /// (0002,0012) Implementation Class UID of the writer.
  Uid? get implementationClassUid =>
      _uid(dataset.get(DicomTags.implementationClassUid));

  /// (0002,0016) Source Application Entity Title.
  String? get sourceApplicationEntityTitle =>
      dataset.get(DicomTags.sourceApplicationEntityTitle);

  /// The bytes that precede a dataset in a Part 10 file: the 128-byte
  /// [preamble] (zeros by default), `DICM`, and group 0002 with its group
  /// length.
  Uint8List toHeaderBytes({Uint8List? preamble}) {
    // Every element but the group length, kept as read: untouched elements
    // are copied byte for byte.
    final group = encodeDataset(
        readDataset(
            dataset.elements.where(
                (e) => e.tag != DicomTags.fileMetaInformationGroupLength),
            dataset.transferSyntax),
        TransferSyntax.explicitVrLittleEndian);
    final groupLength = (ByteData(12)
          ..setUint32(0, 0x00000002, Endian.little) // (0002,0000)
          ..setUint8(4, 0x55) // U
          ..setUint8(5, 0x4C) // L
          ..setUint16(6, 4, Endian.little)
          ..setUint32(8, group.length, Endian.little))
        .buffer
        .asUint8List();
    return (BytesBuilder(copy: false)
          ..add(preamble ?? Uint8List(128))
          ..add(ascii.encode('DICM'))
          ..add(groupLength)
          ..add(group))
        .takeBytes();
  }

  @override
  String toString() => 'FileMetaInformation(${dataset.length} elements)';
}

Uid? _uid(String? value) => value == null ? null : Uid(value);
