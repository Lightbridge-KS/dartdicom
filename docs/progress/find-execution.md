---
summary: Additive Find execution handle, review corrections and local PR verification against the dev.2 baseline.
read_when:
  - reviewing the owned Find lifecycle or its PR verification
  - preparing a later release and consumer dependency migration
---

# Find execution

Parent: [overview](overview-v0.md). Contract: [Find execution](../api/find-execution.md).

## Scope and state

The 2026-11-04 candidate is based on `53ee5ec` (`v0.1.0-dev.2`). It adds
`startCFind`, retained terminal evidence, response-context correlation, an opt-in
Identifier reassembly limit and character-set support reporting. It shares the
legacy multi-response engine and retains `sendCFind` defaults. No package version,
release tag or publication change is included.

Delivery is scoped to a draft PR. Merge, release publication, downstream pins and
clean-clone application acceptance remain separate work. The PR owns the final
commit, reproducibility-review disposition and hosted check receipts.

## Review corrections

- [x] Make explicit cancellation independent of a paused match listener's close
  notification. Network drain and presentation delivery have separate lifetimes.
- [x] Retain Identifier parse errors as typed protocol failures, including the
  preceding validated pending count and optional-key warning.
- [x] Reject missing Status in the owned Find handle instead of inventing a final
  status; retain the legacy stream's existing fallback.
- [x] Cover command/message/context correlation, success racing cancellation,
  exact Identifier limits, limit reset before a legacy Find, and invalid limits.
- [x] Add browser-capable character-set declaration tests and preserve permissive
  fallback decoding. Reconcile the surface/structure docs with the additive handle.

The first three regression tests fail before the review corrections and pass
afterward. Each match owns decoded data received by the operation, but broadcast
listeners share that same mutable Dataset. Applications must coordinate access
and bound their own retained rows or paused-listener buffers.

## Local verification

Evidence date: **2026-11-04**. The following checks ran on the candidate source
before commit; they are not hosted CI or release/publication acceptance.

| Check | Result |
|---|---|
| Association/trace suite | 103 tests passed |
| `just dry chrome`, Dart 3.13.5 | Format, analysis, dependency boundaries, VM/Chrome, Wasm, fixtures and written-file checks passed; dirty core/net publication dry-runs skipped, unchanged pixel/web members passed |
| Actual Dart 3.6.0 floor replay | Dependency resolution, analysis and all workspace VM tests passed in an isolated source snapshot: core 404, pixel 194, network 249; live tests skipped |
| `just live` with the repository test PACS | All 20 Orthanc/DCMTK/pynetdicom interop tests passed, including owned Find terminal evidence and association reuse; both C-GET/C-MOVE retrieval/render examples passed |
| `just hooks` and diff hygiene | All-file hooks and `git diff --check` passed; staged hooks also run before the reproducibility-review candidate is captured |

Run package tests from their package directory; fixture paths are relative there.
Use the root task runner for the dry/live suites. Live checks require the test
PACS from `just pacs-up` and the tools documented by the existing interop scripts;
stop a PACS started for the checks with `just pacs-down`. The SDK version was
verified explicitly for the isolated floor replay rather than inferred from a
wrapper's label.

The earlier consumer loopback evidence uses paired local overrides and remains
provisional downstream evidence. It is not a dependency of upstream package
checks, a qualification of an external PACS bundle, or desktop acceptance.
Published dev.2 does not contain these additive APIs.

## Follow-up lifecycle review (2026-11-04)

The follow-up is based on `6ac4be5`. Four new regressions reproduce two defects:
an owned Find can remain pending behind a stalled request write after explicit
cancellation, and whole-PDU assembly can discard a preceding complete match when
a later message fails. Both are corrected. A fifth test preserves legacy Find
behavior when several valid messages share one PDU.

- [x] Bound the owned Find's wait for a request write at its explicit cancellation
  deadline. Consume late write errors and retain an earlier association failure.
  Fail later sends on the ended association promptly with that same cause.
- [x] Consume incoming messages in PDV order, preserving completed match evidence
  before a later malformed/oversized message. Drop queued PDVs on assembly failure.
- [x] Rerun the focused association/trace suite: 108 tests passed.
- [x] Rerun the full Dart 3.13.5 dry/Chrome/Wasm/fixture/written-file gates and
  hooks. Actual Dart 3.6.0 resolution, analysis and workspace VM tests passed in
  an isolated snapshot: core 404, pixel 194, network 254.
- [x] Rerun all 20 live interop cases and both retrieval/render examples. Stop
  the repository test PACS started for this verification.

Public method signatures and result fields are unchanged. No application UI or
call-site migration is required for these corrections. Clients must still await
association cleanup separately from operation completion and must not infer peer
cancellation confirmation from a completed cancellation future. Downstream
verification remains separately owned; the upstream PR records final hosted
checks and the required reproducibility-review receipt.

## Remaining delivery boundaries

- Draft-PR review and merge acceptance.
- A separately authorized package version/release and consumer Git-pin migration.
- Downstream clean-clone and outstanding desktop acceptance checks.
