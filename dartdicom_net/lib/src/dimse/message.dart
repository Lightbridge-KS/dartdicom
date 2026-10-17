import 'dart:typed_data';

import 'package:dartdicom/dartdicom.dart';

/// Command Field (0000,0100) values (PS3.7 §E.1).
abstract final class CommandField {
  static const cStoreRq = 0x0001;
  static const cStoreRsp = 0x8001;
  static const cGetRq = 0x0010;
  static const cGetRsp = 0x8010;
  static const cFindRq = 0x0020;
  static const cFindRsp = 0x8020;
  static const cMoveRq = 0x0021;
  static const cMoveRsp = 0x8021;
  static const cEchoRq = 0x0030;
  static const cEchoRsp = 0x8030;
  static const cCancelRq = 0x0FFF;
}

/// Command Data Set Type (0000,0800): no dataset follows.
const noDataset = 0x0101;

/// Priority (0000,0700): medium.
const mediumPriority = 0x0000;

/// One DIMSE message: a command set and, optionally, a dataset, on one
/// presentation context (PS3.7 §6.3).
///
/// The command set is always Implicit VR Little Endian; the dataset is in
/// the context's negotiated transfer syntax, and is kept as bytes so that
/// received instances can be stored exactly as they came.
final class DimseMessage {
  DimseMessage(this.contextId, this.command, [this.dataset]);

  final int contextId;

  /// The group 0000 elements, without (0000,0000) Command Group Length.
  final Dataset command;

  /// The encoded dataset, or `null` for none.
  final Uint8List? dataset;

  int get commandField => command.require(DicomTags.commandField);
  int? get messageId => command.get(DicomTags.messageId);
  int? get messageIdBeingRespondedTo =>
      command.get(DicomTags.messageIdBeingRespondedTo);
  int? get status => command.get(DicomTags.status);
  String? get affectedSopClassUid => command.get(DicomTags.affectedSopClassUid);
  String? get affectedSopInstanceUid =>
      command.get(DicomTags.affectedSopInstanceUid);

  /// The command set in Implicit VR Little Endian, led by (0000,0000) with
  /// the length of the rest (PS3.7 §6.3.1).
  Uint8List encodeCommand() {
    final body = command.toBytes(
        transferSyntax: TransferSyntaxes.implicitVrLittleEndian);
    return (BytesBuilder(copy: false)
          ..add((ByteData(12)
                ..setUint32(4, 4, Endian.little)
                ..setUint32(8, body.length, Endian.little))
              .buffer
              .asUint8List())
          ..add(body))
        .takeBytes();
  }

  /// Decodes a command set (with or without its group length).
  static Dataset decodeCommand(Uint8List bytes) {
    final ds = Dataset.fromBytes(bytes,
        transferSyntax: TransferSyntaxes.implicitVrLittleEndian);
    ds.remove(DicomTags.commandGroupLength);
    return ds;
  }

  @override
  String toString() =>
      'DimseMessage(0x${commandField.toRadixString(16).padLeft(4, '0')}, '
      'context $contextId${dataset == null ? '' : ', ${dataset!.length}-byte dataset'})';
}

/// A request's command set: [field], [messageId], the SOP class, and
/// whether a dataset follows.
Dataset requestCommand(int field, int messageId, Uid sopClass,
    {required bool hasDataset, int? priority}) {
  final ds = Dataset()
    ..set(DicomTags.affectedSopClassUid, sopClass.value)
    ..set(DicomTags.commandField, field)
    ..set(DicomTags.messageId, messageId)
    ..set(DicomTags.commandDataSetType, hasDataset ? 0x0001 : noDataset);
  if (priority != null) ds.set(DicomTags.priority, priority);
  return ds;
}
