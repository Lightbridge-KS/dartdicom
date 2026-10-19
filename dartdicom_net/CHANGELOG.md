# Changelog

## [Unreleased]

## [0.1.0-dev.2] - 2026-10-19

GitHub-only prerelease; not published on pub.dev.

### Added

- Optional `AssociationObserver` with immutable, ordered, payload-free transport,
  association and DIMSE observations, a caller-supplied association ID and
  monotonic elapsed time. Negotiation observations retain rejected contexts,
  explicit peer parameters and numeric rejection/abort facts.
- `AssociationCancellation` before and during establishment, including late socket
  cleanup and cancellation of the established association.
- `AbortableTransport`, `Association.forceClose()` and `Association.closed` for
  bounded teardown. `closed` reports unconfirmed cleanup separately from protocol
  outcomes; callers must handle its possible `AssociationAborted` error.
- Numeric `AssociationAborted.source` and `reason`, `locallyCancelled`, and public
  `describeAssociationRejection` interpretation.

### Fixed

- Bound every abort send, including reader-detected protocol violations, so
  stalled writes cannot prevent subsequent cleanup. Consume late send errors.
- Emit outgoing typed observations only after transport submission; a DIMSE
  observation records its first submitted PDU, not receipt or all fragments.
- Distinguish malformed input from transport EOF, and omitted peer Max Length
  from an explicit zero (unlimited), preserving the existing networking fallback.
- Require exactly four body bytes for rejection, release and abort PDUs after
  validating the envelope length.
- Reject negotiation-item decoders that consume beyond their declared body,
  including short maximum-length, asynchronous-window and role-selection items.

### Changed

- Separate DUL observation projection, PDV codecs, sealed PDU families and
  negotiation-item codecs behind compatible exports. Preserve type and
  constructor identity, wire order, data ownership and existing trace defaults.

## [0.1.0-dev.1] - 2026-10-18

First pre-release, from GitHub as tag `v0.1.0-dev.1` (see the repository README, *Use from GitHub*); not on pub.dev yet.

- **`ApplicationEntity` and `associate`:**
  - requested contexts from `PresentationContexts` (`verification`, `studyRootQueryRetrieve`, `patientRootQueryRetrieve`, `storage(…)`, `commonStorage`);
  - `retrieveStorageClasses` for C-GET;
  - `Timeouts`: connect, ACSE, DIMSE and network, as pynetdicom sets them.
- **SCU operations on an `Association`:**
  - `sendCEcho` and `sendCStore`, which return a `DimseStatus`;
  - `sendCFind`, a `Stream<Dataset>` of matches;
  - `sendCGet` and `sendCMove`, each a `Stream<RetrieveProgress>`.

  Cancelling a find or retrieve subscription sends C-CANCEL; `release()` and `abort()` end the association.
- **`StorageScp`:** the embedded Storage SCP that C-MOVE stores into. It accepts only the configured `ScpPeer`s: an AE title, and optionally a host.
- **Received instances:** each goes to an `InstanceSink` (`DirectorySink` or `MemorySink`) as a `ReceivedInstance`, with the transfer syntax negotiated for it.
- **`Trace`:** a protocol trace at DIMSE, PDU or hex level, with no values unless `showValues` is set.
- **Errors:** a sealed `DimseException` (`AssociationRejected`, `AssociationAborted`, `DimseProtocolException`, `DimseTimeout`, `DimseFailureException`) under core's `DicomException`.
- PDUs and command sets are byte-identical to pynetdicom 3.0.4's, and the PS3.8 state table is complete.
- Interoperability is tested against Orthanc, DCMTK and pynetdicom.
