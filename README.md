# dartdicom

Pure-Dart DICOM packages: read, modify, write, display and exchange DICOM data on every Dart platform, with no native toolchain.

> **Status: pre-release.** Nothing is published yet. The design lives in [`docs/`](docs/), starting with the [requirements](docs/req/dartdicom-prd.md).

| Package | What it does | Platforms |
|---|---|---|
| [`dartdicom`](dartdicom/) | Data model; Part 10 read and write; dictionary, tags, UIDs, charsets | all |
| [`dartdicom_pixel`](dartdicom_pixel/) | Pixel Data → typed arrays, LUTs, an 8-bit display buffer | all |
| [`dartdicom_net`](dartdicom_net/) | DIMSE networking: C-ECHO, C-FIND, C-GET, C-MOVE, C-STORE | native |
| [`dartdicom_web`](dartdicom_web/) | DICOMweb client: QIDO-RS, WADO-RS, STOW-RS | all |

Not a medical device; not for diagnostic use.

## Development

- **Dart:** any SDK at or above the package floor (`^3.6.0`). The dev toolchain is pinned in [`mise.toml`](mise.toml); run `mise install` if you use [mise](https://mise.jdx.dev).
- **Workspace:** `dart pub get` (or `just get`) at the repo root resolves every package.
- **Commands:** the root [`justfile`](justfile) lists every workflow (`just`, or `just --list`). The most used:
  - `just dry`: the dry gate suite
  - `just test`: tests
  - `just floor`: the Dart 3.6 floor check
  - `just pacs-up`: start the test PACS
- **Without `just`:** each recipe calls a script in [`scripts/`](scripts/), which runs on its own (`scripts/dry_gates.sh`, `scripts/test_all.sh`, …). CI uses the scripts directly.
- **Test data:** [`fixtures/`](fixtures/) is a small uv project with a `fixtures` CLI (`just fixtures`, `just fixtures-check`); see its README.

## License

[MIT](LICENSE)
