import 'package:dartdicom/dartdicom.dart';

import '../acse/negotiation.dart';
import '../timeouts.dart';
import '../trace/trace.dart';
import '../pdu/pdus.dart';
import '../transport/socket_transport.dart';
import '../transport/transport.dart';
import 'association.dart';
import 'presentation_contexts.dart';

/// This application's DICOM identity and what it proposes when it
/// associates: an immutable value built in one call (surface S2).
///
/// ```dart
/// const ae = ApplicationEntity(
///     aeTitle: 'MYAPP', requestedContexts: PresentationContexts.verification);
/// final assoc = await ae.associate('pacs.local', 104, aeTitle: 'PACS');
/// ```
final class ApplicationEntity {
  const ApplicationEntity({
    required this.aeTitle,
    this.requestedContexts = const [],
    this.retrieveStorageClasses = const [],
    this.maxPduLength = 16384,
    this.timeouts = const Timeouts(),
    this.trace,
  });

  /// This AE's title (the calling AE title): 1–16 characters.
  final String aeTitle;

  /// The presentation contexts to propose.
  final List<PresentationContext> requestedContexts;

  /// Storage SOP classes this AE will accept from a C-GET: each gets a
  /// storage context and an SCP role selection item (PS3.4 §C.4.3.3).
  final List<Uid> retrieveStorageClasses;

  /// The largest P-DATA-TF this AE receives, in bytes (0 = no limit).
  final int maxPduLength;

  /// How long each step may wait (PRD N-13); pynetdicom's defaults.
  final Timeouts timeouts;

  /// Where the protocol is traced, if anywhere (PRD N-14). It shows no
  /// element value unless [Trace.showValues] is set.
  final Trace? trace;

  /// Connects to [host]:[port] and associates with the AE titled [aeTitle].
  ///
  /// Throws [AssociationRejected] if the peer rejects the association, a
  /// [DimseTimeout] if it doesn't connect or answer in time ([timeouts]),
  /// and a `SocketException` if it refuses or can't be reached.
  Future<Association> associate(String host, int port,
      {required String aeTitle}) async {
    final rq = associateRqFor(this, aeTitle);
    final transport =
        await SocketTransport.connect(host, port, timeout: timeouts.connect);
    return Association.request(transport, rq, this);
  }

  /// Associates over an already connected [transport] (e.g. an
  /// `InMemoryTransport` in a test) with the AE titled [aeTitle].
  Future<Association> associateOver(Transport transport,
          {required String aeTitle}) =>
      Association.request(transport, associateRqFor(this, aeTitle), this);
}

/// The A-ASSOCIATE-RQ [ae] sends to [calledAeTitle]: its requested
/// contexts, then a storage context with an SCP role item per retrieve
/// storage class.
AssociateRq associateRqFor(ApplicationEntity ae, String calledAeTitle) =>
    buildAssociateRq(
      callingAeTitle: ae.aeTitle,
      calledAeTitle: calledAeTitle,
      contexts: [
        for (final c in ae.requestedContexts)
          (c.abstractSyntax, c.transferSyntaxes),
        for (final sopClass in ae.retrieveStorageClasses)
          (sopClass, PresentationContext.uncompressed),
      ],
      scpRoleClasses: ae.retrieveStorageClasses,
      maxPduLength: ae.maxPduLength,
    );
