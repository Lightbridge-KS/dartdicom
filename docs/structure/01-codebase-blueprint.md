---
summary: Codebase blueprint for the dartdicom monorepo. Covers the findings from reconciling the PRD, the system and data architecture docs and Dart platform facts; the confirmed structural forks; the repository tree; the import matrix and the tools that enforce it; seams; where each kind of change lands; what is deliberately absent; the invariants table; and CI and release mechanics.
read_when:
  - creating or moving a file, folder or package in the repo
  - adding an import between packages or layers, or a new seam or interface
  - changing CI, generated code, fixtures, or the release and publish flow
---

# dartdicom: codebase blueprint

> Inputs: [requirements](../req/dartdicom-prd.md) · [system architecture](../design/01-system-architecture.md) · [data architecture](../design/02-data-architecture.md) (reconciled 2026-10-16: F15–F27) · [surface architecture](../design/03-surface-architecture.md) (reconciled 2026-10-16: F28–F36) · Dart platform facts checked 2026-10-16 (§1) · Date: 2026-10-16
> See also: [Progress](../progress/overview-v0.md)

Status: first-pass draft, to be refined together with the design. The structural forks in §2 were confirmed on 2026-10-16. The model here is **conceptual**: names and responsibilities, not pinned signatures.

## 1. Reconciliation findings

These are the places where two inputs disagree, or where a single input disagrees with what Dart can actually do. "Resolution" is the structural answer this blueprint takes.

**Framework sources.** This repo has no vendored framework docs. The Dart facts were checked against:

- dart.dev, *Pub workspaces*
- dart.dev, *package:web migration* (conditional imports)
- the `package:http` `BrowserClient` source and changelog
- three local spikes on Dart 3.8.1: dictionary bundle size, which objects can be sent to another isolate, and typed tag constants (DA1)

| # | Collision | Resolution |
|---|---|---|
| F1 | PRD G3 (core runs in the browser) and C-20 (random-access source) **×** browser `Blob` reads, which are async only | One synchronous parser over `ByteSource`. Async sources fetch a prefix and retry when the parser reports `NeedMoreBytes` (design D1). |
| F2 | PRD N-21 (decode on a worker isolate) and C-09 (deferred values) **×** Dart isolates: an open `RandomAccessFile` is **unsendable**, even when held inside another object (spike) | A deferred value holds a `SourceOpener`, a small immutable value that reopens by path and *is* sendable (F16). It never holds an open handle. |
| F3 | PRD N-09 (embedded Storage SCP, P0) **×** N-15 (general SCP, P1) | The acceptor half of the stack (the state machine's acceptor states, ACSE acceptor negotiation, the listener) is P0. Only the handler framework for non-storage services waits. `Association` serves both roles from the start. |
| F4 | PRD X-03 (pixel access is called on a `Dataset`) and the layering rule (core has no pixel code) **×** the prototype, whose `Dataset` imports `pixels/decoder` | Core publicly exposes an element's raw bytes and the dataset's encoding (transfer syntax and endianness). `dartdicom_pixel` provides `ds.pixels` as an extension. |
| F5 | PRD N-14 (protocol trace with PHI redacted) **×** C-21 (dump with PHI masked): two packages need one policy | `Redactor` lives in core, and `dartdicom_net` uses it. |
| F6 | PRD C-04 (SV, UV) **×** Dart `int`: UV up to 2⁶⁴−1 overflows a signed 64-bit `int`, and dart2js `int` is exact only to 2⁵³ | SV and UV values are `BigInt` on every platform (design §5.1). |
| F7 | PRD C-03 (tag constants that tree-shake) **×** C-02 (the dictionary is needed at runtime for implicit VR and keyword lookup) | The dictionary always ships in the build. The spike measured +78 KB gzipped under dart2js, which is acceptable. |
| F8 | PRD toolchain (Dart ≥ 3.6) **×** workspace globs, which need Dart ≥ 3.11 | The root `pubspec.yaml` lists workspace members explicitly; there are no globs. The dev SDK is now pinned to 3.13.5 (`mise.toml`), but the CI floor job still runs Dart 3.6, which predates globs. |
| F9 | PRD W-04 (streaming) **×** `package:http` in browsers, which streams responses but not request bodies | Accepted, and already stated in W-05: STOW request bodies are held in memory in browsers. |
| F10 | PRD N-11 (hand each received instance to a sink) **×** the wire: a dataset's bytes don't say how they are encoded; only the presentation context does | The sink receives a `ReceivedInstance` that carries the **negotiated transfer syntax**, so the sink can write valid file meta. *(PRD N-11 and design §5.2 amended.)* |
| F11 | PRD "no shared global state" **×** private dictionaries, which pydicom adds to a global `add_dict_entry` | `Dictionary` is an immutable value: `Dictionary.standard.withPrivate(...)`, passed in through `ReadOptions`. |
| F12 | Design D3 (`DimseStatus` returned as a value) **×** PRD N-05 (never an empty or falsy stand-in) | These are compatible only if `DimseStatus` is sealed and has no default that means success. Callers must match on it or call `.orThrow()`. |
| F13 | Design §4.1 (the dataset converts lazily and loads deferred values) **×** the prototype, where `Dataset` imports both `filereader` and `filewriter` (a cycle) | `dataset/` imports nothing from `read/` or `write/`. Loading a deferred value goes through the injected `SourceOpener` and the value converters (invariant I-5). |
| F14 | PRD N-07 (C-CANCEL) **×** Dart streams | Cancelling the subscription to the `sendCFind` / `sendCGet` / `sendCMove` stream sends C-CANCEL-RQ. Cancel is never a separate method. |

**Reconciliation with the data architecture (2026-10-16).**

| # | Collision | Resolution |
|---|---|---|
| F15 | Data §4.2 (`DirectorySink` writes Part 10 files, so it needs `dart:io`) **×** §4 import matrix (net may use `dart:io` only in `transport/` and `scp/`) | The sink had no legal home. It gets `dartdicom_net/lib/src/sink/`, which joins footnote ² and I-6. |
| F16 | Data DA2 (throw if the source changed) **×** F2 / §5 (`SourceOpener` as a bare closure) | A closure cannot carry the size and modification time to check. `SourceOpener` becomes a small immutable value, `FileSourceOpener(path, size, modified)`, that is still sendable (I-14). *(Design §7 amended.)* |
| F17 | Data §4.3 (the writer byte-swaps OW/OF/OL/OD/OV when byte order changes) **×** §6 and §8, which have no landing spot or check | The rule lands in `write/`, and I-18 checks it against pydicom's pixel arrays. |
| F18 | Data §3.4 (the VR → Dart contract is public API) **×** §8: nothing guards it | I-19: a contract test that lists every `Vr` with its Dart type. |
| F19 | Data §6 (views pin their buffer; `FileSource` copies) **×** §5: the `ByteSource` contract says nothing about it | Contract: `BytesSource.read` returns views and `FileSource.read` returns owned copies. The parser never copies; the source decides. |
| F20 | Data §6 (sink paths built from UIDs only) **×** I-9, which covers logs and exceptions but not file paths | I-21: a check on every path the sink writes. |
| F21 | Data §2 and §7 (no temp files, no cache) **×** §8: no check | I-22: a grep for temp-file APIs in every `lib/`. |
| F22 | Data §3.3 (`ReadReport` holds no values) **×** I-9's scope | I-9 now covers `ReadReport` too. |
| F23 | Data §5 (file meta is always derived; SOP UIDs and transfer syntax exist twice) **×** C-07, which has no check | I-17: writer tests for conflicting UIDs and for the transfer syntax written into the meta. |
| F24 | Data §3.4 (DS and IS keep their text) **×** writing *modified* values: DS is limited to 16 bytes and IS to 12 | Formatting lands in `vr/`; I-23 is a property test. |
| F25 | Data §4.2 (store as received) **×** a crash in the middle of a write, which would leave a truncated `.dcm` that looks complete | `DirectorySink` writes `<name>.part` in the target directory, then renames it. I-20 checks that the stored bytes equal the received bytes. |
| F26 | Data §4.4 (fetching corpora into a cache, now `fixtures corpus fetch`) **×** §3 tree | The corpus fetcher lands in the fixtures CLI (`fixtures corpus fetch`). Where the cache lives is still open (data §8). |
| F27 | Data DA1 (typed tags, **decided 2026-10-16**) **×** design D2 (typed getters) and PRD C-03 (generated constants) | The generator emits `One<T>` / `Many<T>` from the data §3.4 table plus the dictionary VM. `Dataset` reads become `get` / `require` / `getAll`, plus list-only getters for untyped tags. A VR with alternatives of different Dart types gets a plain `Tag`. I-24 checks that misuse doesn't compile. *(Design D2 and PRD C-03 amended.)* |

**Reconciliation with the surface architecture (2026-10-16).** One more Dart fact was checked for these, on 3.13.5: a sealed class cannot be extended from another library.

| # | Collision | Resolution |
|---|---|---|
| F28 | Surface §2 (`file.report` on `DicomFile`) **×** I-5: `dataset/` imports nothing from `read/`, and `ReadReport` lived in `read/` | `ReadReport` is a plain value type, so it moves to `dataset/`. `read/` builds it. |
| F29 | Surface S2 (preset context lists, `retrieveStorageClasses`) **×** §3 tree (no home) and the UID registry (doesn't mark storage classes) | The generator also emits `SopClasses.storage` from the PS3.6 UID table. Net's `association/presentation_contexts.dart` builds the presets and C-GET role selection on top of it. |
| F30 | Surface §5 and design D3 (one sealed `DicomException` tree) **×** Dart: a sealed class's subtypes must be in its own library (`invalid_use_of_type`, checked) | An open `abstract base class DicomException` lives in core. Each package has its own **sealed** subtree in one library: `dartdicom/lib/src/errors.dart` (`DicomDataException`), `dartdicom_net/lib/src/errors.dart` (`DimseException`), `dartdicom_web/lib/src/errors.dart` (`DicomWebException`). *(Design §5.2 and surface §5 amended.)* |
| F31 | Surface §3 and §6.4 (the README mapping table and `llms.txt`) **×** §3 tree (absent) and the risk of docs going stale | Each package root gets an `llms.txt`, and the repo root gets an index. I-25 compiles every Dart snippet in the READMEs and `llms.txt` files against the current API. |
| F32 | Surface S4 (keyword → identifier; the generator fails on a collision) **×** §8, which had no check | `gen_dictionary/naming.dart` holds the rule. I-26 is a golden test of the edge cases plus a collision check. |
| F33 | Surface S5 (a final Failure is a stream error) **×** design D3 (status as a value) | D3 is refined, not reversed. `DimseFailureException` joins net's sealed tree, and `RetrieveProgress.status` carries the final status. *(Design §5.2 and D3 amended.)* |
| F34 | Surface §6.4 (`examples/` as runnable docs against the test PACS) **×** §9, where the live gates didn't run them | `interop.yml` also runs `examples/`. |
| F35 | Surface §4.2 (`Dataset()` built in memory and filled with `set`) **×** data §3.4 (charset rules cover *decoding* only) | **Decided 2026-10-16: the write fails.** Text that the dataset's declared charset can't encode, or non-ASCII text with no (0008,0005) at all, raises a `DicomWriteException`. The message names the tag and says how to fix it (`set DicomTags.specificCharacterSet to 'ISO_IR 192'`). Nothing is added silently. This lands in `write/`, and I-27 checks it. *(Data §3.4 amended.)* |
| F36 | Surface §2 (family list getters such as `getInts(Tag)` for untyped tags) **×** DA1: `One` and `Many` implement `Tag`, so `getInts(DicomTags.patientName)` compiles | Accepted, because a subtype can't be excluded. At runtime it throws an `ArgumentError` naming the tag's typed accessor (`use ds.get(DicomTags.patientName)`). |
| F37 | PRD C-03 (generated constants named `Tags`) **×** `package:test`, which also exports `Tags` (found in M0: `ambiguous_import` in any test importing both) | Renamed to `DicomTags` (surface S6). The generator emits `abstract final class DicomTags`. *(PRD C-03, design and surface examples amended.)* |
| F38 | §3 tree (`DicomFile`, `FileMetaInformation` in `dataset/`) and surface `Dataset.fromBytes` **×** I-5 (`dataset/` imports nothing from `read/` or `write/`): `fromBytes`/`toBytes` must call the parser and writer (found planning M1) | `DicomFile` and `FileMetaInformation` move to `lib/src/file/`, which may import `read/` and `write/`; meta derivation (I-17) lands there too. `read/` and `write/` see only `Dataset` and never import `file/`. **Decided 2026-10-17:** net's raw codec is `Dataset.fromBytes(bytes, transferSyntax:)` / `ds.toBytes(transferSyntax:)`, so I-5 is narrowed: only `dataset/dataset.dart` may import them. Rejected: a `DatasetCodec` value. |
| F39 | Data §4.2 (storing costs no parsing) and §6 (`DirectorySink` lays files out by Study and Series UID) **×** the wire: a C-STORE-RQ command carries only the SOP Class and Instance UIDs | `DirectorySink` parses the received bytes' header (`stopBeforePixels`) to build the path, then stores the bytes unchanged. A UID that fails `^[0-9.]+$`, or a sink exception, gets a failure C-STORE-RSP (`0xC211`, as pynetdicom does); the retrieve carries on. *(Data §4.2 amended.)* |

**Verb → action → field.** Each verb the first consumer needs, traced to the action that performs it and the field it lands on:

| Verb | Action | Field |
|---|---|---|
| query | `Association.sendCFind` | identifier `Dataset` |
| retrieve | `Association.sendCGet` / `.sendCMove` | `RetrieveProgress` {remaining, completed, failed, warning}, from command elements (0000,1020)–(0000,1023) |
| save | `InstanceSink.accept` | `ReceivedInstance` {SOP class, SOP instance, transfer syntax, bytes, source AE title, file meta} *(amended: "calling AE" was wrong for C-GET, where the peer is the called AE; the value is (0002,0016))* |
| store | `DirectorySink.accept` | a Part 10 file: `fileMeta.toHeaderBytes()` + the received bytes unchanged, at a UID-only path (F25, F20, F39) |
| display | `ds.pixels.frame(i).toDisplay(window)` | `DisplayBuffer` |
| inspect | `Dataset.get` / `require` / `getAll` (typed tags), list-only getters for untyped tags / dump | element values |
| modify | `Dataset.set` / `setAll` / `setEmpty` / `remove` / `setRaw` (S1) | `DataElement`; `setEmpty` is a zero-length element |
| query | `sendCFind(Dataset)` (S3) | identifier: matching keys hold values, return keys are empty |

Every verb lands on a field. None is blocking.

## 2. Structural forks (confirmed 2026-10-16)

| Fork | Decision | Consequence if wrong |
|---|---|---|
| **Use-case ownership** | Parsing is owned by `DicomFile.fromBytes` (and the `File` extensions in `io.dart`); the `Dataset` owns its elements and their lazy-conversion state. `Association` sequences DIMSE operations and owns per-association state: message IDs, contexts, state machine. `ApplicationEntity` is immutable configuration. `StorageScp` owns the listener and the associations it accepts. | Call sites would juggle message IDs and context lookups themselves. |
| **Failure model** | Design D3 plus the PRD constraint: an open `DicomException` base with a sealed subtree per package (F30); `DimseStatus` returned as a value; a final Failure on a stream operation is a stream error (F33); lenient-read repairs go into `ReadReport`, not exceptions. | Every public signature changes. |
| **Boundary thickness** | `dart:io` types (`Socket`, `RandomAccessFile`, `ZLibCodec`) never cross into core or into net's protocol layers. They live only in adapters: `dartdicom/lib/src/io/` and `dartdicom_net/lib/src/transport/`. `package:http` types appear in web's public API only as the injected `http.Client`. | The protocol layers could not be tested without sockets, and the core would not compile for the web. |
| **Wiring and substitution** | Constructor or parameter injection with defaults that need no setup (`const ReadOptions()`). No DI container. Tests substitute `BytesSource`, `InMemoryTransport.pair()`, `MemorySink`, `MockClient`, and use `fake_async` for timers. | A seam that a test cannot substitute is not a seam. |
| **Tree axis** | Top level: one folder per package (design §3). Inside a package: one folder per component (design §4). | — |
| **Concurrency and atomicity** | One event loop per isolate; each association is an async task. Lazy conversion runs synchronously, so there is no interleaving across an `await`. The unit of atomicity is one PDU send (`await flush`), and an instance reaches the sink only once it is fully reassembled. On disk, `DirectorySink` writes to a temporary name and renames, so a stored file is either complete or absent (F25). Isolate offload (N-21) copies bytes in and gets a `Dataset` back. | Torn instances in the sink, or a stalled event loop that starves every other association's timers. |
| **Prescriptiveness** | Conceptual: names and responsibilities. Signatures are pinned only where the design doc pins them. | — |

## 3. Repository tree

```text
dartdicom/                        git root · pub workspace (github.com/Lightbridge-KS/dartdicom)
├── mise.toml                     dev toolchain pin: dart only (not the package floor; that is each pubspec's sdk:)
├── pubspec.yaml                  name: dartdicom_workspace · publish_to: none · workspace: [explicit list] (F8)
├── analysis_options.yaml         shared lints: package:lints/recommended + strict-casts/inference/raw-types
├── LICENSE                       MIT
├── README.md                     ecosystem overview, package table, and the pydicom → dartdicom mapping
├── llms.txt                      index for agents: links to each package's llms.txt (F31)
├── AGENTS.md  (CLAUDE.md → AGENTS.md)
├── justfile                      the front door: one recipe per workflow (dry, test, floor, pacs-up, …); recipes call scripts/
├── .pre-commit-config.yaml       fast subset: dart format, gitleaks, pre-commit-hooks
├── .github/workflows/            ci.yml (dry gates) · interop.yml (live gates) · publish.yml
├── dartdicom/                    core package
│   ├── lib/dartdicom.dart        the only pure public library
│   ├── lib/io.dart               native adapter entry point: File.readAsDicom/Sync, writeAsDicom/Sync, FileSource
│   ├── lib/src/tag/              Tag, One<T>, Many<T>; DicomTags (generated, typed: DA1; named by S6)
│   ├── lib/src/dictionary/       Dictionary value; generated tables
│   ├── lib/src/uid/              Uid, UID generation; TransferSyntax descriptors; SopClasses (generated)
│   ├── lib/src/vr/               Vr enum; per-VR converters and writers
│   ├── lib/src/charset/          CharsetResolver; single-byte codecs
│   ├── lib/src/errors.dart       DicomException (open base) + the sealed DicomDataException tree (F30)
│   ├── lib/src/dataset/          Dataset (+ its fromBytes/toBytes entry points, F38), DataElement, Sequence, ReadReport (F28)
│   ├── lib/src/file/             DicomFile, FileMetaInformation, file meta derivation (F38) *(amended)*
│   ├── lib/src/read/             ByteSource, SourceOpener, Parser, ReadOptions, repairs, deflate
│   ├── lib/src/write/            Writer, WriteOptions
│   ├── lib/src/redact/           Redactor; dump
│   ├── lib/src/io/               FileSource, ZLibDeflateCodec: the only dart:io in this package
│   ├── tool/gen_dictionary/      source.dart (release pin + SHA-256) · parse.dart · emit.dart · value_types.dart (I-19) · naming.dart (S4) → lib/src/**/*.g.dart (committed)
│   ├── test/                     includes architecture_test.dart, vs_pydicom_test.dart and compile_fail/ (I-24)
│   └── example/  README.md  llms.txt  CHANGELOG.md  LICENSE  pubspec.yaml
├── dartdicom_pixel/lib/src/      pixel_array/ · decode/ · lut/ · display/ · codec/
├── dartdicom_net/lib/src/        pdu/ · fsm/ · dul/ · acse/ · dimse/ · association/ (+ presentation_contexts.dart, F29) · scp/ · sink/ · transport/ · trace/ · errors.dart
│                                 every package root also has README.md (with the pydicom mapping) and llms.txt (F31)
├── dartdicom_web/lib/src/        client/ · qido/ · wado/ · stow/ · multipart/ · auth/
├── examples/                     workspace member, publish_to: none; depends on all packages; runnable end-to-end demos
├── fixtures/                     uv project (Python ≥ 3.13): `fixtures` CLI (typer) · src/dartdicom_fixtures/ · tests/ (pytest) · uv.lock
│   └── data/                     committed artifacts only: synthetic/ · pydicom/ · golden/ · PROVENANCE.md (all generated)
├── scripts/                      dry_gates.sh · test_all.sh · check_deps.sh · floor_check.sh · check_fixtures.sh (bash; CI calls these, so it needs no just)
├── docker/compose.yaml           stock Orthanc (DIMSE + DICOMweb): the minimal test PACS; host ports overridable
└── docs/                         req/ · design/ · structure/ · progress/
```

- The package folders sit at the repo root. That matches the existing folders and works without globs.
- **Toolchain (decided 2026-10-16):** mise pins only Dart, through `mise.toml`.
  - `dart` resolves through mise shims, activated in the login shell profile (`eval "$(mise activate zsh --shims)"`). Shims also work in non-interactive shells, such as agents and scripts.
  - Outside the repo, the shim falls back to the next `dart` on `PATH`.
  - Dart-Code can't follow a shim back to an SDK, so a gitignored `.vscode/settings.json` sets `dart.sdkPath` to the mise install.
  - Contributors without mise use any Dart at or above the floor.
  - **Task runner:** the root `justfile` fronts `scripts/`, which stay the implementation. CI and contributors without `just` run the scripts directly.
  - Rejected: FVM (it manages Flutter SDKs), and mise tasks (they would be a second task runner next to `just`).
- `examples/` is the only place where several packages meet. The packages themselves never depend on each other.
- **Fixtures (decided 2026-10-16):** small curated files are committed directly under a size budget, with no Git LFS. They come from three places:
  - **Synthetic.** `fixtures build` (pydicom, pinned in `fixtures/uv.lock`) builds 13 named scenarios from scratch into `fixtures/data/synthetic/`: signed HU vs unsigned + `RescaleIntercept −1024`, Implicit, Deflated and Big Endian variants, MONOCHROME1, multi-frame, RGB, Latin-1 and UTF-8 names, a missing `StudyDate`, undefined-length sequences, private tags. UIDs are name-based (`2.25.` + UUID v5) and dates fixed, so a re-run reproduces every byte.
  - **Curated copies.** 14 small files from pydicom's own bundled test data (MIT), copied from the pinned pydicom wheel into `fixtures/data/pydicom/`.
  - **Real-world corpora.** `fixtures corpus fetch` checks out pydicom-data at a pinned commit (and later public collections) into the user cache (`$DARTDICOM_CACHE`, else `$XDG_CACHE_HOME/dartdicom`, else `~/.cache/dartdicom`). Never committed.
  - **Golden.** `fixtures golden` exports pydicom's reading of every fixture (elements, recursively, plus pixel shape, dtype and SHA-256) into `fixtures/data/golden/`, for I-11.
  - `fixtures/data/PROVENANCE.md` is generated with each file's source and checksum. `fixtures check` rebuilds everything into a temporary directory and fails on any difference or extra file (I-28). The package is a uv project (`fixtures/`), checked by ruff, pyright and pytest through `scripts/check_fixtures.sh`.

  Rejected: Git LFS, and a separate fixtures repo.
- **Test PACS for the live gates:** any Orthanc-based PACS, chosen by environment variables (host, port, called AE title, and the app's own AE and port for C-MOVE). `docker/compose.yaml` is the minimal default. A richer external test PACS with a curated, messier corpus can stand in without changing any code.
  - **Default test ports**, chosen 2026-10-16 to avoid the 4242 / 8042 / 11112 that other local PACS and toys tend to hold. Each is overridable through an environment variable.

    | Port | Use | Variable |
    |---|---|---|
    | **14242** | DIMSE (called AE `ORTHANC`) | `ORTHANC_DIMSE_PORT` |
    | **18042** | REST and `/dicom-web/` | `ORTHANC_HTTP_PORT` |
    | **14112** | the app's Storage SCP, AE `DARTDICOM`, the C-MOVE destination | `DARTDICOM_SCP_PORT` |

## 4. Layers and the import matrix

Rows import columns. ✅ allowed · ❌ forbidden · — not applicable.

| Imports → | `dartdicom` | `dartdicom/io.dart` | pixel | net | web | `dart:io` | `package:http` | Flutter |
|---|---|---|---|---|---|---|---|---|
| `dartdicom` (pure lib) | — | ❌ | ❌ | ❌ | ❌ | ❌ | ❌ | ❌ |
| `dartdicom/io.dart` + `src/io/` | ✅ | — | ❌ | ❌ | ❌ | ✅ | ❌ | ❌ |
| `dartdicom_pixel` | ✅ | ❌ | — | ❌ | ❌ | ❌¹ | ❌ | ❌ |
| `dartdicom_net` | ✅ | ✅ | ❌ | — | ❌ | ✅² | ❌ | ❌ |
| `dartdicom_web` | ✅ | ❌ | ❌ | ❌ | — | ❌¹ | ✅ | ❌ |
| `examples/` | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ❌ |

¹ Allowed only behind a conditional import. ² Allowed only in `transport/`, `scp/` (the listener) and `sink/` (`DirectorySink`, F15). The protocol layers `pdu/ fsm/ dul/ acse/ dimse/` import no `dart:io`.

Two rules *inside* packages:

- In core, `dataset/` imports nothing from `read/` or `write/` (F13), except `dataset/dataset.dart` for `Dataset.fromBytes` / `toBytes` (F38). `read/` and `write/` never import `file/`. *(amended)*
- In net, layers import downward only: association → dimse/acse → dul → pdu.

**Enforcement.** A layering rule that is only written down is already broken, so each rule has a tool:

| Rule | Tool |
|---|---|
| package-level dependencies | `scripts/check_deps.sh` (yq over every `pubspec.yaml`) in CI, plus the `depend_on_referenced_packages` lint |
| no platform imports in core | `dartdicom/test/architecture_test.dart` scans `lib/` for `dart:io`, `dart:ffi`, `dart:html`, `dart:js_interop` and `package:flutter`, excluding `io.dart` and `src/io/` |
| web compatibility, end to end | `dart test -p chrome` and a `dart compile wasm` check fail if `dart:io` leaks into the web build |
| net's layering | `dartdicom_net/test/architecture_test.dart` |

## 5. Seams and collaborators

Interfaces exist only at real seams, and each has at least two implementations.

| Seam | Production | Test or alternative |
|---|---|---|
| `ByteSource` | `BytesSource` (all platforms) returns views; `FileSource` (io) returns owned copies (F19) | truncated or fuzzed `BytesSource`; browser prefix adapter |
| `SourceOpener` | `FileSourceOpener(path, size, modified)`, which throws `SourceChangedException` on a mismatch (F16); `BytesSourceOpener` | counting opener; an opener that reports a changed file |
| `DeflateCodec` | pure-Dart default (core), `ZLibDeflateCodec` (io) | each one reads the other's output |
| `CharsetResolver` | standard resolver | override for mislabeled data |
| `Transport` | `SocketTransport` | `InMemoryTransport.pair()`: SCU and SCP in one test, no sockets |
| `InstanceSink` | `DirectorySink` (net `sink/`): stores as received, UID-only paths, write then rename | `MemorySink` |
| `TraceSink` | none, or a logger adapter | capturing sink (used by the PHI canary test) |
| `DecoderPlugin` | RLE (P1), native and WASM codec packages (P2) | stub plugin |
| `http.Client` | `package:http` default | `MockClient` |

**Composition root.** The consuming app is the composition root. The library ships defaults that need no setup and has no global `init()`. The `examples/` package shows the full wiring for the first consumer:

`ApplicationEntity` → `associate` → `sendCFind` → `sendCGet(sink: DirectorySink)` → `File(path).readAsDicom()` → `pixels` → `DisplayBuffer`.

**One flow at object level: C-GET.**

1. `Association.sendCGet(query, sink)` builds `CGetRq` (dimse).
2. The `Fragmenter` splits it into PDVs for the peer's max PDU size.
3. `Dul.send` passes it through the state machine to `Transport.send`.
4. Incoming `PDataTf` PDVs go to the `Assembler`, which produces `CStoreRq`.
5. `sink.accept(ReceivedInstance(..., transferSyntax: context.ts))`, then `CStoreRsp` is sent.
6. `CGetRsp` (pending) becomes a `RetrieveProgress` on the stream.
7. The final `CGetRsp` (success) closes the stream.

## 6. Where a change lands

| Task | File (one obvious place) |
|---|---|
| Add a developer workflow | a `scripts/` script, plus a `justfile` recipe that calls it |
| Add a synthetic fixture scenario | a `@scenario` function in `fixtures/src/dartdicom_fixtures/scenarios.py`, then `just fixtures` |
| Bump the dev Dart SDK | `mise use dart@<version>` (rewrites `mise.toml`), plus the local `.vscode/settings.json` `dart.sdkPath` |
| Raise the package floor | `environment: sdk:` in every member's `pubspec.yaml`, plus the CI floor job's version |
| Refresh the dictionary to a new DICOM release | `dartdicom/tool/gen_dictionary/`, then regenerate `*.g.dart` |
| Fix how a VR's value is parsed or written, including DS/IS formatting | `dartdicom/lib/src/vr/` |
| Add or change an exception type | the package's `lib/src/errors.dart` (its sealed subtree, F30) |
| Change the keyword → identifier rule | `dartdicom/tool/gen_dictionary/naming.dart`, plus its golden test (I-26) |
| Add a preset context list | `dartdicom_net/lib/src/association/presentation_contexts.dart` |
| Update the pydicom mapping or agent docs | the package's `README.md` and `llms.txt` (the snippets must compile, I-25) |
| Change a VR's Dart type (the data §3.4 contract): a **major** version | the contract table in `dartdicom/tool/gen_dictionary/`, plus `vr/` |
| Change how values are byte-swapped when byte order changes | `dartdicom/lib/src/write/` |
| Change how file meta is derived or validated (I-17), or the implementation UID and version name | `dartdicom/lib/src/file/`, `dartdicom/lib/src/uid/implementation.dart` |
| Change the folder layout or naming of stored files | `dartdicom_net/lib/src/sink/` |
| Add a character set | `dartdicom/lib/src/charset/` |
| Add a lenient-read repair | `dartdicom/lib/src/read/repairs.dart` (and its `ReadReport` kind) |
| Add an uncompressed transfer syntax | `dartdicom/lib/src/uid/transfer_syntax.dart`: a descriptor (explicit VR? endianness, deflated, encapsulated) that both the reader and the writer read |
| Change PHI masking | `dartdicom/lib/src/redact/` |
| Add a PDU sub-item (e.g. user identity) | `dartdicom_net/lib/src/pdu/items.dart` |
| Fix a state-machine transition | `dartdicom_net/lib/src/fsm/table.dart` |
| Add a DIMSE service | `dartdicom_net/lib/src/dimse/messages.dart` plus an `Association` method |
| Add a pixel codec | its own package, or `dartdicom_pixel/lib/src/codec/<name>.dart`; registered by the caller |
| Change windowing or LUT behavior | `dartdicom_pixel/lib/src/lut/` |
| Add a DICOMweb endpoint | `dartdicom_web/lib/src/{qido,wado,stow}/` |

## 7. What is deliberately absent

- **No global `config`, `hooks` or registries** (pydicom's `config` and `hooks`, pynetdicom's `_config`), because Dart globals exist once per isolate (PRD constraint).
- **No `noSuchMethod` / dynamic attribute access** (PRD C-03).
- **No DI container or service locator.** Constructor parameters with defaults are enough.
- **No `IFoo` + `FooImpl` pairs.** An interface appears only at a seam in §5.
- **No `Clock` abstraction.** `fake_async` already controls Dart timers (ARTIM, DIMSE timeouts) in tests.
- **No async twin of the parser** (design D1).
- **No threads, queues or reactor polling** (pynetdicom). The event loop and streams do that job.
- **No barrel files** beyond each package's single public library, plus `io.dart`.
- **No Melos.** A pub workspace is enough; revisit if release automation needs it.
- **No Flutter app or dependency in this repo.** Flutter widgets come later, in a separate repo.

## 8. Invariants

★ means a tool checks it.

| # | Invariant | Checked by |
|---|---|---|
| I-1 ★ | Core `lib/` imports no `dart:io`, `dart:ffi`, `dart:html`, `dart:js_interop` or Flutter (excluding `io.dart` and `src/io/`) | `dartdicom/test/architecture_test.dart` |
| I-2 ★ | Core tests pass compiled to JS, and core compiles to Wasm | CI `dart test -p chrome`, `dart compile wasm` |
| I-3 ★ | Each package's `dependencies` are within its row of §4 | `scripts/check_deps.sh` in CI |
| I-4 ★ | No import of an undeclared package | `depend_on_referenced_packages` lint |
| I-5 ★ | `dataset/` imports nothing from `read/` or `write/`, except `dataset/dataset.dart` (F38); `read/` and `write/` import nothing from `file/` *(amended)* | architecture test |
| I-6 ★ | In net, only `transport/`, `scp/` and `sink/` import `dart:io` | `dartdicom_net/test/architecture_test.dart` |
| I-7 ★ | No top-level mutable variables (`var`, `late`, non-const `final`) in any `lib/` | architecture test (grep) |
| I-8 ★ | Generated files match the generator's output for the pinned release | `dart run tool/gen_dictionary/main.dart --check` in `.github/workflows/generated.yml` (on generator or output changes; the release XML is cached) |
| I-9 ★ | Element values never appear in exception messages, the default `toString`, trace output, or the `ReadReport` | PHI canary test: fixtures carry sentinel values; the test triggers errors and traces and asserts the sentinels are absent |
| I-10 ★ | Reading then writing an untouched file in the same transfer syntax gives byte-identical output | golden round-trip test |
| I-11 ★ | Every element agrees with pydicom on the fixture corpus | `vs_pydicom_test.dart` against `fixtures/data/golden/` |
| I-12 ★ | PDUs and command sets are byte-identical to pynetdicom's encoders | net golden test against pynetdicom-generated fixtures |
| I-13 ★ | The state table defines every (event, state) pair of PS3.8 Table 9-10 (19 × 13) | state-machine test |
| I-14 ★ | A lazily read `Dataset` with deferred values can be sent to another isolate | isolate test (F2) |
| I-15 ★ | `dart format` is clean and `dart analyze --fatal-infos` passes | CI and pre-commit |
| I-16 ★ | A release tag's version equals the package's `pubspec.yaml` version | `publish.yml` guard |
| I-17 ★ | A write fails when the meta's SOP UIDs differ from the dataset's, and the written (0002,0010) equals the encoding actually used | writer tests (F23) |
| I-18 ★ | A Big Endian fixture written as Little Endian gives the same pixel array (read by pydicom) as the original | golden test (F17) |
| I-19 ★ | The VR → Dart contract is unchanged: every `Vr` is listed with its expected Dart type | contract test (F18) |
| I-20 ★ | Store as received: the dataset bytes in a stored file equal the bytes received | net test over `InMemoryTransport` (F25) |
| I-21 ★ | Every path `DirectorySink` writes, relative to its root, matches `^[0-9.]+(/[0-9.]+)*\.dcm$` | sink test (F20) |
| I-22 ★ | No `lib/` uses temp-file or cache APIs (`Directory.systemTemp`, `createTemp`) | architecture test (grep) (F21) |
| I-23 ★ | Written DS values are ≤ 16 bytes and IS values ≤ 12 bytes | property test (F24) |
| I-24 ★ | Typed-tag misuse doesn't compile: a `Many` tag to `get`, a `One` tag to `getAll`, or the wrong value type | a negative compile test: `dart analyze` on `test/compile_fail/` expects exactly these `argument_type_not_assignable` errors (F27) |
| I-25 ★ | Every Dart snippet in the README and `llms.txt` files compiles against the current API | `scripts/check_snippets` extracts the fenced Dart blocks and analyzes them in `examples/` (F31) |
| I-26 ★ | Keyword → identifier: the golden edge cases hold (`SOPInstanceUID` → `sopInstanceUid`, digit runs, …), and no two keywords produce the same identifier | generator golden test plus collision check (F32) |
| I-27 ★ | Writing text the declared charset can't encode, or non-ASCII text with no (0008,0005), fails with a `DicomWriteException` that names the tag and suggests the fix | writer test (F35) |
| I-28 ★ | The committed fixtures, golden files and `PROVENANCE.md` reproduce exactly from the pinned tools | `fixtures check` via `scripts/check_fixtures.sh` (in the dry gates) |

## 9. CI and release

**Dry gates** (`ci.yml`, every PR, blocking). Run per package, with path filters; a change in `dartdicom/` tests every package.

- **Two SDK jobs.** The **pinned** job installs Dart from `mise.toml` with mise's GitHub Action, so local and CI can't drift. The **floor** job runs `dart-lang/setup-dart` at the lowest `sdk:` (3.6.x).
  - Language versioning only catches newer *language* features against the floor. Newer *core-library APIs* need this real floor run.
- format, analyze, `dart test -p vm`
- for core, pixel and web: `-p chrome` and the wasm compile check
- `check_deps`, the generated-files check, `dart pub publish --dry-run`

**Live gates** (`interop.yml`, nightly and manual, not on PRs):

- a test PACS chosen by environment variables (§3): `docker/compose.yaml` by default, or any richer Orthanc-based PACS
- DCMTK, plus pynetdicom from `uv`
- the `examples/` programs, run end to end as executable docs (F34)
- C-ECHO, C-FIND, C-GET, C-MOVE and C-STORE in both directions (PRD success criteria)

**Release.**

1. **Version source of truth:** each package's `pubspec.yaml`. The tag must equal it (I-16).
2. **Trigger:** pushing an annotated tag per package, matching the pub.dev automated-publishing tag pattern: `dartdicom-v{{version}}`, `dartdicom_pixel-v{{version}}`, `dartdicom_net-v{{version}}`, `dartdicom_web-v{{version}}`. `workflow_dispatch` is the escape hatch.
3. **Who drafts:** CI drafts the GitHub release from that package's CHANGELOG section, and a human reviews and publishes it.
   - The pub.dev publish job authenticates with GitHub OIDC.
   - It runs in a protected `pub.dev` environment that requires reviewer approval.
   - Prerelease versions (`0.1.0-dev.N`) stand in for staging.
   - The core is published before the packages that depend on it.
   - Packages start under an individual uploader; a verified publisher (which needs a domain) can come later.

## 10. Upstream amendments

Structural amendments are applied in place and marked *(amended)*. Behavioral ones are raised as questions instead.

| Entry | Overrides | Kind | Status |
|---|---|---|---|
| F10: the sink receives the negotiated transfer syntax | PRD N-11; design §5.2 and §6.2 (`InstanceSink.accept`) | structure | applied |
| F8: workspace members listed explicitly | PRD constraint *Toolchain* | structure | applied |
| F14: cancel = cancelling the stream subscription | design §5.2 (no `cancel()` method) | structure | consistent; no change needed |
| F16: `SourceOpener` is an immutable value that checks size and modification time | design §7 | structure | applied |
| F15: `sink/` added to net's `dart:io` allowance | this doc, §4 and I-6 | structure | applied |
| F27: typed tags reshape the `Dataset` reads | design D2, PRD C-03 and its success criterion, data §3.4 | **behavior** (public API) | raised as DA1; decided 2026-10-16; applied |
| F30: an open exception base plus a sealed subtree per package | design §5.2, surface §5 | structure | applied |
| F33: a final Failure on a stream is a stream error | design D3 and §5.2 | behavior | raised as S5; decided 2026-10-16; applied |
| F35: how to write non-ASCII text when no Specific Character Set is present | data §3.4, surface §4.2 | **behavior** | decided 2026-10-16: the write fails, with a message saying how to fix it. Rejected: adding ISO_IR 192 automatically. Applied. |
| F38: `file/` for `DicomFile`; `Dataset.fromBytes` / `toBytes`; I-5 narrowed | this doc §3, §4, I-5; surface §2 | **behavior** (public API) | decided 2026-10-17; applied |
| F39: `DirectorySink` parses the header for its path | data §4.2 | structure | applied |
