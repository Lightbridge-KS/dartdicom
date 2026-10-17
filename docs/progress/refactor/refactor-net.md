---
summary: Net library refactor. One rule for a response's Status, _operation owns the response check, the trace owns its masking rules (F5), and the DUL's one-PDU read-ahead gets a name. F14, F42, F5, I-9, I-12, I-13 and I-30 hold, and so does every test.
read_when:
  - Planning or executing the dartdicom_net lib/src refactor; reviewing its evidence
  - Changing how Association reads responses, how the DUL hands PDUs over, or what the trace masks
status: complete
date: 2026-10-17
---
# Net library refactor

Parent: [overview](../overview-v0.md) · Design: [codebase blueprint](../../structure/01-codebase-blueprint.md) F5, F14, F42, §8

Behaviour-preserving moves in `dartdicom_net/lib/src` after M3. Cards #3 (`_operation` as a method object), #6 (`serveStorage` builds its own channel) and #7 (one AE-title check, a behaviour question) were not picked.

- [x] **#1 + #2.** `DimseMessage.outcome` holds the rule that a response without Status is failure 0xC000. `CommandField.responseOf` and `isRequest` replace the bit arithmetic. `_operation` checks each response against the request and applies the final-status rule once. find, get and move each pass an `emit` function (get and move also an `onStore`), and the `_Step` record goes. `refusedStore` replaces the throwaway `MemorySink` a C-MOVE used to refuse a store. One wording changes: an unexpected message during a get or move aborts with `_expect`'s message (no test asserts it, and it holds no values).
- [x] **#4.** An internal extension in `trace/` records PDU events: the level check and the P-DATA hex rule (F5) move out of `dul.dart`, and `StorageScp` uses the same call.
- [x] **#5.** `dul/read_ahead.dart` holds the one-PDU hand-off between the reader and `receive` (F42). In place: the release-collision next state is computed once, `_startTimer` loses its always-ACSE parameter, `_transmit` and `_sendAbort` share one write, and the PS3.8 transition names move to `fsm/table.dart`.

Preserve: F14 (cancel completes normally; cancelling on the last item cancels nothing; the drain is bounded by one DIMSE timeout; a cancelled C-GET still stores what is in flight). S5 (a final Failure is a stream error after the last item). F42 (one read pending; a recorded cause, never a `StateError` afterwards; an idle peer release answered with A-RELEASE-RP). F5 and I-9 (trace output line for line). I-13 (247 cells), I-12, I-30. The timers: ARTIM in Sta2 and Sta13, the network timer only while idle in Sta6. Error categories, with `DimseProtocolException` after an abort.

Proof: the same net test names pass before and after (153 at 91ac8cf, `live` excluded), `just dry`, `just floor`, `just fuzz`, and `just live` for #2 and #5.

## Evidence

- **#1 + #2.** The same 153 net test names pass, plus one new one: a C-STORE-RQ on a C-MOVE's own association is refused with 0x0122. No test covered that path; the new test passes on the code before and after the move, and fails when the refusal is removed. Removing the final-Failure stream error fails the find, get and move tests. `just dry`, `just floor`, `just fuzz` (100,000 cases per group; the core's counts are unchanged, and net's four groups pass) and `just live` (19 tests against Orthanc, DCMTK and pynetdicom, plus `retrieve_and_render --via=get` and `--via=move`) all pass. Landed in 424f140.

- **#4.** The same 154 net test names pass. Showing P-DATA bytes without `showValues` fails the trace and PHI canary tests, and dropping the level check fails the trace tests. The blueprint's "Change PHI masking" row now names `trace/record.dart` too. `just dry` and `just floor` pass. Landed in de7fb46.
- **#5.** All 160 net tests pass: the 153 from before this refactor, the move test above, and six new read-ahead tests. Two F42 behaviours had no test: the next PDU is read only once the last is taken, and an abort drops a PDU not yet taken. `dul_test` gains both; they pass on the code before and after the move. Making `vacated` return at once, or keeping the PDU after an abort, now fails them. `read_ahead_test` covers the hand-off itself. Dropping the AR-8 role rule fails the release-collision test. `just dry`, `just floor`, the net half of `just fuzz` at 100,000 cases (the core is untouched since the #1 + #2 run) and `just live` pass. The live run's 16 minutes, against 35 s before, was the machine sleeping during the idle test's 35 s wait (two sleeps of about 15.5 minutes in the power log), not the code.

On completion: set `status: complete`, then ask whether to prune this tracker.
