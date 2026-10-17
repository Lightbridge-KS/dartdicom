import 'dart:typed_data';

import 'package:dartdicom/dartdicom.dart';

/// Where received instances go, one at a time, so a study is never held
/// whole in memory (PRD N-11).
///
/// `accept` may be slow (a disk write): the association waits for it before
/// answering the C-STORE-RQ. If it throws an [Exception], the peer gets a
/// failure status for that instance and the retrieve carries on.
abstract interface class InstanceSink {
  /// Takes one received instance.
  Future<void> accept(ReceivedInstance instance);
}

/// One instance received over DIMSE, exactly as it came: the dataset bytes
/// in the transfer syntax negotiated for its presentation context
/// (blueprint F10).
final class ReceivedInstance {
  ReceivedInstance({
    required this.sopClassUid,
    required this.sopInstanceUid,
    required this.transferSyntax,
    required this.bytes,
    required this.sourceAeTitle,
  });

  /// (0000,0002) Affected SOP Class UID.
  final Uid sopClassUid;

  /// (0000,1000) Affected SOP Instance UID.
  final Uid sopInstanceUid;

  /// The transfer syntax [bytes] are encoded in: the presentation
  /// context's, since the bytes themselves don't say.
  final Uid transferSyntax;

  /// The dataset, as received: no preamble, no file meta.
  final Uint8List bytes;

  /// The AE title of the peer that sent it, for (0002,0016).
  final String sourceAeTitle;

  /// File meta for storing [bytes] as a Part 10 file: write
  /// `fileMeta.toHeaderBytes()`, then [bytes] unchanged.
  FileMetaInformation get fileMeta => FileMetaInformation.forInstance(
      sopClassUid: sopClassUid,
      sopInstanceUid: sopInstanceUid,
      transferSyntax: transferSyntax,
      sourceAeTitle: sourceAeTitle);

  /// Parses [bytes] (e.g. with `ReadOptions(stopBeforePixels: true)` for
  /// a header).
  Dataset parse({ReadOptions options = const ReadOptions()}) =>
      Dataset.fromBytes(bytes,
          transferSyntax: transferSyntax, options: options);

  @override
  String toString() =>
      'ReceivedInstance(${sopClassUid.value}, ${bytes.length} bytes)';
}

/// Keeps every received instance in memory: for tests and small
/// retrieves.
final class MemorySink implements InstanceSink {
  /// The instances received so far, in order.
  final instances = <ReceivedInstance>[];

  @override
  Future<void> accept(ReceivedInstance instance) async =>
      instances.add(instance);
}
