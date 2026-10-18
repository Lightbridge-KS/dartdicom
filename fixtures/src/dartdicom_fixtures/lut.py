"""pydicom's Modality LUT and VOI output for every frame (I-33, blueprint F47).

For each grayscale native fixture, lut/<group>/<name>.json holds, frame by
frame:

- "modality": the SHA-256 of `apply_modality_lut`'s output as float64, little
  endian, C order. dartdicom's `toModality()` must match it bit for bit.
- "voi": one entry per VOI the frame has, each VOI LUT item ("kind": "lut")
  and each window ("kind": "window") by its index. "gray" is base64 uint8:
  pydicom's output rescaled to 0–255 and rounded (half to even). A window is
  rescaled by the output range pydicom used, read back from two sentinels
  (-inf and +inf) appended to the input; a LUT by 2**bits − 1, its
  descriptor's bits per entry. pydicom's error class replaces "gray" when it
  raises. MONOCHROME1 is not inverted: the Dart side compares before it.

pydicom's `apply_*` read only the top level, so for an enhanced multi-frame
image each frame's Pixel Value Transformation and Frame VOI LUT items (its
per-frame item, else the shared one) replace the top level's attributes
first (F44). The test then checks dartdicom's resolution with pydicom's
arithmetic.

`strict` (the committed fixtures) asserts what must hold for the goldens to
reproduce on any CPU (I-28) and to stay inside the domain where pydicom is
right: no sigmoid value within 1e-6 of a rounding tie (`np.exp` differs by
CPU), and no LUT index pydicom would wrap.
"""

from __future__ import annotations

import base64
import hashlib
import json
import warnings
from pathlib import Path
from typing import Any

import numpy as np
from pydicom.dataset import Dataset
from pydicom.pixels.processing import apply_modality_lut, apply_voi, apply_windowing

from .golden import read

_MONOCHROME = ("MONOCHROME1", "MONOCHROME2")

# The attributes a functional group macro replaces at the top level.
_MODALITY = ("RescaleSlope", "RescaleIntercept", "RescaleType", "ModalityLUTSequence")
_VOI = (
    "WindowCenter",
    "WindowWidth",
    "VOILUTFunction",
    "WindowCenterWidthExplanation",
    "VOILUTSequence",
)
_MACROS = {
    "PixelValueTransformationSequence": _MODALITY,
    "FrameVOILUTSequence": _VOI,
}


def record(path: Path, data_root: Path, *, strict: bool, **stamps: str) -> Any:
    """The LUT golden of `path`, or None when it holds no grayscale native
    pixels."""
    with warnings.catch_warnings():
        warnings.simplefilter("ignore")
        ds, _ = read(path)
        meta = getattr(ds, "file_meta", Dataset())
        ts = meta.get("TransferSyntaxUID")
        if (
            "PixelData" not in ds
            or ds.get("PhotometricInterpretation") not in _MONOCHROME
            or (ts is not None and ts.is_encapsulated)
        ):
            return None
        head = {"file": path.relative_to(data_root).as_posix(), **stamps}
        try:
            arr = ds.pixel_array  # every frame at once: pydicom's per-frame
        except Exception as exc:  # 1-bit path is off by a byte
            return head | {"error": type(exc).__name__}
        frames = arr if int(ds.get("NumberOfFrames") or 1) > 1 else arr[None]
        return head | {
            "frames": [
                _frame(f, _frame_source(ds, i), strict) for i, f in enumerate(frames)
            ]
        }


def golden(path: Path, data_root: Path, *, strict: bool, **stamps: str) -> str | None:
    result = record(path, data_root, strict=strict, **stamps)
    return None if result is None else json.dumps(result, indent=1) + "\n"


def _frame_source(ds: Dataset, index: int) -> Dataset:
    """`ds` with frame `index`'s functional group macros at the top level:
    each whole item replaces the attributes of its kind, never a mix."""
    per = ds.get("PerFrameFunctionalGroupsSequence")
    shared = ds.get("SharedFunctionalGroupsSequence")
    groups = [
        per[index] if per is not None and index < len(per) else None,
        shared[0] if shared else None,
    ]
    out = ds
    for macro, keywords in _MACROS.items():
        item = next(
            (g[macro][0] for g in groups if g is not None and g.get(macro)), None
        )
        if item is None:
            continue
        if out is ds:
            # A new top level sharing the elements: the original stays as is
            # for the next frame. The meta says how OW LUT Data is ordered.
            out = Dataset()
            for element in ds:
                out.add(element)
            if hasattr(ds, "file_meta"):
                out.file_meta = ds.file_meta
        for keyword in keywords:
            if keyword in out:
                delattr(out, keyword)
        for element in item:
            out[element.tag] = element
    return out


def _frame(stored: np.ndarray, src: Dataset, strict: bool) -> dict[str, Any]:
    modality = np.asarray(apply_modality_lut(stored, src), dtype="<f8")
    variants: list[dict[str, Any]] = []
    for i, item in enumerate(src.get("VOILUTSequence") or []):
        variants.append(
            _variant(
                "lut",
                i,
                lambda i=i, item=item: _lut_gray(modality, src, i, item, strict),
            )
        )
    for i in range(_window_count(src)):
        variants.append(
            _variant("window", i, lambda i=i: _window_gray(modality, src, i, strict))
        )
    return {
        "modality": hashlib.sha256(
            np.ascontiguousarray(modality).tobytes()
        ).hexdigest(),
        "voi": variants,
    }


def _variant(kind: str, index: int, gray: Any) -> dict[str, Any]:
    try:
        values = gray()
    except AssertionError:  # a strict check: the fixture must change
        raise
    except Exception as exc:
        return {"kind": kind, "index": index, "error": type(exc).__name__}
    encoded = base64.b64encode(values.astype(np.uint8).tobytes()).decode("ascii")
    return {"kind": kind, "index": index, "gray": encoded}


def _window_count(src: Dataset) -> int:
    if "WindowCenter" not in src or "WindowWidth" not in src:
        return 0
    return max(src["WindowCenter"].VM, src["WindowWidth"].VM)


def _window_gray(
    modality: np.ndarray, src: Dataset, index: int, strict: bool
) -> np.ndarray:
    flat = np.concatenate([modality.ravel(), [-np.inf, np.inf]])
    with np.errstate(over="ignore", invalid="ignore"):
        out = apply_windowing(flat, src, index)
    y_min, y_max = out[-2], out[-1]
    if y_max == y_min:
        raise ZeroDivisionError("the output range is empty")
    scaled = (out[:-2] - y_min) / (y_max - y_min) * 255
    if strict and str(src.get("VOILUTFunction", "")).upper() == "SIGMOID":
        # At the center itself exp(0) is exact, so that tie is the same on
        # every CPU; any other near-tie could round differently.
        element = src["WindowCenter"]
        center = float(element.value[index] if element.VM > 1 else element.value)
        tie = np.abs(scaled - np.floor(scaled) - 0.5) < 1e-6
        assert not (tie & (flat[:-2] != center)).any(), "a sigmoid value nears a tie"
    return np.clip(np.rint(scaled), 0, 255)


def _lut_gray(
    modality: np.ndarray, src: Dataset, index: int, item: Dataset, strict: bool
) -> np.ndarray:
    _, first, bits = item.LUTDescriptor
    if strict:
        width = 1 << (8 if bits == 8 else 16)
        assert modality.max() - first < width, "pydicom would wrap the LUT index"
    out = apply_voi(modality, src, index).astype(np.float64)
    top = (1 << bits) - 1
    return np.rint(np.minimum(out, top) * 255 / top).reshape(-1)


def stamp() -> dict[str, str]:
    """What a corpus record carries so a stale cache is detectable."""
    return {"lut_py": hashlib.sha256(Path(__file__).read_bytes()).hexdigest()[:12]}
