"""pydicom's reading of every fixture, as golden JSON (I-11).

For each <group>/<name>.dcm, golden/<group>/<name>.json holds every element
(tag, VR, normalized value; recursive for sequences) and, when the file has
pixels, the shape, dtype and SHA-256 of pydicom's pixel array in little-endian
C order. The Dart tests compare against these.
"""

from __future__ import annotations

import hashlib
import json
import warnings
from pathlib import Path
from typing import Any

import numpy as np
import pydicom
from pydicom.dataset import Dataset
from pydicom.multival import MultiValue
from pydicom.sequence import Sequence
from pydicom.valuerep import PersonName

# One of pydicom's own test files carries a UID with a leading-zero component
# ("…9.0123…"), invalid for VR UI. It is real-world mess the lenient reader
# must handle (C-10); the warning is known, so it isn't repeated on every run.
warnings.filterwarnings(
    "ignore", message="Invalid value for VR UI", category=UserWarning
)


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
    return [
        {"tag": f"{int(e.tag):08X}", "vr": e.VR, "value": normalize(e.value)}
        for e in ds
    ]


def pixels(ds: Dataset) -> dict[str, Any] | None:
    if "PixelData" not in ds:
        return None
    arr = np.ascontiguousarray(ds.pixel_array)
    canonical = arr.astype(arr.dtype.newbyteorder("<")).tobytes()
    return {
        "shape": list(arr.shape),
        "dtype": arr.dtype.name,
        "sha256": hashlib.sha256(canonical).hexdigest(),
    }


def golden(path: Path, data_root: Path) -> str:
    ds = pydicom.dcmread(path)
    record = {
        "file": path.relative_to(data_root).as_posix(),
        "pydicom": pydicom.__version__,
        "transfer_syntax": str(ds.file_meta.TransferSyntaxUID),
        "meta": elements(ds.file_meta),
        "dataset": elements(ds),
        "pixels": pixels(ds),
    }
    return json.dumps(record, indent=1, ensure_ascii=False) + "\n"
