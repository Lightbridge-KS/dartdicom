"""Curated copies of pydicom's bundled test files (MIT), from the pinned wheel.

Their README: "I believe there is no restriction on using any of these files
in this manner." All are under 40 KB.
"""

from __future__ import annotations

import shutil
from pathlib import Path

from pydicom.data import get_testdata_file

FILES = {
    "CT_small.dcm": "Explicit VR LE, ISO_IR 100, private tags",
    "MR_small.dcm": "Explicit VR LE",
    "MR_small_implicit.dcm": "Implicit VR LE",
    "MR_small_bigendian.dcm": "Explicit VR BE (retired)",
    "MR_small_RLE.dcm": "RLE Lossless",
    "image_dfl.dcm": "Deflated Explicit VR LE",
    "rtplan.dcm": "Implicit VR LE, deeply nested sequences",
    "rtdose.dcm": "multi-frame 32-bit dose grid",
    "SC_rgb_small_odd.dcm": "RGB, odd dimensions",
    "SC_rgb_small_odd_big_endian.dcm": "RGB, odd dimensions, Big Endian",
    "SC_rgb_rle.dcm": "RGB, RLE",
    "SC_rgb_rle_2frame.dcm": "RGB, RLE, 2 frames",
    "SC_rgb_rle_16bit.dcm": "RGB, RLE, 16-bit",
    "SC_rgb_rle_32bit_2frame.dcm": "RGB, RLE, 32-bit, 2 frames",
}


def copy(name: str, out_dir: Path) -> Path:
    source = get_testdata_file(name)
    if source is None:
        raise FileNotFoundError(f"pydicom has no bundled test file {name}")
    target = out_dir / name
    shutil.copy(str(source), target)
    return target
