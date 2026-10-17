---
summary: Core tests refactor. dartdicom/test mirrors lib/src, the whole-library gates move to test/gates/, the two curated lists become Dart, and fixture loading and byte building are shared. Every test keeps running, and every gate keeps its entry point.
read_when:
  - Planning or executing the core tests refactor; reviewing its evidence
  - Deciding where a new core test, gate or curated list goes
status: in progress
date: 2026-10-18
---
# Core tests refactor

Parent: [overview](../overview-v0.md) · Design: [codebase blueprint](../../structure/01-codebase-blueprint.md) §3, §6, §8

`dartdicom/test/` had 15 files at its root. They mixed unit tests of one `lib/src` folder with whole-library gates over the fixtures and corpora, and the two human-curated lists sat beside them as `.txt` files. Only `read/`, `vr/` and `tool/` mirrored the code.

Target:

```text
test/
├── tag/ dictionary/ uid/ vr/ source/ dataset/ read/ write/ file/ io/   one folder per lib/src folder (io/: lib/io.dart + src/io/)
├── tool/       the generator (tool/gen_dictionary/)
├── gates/      whole-library claims over the fixtures and corpora: architecture, round trip (I-10),
│               vs pydicom and corpus (I-11), written files, fuzz (I-30), PHI canary (I-9);
│               expected.dart holds the curated lists
└── support/    shared helpers, no _test.dart
```

- [x] **T1 + T2** (`b43fabc`). Move the tests into the mirrored folders and `gates/`. Move `writer_test.dart`'s file-meta groups (I-17, implementation identity) into `file/dicom_file_test.dart`, with the two I-17 groups as one. Pure moves.
- [x] **T3 (option B)** (`9f45b24`). `corpus_expected.txt` and `dcmdump_allowlist.txt` become const records in `gates/expected.dart`, so a reason is required by the type. Both line parsers go away.
- [x] **T4** (this commit). `support/fixtures.dart` holds the fixture root, `fixtureSet`, `fixture`/`readFixture`/`fixtureDirectory`, `fixtureName` and `goldenRecords`. It replaces the root path written 16× in 9 files, three fixture listings, two golden listings and the duplicated `_fixture` loader. `goldenRecords` lives here, not in `golden.dart`, so `golden.dart` stays free of `dart:io`.
- [ ] **T5.** Explore `support/bytes.dart`: one byte-building kit, shared by `lenient_test` and `phi_canary_test`.

Preserve:
- Every test still runs: the same names on the VM and on node, except the I-17 tests that T2 regroups.
- The gates' entry points: `scripts/fuzz.sh`, `scripts/written_gate.sh` and the CI `corpus` job.
- The ratchet works both ways: an unlisted failure fails, and a listed file that passes fails.
- The DCMTK allowlist still matches on the version prefix and the regex.
- A test never borrows the library rule it checks (T5).

Proof:
- T1 + T2: test-name lists diffed before and after; `just dry`, `just fuzz`, `just written --corpus`, the corpus test.
- T3: the corpus test and the written gate, and a planted entry that still trips the ratchet.

## Evidence

Baseline at `beca601`: 350 test names on the VM (349 pass, 1 skipped: the written gate, run by its script) and 174 on node.

T1 + T2 (`b43fabc`): the same 350 names on the VM and 174 on node. Only the two tests of the old "I-17: the meta follows the dataset" group are renamed, now under "file meta is derived from the dataset (I-17)". `just dry`, `just fuzz`, `just written --corpus` and the corpus test (85 of 85) pass from their scripts at the new paths.

T3 (`9f45b24`): the Dart regex is identical to the `.txt` one, after that parser's whitespace join. Planting a passing corpus file in `corpusExpectedFailures` fails the corpus test ("these now pass"). Emptying `dcmdumpAllowlist` fails `just written --corpus` on the CP-246 warning, while the fixture-only gate never raises it.

T4: the same 350 names on the VM. `just fuzz` at the default seed gives identical counts (mutated 85,465 read / 14,545 refused; force 97,175 / 2,830), so the seed order held. `just dry`, `just written --corpus` and the corpus test (85 of 85) pass.

On completion: set `status: complete`, then ask whether to prune this tracker.
