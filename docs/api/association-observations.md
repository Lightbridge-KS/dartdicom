---
summary: Payload-free typed association diagnostics, establishment cancellation and bounded socket cleanup.
read_when:
  - integrating diagnostic applications with dartdicom_net
  - implementing observers or application shutdown
---

# Association diagnostics and cancellation

`ApplicationEntity.observer` optionally accepts an `AssociationObserver`. Existing
Trace and networking APIs/default timeouts are retained. Observations contain a
caller-supplied association ID, strictly increasing sequence, monotonic elapsed
time, direction and typed transport/UL/DIMSE facts. `associate` and `associateOver`
accept optional `associationId` and `AssociationCancellation` parameters.

Observers run synchronously and must remain fast. Exceptions from `record` are
isolated from networking. Observations expose immutable context lists and scalar
fields; no Dataset, payload bytes, AE titles, hostnames, peer comments or arbitrary
exception text is passed. Implementation version text and unknown user-information
sub-item bytes are deliberately omitted. Peer maximum PDU, implementation-class
UID, asynchronous window and explicit role selections are available when observed.
Unobserved parameters remain null; absent role negotiation is not an explicit
peer role response. An absent Max Length sub-item remains null in observations;
an explicitly supplied zero means unlimited. The existing networking fallback
for an absent Max Length remains zero. *(amended)*

Negotiation includes all proposed contexts, numeric acceptance/rejection results
and returned transfer syntax. Command observations include command field, context,
message/response IDs and status when present. Rejection and abort fields remain
numeric; `AssociationAborted.source/reason` are null for local or transport causes.
`describeAssociationRejection` provides the library's standard interpretation.
Typed timeout observations identify the expired timer. An outgoing observation
means submitted to local transport, never proof of peer receipt. Connection
elapsed time includes lookup; no independent DNS timing is claimed.
An outgoing DIMSE observation is emitted when its first PDU is submitted, even
if the transport's completion is still pending; it does not claim submission of
all fragments. Failed encoding/fragmentation, a synchronous transport rejection,
or cancellation before submission emits no outgoing fact. Malformed incoming
PDUs do not imply transport closure. *(amended)*

Cancel the token before or during establishment to stop an attempt. A task that
completes after cancellation is still consumed and any socket destroyed. A token
also aborts its established association. Cancellation intent does not supersede an
already observed response, and C-ECHO has no C-CANCEL operation. Consumers should
retain these facts independently.

`Association.closed` completes successfully after confirmed transport/subscription
cleanup, independently of a protocol result. It fails with a payload-free
`AssociationAborted` if close or subscription cancellation fails or exceeds its
one-second bound and cleanup cannot be confirmed. A successful forced teardown
can confirm transport closure after a graceful-close failure; subscription
cancellation must still finish successfully. Cleanup failure does not replace an
already observed DIMSE status, graceful-release result or establishment failure.
The local `transportClosed` observation is emitted only after confirmed cleanup;
an incoming `transportClosed` observation records actual transport EOF separately.
Late cleanup completions and errors are consumed without changing the recorded
cleanup result. Repeated teardown shares that same result. *(amended)*

`forceClose()` tears down an owned socket immediately for a bounded shutdown;
it does not promise graceful release. Abort sending and local close each have
bounded waits before forced socket teardown. Caller-supplied transports should
implement `AbortableTransport` when they own forcible resources. Callers awaiting
`closed`, including after `forceClose()`, must handle cleanup failure separately
from the protocol result.

Verification: `dartdicom_net/test/trace/observations_test.dart` covers callback
failure isolation, immutable/ordered evidence, numeric rejection/abort data,
rejected contexts, missing peer parameters and establishment/socket cancellation.
`observation_regressions_test.dart` additionally covers bounded cleanup failures
and late errors, protocol-result preservation, actual submission timing, malformed
input versus EOF, and absent versus explicitly unlimited Max Length.
The app consumer must additionally test stop/response races and persistent evidence
policy; the networking package does not own application history.
