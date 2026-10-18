# Changelog

## 0.1.0-dev.1 (unreleased)

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
