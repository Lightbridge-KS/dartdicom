import '../pdu/pdus.dart';
import '../trace/observations.dart';

/// Projects PDUs into payload-free observations for one DUL. Owns only the
/// proposal snapshot; transport, protocol state and emission timing stay in Dul.
final class PduObservations {
  PduObservations(this._recorder);

  final ObservationRecorder? _recorder;
  List<ContextObservation> _proposed = const [];

  /// Captures the proposal at the same point as the association request.
  void rememberProposals(AssociateRq rq) {
    _proposed = [
      for (final c in rq.contexts)
        ContextObservation(
            id: c.id,
            abstractSyntax: c.abstractSyntax,
            proposedTransferSyntaxes: c.transferSyntaxes)
    ];
  }

  void record(Pdu? pdu, ObservationDirection direction) {
    final kind = switch (pdu) {
      AssociateRq() => ObservationKind.associateRequest,
      AssociateAc() => ObservationKind.associateAccept,
      AssociateRj() => ObservationKind.associateReject,
      ReleaseRq() => ObservationKind.releaseRequest,
      ReleaseRp() => ObservationKind.releaseResponse,
      Abort() => ObservationKind.abort,
      PDataTf() => ObservationKind.data,
      null => ObservationKind.transportClosed,
    };
    _recorder?.emit(kind,
        direction: direction,
        contexts: pdu is AssociateAc
            ? [
                for (final c in _proposed)
                  ContextObservation(
                      id: c.id,
                      scuRole: pdu.userInformation.roles
                          .where((r) => r.sopClass == c.abstractSyntax)
                          .firstOrNull
                          ?.scu,
                      scpRole: pdu.userInformation.roles
                          .where((r) => r.sopClass == c.abstractSyntax)
                          .firstOrNull
                          ?.scp,
                      abstractSyntax: c.abstractSyntax,
                      proposedTransferSyntaxes: c.proposedTransferSyntaxes,
                      result: pdu.results
                          .where((x) => x.id == c.id)
                          .firstOrNull
                          ?.result,
                      selectedTransferSyntax: pdu.results
                          .where((x) => x.id == c.id && x.result == 0)
                          .firstOrNull
                          ?.transferSyntax),
                for (final result in pdu.results
                    .where((r) => !_proposed.any((c) => c.id == r.id)))
                  ContextObservation(
                      id: result.id,
                      abstractSyntax: '',
                      proposedTransferSyntaxes: const [],
                      result: result.result,
                      selectedTransferSyntax:
                          result.result == 0 ? result.transferSyntax : null),
              ]
            : pdu is AssociateRq
                ? _proposed
                : const [],
        result: pdu is AssociateRj ? pdu.result : null,
        source: pdu is AssociateRj
            ? pdu.source
            : pdu is Abort
                ? pdu.source
                : null,
        reason: pdu is AssociateRj
            ? pdu.reason
            : pdu is Abort
                ? pdu.reason
                : null,
        peerImplementationClassUid: pdu is AssociateAc &&
                RegExp(r'^[0-9]+(?:\.[0-9]+)+$')
                    .hasMatch(pdu.userInformation.implementationClassUid) &&
                pdu.userInformation.implementationClassUid.length <= 64
            ? pdu.userInformation.implementationClassUid
            : null,
        maxInvoked: pdu is AssociateAc
            ? pdu.userInformation.asyncWindow?.invoked
            : null,
        maxPerformed: pdu is AssociateAc
            ? pdu.userInformation.asyncWindow?.performed
            : null,
        peerMaxPduLength: pdu is AssociateAc && pdu.userInformation.hasMaxLength
            ? pdu.userInformation.maxLength
            : null);
  }
}
