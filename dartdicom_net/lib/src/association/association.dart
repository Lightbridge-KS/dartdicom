import 'dart:async';
import 'dart:collection';

import 'package:dartdicom/dartdicom.dart';

import '../acse/negotiation.dart';
import '../dimse/fragments.dart';
import '../dimse/message.dart';
import '../dimse/status.dart';
import '../dul/dul.dart';
import '../errors.dart';
import '../pdu/pdus.dart';
import '../sink/instance_sink.dart';
import 'presentation_contexts.dart';
import 'retrieve_progress.dart';
import '../transport/transport.dart';
import 'application_entity.dart';

/// An established association with a peer AE: the DIMSE operations run
/// here, one at a time.
///
/// Get one from `ApplicationEntity.associate`; end it with [release] (or
/// [abort]). Transport, association and protocol failures throw a
/// [DimseException]; DIMSE outcomes come back as a [DimseStatus] (design
/// D3).
final class Association {
  Association._(this._dul, this.calledAeTitle, this.acceptedContexts,
      this._peerMaxPduLength);

  /// Requests an association over [transport] with [rq].
  static Future<Association> request(
      Transport transport, AssociateRq rq, ApplicationEntity ae) async {
    final dul = Dul.requestor(transport);
    final ac = await dul.requestAssociation(rq);
    return Association._(dul, rq.calledAeTitle, negotiatedContexts(rq, ac),
        ac.userInformation.maxLength);
  }

  final Dul _dul;
  final int _peerMaxPduLength;
  final _assembler = Assembler();
  final _received = Queue<DimseMessage>();
  var _lastMessageId = 0;
  var _busy = false;

  /// The peer's AE title.
  final String calledAeTitle;

  /// The presentation contexts the peer accepted.
  final List<AcceptedContext> acceptedContexts;

  /// Sends C-ECHO-RQ and returns the response's status.
  Future<DimseStatus> sendCEcho() => _exclusive(() async {
        final context = _contextFor(SopClasses.verification, 'C-ECHO');
        final id = _nextMessageId();
        await _send(DimseMessage(
            context.id,
            requestCommand(CommandField.cEchoRq, id, SopClasses.verification,
                hasDataset: false)));
        final rsp = await _responseTo(id, CommandField.cEchoRsp);
        return DimseStatus(rsp.status ?? 0xC000);
      });

  /// Sends C-FIND-RQ with [query] and streams the matches (PRD N-07).
  ///
  /// [query] is a plain [Dataset] (surface S3): matching keys hold values,
  /// return keys are empty (`setEmpty`), and (0008,0052) QueryRetrieveLevel
  /// says the level. The stream completes on a final Success, Warning or
  /// Cancel; a final Failure is a [DimseFailureException] stream error, so
  /// a failed query never looks like "no matches" (surface S5).
  ///
  /// Cancelling the subscription aborts the association in this version
  /// (C-CANCEL comes later).
  Stream<Dataset> sendCFind(Dataset query,
      {QueryRetrieveModel model = QueryRetrieveModel.studyRoot}) async* {
    final context = _contextFor(model.find, 'C-FIND');
    _enter();
    var finished = false;
    try {
      final id = _nextMessageId();
      await _send(DimseMessage(
          context.id,
          requestCommand(CommandField.cFindRq, id, model.find,
              hasDataset: true, priority: mediumPriority),
          query.toBytes(transferSyntax: context.transferSyntax)));
      while (true) {
        final rsp = await _responseTo(id, CommandField.cFindRsp);
        switch (DimseStatus(rsp.status ?? 0xC000)) {
          case DimsePending():
            final identifier = rsp.dataset;
            if (identifier != null) {
              yield Dataset.fromBytes(identifier,
                  transferSyntax: context.transferSyntax);
            }
          case final DimseFailure failure:
            finished = true;
            throw DimseFailureException(failure);
          case _:
            finished = true;
            return;
        }
      }
    } finally {
      _busy = false;
      if (!finished) await _dul.abort();
    }
  }

  /// Sends C-GET-RQ with [query] and receives the instances it matches on
  /// this association, each handed to [sink] (PRD N-08, N-11).
  ///
  /// The storage classes to receive must have been proposed in
  /// `ApplicationEntity.retrieveStorageClasses`, so the peer accepted this
  /// side as their SCP. Each C-STORE sub-operation is answered once [sink]
  /// has taken the instance: success, or a failure (0xC211) if it threw an
  /// [Exception], and the retrieve carries on.
  ///
  /// Emits a [RetrieveProgress] for each response; the last carries the
  /// final status. A final Failure is then also a [DimseFailureException]
  /// stream error (surface S5). Cancelling the subscription aborts the
  /// association in this version.
  Stream<RetrieveProgress> sendCGet(Dataset query, InstanceSink sink,
      {QueryRetrieveModel model = QueryRetrieveModel.studyRoot}) async* {
    final context = _contextFor(model.get, 'C-GET');
    _enter();
    var finished = false;
    try {
      final id = _nextMessageId();
      await _send(DimseMessage(
          context.id,
          requestCommand(CommandField.cGetRq, id, model.get,
              hasDataset: true, priority: mediumPriority),
          query.toBytes(transferSyntax: context.transferSyntax)));
      while (true) {
        final message = await _receive();
        if (message.commandField == CommandField.cStoreRq) {
          await _store(message, sink);
          continue;
        }
        if (message.commandField != CommandField.cGetRsp ||
            message.messageIdBeingRespondedTo != id) {
          await _protocolAbort('expected a C-GET response or a C-STORE '
              'sub-operation, but got $message');
        }
        final progress = RetrieveProgress.fromResponse(message);
        if (!progress.isFinal) {
          yield progress;
          continue;
        }
        finished = true;
        yield progress;
        if (progress.status case final DimseFailure failure) {
          throw DimseFailureException(failure);
        }
        return;
      }
    } finally {
      _busy = false;
      if (!finished) await _dul.abort();
    }
  }

  /// Answers one C-STORE sub-operation of a C-GET: [sink] takes the
  /// instance, then the C-STORE-RSP goes back on the same context.
  Future<void> _store(DimseMessage rq, InstanceSink sink) async {
    final context =
        acceptedContexts.where((c) => c.id == rq.contextId).firstOrNull;
    final sopClass = rq.affectedSopClassUid;
    final sopInstance = rq.affectedSopInstanceUid;
    int status;
    if (context == null || !context.scpRole) {
      status = 0x0122; // SOP class not supported: no SCP role was accepted
    } else if (sopClass == null || sopInstance == null || rq.dataset == null) {
      status = 0xC211;
    } else {
      try {
        await sink.accept(ReceivedInstance(
            sopClassUid: Uid(sopClass),
            sopInstanceUid: Uid(sopInstance),
            transferSyntax: context.transferSyntax,
            bytes: rq.dataset!,
            sourceAeTitle: calledAeTitle));
        status = 0x0000;
      } on Exception {
        status = 0xC211; // the sink failed; the peer counts it as failed
      }
    }
    final rsp = Dataset()
      ..set(DicomTags.commandField, CommandField.cStoreRsp)
      ..set(DicomTags.messageIdBeingRespondedTo, rq.messageId ?? 0)
      ..set(DicomTags.commandDataSetType, noDataset)
      ..set(DicomTags.status, status);
    if (sopClass != null) rsp.set(DicomTags.affectedSopClassUid, sopClass);
    if (sopInstance != null) {
      rsp.set(DicomTags.affectedSopInstanceUid, sopInstance);
    }
    await _send(DimseMessage(rq.contextId, rsp));
  }

  /// Releases the association gracefully (A-RELEASE) and closes the
  /// connection.
  Future<void> release() => _exclusive(_dul.release);

  /// Aborts the association (A-ABORT) and closes the connection.
  Future<void> abort() => _dul.abort();

  /// Runs [operation] alone: one DIMSE operation at a time, since no
  /// asynchronous operations window is negotiated.
  Future<T> _exclusive<T>(Future<T> Function() operation) async {
    _enter();
    try {
      return await operation();
    } finally {
      _busy = false;
    }
  }

  void _enter() {
    if (_busy) {
      throw StateError('another operation is still running on this '
          'association; await it (or cancel its stream) first');
    }
    _busy = true;
  }

  AcceptedContext _contextFor(Uid sopClass, String operation) =>
      acceptedContexts.where((c) => c.abstractSyntax == sopClass).firstOrNull ??
      (throw StateError('$operation needs an accepted presentation context '
          'for ${sopClass.value}, and the peer accepted none; propose it in '
          'ApplicationEntity.requestedContexts'));

  int _nextMessageId() =>
      _lastMessageId = _lastMessageId == 0xFFFF ? 1 : _lastMessageId + 1;

  Future<void> _send(DimseMessage message) async {
    for (final pdu in fragment(message, _peerMaxPduLength)) {
      await _dul.send(pdu);
    }
  }

  /// The next whole DIMSE message from the peer.
  Future<DimseMessage> _receive() async {
    while (_received.isEmpty) {
      final pdu = await _dul.receive();
      if (pdu is! PDataTf) {
        await _protocolAbort('unexpected $pdu during an operation');
      }
      final List<DimseMessage> messages;
      try {
        messages = _assembler.feed(pdu);
      } on DimseProtocolException {
        await _dul.abort();
        rethrow;
      }
      _received.addAll(messages);
    }
    return _received.removeFirst();
  }

  /// The next message, which must be a [field] response to request [id].
  Future<DimseMessage> _responseTo(int id, int field) async {
    final message = await _receive();
    if (message.commandField != field ||
        message.messageIdBeingRespondedTo != id) {
      await _protocolAbort('expected the response to message $id, but got '
          '$message responding to ${message.messageIdBeingRespondedTo}');
    }
    return message;
  }

  Future<Never> _protocolAbort(String problem) async {
    await _dul.abort();
    throw DimseProtocolException(problem);
  }

  @override
  String toString() => 'Association($calledAeTitle, '
      '${acceptedContexts.length} accepted contexts)';
}
