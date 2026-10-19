import 'dart:math';
import '../timeouts.dart';

/// Structured, payload-free facts. Sending means submitted to the transport,
/// never proof that a peer received the message.
enum ObservationKind {
  connecting,
  connected,
  associateRequest,
  associateAccept,
  associateReject,
  data,
  releaseRequest,
  releaseResponse,
  abort,
  transportClosed,
  dimse,
  timeout,
}

enum ObservationDirection { local, outgoing, incoming }

/// A negotiation context, including rejected contexts and their numeric result.
final class ContextObservation {
  ContextObservation(
      {required this.id,
      required String abstractSyntax,
      required Iterable<String> proposedTransferSyntaxes,
      this.result,
      String? selectedTransferSyntax,
      this.scuRole,
      this.scpRole})
      : abstractSyntax = _protocolUid(abstractSyntax) ?? '',
        selectedTransferSyntax = _protocolUid(selectedTransferSyntax),
        proposedTransferSyntaxes = List.unmodifiable(
            proposedTransferSyntaxes.map(_protocolUid).whereType<String>());
  final bool? scuRole, scpRole;
  final int id;
  final String abstractSyntax;
  final List<String> proposedTransferSyntaxes;
  final int? result;
  final String? selectedTransferSyntax;
}

/// Immutable evidence; no AE titles, addresses, datasets or peer comments.
final class AssociationObservation {
  AssociationObservation(
      {required this.associationId,
      required this.sequence,
      required this.elapsed,
      required this.kind,
      required this.direction,
      Iterable<ContextObservation> contexts = const [],
      this.result,
      this.source,
      this.reason,
      this.commandField,
      this.messageId,
      this.responseTo,
      this.status,
      this.contextId,
      this.peerMaxPduLength,
      this.timeoutKind,
      this.peerImplementationClassUid,
      this.maxInvoked,
      this.maxPerformed})
      : contexts = List.unmodifiable(contexts);
  final String associationId;
  final TimeoutKind? timeoutKind;
  final String? peerImplementationClassUid;
  final int? maxInvoked, maxPerformed;
  final int sequence;
  final Duration elapsed;
  final ObservationKind kind;
  final ObservationDirection direction;
  final List<ContextObservation> contexts;
  final int? result,
      source,
      reason,
      commandField,
      messageId,
      responseTo,
      status,
      contextId,
      peerMaxPduLength;
}

abstract interface class AssociationObserver {
  void record(AssociationObservation observation);
}

/// Per-association recorder shared by transport, UL and DIMSE layers.
/// Internal orchestration type; consumers implement AssociationObserver.
final class ObservationRecorder {
  ObservationRecorder(this.observer, this.associationId);
  static String createId() {
    final random = Random.secure();
    return List.generate(
            4, (_) => random.nextInt(1 << 32).toRadixString(16).padLeft(8, '0'))
        .join();
  }

  final AssociationObserver? observer;
  final String associationId;
  final Stopwatch _clock = Stopwatch()..start();
  int _sequence = 0;
  void emit(ObservationKind kind,
      {ObservationDirection direction = ObservationDirection.local,
      Iterable<ContextObservation> contexts = const [],
      int? result,
      int? source,
      int? reason,
      int? commandField,
      int? messageId,
      int? responseTo,
      int? status,
      int? contextId,
      int? peerMaxPduLength,
      TimeoutKind? timeoutKind,
      String? peerImplementationClassUid,
      int? maxInvoked,
      int? maxPerformed}) {
    if (observer == null) return;
    final event = AssociationObservation(
        associationId: associationId,
        sequence: ++_sequence,
        elapsed: _clock.elapsed,
        kind: kind,
        direction: direction,
        contexts: contexts,
        result: result,
        source: source,
        reason: reason,
        commandField: commandField,
        messageId: messageId,
        responseTo: responseTo,
        status: status,
        contextId: contextId,
        peerMaxPduLength: peerMaxPduLength,
        timeoutKind: timeoutKind,
        peerImplementationClassUid: peerImplementationClassUid,
        maxInvoked: maxInvoked,
        maxPerformed: maxPerformed);
    try {
      observer!.record(event);
    } on Object {/* Observation cannot break I/O. */}
  }
}

String? _protocolUid(String? value) => value != null &&
        value.length <= 64 &&
        RegExp(r'^[0-9]+(?:\.[0-9]+)+$').hasMatch(value)
    ? value
    : null;
