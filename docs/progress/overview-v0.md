---
summary: Progress tracker for dartdicom 0.x, the path to the first consumer (a Flutter desktop tool that queries, retrieves and displays from a PACS). Holds milestones with exit criteria, Now/Next, deferred work, open questions, confirmed contracts and risks.
read_when:
  - starting a work session or choosing the next task
  - landing work (tick the box and add the commit SHA)
  - checking whether a requirement is scheduled, deferred, or blocked by an open question
---

# dartdicom 0.x: progress

Links: [requirements](../req/dartdicom-prd.md) · [system architecture](../design/01-system-architecture.md) · [data architecture](../design/02-data-architecture.md) · [surface architecture](../design/03-surface-architecture.md) · [codebase blueprint](../structure/01-codebase-blueprint.md)

**Now:** M3 `dartdicom_net` P0, planned 2026-10-17 in 11 steps (below); M4 follows. **M2 is done** (2026-10-17, `94d6759`…`c97b788`): every exit criterion met; CI's `corpus` job and the DCMTK install run for the first time on push. **M1 is done** (2026-10-17, `1569aad`…`165b8f6`): `retrieve_and_render` retrieves a series from Orthanc and renders a frame. **M0 is done** (2026-10-17, `285623d` · `424cfa2` · `bed879b`): all exit criteria met, CI green on both workflows.
**Next:** M5, 0.1.0 and the first consumer.

## Roadmap

```text
M0 Foundation ─▶ M1 Tracer bullet ─▶ M2 Core P0 ─┬─▶ M5 0.1.0 + first consumer ─▶ P1 work
                                     M3 Net P0  ─┤
                                     M4 Pixel P0 ┘
```

M1 builds the thinnest end-to-end slice through every package the first consumer needs. M2–M4 then fill out each package and can run in any order.

## Milestones

### M0 Foundation

- [x] `git init`; `.gitignore` (`_playground/`, `.dart_tool/`, `build/`, `pubspec.lock`, local agent files); MIT `LICENSE` (root and each package); root `README.md`; `AGENTS.md` (`285623d`)
- [x] Pin the dev Dart SDK to 3.13.5 with mise (`mise.toml`), with shims activated in the login shell profile and Dart-Code pointed at the install (`.vscode/settings.json`, local only). Done 2026-10-16 (`285623d`).
- [x] `.gitignore` includes `.vscode/settings.json` (it holds a home path) (`285623d`)
- [x] Root workspace `pubspec.yaml` with members listed explicitly; shared `analysis_options.yaml` (strict modes, `unawaited_futures`, `_playground/` excluded) (`285623d`)
- [x] Scaffold the four packages and `examples/` with `dart create -t package`; reworked to version `0.1.0-dev.1`, floor `^3.6.0`, `resolution: workspace`. Core seed: `Tag` (C-01) plus architecture tests (I-1, I-5, I-7, I-22, no `print`) (`285623d`)
- [x] Dictionary generator (`dartdicom/tool/gen_dictionary/`): DICOM **2026d** pinned by SHA-256 → committed `dictionary.g.dart` (5,355 entries), `tags.g.dart` (5,257 typed constants + 71 repeating-group functions), `uids.g.dart` (468 UIDs, `SopClasses.storage`). I-8 check in `generated.yml`; I-19 and I-26 tests. Cross-checked against pydicom 3.0.2 (DICOM 2024c): 176 newer entries, none missing, 4 field differences, all standard changes. Done 2026-10-17 (`bed879b`)
- [x] Fixture tooling (blueprint §3): `fixtures/` is a uv project with a typer CLI, `fixtures` (`build`, `golden`, `check`, `list`, `corpus fetch|where`, `pydicom-dictionary`). Data in `fixtures/data/`: 13 synthetic scenarios + 14 pydicom copies, all byte-reproducible; pydicom's golden reading of all 27; generated `PROVENANCE.md`. Corpora: pydicom-data @ `abc42b9` in the cache. Checked by ruff, pyright, pytest and `fixtures check` (I-28) through `scripts/check_fixtures.sh`, in the dry gates and CI. DCMTK reads all 13 synthetic files. Done 2026-10-17 (`bed879b`)
- [x] Dry-gate CI (`ci.yml`): a pinned job (mise) runs `scripts/dry_gates.sh` with Chrome, and a floor job (Dart 3.6.0) runs analyze and VM tests. Green on the first GitHub run (`285623d`): Chrome tests, Wasm, strict publish dry-run; floor on Dart 3.6.0 with lints 5.1.1
- [x] `.pre-commit-config.yaml` (pre-commit-hooks v6.0.0 hygiene set, `dart format`, gitleaks); `prek run --all-files` passes; the hook is installed with `prek install` (`285623d`)
- [x] Root `justfile` fronting `scripts/` (renamed from `tool/` 2026-10-17) (`dry`, `test`, `test-web`, `floor`, `hooks`, `pacs-up` / `pacs-echo` / `pacs-down`), plus `scripts/floor_check.sh`, which reads the floor SDK from `ci.yml`. Verified: `just deps`, `fmt-check`, `floor` (Dart 3.6.0) and the PACS recipes
- [x] `docker/compose.yaml`: stock Orthanc 26.9.1 (DICOMweb, find/get allowed, `DARTDICOM` registered as the C-MOVE destination). Default ports 14242 (DIMSE), 18042 (HTTP) and 14112 (C-MOVE destination), each overridable. Verified side by side with another local PACS on 4242/8042: REST, `/dicom-web/studies` 200, C-ECHO. DCMTK comes from the host or runner, not a container (`285623d`)

**Exit:** CI is green, the dictionary is generated from the pinned release, and `dart pub publish --dry-run` passes for every package.

### M1 Tracer bullet: "find, get, show one image"

Planned 2026-10-17. Each step ends with the dry gates green.

- [x] **0. Spike and docs** (`1569aad`).
  - The DCMTK `findscu` / `getscu` run against the compose Orthanc is done (see *Confirmed contracts*).
  - Docs amended: blueprint F38 (`file/`, `Dataset.fromBytes`, I-5 narrowed) and F39 (the sink parses the header), surface S7 and S8, data §4.2.
- [x] **1. Core model** (`17842f1`).
  - `errors.dart` (`DicomException` + the sealed `DicomDataException`); the `TransferSyntax` descriptor; the implementation identity; per-VR converters; charsets (default, `ISO_IR 100`, `ISO_IR 192`; F35 on encode).
  - `DataElement` keeps its raw span; `Dataset` (typed reads and writes, iteration, `transferSyntax`); `Sequence`.
- [x] **2. Core parse, write, façade** (`342463d`). `ByteSource` waits for `FileSource` in M2: a seam needs two implementations (blueprint §5).
  - A sync parser for Explicit and Implicit VR LE: defined and undefined lengths, nested SQ, encapsulated data kept raw, `stopBeforePixels`, ambiguous OB/OW and US/SS.
  - A passthrough writer; `file/` (`DicomFile`, `FileMetaInformation`, I-17); `io.dart` over whole-file bytes.
  - Tests: I-11 and I-10 on the LE fixtures.
- [x] **3. Pixel** (`5c2d543`). Bits Allocated 8 decodes too (the same path). The Wasm gate now also compiles `dartdicom_pixel`.
  - `ds.pixels.frame(i)` → `PixelArray`, with BitsStored masking; Modality LUT; linear VOI (PS3.3 C.11.2.1.2.1); MONOCHROME1; `ds.voiWindow()`; `DisplayBuffer` (`gray`, `toRgba()`).
  - Tests: sha256 against golden for the 16-bit monochrome fixtures.
- [x] **4. Net through C-ECHO** (`81b9de5`). The live echo passed on its first run. Transports (socket, in-memory), PDUs (with role selection), framing, the FSM (requestor rows), ACSE, `ApplicationEntity`, `associate` / `sendCEcho` / `release` / `abort`, and `DimseStatus`.
  - Tests: hand-checked PS3.8 vectors, a captured Orthanc A-ASSOCIATE-AC, and a live echo.
- [x] **5. DIMSE and C-FIND** (`b9446f8`). Live STUDY and SERIES finds passed on the first run. Command sets, the fragmenter, the assembler (every PDV of every P-DATA-TF), and message IDs. `sendCFind` → `Stream<Dataset>` (S5).
  - Tests: a scripted peer, and a live find at STUDY and SERIES level.
- [x] **6. C-GET and sinks** (`a436910`). `commonStorage` holds 36 classes. The live series get into a `DirectorySink` passed on its first run. `PresentationContexts.commonStorage` plus role items (≤ 128 contexts); `sendCGet` → `Stream<RetrieveProgress>`; `InstanceSink`, `ReceivedInstance`, `MemorySink`, `DirectorySink`.
  - Tests: I-20, I-21, and a live series get.
- [x] **7. Example and live gate** (`165b8f6`). `examples/bin/retrieve_and_render.dart` (Orthanc → C-FIND → C-GET → PGM); `scripts/pacs_up.sh` (the `pacs-up` recipe body moved here), `scripts/pacs_seed.sh`, `scripts/live_gates.sh`, `just pacs-seed` / `just live`; `interop.yml` (`workflow_dispatch` only).

**Exit:** the example retrieves a series from Orthanc and renders a frame. Every seam is crossed: bytes → `Dataset` → pixels, and PDVs → `Dataset` → sink. **Met 2026-10-17** (`just live`).

**M1 limits** (each is lifted later):

- Cancelling a `sendCFind` / `sendCGet` subscription **aborts the association**. C-CANCEL-RQ (F14) comes in M3.
- One operation runs at a time per association, and a second concurrent call throws `StateError`.
- There are no timers yet (ARTIM, DIMSE, ACSE: N-13 in M3), so the live gate runs under `timeout`.
- Files are read as whole bytes (`FileSource` and deferral are M2).
- Deflated and Big Endian data isn't supported yet (M2).

### M2 `dartdicom` P0 complete

Planned 2026-10-17. Decisions:
- the exit corpus is the committed fixtures plus pydicom-data from the cache;
- written files are checked with pydicom and DCMTK, with dciodvfy at M5;
- inflate is pure Dart and deflate goes through zlib;
- the implementation identity changes only when the file did;
- private blocks resolve tags (surface S9);
- `Uid.generate` uses `2.25.` + a UUID (S10).

Each step ends with the dry and floor gates green, and `just live` after a read or write change.

- [x] **0. Docs** (`94d6759`). The decisions above; blueprint F40 (`lib/src/source/`) and F41 (I-10 by rule); surface S9 and S10; the PRD's dciodvfy clause moved to M5.
- [x] **1. Dataset API, UIDs, the encapsulation bug** (`da29dd4`).
  - The untyped getters (F36), `ds.element(tag)`, `setRaw`, `privateBlock`, `Uid.generate` / `isValid`.
  - The writer refuses to change between encapsulated and native syntaxes while Pixel Data is present.
  - I-23's property test.
- [x] **2. Sources, random access, deferral** (`3062462`). Sequences keep no raw span now: the writer rebuilds them from their items in the length forms read, so a file source never copies nested bytes twice.
  - `source/` (a leaf) and `DicomFile.fromSource`.
  - `FileSource` / `FileSourceOpener`, `SourceChangedException` (DA2), `deferSize`, I-14.
  - D1's async prefix read with geometric growth; a nesting-depth limit.
  - Writing a partial read is refused.
- [x] **3. Corpus census** (`cf14863`). First run: 85 files, 68 compared, 25 failing, each scheduled in `dartdicom/test/corpus_expected.txt`. The census found a crash, a `TypeError` on a UN (0008,0005); it is guarded now and repaired in step 5.
  - `golden.py` hardened (per-element errors, raw forms, stamps, `force`); `fixtures golden --corpus`.
  - A shared comparator with named tolerances.
  - `corpus_test.dart` as a ratchet over `corpus_expected.yaml`; the CI `corpus` job.
- [x] **4a. Deflated** (`0d79809`). The puff.c-style inflate matched zlib on the first run (stored, fixed and dynamic blocks, levels 0–9); both Deflated fixtures agree with pydicom element for element and pixel for pixel. Pure-Dart inflate with a size cap; `ZLibDeflateCodec`; inflate in both parse entry points.
- [x] **4b. Big Endian and the cross-syntax writer** (`e166995`). All 11 Big Endian corpus files agree with pydicom; the corpus ratchet is down to 17.
  - `WriteOptions`; the copy rule by VR; the swap rule (OW Pixel Data by Bits Allocated, 8-bit included).
  - Stale group lengths dropped.
  - Writing BE is refused with the fix named.
- [x] **4c. Implementation identity and I-17** (`218bb8d`). The six `SC_rgb*` corpus files now round-trip byte for byte; the ratchet is down to 11, all scheduled for step 5. "Changed" means not verbatim, or the meta was edited.
- [x] **5. Lenient reading and `ReadReport`** (`7daad21`). All 85 corpus files agree with pydicom and pass F41; `corpus_expected.txt` is empty. One named tolerance remains (*Confirmed contracts*).
  - `ReadReport` on `file.report` and `ds.report`: 14 repair kinds, each with a case in `test/read/lenient_test.dart`.
  - `ReadOptions.force` and `tags`; syntax detection; the UN rules (`unReplaced`, `unSequence`); pydicom's ambiguous-VR rules settled once a dataset level is read; truncation kept partial; wrong lengths decode the whole values.
  - F41 shared by the fixture and corpus round trips (`test/support/f41.dart`), with two refinements recorded in the blueprint.
  - Divergences from pydicom: a wrong-length number decodes (pydicom throws on access); a dataset that ends inside an undefined-length value keeps what came before (pydicom empties it).
- [x] **6. Written-file gate** (`fe7a42b`). `scripts/written_gate.sh`: the fixtures in the dry gates (65 files written, 24 refused as expected), the corpus in the corpus job (362 written, 238 refused).
  - `tool/write_all.dart` writes each source in every syntax it can (as read, Implicit, Explicit, Deflated) and asserts each refusal F41 promises: encapsulated ↔ native, Big Endian as read, partial reads, missing or contradicting SOP UIDs.
  - `fixtures golden --written` exports pydicom's reading; `test/written_test.dart` checks it agrees with dartdicom's reading (I-11), that dartdicom's reading holds the source's elements in the new encoding, that pydicom's pixel arrays match the source's (I-18), and that `dcmdump` raises nothing the source didn't, beyond `test/dcmdump_allowlist.txt`.
  - The check is transitive (pydicom ↔ dartdicom on the written file, dartdicom written ↔ source), so the comparator needs one more named tolerance only: implicit private tags pydicom types from its private dictionary (F11).
  - The writer gives a sequence the dictionary doesn't know (a private one) an undefined length in Implicit VR, so a reader without a private dictionary still finds its items (found on `OBXXXX1A_expb.dcm`).
- [x] **7. Fuzz, PHI canary, close.** No crash in the dry gates' 6,000 cases or a 150,000-case run; the only failure found was the harness writing Deflated without an encoder (the documented `UnsupportedError`).
  - `test/fuzz_test.dart` (I-30): bit flips, truncations, rewritten lengths and random tails over the small fixtures; the force path on files cut at random points; the inflater on mutated streams and noise. `just fuzz [cases] [seed]` runs more.
  - The `phi_canary` fixture and `test/phi_canary_test.dart` (I-9): no `toString`, exception, or read report shows a sentinel, across truncations every 3 bytes, damage around each sentinel, wrong-type reads, write failures and repairs. A planted leak in `DataElement.toString` fails it.

**Exit** (all met, 2026-10-17):
- every element agrees with pydicom on the committed fixtures **and** the pydicom-data corpus (I-11), with the corpus exceptions that remain listed and reasoned (none remain);
- round trips are byte-identical under F41's rule (I-10);
- pydicom and DCMTK read everything written (`dciodvfy` moves to M5);
- the PHI canary passes (I-9);
- the parser, the inflater and the `force` path are fuzzed.

**Tests that flipped:**
- `vs_pydicom_test`'s readable set widens to Deflated and BE;
- `round_trip_test` follows F41;
- the pixel test's BE/Deflated skip goes;
- an unknown VR code becomes a repair.

### M3 `dartdicom_net` P0 complete

Planned 2026-10-17. Decisions:
- C-GET leads in the docs and examples, and C-MOVE is documented beside it; the local Orthanc is the first testing PACS;
- the interop matrix is full: each operation against each peer that can play the other role, our StorageScp included;
- the StorageScp accepts `ScpPeer(aeTitle, {host})` peers, and the called AE title must be its own (F43);
- the StorageScp prefers uncompressed syntaxes and accepts compressed ones as a fallback;
- the trace shows no values unless `showValues: true` (F5 amended);
- timeouts are pynetdicom's: connect 30 s, ACSE 30 s (ARTIM too), DIMSE 30 s per response, network idle 60 s; expiry aborts and throws;
- a cancelled C-GET keeps storing sub-operations already in flight (F14 amended).

Each step ends with the dry and floor gates green, and `just live` after a network change.

- [x] **0. Docs** (`9f4f10a`). The decisions above; blueprint F5, F14 amended, F42 (the DUL's reader model), F43 (StorageScp peers), `trace/` at rank 0, I-9/I-12/I-13 references; surface names for M3.
- [x] **1. pynetdicom vectors (I-12)** (`de98d86`). `fixtures build` now also writes `fixtures/data/net/vectors.json` (26 vectors from pynetdicom 3.0.4) and `transition_table.json` (its 123 cells), checked by `fixtures check` (I-28). Every PDU type and every command set M3 uses matched on the first run: the M1 encoders were already pynetdicom's byte for byte. Added: the typed async window item (0x53), and one PDV per message part when the peer sets no PDU limit.
- [x] **2. Reader model, full table, acceptor DUL (N-02, I-13, F42)** (`3218f65`). The 247-cell test matches pynetdicom's table, and the M1 cells it corrected are Sta13 + Evt19 → AA-7 and Sta13 + Evt6. The live gates passed unchanged on the new DUL.
  - **Reader:** a one-PDU read-ahead reader; a peer's release while idle is answered (AR-2, AR-4); every later call throws the recorded cause, never a `StateError`.
  - **Acceptor:** request, accept, reject, release, and release collisions on both sides.
  - **Abort reasons:** an unexpected PDU aborts with reason 2 and an invalid one with reason 1, where pynetdicom always sends 0.
- [x] **3. Timeouts (N-13)** (`2e7e237`). `Timeouts` (pynetdicom's defaults) on `ApplicationEntity`; `DimseTimeout(TimeoutKind)` in net's sealed tree; ACSE, ARTIM and network timers inside the DUL and the DIMSE timer in the channel; the connect timeout in `SocketTransport` (`Timeouts.connect` replaces `associate(connectTimeout:)`). Tested under `fake_async`; live, an association left idle past Orthanc's timeout ends with a clear `AssociationAborted`.
- [x] **4. C-CANCEL (N-07, F14).**
  - Cancelling a find or get subscription sends C-CANCEL-RQ at once (pynetdicom's three-element command set, checked against its vector). It then drains to the final response within one DIMSE timeout; a get keeps storing what is in flight.
  - `cancel()` always completes normally, and the association is free afterwards. Live, a find cancelled on its first Orthanc match leaves the association usable.
  - The channel sends whole messages in order. `_operation` runs on a `StreamController` that stops reading while its subscription is paused.
- [ ] **5. Trace (N-14).** `Trace`, `TraceSink`, `TraceEvent` (DIMSE, PDU), levels; no values by default.
- [ ] **6. C-STORE SCU (N-10).** `sendCStore(DicomFile)`; SCU+SCP roles for classes both requested and retrieved; `ApplicationEntity.deflateCodec`.
- [ ] **7. StorageScp (N-09, F3).** The listener, acceptor ACSE, the serve loop, the shared store handler; `peerAeTitle`; concurrency-safe `DirectorySink`; an acceptor fuzz.
- [ ] **8. C-MOVE SCU (N-09).** `sendCMove`; compose `host-gateway`; `retrieve_and_render --via=move`.
- [ ] **9. Interop matrix.** DCMTK (`dcmqrscp`, `storescp`, `storescu`) and pynetdicom (`qrscp`, `storescp`, `storescu`) peers via `scripts/interop_peers.sh`; `interop.yml` nightly.
- [ ] **10. Fuzz, net PHI canary, close.** PDU decoder, assembler and DUL fuzz; the canary over trace and exceptions; I-7's regex.

**Exit:**
- the live interop gate passes C-ECHO, C-FIND, C-GET, C-MOVE and C-STORE against Orthanc, DCMTK and pynetdicom
- PDUs are byte-identical to pynetdicom's encoders (I-12), and the state table matches PS3.8's 247 cells (I-13)
- the net PHI canary passes (I-9), and the PDU decoder is fuzzed

**Tests that will flip:**
- get/find "cancel aborts" (an M1 limit) → cancel and drain;
- `fsm_test`'s blank-cell check → all 247 cells; Sta13 + Evt19 → AA-7;
- `associate(connectTimeout:)` → `Timeouts.connect`;
- the live gate's `perl alarm` deadlines become a backstop.

### M4 `dartdicom_pixel` P0 complete

- [ ] X-01–X-04, X-07

**Exit:**
- pixel arrays match pydicom's sha256 for the native fixtures
- VOI output matches pydicom's `apply_voi_lut` within a stated tolerance

### M5 0.1.0 and the first consumer

- [ ] Publish `dartdicom`, `dartdicom_pixel` and `dartdicom_net` as `0.1.0-dev.N`, then `0.1.0`, core first
- [ ] The first consumer integrates on each desktop OS it ships on
- [ ] Written files pass `dciodvfy` (dicom3tools) where it applies (moved from M2, 2026-10-17)

**Exit:** the PRD's first-consumer success criterion is met: query, retrieve and display with no sidecar runtime.

### After 0.1: P1

These run in order of demand:

- core: C-13, C-15, C-17, C-18, C-19, C-21
- pixel: X-05, X-06
- net: N-15, N-16
- web: W-01–W-06 (`dartdicom_web`)

## Deferred (P2)

- **core:** C-14 ISO 2022 · C-22 de-identification · C-23 DICOMDIR
- **pixel:** X-08 color · X-09 JPEG Baseline · X-10 native/WASM codecs (separate repos) · X-11 encoding
- **net:** N-17 streaming a large instance to disk · N-18 Modality Worklist · N-19 TLS · N-20 N-services · N-21 isolate offload
- **web:** W-07 WADO-URI · W-08 UPS-RS · W-09 server helpers

## Open questions

- **Before 1.0:** does PN become `PersonName`, and do DA/TM/DT become date types (C-15)? Typed tags fix each VR's Dart type in every generated constant, so this is free only before 1.0 (data §8).
- **Before 1.0:** should the wrong value type for a typed tag fail to compile (I-24)? `ds.set(DicomTags.rows, 'x')` compiles today, because Dart widens `T` to `Object`. `set` and `setAll` refuse it at runtime with an `ArgumentError`. A compile-time guard would change the public writing API, for example setters bound to the tag, so that `T` comes from the tag alone. `test/compile_fail/` pins the gap, so closing it means editing that file.

**Answered 2026-10-17, planning M3:** C-GET stays the retrieve path the docs and examples lead with, and C-MOVE is documented beside it. The local Orthanc is the first testing PACS, and the first consumer's own PACS is checked at M5.

**Answered 2026-10-17, planning M2:** when a file is rewritten, its meta names dartdicom (0002,0012/0013) only if the file changed: an edit, a re-encode, or an edited meta. Otherwise the pair is kept as read, so I-10 holds. A missing or empty pair is filled, both tags together.

**Answered 2026-10-17** (recorded in blueprint §3):

- **Dictionary release:** DICOM **2026d**, pinned by SHA-256. The generator tries the release URL first, then `current`, and refuses a checksum mismatch. Refresh: bump `release` and the checksums in `tool/gen_dictionary/source.dart`, then run `just dict`.
- **Corpus cache:** the user cache (`$DARTDICOM_CACHE`, else `$XDG_CACHE_HOME/dartdicom`, else `~/.cache/dartdicom`), never inside the repo.
- **Curated fixtures:** 14 small files from pydicom's bundled test data, copied from the pinned pydicom 3.0.2 wheel. pydicom-data stays in the cache at commit `abc42b9`.

## Confirmed contracts

| Contract | Evidence |
|---|---|
| Orthanc 1.13.0 ends an association left idle for its `DicomScpTimeout` (30 s by default) with an A-ABORT. Our network timeout (60 s) is longer, so against a stock Orthanc the PACS ends an idle association first; the DUL's pending read notices it while no operation runs (F42). | `live_test.dart`, 2026-10-17 |
| DCMTK 3.7.0's `dcmdump` raises nothing on the 427 files dartdicom writes from the fixtures and the corpus, except a notice for private sequences in Implicit VR (CP-246, allowlisted). The one source warning, OW on encapsulated Pixel Data in `SC_rgb_rle_16bit.dcm`, is the source's: the as-read write copies it under I-10. | `scripts/written_gate.sh`, 2026-10-17 |
| pydicom types private tags in Implicit VR from its private dictionary, sequences included: a defined-length private SQ written as Implicit VR reads as an SQ in pydicom and as UN without one (`OBXXXX1A_expb.dcm`, (200D,110D)). | `written_test.dart`, pydicom 3.0.2, 2026-10-17 |
| pydicom 3.0.2 empties a dataset that ends inside an undefined-length value: `read_dataset` builds it in a dict comprehension, so the `EOFError` loses every element read before (`emri_small_jpeg_2k_lossless_too_short.dcm`). dartdicom keeps them and reports `valueDropped`; the comparator's only tolerance excuses exactly this. | pydicom `filereader.py`, 2026-10-17 |
| pydicom's ambiguous-VR rules key on the *dataset's* encoding as read (`original_encoding`): implicit Pixel Data and waveform data are OW even where one element was read implicitly in an explicit dataset. | pydicom 3.0.2 `filewriter.py`, 2026-10-17 |
| The repairs the pydicom-data corpus needs: 37 `unReplaced` (`explicit_VR-UN.dcm`, `bad_sequence.dcm`), 5 `staleGroupLength` (`693_*`), 5 `noPreamble` (4 JPEG-LS files with meta at offset 0, `OT-PAL-8-face.dcm`), 1 `noFileMeta`, 1 `valueDropped`. No file triggers a syntax, length or VM repair. The 4 JPEG-LS files carry no SOP UIDs anywhere, so they read but can't be written. | `corpus_test.dart` census, 2026-10-17 |
| Real files carry stale group lengths: pydicom-data's `693_UNCI.dcm` says (7FE0,0000) = 105,406 for 524 KB of uncompressed Pixel Data, left over from its compressed sibling. The writer drops a group length that no longer equals its group. | `corpus_test.dart`, 2026-10-17 |
| pydicom decodes 8-bit OW Big Endian Pixel Data by swapping 16-bit words across the whole padded value, so an odd image's last pixel comes from the padding word (`SC_rgb_small_odd_big_endian.dcm`). `dartdicom_pixel` matches it. | pydicom 3.0.2, 2026-10-17 |
| A header-only read of an 8 MiB file through `FileSource` reads one 64 KiB window, and so does a full read with the Pixel Data deferred. A deferred `Dataset` moves to another isolate and loads its value there (I-14). Async and sync reads agree on every fixture in all three modes. | `file_source_test.dart`, 2026-10-17 |
| dart2js's `Random.secure()` throws under Node (the SDK runtime calls the `crypto` getter with the wrong receiver), but works in Chrome and on the VM. `Uid.generate`'s tests skip Node; Node is not a target. | `uid_test.dart` on node and chrome, Node 26, 2026-10-17 |
| Native frames decoded by `dartdicom_pixel` match pydicom 3.0.2's `pixel_array` (sha256, after `correct_unused_bits`) for all 15 native Little Endian fixtures with 8 or 16 bits allocated, multi-frame and interleaved RGB included. An aligned host-order frame is a zero-copy view. | `dartdicom_pixel/test/vs_pydicom_test.dart`, 2026-10-17 |
| The M1 parser reads all 22 Little Endian fixtures, the 5 RLE (encapsulated) ones included, and agrees with pydicom 3.0.2 on every element of each (I-11 on the slice). Every one of them round-trips byte for byte, except pydicom's `rtdose.dcm` and `rtplan.dcm`: their file meta SOP Instance UID contradicts the dataset's, so the write is refused (I-17, data §5). | `vs_pydicom_test.dart`, `round_trip_test.dart`, 2026-10-17 |
| pydicom's test files carry non-zero 128-byte preambles (a TIFF header), so `DicomFile` keeps the preamble it read | `round_trip_test.dart`, 2026-10-17 |
| `examples/bin/retrieve_and_render.dart` retrieves CT_small's series from the compose Orthanc (C-ECHO, C-FIND STUDY and SERIES, C-GET 1/1) and renders a 128×128 frame that reads as an axial CT slice; `just live` checks the PGM | `scripts/live_gates.sh`, 2026-10-17 |
| A DUL must cancel its PDU reader when it closes the transport: a paused subscription on a socket keeps the isolate, and so the program, alive after release. Only the live example caught it, because the test runner tears isolates down. | live run, 2026-10-17 |
| dartdicom_net associates with Orthanc, C-ECHOes and releases; Orthanc's A-ASSOCIATE-AC is committed as `dartdicom_net/test/vectors/orthanc_associate_ac.bin` | `live_test.dart`, 2026-10-17 |
| An `InMemoryTransport.close()` must not await `StreamController.close()`: that completes only once the peer reads the done event, which a paused `StreamIterator` never does | association tests hung, 2026-10-17 |
| Orthanc 1.13.0 (image `orthancteam/orthanc:26.9.1`) as a C-GET SCP accepts a role item with SCU 0 and SCP 1 for each proposed storage class (`Accepted SCP/SCU Role: SCP`). It accepts the first proposed transfer syntax (Explicit VR LE), receives at most 16384-byte PDUs, and identifies itself as DCMTK 3.7.0 (`1.2.276.0.7230010.3.0.3.7.0`, `OFFIS_DCMTK_370`). `getscu` proposed 121 contexts, and all were accepted. | DCMTK `getscu -d`, 2026-10-17 |
| Orthanc's C-GET of a one-instance series goes: C-STORE-RQ, then a Pending C-GET-RSP (remaining 0, completed 1), then a final Success with **no** Remaining element | DCMTK `getscu -d`, 2026-10-17 |
| Orthanc's C-FIND matches come in Explicit VR LE and carry (0008,0005) `ISO_IR 100` and (0008,0054) RetrieveAETitle. A SERIES-level query needs StudyInstanceUID. | DCMTK `findscu`, 2026-10-17 |
| The full dictionary costs about +78 KB gzipped under dart2js, which is acceptable | local spike, 2026-10-16 |
| An open `RandomAccessFile` or `ServerSocket`, or an object holding one, cannot be sent to another isolate; a closure capturing only a path can | local spike, Dart 3.8.1, 2026-10-16 |
| `package:http`'s `BrowserClient` uses fetch (from 1.3.0) and streams responses, but not request bodies | `package:http` source and changelog |
| Pub workspaces need Dart ≥ 3.6; glob patterns in `workspace:` need ≥ 3.11 | dart.dev *Pub workspaces* |
| Web-vs-native conditional imports use `dart.library.io` / `dart.library.js_interop`; `dart:html` is deprecated and unavailable on Wasm | dart.dev *package:web* migration guide |
| The prototypes work: the pydicom-core port passes 74 tests and the pynetdicom-core port passes 37 | local run, 2026-10-16 |
| A static member declared in an extension is reached only through the extension's name, never through the extended type, so `DicomFile.read` can't come from `io.dart` | `dart analyze`, Dart 3.8.1, 2026-10-16 |
| mise: in the repo, `dart` resolves to 3.13.5 in both kinds of login shell; outside it, the shim falls back to the next `dart` on `PATH` (e.g. a Flutter SDK's). A shim resolves to the `mise` binary, not into an SDK, so Dart-Code needs `dart.sdkPath`. | local check, 2026-10-16 |
| An extension type that doesn't implement `Object` isn't assignable to `Object` (it is potentially nullable), so `Tag` declares `implements Object` (but not `int`) | compile error in `tag_test.dart`, Dart 3.13.5, 2026-10-16 |
| The 3.6 floor resolves with `lints: ">=5.1.0 <7.0.0"` → 5.1.1 and `test: ^1.25.0` → 1.26.3, provided no lockfile is committed | local floor run, Dart 3.6.0, 2026-10-16 |
| `package:test` exports a class named `Tags` (for `@Tags`), so a test importing both it and a library exporting `Tags` gets `ambiguous_import` | `dart analyze`, 2026-10-17 (surface S6) |
| Typed tags tree-shake: a web program using three tags and a UID compiles to 33 KB, the same as the baseline example; 5,254 unused constants cost nothing | `dart compile js -O2`, Dart 3.13.5, 2026-10-17 |
| pydicom's `generate_uid(prefix=None, entropy_srcs=…)` is random (UUID4) whatever the entropy sources; deterministic fixtures use their own `2.25.` + UUID v5 | fixture reproducibility check, 2026-10-17 |
| NEMA serves the newest release only under `/current/`; a release gets its own URL once superseded (e.g. 2026c) | HTTP probes, 2026-10-17 |
| A sealed class's subtypes must be in its own library (`invalid_use_of_type`); an open `abstract base` class with a sealed subtree per package works, and stays exhaustive | `dart analyze`, Dart 3.13.5, 2026-10-16 |
| Typed tag constants (`extension type const One<T>(int)` / `Many<T>`) cost nothing at runtime; their value types are inferred; misuse is a compile error; they build on the VM, dart2js and dart2wasm | local spike, Dart 3.8.1, 2026-10-16 |

## Risks

| Risk | Mitigation |
|---|---|
| The DICOM standard is huge, so scope creeps | Strict P0 per milestone; the PRD's priorities are the yardstick |
| One maintainer plus AI has limited bandwidth | Tracer first; client-first networking; follow pydicom and pynetdicom designs instead of inventing |
| State-machine bugs hang associations | Table-driven, with every pair covered (I-13), plus interop gates |
| PHI leaks through logs | Redaction by default, plus the canary test (I-9) |
| Compressed images block the viewer | Offer uncompressed transfer syntaxes only (N-03); codecs come later as plugins |
| 64-bit values are wrong in browsers | `BigInt` for SV and UV; chrome CI (I-2) |
| CI time grows | Path filters; interop runs as a nightly or manual live gate |
| Someone takes the package names | Names were confirmed free on 2026-10-16; publish `0.1.0-dev.1` once M1 passes |
| Binary fixtures bloat the repo | A small curated set; larger corpora are fetched into the cache by `fixtures corpus fetch` |
