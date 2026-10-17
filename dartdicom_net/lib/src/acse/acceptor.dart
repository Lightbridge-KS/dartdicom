import 'package:dartdicom/dartdicom.dart';

import '../pdu/items.dart';
import '../pdu/pdus.dart';
import 'negotiation.dart';

// ACSE for an acceptor that serves storage (PS3.8 §7.1, PS3.7 Annex D),
// following pynetdicom's rules: what to answer an A-ASSOCIATE-RQ.

/// The acceptor's transfer syntaxes, most preferred first: uncompressed,
/// then every other syntax the core knows. Instances are stored as
/// received, so a compressed one is kept as it came (M3 decision 4).
List<Uid> get acceptorSyntaxes => [
      TransferSyntaxes.explicitVrLittleEndian,
      TransferSyntaxes.implicitVrLittleEndian,
      for (final ts in TransferSyntaxes.all)
        if (ts != TransferSyntaxes.explicitVrLittleEndian &&
            ts != TransferSyntaxes.implicitVrLittleEndian)
          ts,
    ];

/// Why an association is rejected before its contexts are looked at.
enum Refusal {
  /// The called AE title isn't this AE's: (1, 1, 7).
  calledAeTitle(1, 1, 7),

  /// The calling AE title, or its host, isn't allowed: (1, 1, 3).
  callingAeTitle(1, 1, 3),

  /// Too many associations at once: (2, 3, 2), transient.
  tooMany(2, 3, 2);

  const Refusal(this.result, this.source, this.reason);

  final int result;
  final int source;
  final int reason;

  AssociateRj get rj =>
      AssociateRj(result: result, source: source, reason: reason);
}

/// The answer to [rq] when it is acceptable: an A-ASSOCIATE-AC accepting
/// Verification and every storage SOP class with the first of
/// [acceptorSyntaxes] the requestor proposed, and the contexts it accepted
/// (this side as SCP). Other contexts are rejected: 0x03 for an abstract
/// syntax not served, 0x04 when no proposed syntax is acceptable. No role
/// replies are sent (pynetdicom's storescp does the same), so the default
/// roles hold: the requestor SCU, this side SCP.
(AssociateAc, List<AcceptedContext>) acceptStorage(AssociateRq rq,
    {required int maxPduLength}) {
  final storage = {for (final c in SopClasses.storage) c.value};
  final preference = acceptorSyntaxes;
  final results = <ContextResult>[];
  final accepted = <AcceptedContext>[];
  for (final c in rq.contexts) {
    final served = c.abstractSyntax == SopClasses.verification.value ||
        storage.contains(c.abstractSyntax);
    final ts = served
        ? preference
            .where((ts) => c.transferSyntaxes.contains(ts.value))
            .firstOrNull
        : null;
    // A rejected context carries the requestor's first syntax, as
    // pynetdicom answers it.
    final fallback = c.transferSyntaxes.firstOrNull ?? '';
    results.add(ContextResult(
        c.id, ts != null ? 0 : (served ? 4 : 3), ts?.value ?? fallback));
    if (ts != null) {
      accepted.add(AcceptedContext(c.id, Uid(c.abstractSyntax), ts,
          scuRole: false, scpRole: true));
    }
  }
  final ac = AssociateAc(
    calledAeTitle: rq.calledAeTitle,
    callingAeTitle: rq.callingAeTitle,
    results: results,
    userInformation: UserInformation(
      maxLength: maxPduLength,
      implementationClassUid: dartdicomImplementationClassUid.value,
      implementationVersionName: dartdicomImplementationVersionName,
      asyncWindow: rq.userInformation.asyncWindow == null
          ? null
          : const AsyncOperationsWindow(invoked: 1, performed: 1),
    ),
  );
  return (ac, List.unmodifiable(accepted));
}
