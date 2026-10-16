---
summary: Progress tracker for dartdicom 0.x, the path to the first consumer (a Flutter desktop tool that queries, retrieves and displays from a PACS). Holds milestones with exit criteria, Now/Next, deferred work, open questions, confirmed contracts and risks.
read_when:
  - starting a work session or choosing the next task
  - landing work (tick the box and add the commit SHA)
  - checking whether a requirement is scheduled, deferred, or blocked by an open question
---

# dartdicom 0.x: progress

Links: [requirements](../req/dartdicom-prd.md) · [system architecture](../design/01-system-architecture.md) · [data architecture](../design/02-data-architecture.md) · [surface architecture](../design/03-surface-architecture.md) · [codebase blueprint](../structure/01-codebase-blueprint.md)

**Now:** M0 Foundation. All of these were settled on 2026-10-16:

- design D1–D4
- data DA1 (typed tags) and DA2 (throw on a changed source)
- surface S1–S5 (write API, immutable AE, Dataset queries, Effective Dart identifiers, a final Failure as a stream error)
- the blueprint forks
- the fixture strategy
**Next:** M1 Tracer bullet.

## Roadmap

```text
M0 Foundation ─▶ M1 Tracer bullet ─▶ M2 Core P0 ─┬─▶ M5 0.1.0 + first consumer ─▶ P1 work
                                     M3 Net P0  ─┤
                                     M4 Pixel P0 ┘
```

M1 builds the thinnest end-to-end slice through every package the first consumer needs. M2–M4 then fill out each package and can run in any order.

## Milestones

### M0 Foundation

- [x] `git init`; `.gitignore` (`_playground/`, `.dart_tool/`, `build/`, `pubspec.lock`, local agent files); MIT `LICENSE` (root and each package); root `README.md`; `AGENTS.md`
- [x] Pin the dev Dart SDK to 3.13.5 with mise (`mise.toml`), with shims activated in the login shell profile and Dart-Code pointed at the install (`.vscode/settings.json`, local only). Done 2026-10-16; commit SHA to follow `git init`.
- [x] `.gitignore` includes `.vscode/settings.json` (it holds a home path)
- [x] Root workspace `pubspec.yaml` with members listed explicitly; shared `analysis_options.yaml` (strict modes, `unawaited_futures`, `_playground/` excluded)
- [x] Scaffold the four packages and `examples/` with `dart create -t package`; reworked to version `0.1.0-dev.1`, floor `^3.6.0`, `resolution: workspace`. Core seed: `Tag` (C-01) plus architecture tests (I-1, I-5, I-7, I-22, no `print`)
- [ ] Dictionary generator: pinned DICOM release, PS3.6 + PS3.7 XML → committed `*.g.dart`, cross-checked against pydicom's dictionary. It emits typed tags (`One<T>` / `Many<T>`) from the data §3.4 table plus the dictionary VM (DA1).
- [ ] Fixture tooling (blueprint §3):
  - `tool/make_fixtures.py`: a synthetic scenario generator, written from scratch
  - `tool/fetch_corpus.py`: pydicom-data and public collections, fetched on demand and never committed
  - golden JSON export
  - `fixtures/PROVENANCE.md`
- [ ] Dry-gate CI (`ci.yml`): a pinned job (mise) runs `tool/dry_gates.sh` with Chrome, and a floor job (Dart 3.6.0) runs analyze and VM tests. **Both run green locally** (floor: lints 5.1.1, test 1.26.3); the first CI run needs the GitHub repo
- [x] `.pre-commit-config.yaml` (pre-commit-hooks v6.0.0 hygiene set, `dart format`, gitleaks); `prek run --all-files` passes. `prek install` not run yet
- [x] `docker/compose.yaml`: stock Orthanc 26.9.1 (DICOMweb, find/get allowed, `DARTDICOM` registered as the C-MOVE destination). Default ports 14242 (DIMSE), 18042 (HTTP) and 14112 (C-MOVE destination), each overridable. Verified side by side with another local PACS on 4242/8042: REST, `/dicom-web/studies` 200, C-ECHO. DCMTK comes from the host or runner, not a container

**Exit:** CI is green, the dictionary is generated from the pinned release, and `dart pub publish --dry-run` passes for every package.

### M1 Tracer bullet: "find, get, show one image"

- [ ] core: read and write Explicit VR LE and Implicit VR LE, with enough dictionary and value support for the slice
- [ ] net: associate and release; C-ECHO; C-FIND at study level; C-GET of one series with role selection; `InstanceSink`
- [ ] pixel: native 16-bit monochrome → Modality LUT → VOI window → 8-bit buffer
- [ ] `examples/retrieve_and_render.dart`: Orthanc → C-FIND → C-GET → write one frame as a PGM

**Exit:** the example retrieves a series from Orthanc and renders a frame. Every seam is crossed: bytes → `Dataset` → pixels, and PDVs → `Dataset` → sink.

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
- **M0:** where does the fetched-corpus cache live: a gitignored folder in the repo, or the user's cache directory (data §8)?
- **M0:** which DICOM release does the dictionary pin to, and how often is it refreshed?
- **M0:** which pydicom-data files (MIT) are small and clean enough to commit as curated fixtures? Each file's upstream provenance must be checked.
- **M1 / M3:** which PACS products must the first consumer support, and do they support C-GET? The answer settles whether the tracer and the default retrieve path use C-GET or C-MOVE.

## Confirmed contracts

| Contract | Evidence |
|---|---|
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
| Binary fixtures bloat the repo | A small curated set; larger corpora are downloaded by `tool/` scripts |
