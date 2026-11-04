---
summary: Additive C-FIND execution handle, independently retained terminal evidence, cancellation and opt-in response Identifier limit.
read_when:
  - consuming streamed Find results with reliable terminal diagnostics
  - reviewing cancellation, correlation or incoming Identifier limits
---

# Find execution and terminal evidence

`Association.startCFind(identifier, model: ..., maxIdentifierBytes: ...)` adds a
`FindOperation` without changing `sendCFind` defaults. Both use the association's
existing multi-response engine. Attach `matches` immediately; it is a broadcast
notification stream with no replay. Each `FindMatch` contains the owned decoded
Dataset, validated pending status and encoded Identifier byte count. Dataset
values never enter the association observation sink.
Multiple listeners receive the same match and mutable Dataset; the stream does
not make a private Dataset copy for each listener.

`done` completes independently of match-listener lifetime. `FindCompletion`
retains the correlated final status, typed failure, cancellation intent,
validated pending-response count and optional-key warning. A final status can
coexist with a later failure; consumers must preserve both. Presentation stream
cancellation does not cancel the operation. Pausing a match listener does not
pause network consumption and can buffer that listener's events: consume promptly
and impose application retention limits.
`FindCompletion.failure` describes execution errors; a correlated final DIMSE
failure is represented by `status` instead. Local API/configuration errors, such
as starting another operation while busy or lacking a presentation context, can
complete `done` with an error rather than a `FindCompletion`.

Call `FindOperation.cancel()` to request C-CANCEL. It shares the existing bounded
cancel-and-drain engine. Inspect `done`, not the cancellation future, for peer
confirmation (`DimseCancel`, 0xFE00). A racing final success remains success;
ignored cancellation ends with timeout/abort evidence. Before establishment,
use `AssociationCancellation` on `ApplicationEntity.associate`. Operation
completion is not association cleanup: release or abort and await `closed`.
The cancellation future waits for network drain, not a paused match listener's
close notification.
The same cancellation deadline also ends an owned Find that is waiting for a
request write to finish. A late write error is consumed; an already recorded
association failure takes precedence over a new timeout. Association cleanup
still requires its separate `closed` result. Later sends on the failed
association fail with its recorded cause instead of waiting behind a stalled
write; retry requires a new association. *(amended, 2026-11-04)*

Command field, Message ID Being Responded To and presentation context must match
before a response becomes an operation status. Invalid correlation is a protocol
failure. Numeric association observations may still describe what arrived; they
do not assert that an invalid response belongs to the operation.
A missing Status is a protocol failure in `startCFind`; it does not invent a
terminal code. Invalid Identifier decoding is also retained as a typed protocol
failure. The legacy stream's missing-Status fallback is unchanged.
Complete messages are consumed in PDV order. A later malformed or oversized
Identifier inside the same PDU does not erase an earlier validated match, pending
count or optional-key warning. *(amended, 2026-11-04)*

A positive `maxIdentifierBytes` limits accumulated response dataset fragments
before complete Identifier decoding. Exceeding it fails with
`DimseIdentifierTooLarge` and aborts the operation. The default is null (the prior
unbounded behavior); command/PDU limits remain separate. This is not a process
memory limit or a PACS-side workload limit.
`DimseIdentifierTooLarge` is a new member of the sealed `DimseException` family;
consumers with exhaustive exception switches must add a case for it.

The core `characterSetSupport(terms)` reports the decoder's supported declarations:
absent/default ASCII, ISO_IR 100 and ISO_IR 192. Code-extension or unrecognized
terms report unsupported. Existing permissive decoding is unchanged. Consumers
must label such text decode-limited instead of claiming a verified character
interpretation.

Verification: [Find lifecycle tests](../../dartdicom_net/test/association/find_operation_test.dart),
[character-set tests](../../dartdicom/test/charset/charset_support_test.dart) and
the existing network association/trace tests. The consumer's loopback tests are
separate downstream evidence; they are not a prerequisite for these package tests.
Run package tests from their package directory; relative fixture paths are part
of the existing test harness.
