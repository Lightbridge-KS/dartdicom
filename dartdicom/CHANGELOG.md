# Changelog

## [Unreleased]

## [0.1.0-dev.2] - 2026-10-19

GitHub-only prerelease; not published on pub.dev.

### Changed

- Coordinate the GitHub-only package version with `dartdicom_net` 0.1.0-dev.2.
  Core runtime behavior is unchanged from 0.1.0-dev.1.

## [0.1.0-dev.1] - 2026-10-18

First pre-release, from GitHub as tag `v0.1.0-dev.1` (see the repository README, *Use from GitHub*); not on pub.dev yet.

- **Read and write Part 10 files:**
  - `DicomFile.fromBytes`, `DicomFile.fromSource` and `toBytes`. Reads Implicit and Explicit VR Little Endian, Deflated, and Explicit VR Big Endian (retired, read only), and writes the Little Endian syntaxes.
  - An untouched element is written byte for byte; the file meta is generated and checked.
  - Bare datasets, such as DIMSE identifiers: `Dataset.fromBytes(bytes, transferSyntax:)` and `ds.toBytes(transferSyntax:)`.
- **`Dataset`:**
  - elements in tag order, with nested `Sequence`s and private blocks (`privateBlock`);
  - typed reads through the generated `DicomTags` (`get`, `require`, `getAll`);
  - untyped getters (`getStrings`, `getInts`, …) and `element(tag)`;
  - writes with `set`, `setAll`, `setEmpty`, `setRaw` and `remove`.
- **Read options and repairs:**
  - `ReadOptions`: `stopBeforePixels`, `deferSize`, `tags` and `force`.
  - Real-world files read leniently, and every repair is listed in `file.report` (`ReadReport`).
- **Character sets:** the default repertoire, `ISO_IR 100` and `ISO_IR 192`.
- **Generated constants** from DICOM 2026d: `DicomTags`, `TransferSyntaxes` and `SopClasses`; also `Uid.generate`, `Uid.isValid` and `TransferSyntax.of`.
- **`package:dartdicom/io.dart`** (native only):
  - `File.readAsDicom`, `readAsDicomSync`, `writeAsDicom` and `writeAsDicomSync`;
  - a random-access `FileSource`, so a header-only read doesn't load the whole file;
  - `ZLibDeflateCodec`.
- **Errors:** a sealed `DicomDataException` (`DicomParseException`, `MissingElementException`, `DicomWriteException`, `SourceChangedException`) under `DicomException`. Messages never contain a value.
- `Tag`: a zero-cost DICOM attribute tag (group, element, private-tag check).
- `describeTag(tag)`: a tag as exception messages name it, `(0010,0010) PatientName`, for packages and apps that raise their own. It never carries a value.
