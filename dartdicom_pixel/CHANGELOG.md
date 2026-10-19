# Changelog

## [Unreleased]

## [0.1.0-dev.2] - 2026-10-19

GitHub-only prerelease; not published on pub.dev.

### Changed

- Coordinate the GitHub-only package version and core dependency with 0.1.0-dev.2.
  Pixel runtime behavior is unchanged from 0.1.0-dev.1.

## [0.1.0-dev.1] - 2026-10-18

First pre-release, from GitHub as tag `v0.1.0-dev.1` (see the repository README, *Use from GitHub*); not on pub.dev yet.

- `ds.pixels`: `frame(i)` and `allFrames()` decode native (uncompressed) Pixel Data to a `PixelArray`: Bits Allocated 1, 8, 16 and 32, signed or unsigned, unused high bits masked and sign-extended, PlanarConfiguration 1 interleaved, Big Endian included. `shape`, `dtype` (`PixelDtype`) and unmodifiable `values`, a zero-copy view where the bytes allow; `frame(i)` views one frame of a multi-frame array.
- `toModality()`: each frame's Modality LUT (a rescale, or the Modality LUT Sequence), from its functional groups in enhanced multi-frame images.
- `ds.voi()`: a frame's VOI as a sealed `Voi`, either `VoiWindow` (`VoiFunction` linear, linear exact or sigmoid) or `VoiLut`. A VOI LUT wins over a window, as in pydicom.
- `toDisplay([voi])`: an 8-bit `DisplayBuffer` after the Modality LUT, the VOI and MONOCHROME1's inversion, with the frame's own VOI by default and `autoWindow()` when it has none.
- A sealed `PixelDataException`: `UnsupportedPixelEncoding` (compressed data, color display, …) and `InvalidPixelModule`. Messages never show a value.
