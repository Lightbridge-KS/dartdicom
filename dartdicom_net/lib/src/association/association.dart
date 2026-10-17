import 'dart:async';

import 'package:dartdicom/dartdicom.dart';

import '../acse/negotiation.dart';
import '../dimse/channel.dart';
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
      int peerMaxPduLength)
      : _channel = DimseChannel(_dul, peerMaxPduLength);

  /// Requests an association over [transport] with [rq].
  static Future<Association> request(
      Transport transport, AssociateRq rq, ApplicationEntity ae) async {
    final dul = Dul.requestor(transport, timeouts: ae.timeouts);
    final ac = await dul.requestAssociation(rq);
    return Association._(dul, rq.calledAeTitle, negotiatedContexts(rq, ac),
        ac.userInformation.maxLength);
  }

  final Dul _dul;
  final DimseChannel _channel;
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
        await _channel.send(DimseMessage(
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
          {QueryRetrieveModel model = QueryRetrieveModel.studyRoot}) =>
      _operation('C-FIND', model.find, CommandField.cFindRq, query,
          (message, id, context) async {
        final rsp = await _expect(message, id, CommandField.cFindRsp);
        return switch (DimseStatus(rsp.status ?? 0xC000)) {
          DimsePending() => (
              item: switch (rsp.dataset) {
                final identifier? => Dataset.fromBytes(identifier,
                    transferSyntax: context.transferSyntax),
                null => null,
              },
              last: false,
              failure: null,
            ),
          final DimseFailure failure => (
              item: null,
              last: true,
              failure: failure
            ),
          _ => (item: null, last: true, failure: null),
        };
      });

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
          {QueryRetrieveModel model = QueryRetrieveModel.studyRoot}) =>
      _operation('C-GET', model.get, CommandField.cGetRq, query,
          (message, id, context) async {
        if (message.commandField == CommandField.cStoreRq) {
          await _store(message, sink);
          return (item: null, last: false, failure: null);
        }
        if (message.commandField != CommandField.cGetRsp ||
            message.messageIdBeingRespondedTo != id) {
          await _channel.protocolAbort('expected a C-GET response or a C-STORE '
              'sub-operation, but got $message');
        }
        final progress = RetrieveProgress.fromResponse(message);
        return (
          item: progress,
          last: progress.isFinal,
          failure: switch (progress.status) {
            final DimseFailure failure => failure,
            _ => null,
          },
        );
      });

  /// Runs one multi-response operation alone on the association: sends the
  /// [command] request with [query] on the context accepted for [sopClass],
  /// then hands each message that arrives to [step] until one is the last.
  ///
  /// The stream emits each step's item. After the last, a failure is a
  /// [DimseFailureException] stream error (surface S5). Ending any other way
  /// (a cancelled subscription, an error) aborts the association.
  Stream<T> _operation<T>(
      String name,
      Uid sopClass,
      int command,
      Dataset query,
      Future<_Step<T>> Function(
              DimseMessage message, int id, AcceptedContext context)
          step) async* {
    final context = _contextFor(sopClass, name);
    _enter();
    var finished = false;
    try {
      final id = _nextMessageId();
      await _channel.send(DimseMessage(
          context.id,
          requestCommand(command, id, sopClass,
              hasDataset: true, priority: mediumPriority),
          query.toBytes(transferSyntax: context.transferSyntax)));
      while (true) {
        final (:item, :last, :failure) =
            await step(await _channel.receive(), id, context);
        // Marked before the last item is yielded, so cancelling on that item
        // doesn't abort an operation that is already complete.
        if (last) finished = true;
        if (item != null) yield item;
        if (!last) continue;
        if (failure != null) throw DimseFailureException(failure);
        return;
      }
    } finally {
      _exit();
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
    await _channel.send(DimseMessage(rq.contextId, rsp));
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
      _exit();
    }
  }

  void _enter() {
    if (_busy) {
      throw StateError('another operation is still running on this '
          'association; await it (or cancel its stream) first');
    }
    _busy = true;
    _dul.busy = true; // the network timer pauses while it runs
  }

  void _exit() {
    _busy = false;
    _dul.busy = false;
  }

  AcceptedContext _contextFor(Uid sopClass, String operation) =>
      acceptedContexts.where((c) => c.abstractSyntax == sopClass).firstOrNull ??
      (throw StateError('$operation needs an accepted presentation context '
          'for ${sopClass.value}, and the peer accepted none; propose it in '
          'ApplicationEntity.requestedContexts'));

  int _nextMessageId() =>
      _lastMessageId = _lastMessageId == 0xFFFF ? 1 : _lastMessageId + 1;

  /// The next message, which must be a [field] response to request [id].
  Future<DimseMessage> _responseTo(int id, int field) async =>
      _expect(await _channel.receive(), id, field);

  /// [message], which must be a [field] response to request [id]: anything
  /// else aborts the association.
  Future<DimseMessage> _expect(DimseMessage message, int id, int field) async {
    if (message.commandField != field ||
        message.messageIdBeingRespondedTo != id) {
      await _channel
          .protocolAbort('expected the response to message $id, but got '
              '$message responding to ${message.messageIdBeingRespondedTo}');
    }
    return message;
  }

  @override
  String toString() => 'Association($calledAeTitle, '
      '${acceptedContexts.length} accepted contexts)';
}

/// What one message of a multi-response operation produced: an item to
/// emit (or none), whether it was the operation's last, and for the last
/// a failure to end the stream with.
typedef _Step<T> = ({T? item, bool last, DimseFailure? failure});
