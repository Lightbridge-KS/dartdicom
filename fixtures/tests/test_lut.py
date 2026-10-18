import base64

import numpy as np
import pydicom

from dartdicom_fixtures import lut, scenarios
from dartdicom_fixtures.paths import DATA


def _gray(variant: dict) -> np.ndarray:
    return np.frombuffer(base64.b64decode(variant["gray"]), dtype=np.uint8)


def test_color_and_compressed_files_have_no_lut_golden() -> None:
    assert lut.record(DATA / "synthetic" / "sc_rgb.dcm", DATA, strict=True) is None
    assert lut.record(DATA / "pydicom" / "MR_small_RLE.dcm", DATA, strict=True) is None


def test_a_window_is_rescaled_by_the_range_pydicom_used() -> None:
    # dx_monochrome1: 12-bit unsigned, one 2048/4096 window, no rescale.
    path = DATA / "synthetic" / "dx_monochrome1.dcm"
    (variant,) = lut.record(path, DATA, strict=True)["frames"][0]["voi"]
    x = pydicom.dcmread(path).pixel_array.ravel().astype(np.float64)
    c, w = 2048 - 0.5, 4096 - 1  # PS3.3 C.11.2.1.2.1
    expected = np.clip(((x - c) / w + 0.5) * 255, 0, 255)
    assert np.abs(_gray(variant) - expected).max() <= 0.5 + 1e-9


def test_a_voi_lut_is_scaled_by_its_bits_per_entry() -> None:
    # mr_voi_lut_8bit: an 8-bit LUT, first mapped 0, so gray is the entry.
    path = DATA / "synthetic" / "mr_voi_lut_8bit.dcm"
    (variant,) = lut.record(path, DATA, strict=True)["frames"][0]["voi"]
    ds = pydicom.dcmread(path)
    entries = np.asarray(ds.VOILUTSequence[0].LUTData)
    assert variant["kind"] == "lut"
    assert (_gray(variant) == entries[ds.pixel_array.ravel()]).all()


def test_each_frame_takes_its_own_functional_groups_whole() -> None:
    ds = scenarios.SCENARIOS["ect_functional_groups"]("ect_functional_groups")
    shared = lut._frame_source(ds, 0)
    assert (shared.RescaleSlope, shared.RescaleIntercept) == (1, -1024)
    assert "VOILUTFunction" not in shared
    own = lut._frame_source(ds, 2)
    assert (own.RescaleSlope, own.RescaleIntercept) == (2, -2048)
    assert own.VOILUTFunction == "SIGMOID"
    assert "RescaleSlope" not in ds  # the original's top level is untouched
