import 'dart:typed_data';

import 'package:dartdicom/dartdicom.dart';

import '../errors.dart';
import '../pdu/pdus.dart';
import 'message.dart';

/// Splits [message] into P-DATA-TF PDUs that fit the peer's
/// [maxPduLength]: the command first, then the dataset, one PDV per PDU
/// (PS3.8 §9.3.5). Each PDV costs 6 bytes of the PDU. With no limit (0),
/// the command and the dataset are one PDV each, as pynetdicom sends them.
List<PDataTf> fragment(DimseMessage message, int maxPduLength) {
  final chunk = maxPduLength == 0 ? 0x7FFFFFFF : maxPduLength - 6;
  if (chunk < 1) {
    throw DimseProtocolException(
        'the peer\'s maximum PDU length ($maxPduLength) is too small');
  }
  final pdus = <PDataTf>[];
  void split(Uint8List bytes, {required bool isCommand}) {
    for (var at = 0; at < bytes.length || at == 0; at += chunk) {
      final end = at + chunk < bytes.length ? at + chunk : bytes.length;
      pdus.add(PDataTf([
        Pdv(message.contextId, Uint8List.sublistView(bytes, at, end),
            isCommand: isCommand, isLast: end == bytes.length),
      ]));
      if (end == bytes.length) break;
    }
  }

  split(message.encodeCommand(), isCommand: true);
  if (message.dataset != null) split(message.dataset!, isCommand: false);
  return pdus;
}

/// Reassembles DIMSE messages from PDVs: every PDV of every P-DATA-TF, the
/// command first, then its dataset if Command Data Set Type says one
/// follows (PS3.7 §6.3.1, PS3.8 §9.3.5).
///
/// One message is in flight at a time (no asynchronous operations window
/// is negotiated); a PDV for another context mid-message, or a dataset
/// fragment before its command, is a protocol violation.
final class Assembler {
  final _command = BytesBuilder(copy: false);
  final _dataset = BytesBuilder(copy: false);
  Dataset? _awaitingDataset;
  int? _contextId;

  /// Feeds [pdu]; returns the messages it completed, in order.
  List<DimseMessage> feed(PDataTf pdu) {
    final done = <DimseMessage>[];
    for (final pdv in pdu.pdvs) {
      if (_contextId != null && pdv.contextId != _contextId) {
        throw DimseProtocolException(
            'a PDV for context ${pdv.contextId} arrived in the middle of a '
            'message on context $_contextId');
      }
      _contextId = pdv.contextId;
      if (pdv.isCommand) {
        if (_awaitingDataset != null) {
          throw DimseProtocolException(
              'a command fragment arrived where a dataset was expected');
        }
        _command.add(pdv.data);
        if (!pdv.isLast) continue;
        final command = DimseMessage.decodeCommand(_command.takeBytes());
        if (command.get(DicomTags.commandDataSetType) == noDataset) {
          done.add(DimseMessage(pdv.contextId, command));
          _contextId = null;
        } else {
          _awaitingDataset = command;
        }
      } else {
        final command = _awaitingDataset;
        if (command == null) {
          throw DimseProtocolException(
              'a dataset fragment arrived before its command');
        }
        _dataset.add(pdv.data);
        if (!pdv.isLast) continue;
        done.add(DimseMessage(pdv.contextId, command, _dataset.takeBytes()));
        _awaitingDataset = null;
        _contextId = null;
      }
    }
    return done;
  }
}
