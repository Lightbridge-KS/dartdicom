"""pydicom's reading of every fixture, as golden JSON (I-11).

For each <group>/<name>.dcm, golden/<group>/<name>.json holds every element
(tag, VR, normalized value; recursive for sequences) and, when the file has
pixels, the shape, dtype and SHA-256 of pydicom's pixel array in little-endian
C order, or the error decoding it (a compressed syntax with no codec
installed). The Dart tests compare against these.

Real-world files break in places, so the reading is recorded element by
element: an element pydicom can't convert carries "error" (the exception
class) instead of "value". Where pydicom's VR isn't the one written (UN it
replaced, an ambiguous "US or SS", an implicit private tag it typed from its
private dictionary), "raw" records the VR as read and the raw bytes' length and
SHA-256, so the Dart side can compare bytes where VRs legitimately differ.
"""

from __future__ import annotations

import hashlib
import json
import warnings
from pathlib import Path
from typing import Any

import numpy as np
import pydicom
from pydicom.dataelem import RawDataElement
from pydicom.dataset import Dataset
from pydicom.errors import InvalidDicomError
from pydicom.multival import MultiValue
from pydicom.sequence import Sequence
from pydicom.valuerep import PersonName

# One of pydicom's own test files carries a UID with a leading-zero component
# ("…9.0123…"), invalid for VR UI. It is real-world mess the lenient reader
# must handle (C-10); the warning is known, so it isn't repeated on every run.
warnings.filterwarnings(
    "ignore", message="Invalid value for VR UI", category=UserWarning
)

# Exceptions are recorded per element, so a failure reads as data, not noise.
_RECORDED = (Exception,)


def normalize(value: Any) -> Any:
    if isinstance(value, Sequence):
        return {"items": [elements(item) for item in value]}
    if isinstance(value, bytes | bytearray):
        if len(value) <= 64:
            return {"bytes": value.hex()}
        return {"bytes_len": len(value), "sha256": hashlib.sha256(value).hexdigest()}
    if isinstance(value, MultiValue | list | tuple):
        return [normalize(v) for v in value]
    if isinstance(value, PersonName):
        return str(value)
    if isinstance(value, float):
        return float(value)
    if isinstance(value, int):
        return int(value)
    if isinstance(value, str):
        return str(value)
    return value  # None (empty value)


def elements(ds: Dataset) -> list[dict[str, Any]]:
    return [element(ds, tag) for tag in sorted(ds.keys())]


def element(ds: Dataset, tag: int) -> dict[str, Any]:
    """One element: its tag, pydicom's VR and value (or the error converting
    it), and the raw form where pydicom's VR isn't the one written."""
    raw = ds.get_item(tag)
    record: dict[str, Any] = {"tag": f"{int(tag):08X}"}
    try:
        converted = ds[tag]
        record["vr"] = converted.VR
        record["value"] = normalize(converted.value)
    except _RECORDED as exc:
        record["vr"] = getattr(raw, "VR", None)
        record["error"] = type(exc).__name__
    if isinstance(raw, RawDataElement):
        written = raw.VR
        vr = record["vr"] or ""
        replaced = written is not None and written != vr
        # pydicom types implicit private tags from its private dictionary.
        private_typed = written is None and (int(tag) >> 16) % 2 == 1
        if replaced or " or " in vr or private_typed:
            value = raw.value if isinstance(raw.value, bytes) else b""
            record["raw"] = {
                "vr": written,
                "len": len(value),
                "sha256": hashlib.sha256(value).hexdigest(),
            }
    return record


def pixels(ds: Dataset) -> dict[str, Any] | None:
    if "PixelData" not in ds:
        return None
    try:
        arr = np.ascontiguousarray(ds.pixel_array)
    except _RECORDED as exc:
        return {"error": type(exc).__name__}
    canonical = arr.astype(arr.dtype.newbyteorder("<")).tobytes()
    return {
        "shape": list(arr.shape),
        "dtype": arr.dtype.name,
        "sha256": hashlib.sha256(canonical).hexdigest(),
    }


def read(path: Path) -> tuple[Dataset, bool]:
    """pydicom's reading of `path`, and whether it needed `force=True` (no
    preamble and `DICM`)."""
    try:
        return pydicom.dcmread(path), False
    except InvalidDicomError:
        return pydicom.dcmread(path, force=True), True


def record(path: Path, data_root: Path, **stamps: str) -> dict[str, Any]:
    """The golden record of `path`; `stamps` say what produced it."""
    with warnings.catch_warnings():
        warnings.simplefilter("ignore")
        ds, force = read(path)
        meta = getattr(ds, "file_meta", Dataset())
        ts = meta.get("TransferSyntaxUID")
        result: dict[str, Any] = {
            "file": path.relative_to(data_root).as_posix(),
            "pydicom": pydicom.__version__,
            **stamps,
        }
        if force:
            result["force"] = True
        result |= {
            "transfer_syntax": str(ts) if ts is not None else None,
            "meta": elements(meta),
            "dataset": elements(ds),
            "pixels": pixels(ds),
        }
        return result


def golden(path: Path, data_root: Path, **stamps: str) -> str:
    return (
        json.dumps(record(path, data_root, **stamps), indent=1, ensure_ascii=False)
        + "\n"
    )


def golden_or_error(path: Path, data_root: Path, **stamps: str) -> str:
    """As [golden], but a file pydicom can't read at all becomes a record
    holding only the error."""
    try:
        return golden(path, data_root, **stamps)
    except _RECORDED as exc:
        failed = {
            "file": path.relative_to(data_root).as_posix(),
            "pydicom": pydicom.__version__,
            **stamps,
            "error": type(exc).__name__,
        }
        return json.dumps(failed, indent=1) + "\n"


def source_hash() -> str:
    """The first 12 hex digits of this file's SHA-256: stamped on corpus
    records, so a stale cache is detectable."""
    return hashlib.sha256(Path(__file__).read_bytes()).hexdigest()[:12]
