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
- **Workspace:** `dart pub get` at the repo root resolves every package.
- **Dry gates:** `dart format --output=none --set-exit-if-changed .`, `dart analyze --fatal-infos`, `tool/check_deps.sh`, `tool/test_all.sh`.

## License

[MIT](LICENSE)
