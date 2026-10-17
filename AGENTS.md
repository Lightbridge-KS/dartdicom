# dartdicom

Pure-Dart DICOM packages in one pub workspace: `dartdicom` (core), `dartdicom_pixel`, `dartdicom_net`, `dartdicom_web`, plus the unpublished `examples/`.

## Read first

- `docs/req/dartdicom-prd.md`: what and for whom, with requirement IDs (C-, X-, N-, W-).
- `docs/design/`: `01` system, `02` data, `03` developer and agent surface. Each records its decisions in place.
- `docs/structure/01-codebase-blueprint.md`: the tree, the import matrix, seams, where a change lands, and the invariants (I-n).
- `docs/progress/overview-v0.md`: milestones, Now/Next, open questions.

## Toolchain

- Dart is pinned in `mise.toml` for development; the package floor is `sdk: ^3.6.0`. If `dart --version` doesn't show the pinned version, use `mise exec -- dart …`.
- `dart pub get` at the root resolves every member.
- Code is at language version 3.6, so `dart format` uses the pre-3.7 style. Don't hand-format against it.

## Commands

The root `justfile` is the front door; `just --list` shows every recipe. Recipes call `scripts/*.sh`, and CI calls those scripts directly.

- `just dry`: the dry gates (format, analyze, dependency rules, VM and web tests, the Wasm compile, publish dry-runs). Use `just dry chrome` for browser tests.
- `just floor`: replays the CI floor job (Dart 3.6) on a temporary copy of the tree.
- `just test` / `just test-web` / `just analyze` / `just fmt` / `just hooks`.
- `just pacs-up` / `pacs-seed` / `pacs-echo` / `pacs-down`: the Orthanc test PACS (DIMSE 14242, HTTP 18042).
- `just live`: the live gates against that PACS (live tests and the `examples/` programs). CI runs them on demand (`interop.yml`).
- `just fixtures` / `just fixtures-check`: regenerate or verify the test data (`fixtures/`, a uv project with a `fixtures` CLI).
- Add a new workflow as a `scripts/` script plus a recipe, not as a long recipe body.

## Rules

Each rule is checked by a test or tool; see blueprint §8.

- Core `lib/` imports no `dart:io`, `dart:ffi`, web or Flutter libraries (I-1). Package dependencies follow blueprint §4 (I-3).
- `lib/` has no top-level mutable state, no `print()`, and no temp files or caches (I-7, I-22).
- Element values never appear in logs, exception messages or `toString` (I-9). Test data is synthetic or MIT-licensed public data, never clinical data.
- Naming: use Dart's convention where Dart has one, and the DICOM vocabulary where it doesn't (design §6, surface §6).
- A change to a settled decision is edited into its doc in place and marked *(amended)*. A change to *behavior* goes to the maintainer as a question first.
