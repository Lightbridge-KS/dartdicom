---
summary: Progress tracker for dartdicom 0.x, the path to the first consumer (a Flutter desktop tool that queries, retrieves and displays from a PACS). Holds milestones with exit criteria, Now/Next, deferred work, open questions, confirmed contracts and risks.
read_when:
  - starting a work session or choosing the next task
  - landing work (tick the box and add the commit SHA)
  - checking whether a requirement is scheduled, deferred, or blocked by an open question
---

# dartdicom 0.x: progress

Links: [requirements](../req/dartdicom-prd.md) · [system architecture](../design/01-system-architecture.md) · [data architecture](../design/02-data-architecture.md) · [surface architecture](../design/03-surface-architecture.md) · [codebase blueprint](../structure/01-codebase-blueprint.md)

**Now:** M1 Tracer bullet, planned 2026-10-17 in 8 steps (below). **M0 is done** (2026-10-17, `285623d` · `424cfa2` · `bed879b`): all exit criteria met, CI green on both workflows.
**Next:** M2–M4, filling out core, net and pixel, in any order.

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
- [x] **1. Core model.**
  - `errors.dart` (`DicomException` + the sealed `DicomDataException`); the `TransferSyntax` descriptor; the implementation identity; per-VR converters; charsets (default, `ISO_IR 100`, `ISO_IR 192`; F35 on encode).
  - `DataElement` keeps its raw span; `Dataset` (typed reads and writes, iteration, `transferSyntax`); `Sequence`.
- [ ] **2. Core parse, write, façade.**
  - A sync parser for Explicit and Implicit VR LE: defined and undefined lengths, nested SQ, encapsulated data kept raw, `stopBeforePixels`, ambiguous OB/OW and US/SS.
  - A passthrough writer; `file/` (`DicomFile`, `FileMetaInformation`, I-17); `io.dart` over whole-file bytes.
  - Tests: I-11 and I-10 on the LE fixtures.
- [ ] **3. Pixel.**
  - `ds.pixels.frame(i)` → `PixelArray`, with BitsStored masking; Modality LUT; linear VOI (PS3.3 C.11.2.1.2.1); MONOCHROME1; `ds.voiWindow()`; `DisplayBuffer` (`gray`, `toRgba()`).
  - Tests: sha256 against golden for the 16-bit monochrome fixtures.
- [ ] **4. Net through C-ECHO.** Transports (socket, in-memory), PDUs (with role selection), framing, the FSM (requestor rows), ACSE, `ApplicationEntity`, `associate` / `sendCEcho` / `release` / `abort`, and `DimseStatus`.
  - Tests: hand-checked PS3.8 vectors, a captured Orthanc A-ASSOCIATE-AC, and a live echo.
- [ ] **5. DIMSE and C-FIND.** Command sets, the fragmenter, the assembler (every PDV of every P-DATA-TF), and message IDs. `sendCFind` → `Stream<Dataset>` (S5).
  - Tests: a scripted peer, and a live find at STUDY and SERIES level.
- [ ] **6. C-GET and sinks.** `PresentationContexts.commonStorage` plus role items (≤ 128 contexts); `sendCGet` → `Stream<RetrieveProgress>`; `InstanceSink`, `ReceivedInstance`, `MemorySink`, `DirectorySink`.
  - Tests: I-20, I-21, and a live series get.
- [ ] **7. Example and live gate.** `examples/bin/retrieve_and_render.dart` (Orthanc → C-FIND → C-GET → PGM); `scripts/pacs_seed.sh`, `scripts/live_gates.sh`, `just pacs-seed` / `just live`; `interop.yml` (`workflow_dispatch` only).

**Exit:** the example retrieves a series from Orthanc and renders a frame. Every seam is crossed: bytes → `Dataset` → pixels, and PDVs → `Dataset` → sink.

**M1 limits** (each is lifted later):

- Cancelling a `sendCFind` / `sendCGet` subscription **aborts the association**. C-CANCEL-RQ (F14) comes in M3.
- One operation runs at a time per association, and a second concurrent call throws `StateError`.
- There are no timers yet (ARTIM, DIMSE, ACSE: N-13 in M3), so the live gate runs under `timeout`.
- Files are read as whole bytes (`FileSource` and deferral are M2).
- Deflated and Big Endian data isn't supported yet (M2).

### M2 `dartdicom` P0 complete

- [ ] C-01–C-12, C-16, C-20, including the lenient reading of real-world data in C-10
- [ ] Fuzz the parser (bounds-checked lengths)

**Exit:**
- every element agrees with pydicom on the fixture corpus (I-11)
- round-trips are byte-identical (I-10)
- pydicom reads everything written, and `dciodvfy` passes where it applies
- the PHI canary test passes (I-9)

### M3 `dartdicom_net` P0 complete

- [ ] N-01–N-14: the full state table (I-13), timeouts, C-CANCEL, C-MOVE plus `StorageScp`, the layered trace
- [ ] Fuzz the PDU decoder

**Exit:**
- the live interop gate passes C-ECHO, C-FIND, C-GET, C-MOVE and C-STORE against Orthanc, DCMTK and pynetdicom
- PDUs are byte-identical to pynetdicom's encoders (I-12)

### M4 `dartdicom_pixel` P0 complete

- [ ] X-01–X-04, X-07

**Exit:**
- pixel arrays match pydicom's sha256 for the native fixtures
- VOI output matches pydicom's `apply_voi_lut` within a stated tolerance

### M5 0.1.0 and the first consumer

- [ ] Publish `dartdicom`, `dartdicom_pixel` and `dartdicom_net` as `0.1.0-dev.N`, then `0.1.0`, core first
- [ ] The first consumer integrates on each desktop OS it ships on

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
- **M3:** which PACS products must the first consumer support, and do they support C-GET? The answer settles whether the default retrieve path is C-GET or C-MOVE. The tracer uses C-GET, which the test Orthanc supports (confirmed 2026-10-17).

**Answered 2026-10-17** (recorded in blueprint §3):

- **Dictionary release:** DICOM **2026d**, pinned by SHA-256. The generator tries the release URL first, then `current`, and refuses a checksum mismatch. Refresh: bump `release` and the checksums in `tool/gen_dictionary/source.dart`, then run `just dict`.
- **Corpus cache:** the user cache (`$DARTDICOM_CACHE`, else `$XDG_CACHE_HOME/dartdicom`, else `~/.cache/dartdicom`), never inside the repo.
- **Curated fixtures:** 14 small files from pydicom's bundled test data, copied from the pinned pydicom 3.0.2 wheel. pydicom-data stays in the cache at commit `abc42b9`.

## Confirmed contracts

| Contract | Evidence |
|---|---|
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
