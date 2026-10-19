# dartdicom

Pure-Dart DICOM packages: read, modify, write, display and exchange DICOM data on every Dart platform, with no native toolchain.

> **Status: pre-release.** GitHub-only prereleases; the packages are not published on pub.dev. The design lives in [`docs/`](docs/), starting with the [requirements](docs/req/dartdicom-prd.md).

| Package | What it does | Platforms |
|---|---|---|
| [`dartdicom`](dartdicom/) | Data model; Part 10 read and write; dictionary, tags, UIDs, charsets | all |
| [`dartdicom_pixel`](dartdicom_pixel/) | Pixel Data → typed arrays, LUTs, an 8-bit display buffer | all |
| [`dartdicom_net`](dartdicom_net/) | DIMSE networking: C-ECHO, C-FIND, C-GET, C-MOVE, C-STORE | native |
| [`dartdicom_web`](dartdicom_web/) | Scaffold only; no public DICOMweb API yet | — |

Not a medical device; not for diagnostic use.

## Use from GitHub

Until the packages are on pub.dev, depend on them from this repository with a `git` dependency for each package you use. `dartdicom_web` is still a scaffold, so leave it out.

```yaml
dependencies:
  dartdicom:
    git:
      url: https://github.com/Lightbridge-KS/dartdicom.git
      path: dartdicom
      ref: v0.1.0-dev.2
  dartdicom_pixel:
    git:
      url: https://github.com/Lightbridge-KS/dartdicom.git
      path: dartdicom_pixel
      ref: v0.1.0-dev.2
  dartdicom_net:
    git:
      url: https://github.com/Lightbridge-KS/dartdicom.git
      path: dartdicom_net
      ref: v0.1.0-dev.2

# Required: dartdicom_pixel and dartdicom_net depend on dartdicom from
# pub.dev, and pub takes a package from only one source.
dependency_overrides:
  dartdicom:
    git:
      url: https://github.com/Lightbridge-KS/dartdicom.git
      path: dartdicom
      ref: v0.1.0-dev.2
```

- **The override is required.** Without it, `dart pub get` (or `flutter pub get`) fails with "dartdicom_net from git is forbidden".
- **Pin `ref`** to a commit or a tag, the same one in every entry, so every machine builds the same code. `pubspec.lock` records the exact commit. To move on, change `ref` and run `dart pub upgrade`.
- **Working on dartdicom and an app side by side:** put `path:` entries for the same packages in a `pubspec_overrides.yaml` next to the app's `pubspec.yaml`, and keep that file out of git. It points the app at your local checkout while `pubspec.yaml` keeps the git entries for everyone else.
- **SDK:** Dart `^3.6.0`, or a Flutter whose bundled Dart is at least 3.6. `dartdicom_net` runs on native platforms only.

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
