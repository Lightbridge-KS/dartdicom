---
summary: Requirements for dartdicom, a family of pure-Dart DICOM packages (core data model, pixel decoding, DIMSE networking, DICOMweb). Covers the problem, users, goals and non-goals, prioritized capabilities with requirement IDs, constraints, and success criteria. The first consumer is a Flutter desktop tool that queries and retrieves from a PACS.
read_when:
  - deciding what a dartdicom package must or must not do, or at what priority
  - writing a design doc, milestone, or test that cites a requirement ID (C-, X-, N-, W-)
  - judging whether a feature request is in scope
---

# dartdicom: requirements

Status: draft, 2026-10-16. Edited in place as requirements change.
Repository: `github.com/Lightbridge-KS/dartdicom` (public, personal open source). Owner: @Lightbridge-KS.
Packages: `dartdicom` · `dartdicom_pixel` · `dartdicom_net` · `dartdicom_web`.
Architecture and repository strategy will live in `docs/design/` and `docs/structure/`, and the roadmap in `docs/progress/`.

## Problem

Dart has no general-purpose, permissively licensed DICOM toolkit. pub.dev survey, 2026-10-16:

| Package | Approach | License | Gap |
|---|---|---|---|
| `dicom_toolkit` | Rust core via FFI/WASM, plus a Flutter viewer | GPL-3.0 | Reads and renders only. No writing, no networking. |
| `flutter_dicom` | Rust core via flutter_rust_bridge | GPL-3.0 | Flutter only, and needs the Rust toolchain |
| `dicom_parser` | Pure Dart | AGPL-3.0 | Discontinued |
| `dicom_web` | Dart | MIT | Reads files and DICOM JSON only |

What's missing:

1. A data model that can both read and write DICOM.
2. DIMSE networking. No Dart package can send a C-ECHO, C-FIND or C-STORE.
3. A substantial DICOMweb client.
4. A permissive license.
5. Verification against a reference implementation.

## Users

**First consumer:** a Flutter desktop tool (macOS, Windows, Linux) that queries a PACS and retrieves studies over DIMSE. Its needs decide what is P0.

| Persona | Typical use | Packages |
|---|---|---|
| Flutter desktop developer | Query and retrieve from a PACS, inspect headers, display images, save instances to disk | core, net, pixel |
| Dart backend / CLI developer | Anonymizer, router, or inference gateway that receives C-STORE | core, net |
| Flutter mobile / web developer | Open a file, read its header, render a frame | core, pixel |
| Web developer | Search and retrieve over DICOMweb | core, web |
| Learner | Read DICOM internals in plain Dart | core |

**Today.** A Flutter desktop tool that has to talk to a PACS has three options:

- shell out to DCMTK (`findscu`, `getscu`, `movescu`)
- run a Python (pynetdicom) or C# (fo-dicom) sidecar
- route through a server

Each option adds a second runtime that must be bundled, versioned and supported on three desktop operating systems. On the Dart side there is still no data model for the results.

**What retrieval demands of a desktop app.**

- **C-MOVE** makes the PACS open a *new* association back to the tool. The tool therefore has to run a Storage SCP on a reachable, fixed port. That port must be allowed through the desktop firewall, and the PACS must have the tool's AE title registered.
- **C-GET** returns the instances over the same association, with no inbound port. PACS support for it varies.
- Both paths are required.

## Goals

- **G1** A Flutter desktop app can C-ECHO, C-FIND and retrieve from a PACS in pure Dart, with no sidecar runtime. Retrieval works either through C-GET, or through C-MOVE plus an embedded Storage SCP. The app can then display the retrieved images.
- **G2** Part 10 files can be read, modified and written faithfully. Elements that weren't touched come out byte-identical, and pydicom and DCMTK can read the output.
- **G3** One core package runs on every Dart platform: VM, Flutter native, and the browser (JS and Wasm).
- **G4** Correctness is measured against reference implementations, not asserted.
- **G5** The API is statically typed, so the compiler and IDE catch tag and type mistakes. Its concepts (`Dataset`, `DataElement`, `Tag`, `Sequence`) and its network vocabulary (`sendCFind`, …) are familiar to pydicom and pynetdicom users. File entry points follow Dart conventions, and a pydicom → dartdicom mapping is documented. *(amended: [design D4](../design/01-system-architecture.md#9-decisions-needed))*
- **G6** MIT license.

## Non-goals

These apply to the whole ecosystem:

- viewer applications; PACS, VNA or router products
- 3D, MPR and volume rendering
- AI inference
- building derived IODs such as SEG, SR or KOS (highdicom's layer)
- clinical certification
- DIMSE in browsers, which have no raw TCP
- HL7 v2 and FHIR
- Flutter widgets, which belong in a later, separate package

## Capabilities

Priority key:

- **P0**: needed by the first consumer
- **P1**: next
- **P2**: later

### `dartdicom`: core data model and file I/O (≈ pydicom)

| ID | Capability | Pri |
|---|---|---|
| C-01 | **Tag** type with no runtime cost. Gives group and element, detects private tags, and can be built from an `int` or a (group, element) pair. | P0 |
| C-02 | **Data dictionary** generated from a pinned DICOM release: PS3.6 data elements plus PS3.7 command elements, including repeater masks (`50xx`, `60xx`). Maps tag ⇄ keyword ⇄ VR ⇄ VM ⇄ name ⇄ retired. | P0 |
| C-03 | **Generated tag constants** for every keyword (e.g. `DicomTags.patientName`; *amended: [surface S6](../design/03-surface-architecture.md#8-decisions)*). The IDE can list them, and tree-shaking removes the unused ones. Each constant carries its value type and multiplicity, so a wrong read (e.g. a single value from a multi-valued attribute) is a compile error. *(amended: [data DA1](../design/02-data-architecture.md#34-the-vr--dart-type-contract))* Keyword-string lookup exists as a secondary path. There is no dynamic (`noSuchMethod`) access. | P0 |
| C-04 | All **VRs** of the current standard, including OV, SV, UV, UC, UR and UT. | P0 |
| C-05 | **Lazy elements.** An element stays raw after reading and is converted on first access. The result is cached. | P0 |
| C-06 | **Dataset**, kept in tag order. Typed reads separate *required* values (a missing value throws, naming the tag but never the value) from *optional* ones (null). Supports mutation, deletion, iteration, nested sequences and private blocks. | P0 |
| C-07 | **File = file meta + dataset**, held as separate parts. On write, the SOP Class and Instance UIDs in the meta and in the dataset are checked or derived so they cannot silently diverge. | P0 |
| C-08 | **Read** Part 10 files and raw datasets: preamble and `DICM` prefix, group 0002, and these transfer syntaxes: Implicit VR LE, Explicit VR LE, Deflated Explicit VR LE, and Explicit VR BE (retired; read-only). Handles defined and undefined lengths and nested SQ. | P0 |
| C-09 | **Read options:** stop before Pixel Data, defer values above a size threshold, read only specific tags, and force-read a file with no preamble. | P0 |
| C-10 | **Lenient reading of real-world data:** <br>• resolve ambiguous VRs (US/SS, OB/OW, …) from context <br>• detect a missing or wrong transfer syntax from the bytes <br>• handle UN whose real VR is known, and UN with undefined length <br>• handle values with the wrong length <br>• return a truncated file as a partial dataset <br>Every repair is reported, never silent. | P0 |
| C-11 | **Write** datasets and files in any supported uncompressed transfer syntax. Untouched elements are copied byte for byte. File meta is generated and validated. Writing is strict: an invalid encoding is refused. | P0 |
| C-12 | **Character sets:** the default repertoire, `ISO_IR 100` (Latin-1) and `ISO_IR 192` (UTF-8). | P0 |
| C-13 | **Other single-byte character sets** (Latin-2 to -9, Cyrillic, Greek, Arabic, Hebrew, Thai). Also a caller-supplied override or fallback for data with the wrong charset label. | P1 |
| C-14 | **ISO 2022 code extensions**, including multi-byte sets (CJK). | P2 |
| C-15 | **Value types:** <br>• PersonName with its components and groups <br>• DA, TM and DT converted to and from Dart dates <br>• DS and IS keeping their original text <br>• multi-valued elements and AT | P1 |
| C-16 | **UIDs:** a registry of well-known UIDs (transfer syntaxes, SOP classes) as generated constants, UID generation under a prefix, and validation. | P0 |
| C-17 | **DICOM JSON model** (PS3.18 Annex F), with BulkDataURI hooks. | P1 |
| C-18 | **Encapsulation**, structure only: fragments, Basic and Extended Offset Tables, frame iteration. | P1 |
| C-19 | **Conversion hooks** for VR resolution and value conversion, e.g. to fix vendor quirks or mask PHI while reading. Hooks apply only to the read call they are passed to. | P1 |
| C-20 | **Native file helpers:** read and write by path. Reading uses a random-access source, so a header-only read of a large file doesn't load the whole file. | P0 |
| C-21 | **Readable dump**, like `pydicom show`. PHI is masked unless the caller opts in. | P1 |
| C-22 | **De-identification** to the PS3.15 Annex E Basic Profile. | P2 |
| C-23 | **DICOMDIR / File-set** read and write. | P2 |

### `dartdicom_pixel`: Pixel Data to numbers (≈ pydicom `pixels`)

The first consumer displays images, so uncompressed decoding and display windowing are P0. It can propose only uncompressed transfer syntaxes and let the PACS decompress. That is why compressed codecs can wait.

| ID | Capability | Pri |
|---|---|---|
| X-01 | **PixelArray**: a typed-data buffer plus shape (frames, rows, columns, samples) and dtype. It is a zero-copy view where the bytes allow. | P0 |
| X-02 | **Native (uncompressed) decoding:** <br>• BitsAllocated 1, 8, 16 and 32 <br>• signed pixels <br>• sign extension when BitsStored < BitsAllocated <br>• PlanarConfiguration <br>• multi-frame | P0 |
| X-03 | **Reachable from a Dataset.** Pixel access is called on a Dataset, but the core itself contains no pixel code. | P0 |
| X-04 | **LUTs:** <br>• Modality LUT: a rescale to HU, or the Modality LUT Sequence <br>• VOI LUT: a window (linear, linear exact or sigmoid), or the VOI LUT Sequence <br>• MONOCHROME1 inversion <br>• For enhanced multi-frame images, each frame's own rescale and window, from its functional groups <br>*(amended: [blueprint F44](../structure/01-codebase-blueprint.md#1-reconciliation-findings))* | P0 |
| X-05 | **Codec plugin interface**, registered per transfer syntax; the first available codec wins. The registry belongs to the caller or instance, not to the process. | P1 |
| X-06 | **Pure-Dart RLE Lossless.** Deflate comes from the core. | P1 |
| X-07 | **8-bit display buffer** after VOI, ready for PNG encoding or a Flutter `Image`. | P0 |
| X-08 | **Color:** RGB, YBR_FULL, YBR_FULL_422 and PALETTE COLOR. | P2 |
| X-09 | **Pure-Dart JPEG Baseline.** | P2 |
| X-10 | **Native or WASM codecs** (JPEG Lossless, JPEG-LS, JPEG 2000/HTJ2K) as separate opt-in packages. | P2 |
| X-11 | **Encoding:** RLE, plus compression for derived images. | P2 |

### `dartdicom_net`: DIMSE networking (≈ pynetdicom), client first

| ID | Capability | Pri |
|---|---|---|
| N-01 | **PDU layer:** all 7 PDU types. User Information items: max PDU length, implementation UID and version, SCP/SCU role selection (needed for C-GET), asynchronous operations window. | P0 |
| N-02 | **Upper Layer state machine** (PS3.8: Sta1–Sta13, Evt1–Evt19, ARTIM timer), driven by a table and testable without sockets. | P0 |
| N-03 | **Presentation context negotiation.** By default, the client proposes uncompressed transfer syntaxes. | P0 |
| N-04 | **PDV fragmentation and reassembly.** `dartdicom` decodes datasets straight from the reassembled bytes. | P0 |
| N-05 | **Association API:** requested contexts, associate, release, abort. A failed association or operation is an exception or a typed result, never an empty or falsy value. | P0 |
| N-06 | **C-ECHO** SCU. | P0 |
| N-07 | **C-FIND** SCU (Patient Root and Study Root), with results delivered as a stream, plus C-CANCEL. | P0 |
| N-08 | **C-GET** SCU, including receiving the C-STORE sub-operations on the same association. | P0 |
| N-09 | **C-MOVE** SCU, plus an **embedded Storage SCP** as the move destination. It binds a configured port and accepts only from configured peers. | P0 |
| N-10 | **C-STORE** SCU. | P0 |
| N-11 | **Per-instance hand-off.** Each received instance goes to a caller-supplied sink, such as a disk file, so a study is never buffered whole in memory. The sink also receives the transfer syntax negotiated for that instance, so it can write valid file meta. *(amended: [blueprint F10](../structure/01-codebase-blueprint.md#1-reconciliation-findings))* | P0 |
| N-12 | **Retrieve progress:** remaining, completed, failed and warning sub-operation counts, emitted as events a UI can show. | P0 |
| N-13 | **Timeouts** (ACSE, DIMSE, network, connection), plus cancellation, graceful release and abort. | P0 |
| N-14 | **Protocol trace by layer** (DIMSE, then PDU and state machine, then hex), with PHI redacted by default. | P0 |
| N-15 | **General SCP:** typed handlers for incoming C-ECHO, C-STORE, C-FIND, C-GET and C-MOVE, with concurrent associations. | P1 |
| N-16 | **User identity negotiation.** | P1 |
| N-17 | **Streaming a single very large instance** straight to a file while it is received. | P2 |
| N-18 | **Modality Worklist** C-FIND. | P2 |
| N-19 | **TLS** (DICOM secure transport profiles). | P2 |
| N-20 | **N-services:** Storage Commitment and MPPS. | P2 |
| N-21 | **Decoding on a worker isolate.** | P2 |

### `dartdicom_web`: DICOMweb client (≈ dicomweb-client)

The first consumer doesn't need this package, so all of it is P1 or later.

| ID | Capability | Pri |
|---|---|---|
| W-01 | **Client** built on `package:http` with an injectable HTTP client. Runs on the VM, in Flutter and in the browser. | P1 |
| W-02 | **QIDO-RS** search for studies, series and instances. Results are always `Dataset`s, never raw JSON maps. | P1 |
| W-03 | **WADO-RS:** instance, series and study, plus metadata, frames, bulk data and rendered images. | P1 |
| W-04 | **Streaming `multipart/related` parsing** of responses. | P1 |
| W-05 | **STOW-RS.** In browsers the request body is held in memory, because `package:http` doesn't stream request bodies there. | P1 |
| W-06 | **Auth hooks** (bearer/OAuth2 token provider, basic auth, custom headers). Retry is opt-in and bounded. | P1 |
| W-07 | **WADO-URI** (legacy). | P2 |
| W-08 | **UPS-RS** and capabilities discovery. | P2 |
| W-09 | **Server-side helpers.** | P2 |

## Constraints

- **Platforms.** `dartdicom` imports no `dart:io`, `dart:ffi` or Flutter. It passes its tests on the VM and compiles for JS and Wasm. Only `dartdicom_net` may use `dart:io` unconditionally.

  | Package | Dart VM | Flutter native | Browser (JS / Wasm) |
  |---|:---:|:---:|:---:|
  | `dartdicom` | ✅ | ✅ | ✅ |
  | `dartdicom_pixel` | ✅ | ✅ | ✅ pure-Dart codecs only |
  | `dartdicom_net` | ✅ | ✅ | ❌ |
  | `dartdicom_web` | ✅ | ✅ | ✅ needs CORS on the server |

- **Layering.** `dartdicom` depends on no other ecosystem package. The other three depend on `dartdicom` only, never on each other. No package depends on Flutter.
- **No shared global state.** No package keeps mutable global state. Configuration, hooks and codec registries are set per call or per instance. They behave the same in every isolate, because Dart globals exist once per isolate.
- **64-bit numbers on the web.** 64-bit values (SV, UV, OV, 64-bit offsets) must be correct under dart2js. There, integers are exact only to 53 bits and `ByteData.getInt64` is unavailable.
- **Memory.** Header-only reads don't load Pixel Data. Value conversion is lazy and large values can be deferred.
- **PHI.** Element values never appear in logs, exception messages or the default `toString`. They show up only when the caller explicitly opts in.
- **Untrusted input.** Parsing checks every declared length against the bounds. The file reader and the PDU decoder are fuzz-tested.
- **Errors.** Errors are a typed exception hierarchy. A failure is never reported as an empty or falsy value.
- **Licensing.** MIT, matching the pydicom and pynetdicom code the design derives from. In addition:
  - code derived from pydicom or pynetdicom keeps their MIT notices
  - native codec licenses stay with their own packages
  - where each test fixture came from is documented
- **Toolchain.** Dart ≥ 3.6, for pub workspaces. Workspace members are listed explicitly, because glob patterns need Dart ≥ 3.11. *(amended: [blueprint F8](../structure/01-codebase-blueprint.md#1-reconciliation-findings))* `dart format` and `dart analyze` must be clean, and each package scores 160/160 pub points.
- **Regulatory.** Not a medical device, and not for diagnostic use.

## Success criteria

- **Fidelity.**
  - Every element agrees with pydicom 3.x across the supported fixture corpus.
  - There are no known data-corrupting bugs.
  - pydicom and DCMTK can read every file the library writes. Where it applies, the file also passes `dciodvfy` (dicom3tools), checked before the 0.1.0 release *(amended 2026-10-17: dciodvfy moved from M2 to M5)*.
- **Interop.** C-ECHO, C-FIND, C-GET, C-MOVE and C-STORE pass against Orthanc, DCMTK and pynetdicom.
- **First consumer.** On each desktop OS it ships on, the Flutter desktop tool queries a real PACS, retrieves a study and displays its images, with no sidecar runtime.
- **Platforms.** The core's tests pass on the VM, and the core compiles for JS and Wasm.
- **Developer experience.**
  - A pydicom user finishes the read–modify–write and echo–find–retrieve quick-starts in under 10 minutes.
  - A misspelled tag name is a compile error, and so is reading one value from a multi-valued attribute.

## Prior evidence

Two unpublished learning prototypes show the approach works:

- **A Dart port of pydicom's core** (about 2,400 lines):
  - its 74 tests include element-by-element comparison with pydicom 3.0.2 on 7 files, and sha256 comparison of 12 pixel arrays
  - its core passes the same tests compiled to JavaScript
- **A Dart port of pynetdicom's core** (about 1,200 lines):
  - its PDUs and command sets are byte-identical to pynetdicom 3.0.4's encoders
  - it completed C-ECHO and C-STORE in both directions with pynetdicom and Orthanc 1.12.2

These prototypes are evidence and reference code. They are not the codebase to grow from: the packages are built from their own design.

The full ~5,100-entry data dictionary adds about 80 KB, gzipped, to a dart2js build (measured 2026-10-16). Size is therefore not a constraint on including the whole dictionary.

## Open questions

- Which PACS products must the first consumer work with, and do they support C-GET? The answer decides whether C-GET or C-MOVE is the default retrieve path.
- Which public test files can the public repository redistribute? Candidates: pydicom-data, NEMA WG samples, TCIA subsets.
- Which DICOM release should the dictionary pin to, and how often should it be refreshed?

**Deferred to design** (recorded here so they aren't lost):

- the parser's sync/async boundary for asynchronous sources (browser `Blob`, HTTP Range)
- package layout and repository tooling
- whether decoding moves to a worker isolate by default
- the names of the top-level entry points
