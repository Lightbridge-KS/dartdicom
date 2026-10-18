"""Synthetic scenarios, built from scratch with pydicom.

Every patient field is synthetic. UIDs are name-based and dates fixed, so a
re-run reproduces every byte. Add a scenario by writing a function decorated
with `@scenario`; its docstring's first line becomes its description.
"""

from __future__ import annotations

import uuid
from collections.abc import Callable
from pathlib import Path

import numpy as np
from pydicom.dataset import Dataset, FileMetaDataset
from pydicom.sequence import Sequence
from pydicom.uid import (
    UID,
    CTImageStorage,
    DeflatedExplicitVRLittleEndian,
    DigitalXRayImageStorageForPresentation,
    EnhancedCTImageStorage,
    ExplicitVRBigEndian,
    ExplicitVRLittleEndian,
    ImplicitVRLittleEndian,
    MRImageStorage,
    MultiFrameGrayscaleWordSecondaryCaptureImageStorage,
    MultiFrameSingleBitSecondaryCaptureImageStorage,
    SecondaryCaptureImageStorage,
)

Scenario = Callable[[str], Dataset]
SCENARIOS: dict[str, Scenario] = {}

_UID_NAMESPACE = uuid.uuid5(
    uuid.NAMESPACE_URL, "https://github.com/Lightbridge-KS/dartdicom/fixtures"
)


def scenario(fn: Scenario) -> Scenario:
    SCENARIOS[fn.__name__] = fn
    return fn


def describe(fn: Scenario) -> str:
    return (fn.__doc__ or "").strip().split("\n\n")[0].replace("\n", " ")


def uid(*parts: str) -> str:
    """A deterministic UID under 2.25 (PS3.5 §B.2) for `parts`.

    A name-based UUID (v5), so re-runs reproduce it. pydicom's
    `generate_uid(prefix=None)` is random whatever its entropy sources.
    """
    return f"2.25.{uuid.uuid5(_UID_NAMESPACE, '/'.join(parts)).int}"


def write(name: str, out_dir: Path) -> Path:
    """Builds scenario `name` and writes it as a Part 10 file in `out_dir`."""
    path = out_dir / f"{name}.dcm"
    SCENARIOS[name](name).save_as(path, enforce_file_format=True)
    return path


# ── building blocks ──────────────────────────────────────────────────────────


def base(name: str, sop_class: str, transfer_syntax: str) -> Dataset:
    """A minimal synthetic instance: patient, study, series, SOP common."""
    meta = FileMetaDataset()
    meta.MediaStorageSOPClassUID = UID(sop_class)
    meta.MediaStorageSOPInstanceUID = UID(uid(name, "instance"))
    meta.TransferSyntaxUID = UID(transfer_syntax)
    ds = Dataset()
    ds.file_meta = meta
    ds.SOPClassUID = sop_class
    ds.SOPInstanceUID = meta.MediaStorageSOPInstanceUID
    ds.PatientName = "Synthetic^Patient"
    ds.PatientID = f"SYN-{name}"
    ds.PatientBirthDate = ""
    ds.PatientSex = "O"
    ds.StudyInstanceUID = uid(name, "study")
    ds.SeriesInstanceUID = uid(name, "series")
    ds.StudyDate = "20260101"
    ds.StudyTime = "120000"
    ds.StudyID = "1"
    ds.AccessionNumber = ""
    ds.ReferringPhysicianName = ""
    ds.SeriesNumber = 1
    ds.InstanceNumber = 1
    return ds


def with_pixels(
    ds: Dataset,
    arr: np.ndarray,
    *,
    bits_stored: int,
    photometric: str = "MONOCHROME2",
    big_endian: bool = False,
) -> Dataset:
    """Attaches `arr` as native Pixel Data, with the Image Pixel module."""
    if arr.ndim == 2:  # one grayscale frame
        frames, rows, cols, samples = 1, *arr.shape, 1
    elif photometric.startswith("MONO"):  # grayscale frames
        frames, rows, cols, samples = *arr.shape, 1
    else:  # one color frame
        frames, rows, cols, samples = 1, *arr.shape
    ds.SamplesPerPixel = samples
    ds.PhotometricInterpretation = photometric
    ds.Rows, ds.Columns = rows, cols
    ds.BitsAllocated = arr.dtype.itemsize * 8
    ds.BitsStored = bits_stored
    ds.HighBit = bits_stored - 1
    ds.PixelRepresentation = 1 if arr.dtype.kind == "i" else 0
    if samples > 1:
        ds.PlanarConfiguration = 0
    if frames > 1:
        ds.NumberOfFrames = frames
    order = ">" if big_endian else "<"
    data = arr.astype(arr.dtype.newbyteorder(order)).tobytes()
    ds.PixelData = data + (b"\x00" if len(data) % 2 else b"")
    ds["PixelData"].VR = "OW" if ds.BitsAllocated > 8 else "OB"
    return ds


def hu_ramp() -> np.ndarray:
    """A 16×16 CT slice: a ramp from -1000 to +1000 HU."""
    return np.linspace(-1000, 1000, 256).round().astype(np.int16).reshape(16, 16)


def ct(name: str, transfer_syntax: str, *, big_endian: bool = False) -> Dataset:
    ds = base(name, CTImageStorage, transfer_syntax)
    ds.Modality = "CT"
    ds.ImageType = ["ORIGINAL", "PRIMARY", "AXIAL"]  # VM 2-n (DA1)
    ds.RescaleIntercept = "0"
    ds.RescaleSlope = "1"
    ds.WindowCenter = ["40", "-600"]  # several windows (DA1)
    ds.WindowWidth = ["400", "1500"]
    ds.PixelSpacing = ["0.5", "0.5"]
    ds.SliceThickness = "1.25"
    return with_pixels(ds, hu_ramp(), bits_stored=16, big_endian=big_endian)


def text_only(name: str, charset: str | None, patient: str) -> Dataset:
    ds = base(name, SecondaryCaptureImageStorage, ExplicitVRLittleEndian)
    if charset:
        ds.SpecificCharacterSet = charset
    ds.PatientName = patient
    ds.Modality = "OT"
    ds.ConversionType = "WSD"
    ds.StudyDescription = patient.replace("^", " ")
    return with_pixels(ds, np.zeros((2, 2), dtype=np.uint8), bits_stored=8)


# ── scenarios ────────────────────────────────────────────────────────────────


@scenario
def ct_signed_explicit_le(name: str) -> Dataset:
    """Signed 16-bit HU, Explicit VR LE; multi-valued ImageType and windows."""
    return ct(name, ExplicitVRLittleEndian)


@scenario
def ct_implicit_le(name: str) -> Dataset:
    """As ct_signed_explicit_le, Implicit VR LE (VRs from the dictionary)."""
    return ct(name, ImplicitVRLittleEndian)


@scenario
def ct_deflated(name: str) -> Dataset:
    """As ct_signed_explicit_le, Deflated Explicit VR LE."""
    return ct(name, DeflatedExplicitVRLittleEndian)


@scenario
def ct_explicit_be(name: str) -> Dataset:
    """As ct_signed_explicit_le, Explicit VR Big Endian (retired)."""
    return ct(name, ExplicitVRBigEndian, big_endian=True)


@scenario
def ct_unsigned_intercept(name: str) -> Dataset:
    """The same HU as ct_signed_explicit_le, stored unsigned 12-bit with
    RescaleIntercept -1024."""
    ds = ct(name, ExplicitVRLittleEndian)
    ds.RescaleIntercept = "-1024"
    stored = (hu_ramp().astype(np.int32) + 1024).astype(np.uint16)
    return with_pixels(ds, stored, bits_stored=12)


@scenario
def dx_monochrome1(name: str) -> Dataset:
    """MONOCHROME1 (higher value = darker), 12-bit unsigned, one window."""
    ds = base(name, DigitalXRayImageStorageForPresentation, ExplicitVRLittleEndian)
    ds.Modality = "DX"
    ds.ImageType = ["ORIGINAL", "PRIMARY"]
    ds.PresentationIntentType = "FOR PRESENTATION"
    ds.WindowCenter = "2048"
    ds.WindowWidth = "4096"
    arr = np.linspace(0, 4095, 256).round().astype(np.uint16).reshape(16, 16)
    return with_pixels(ds, arr, bits_stored=12, photometric="MONOCHROME1")


@scenario
def sc_multiframe(name: str) -> Dataset:
    """Three 8×8 frames of 16-bit grayscale."""
    ds = base(
        name,
        MultiFrameGrayscaleWordSecondaryCaptureImageStorage,
        ExplicitVRLittleEndian,
    )
    ds.Modality = "OT"
    ds.ConversionType = "WSD"
    arr = np.arange(3 * 64, dtype=np.uint16).reshape(3, 8, 8) * 100
    return with_pixels(ds, arr, bits_stored=16)


@scenario
def sc_rgb(name: str) -> Dataset:
    """4×4 RGB, 8-bit, interleaved (PlanarConfiguration 0)."""
    ds = base(name, SecondaryCaptureImageStorage, ExplicitVRLittleEndian)
    ds.Modality = "OT"
    ds.ConversionType = "WSD"
    arr = np.zeros((4, 4, 3), dtype=np.uint8)
    arr[..., 0] = np.arange(16).reshape(4, 4) * 16  # red ramp
    arr[..., 2] = 255 - arr[..., 0]  # blue, the inverse
    return with_pixels(ds, arr, bits_stored=8, photometric="RGB")


@scenario
def charset_latin1(name: str) -> Dataset:
    """ISO_IR 100 (Latin-1) text: a synthetic accented name."""
    return text_only(name, "ISO_IR 100", "Müller^Zoë")


@scenario
def charset_utf8(name: str) -> Dataset:
    """ISO_IR 192 (UTF-8) text, including characters outside Latin-1."""
    return text_only(name, "ISO_IR 192", "Çelik^Łukasz")


@scenario
def missing_study_date(name: str) -> Dataset:
    """StudyDate absent; StudyTime present but empty (Type 2)."""
    ds = text_only(name, None, "Synthetic^Patient")
    del ds.StudyDate
    ds.StudyTime = ""
    return ds


@scenario
def sequences_undefined_length(name: str) -> Dataset:
    """Nested sequences and items with undefined length."""
    ds = text_only(name, None, "Synthetic^Patient")
    code = Dataset()
    code.CodeValue = "T-D0050"
    code.CodingSchemeDesignator = "SRT"
    code.CodeMeaning = "Tissue"
    item = Dataset()
    item.ReferencedSOPClassUID = CTImageStorage
    item.ReferencedSOPInstanceUID = uid(name, "referenced")
    item.PurposeOfReferenceCodeSequence = Sequence([code])
    ds.ReferencedImageSequence = Sequence([item, Dataset(item)])
    ds["ReferencedImageSequence"].is_undefined_length = True
    for i in ds.ReferencedImageSequence:
        i.is_undefined_length_sequence_item = True
    return ds


@scenario
def private_tags(name: str) -> Dataset:
    """A private creator (0009,0010) and two private elements."""
    ds = text_only(name, None, "Synthetic^Patient")
    block = ds.private_block(0x0009, "DARTDICOM TEST", create=True)
    block.add_new(0x01, "LO", "private text")
    block.add_new(0x02, "US", 42)
    return ds


#: The marker every PHI canary value carries; the I-9 test fails wherever it
#: appears outside a value.
CANARY = "ZXQV"


@scenario
def phi_canary(name: str) -> Dataset:
    """Sentinel text (ZXQV…) in names, IDs, descriptions, a private element
    and nested sequence text, for the I-9 canary test."""
    ds = text_only(name, "ISO_IR 192", f"{CANARY}Family^{CANARY}Given")
    ds.PatientID = f"{CANARY}-ID-0001"
    ds.OtherPatientIDsSequence = Sequence([_other_id(f"{CANARY}-OTHER-0002")])
    ds.PatientComments = f"{CANARY} comment: allergic to synthetic data"
    ds.InstitutionName = f"{CANARY} Institution"
    ds.StudyDescription = f"{CANARY} study description"
    ds.AccessionNumber = f"{CANARY}ACC1"
    block = ds.private_block(0x0009, "DARTDICOM CANARY", create=True)
    block.add_new(0x01, "LO", f"{CANARY} private")
    meaning = Dataset()
    meaning.CodeValue = "T-D0050"
    meaning.CodingSchemeDesignator = "SRT"
    meaning.CodeMeaning = f"{CANARY} nested meaning"
    item = Dataset()
    item.ReferencedSOPClassUID = CTImageStorage
    item.ReferencedSOPInstanceUID = uid(name, "referenced")
    item.PurposeOfReferenceCodeSequence = Sequence([meaning])
    ds.ReferencedImageSequence = Sequence([item])
    return ds


def _other_id(value: str) -> Dataset:
    other = Dataset()
    other.PatientID = value
    other.TypeOfPatientID = "TEXT"
    return other


# ── pixel and LUT scenarios (M4) ─────────────────────────────────────────────
#
# Each covers a decode or LUT path pydicom's own files don't. Values are
# arithmetic patterns, not random draws, so the bytes never depend on NumPy's
# generators. Where Bits Stored < Bits Allocated, the unused high bits hold
# garbage: pydicom masks them (correct_unused_bits), and so must dartdicom.


def native(
    ds: Dataset,
    data: bytes,
    *,
    rows: int,
    columns: int,
    bits_allocated: int,
    bits_stored: int,
    signed: bool = False,
    samples: int = 1,
    photometric: str = "MONOCHROME2",
    planar: int | None = None,
    frames: int = 1,
    vr: str | None = None,
) -> Dataset:
    """Attaches `data`, already in the transfer syntax's byte order and in
    the planar layout given, as native Pixel Data with its Image Pixel module."""
    ds.SamplesPerPixel = samples
    ds.PhotometricInterpretation = photometric
    if planar is not None:
        ds.PlanarConfiguration = planar
    if frames > 1:
        ds.NumberOfFrames = frames
    ds.Rows, ds.Columns = rows, columns
    ds.BitsAllocated = bits_allocated
    ds.BitsStored = bits_stored
    ds.HighBit = bits_stored - 1
    ds.PixelRepresentation = 1 if signed else 0
    ds.PixelData = data + (b"\x00" if len(data) % 2 else b"")
    ds["PixelData"].VR = vr or ("OW" if bits_allocated > 8 else "OB")
    return ds


def secondary(name: str, sop_class: str, transfer_syntax: str) -> Dataset:
    ds = base(name, sop_class, transfer_syntax)
    ds.Modality = "OT"
    ds.ConversionType = "WSD"
    return ds


def pattern(n: int, modulus: int) -> np.ndarray:
    """`n` values in 0..modulus-1 that aren't periodic in any small width."""
    i = np.arange(n, dtype=np.int64)
    return (i * 2654435761 + (i * i) // 13) % modulus


def dirty(values: np.ndarray, bits_stored: int, bits: int) -> np.ndarray:
    """`values` (signed or not) in their low `bits_stored` bits, with garbage
    above them, as unsigned `bits`-bit words."""
    mask = (1 << bits_stored) - 1
    garbage = pattern(values.size, 1 << (bits - bits_stored)).reshape(values.shape)
    return (values.astype(np.int64) & mask) | (garbage << bits_stored)


def one_bit(name: str, rows: int, columns: int) -> Dataset:
    ds = secondary(
        name, MultiFrameSingleBitSecondaryCaptureImageStorage, ExplicitVRLittleEndian
    )
    bits = (pattern(3 * rows * columns, 5) < 2).astype(np.uint8)
    data = np.packbits(bits, bitorder="little").tobytes()
    return native(
        ds, data, rows=rows, columns=columns, bits_allocated=1, bits_stored=1, frames=3
    )


@scenario
def seg_1bit_aligned(name: str) -> Dataset:
    """1-bit, 3 frames of 8×8: every frame starts on a byte boundary."""
    return one_bit(name, 8, 8)


@scenario
def seg_1bit_unaligned(name: str) -> Dataset:
    """1-bit, 3 frames of 3×5: frames start at bits 0, 15 and 30, inside a
    byte."""
    return one_bit(name, 3, 5)


@scenario
def int32_signed(name: str) -> Dataset:
    """Signed 32-bit, Bits Stored 32, 2 frames of 4×4, from -2**31 to
    2**31 - 1."""
    ds = secondary(name, SecondaryCaptureImageStorage, ExplicitVRLittleEndian)
    values = (pattern(32, 1 << 32) - (1 << 31)).astype("<i4")
    values[:4] = [-(1 << 31), (1 << 31) - 1, -1, 0]
    return native(
        ds,
        values.tobytes(),
        rows=4,
        columns=4,
        bits_allocated=32,
        bits_stored=32,
        signed=True,
        frames=2,
    )


@scenario
def int32_bs24_dirty(name: str) -> Dataset:
    """Signed 32-bit with Bits Stored 24 and garbage in the top byte."""
    ds = secondary(name, SecondaryCaptureImageStorage, ExplicitVRLittleEndian)
    values = pattern(16, 1 << 24) - (1 << 23)
    stored = dirty(values, 24, 32).astype("<u4")
    return native(
        ds,
        stored.tobytes(),
        rows=4,
        columns=4,
        bits_allocated=32,
        bits_stored=24,
        signed=True,
    )


@scenario
def uint32_explicit_be(name: str) -> Dataset:
    """Unsigned 32-bit OW, Explicit VR Big Endian (retired): each word's four
    bytes differ."""
    ds = secondary(name, SecondaryCaptureImageStorage, ExplicitVRBigEndian)
    values = (pattern(9, 1 << 32) | 0x01020304).astype(">u4")
    return native(
        ds, values.tobytes(), rows=3, columns=3, bits_allocated=32, bits_stored=32
    )


def rgb_frames() -> np.ndarray:
    """Two 3×3 RGB frames, (frames, rows, columns, samples)."""
    return pattern(2 * 3 * 3 * 3, 256).astype(np.uint8).reshape(2, 3, 3, 3)


@scenario
def rgb_planar_2frame(name: str) -> Dataset:
    """RGB, PlanarConfiguration 1, 2 frames of 3×3: each frame holds its own
    three planes, and frame 1 starts on an odd byte."""
    ds = secondary(name, SecondaryCaptureImageStorage, ExplicitVRLittleEndian)
    planes = rgb_frames().transpose(0, 3, 1, 2)  # frames, samples, rows, cols
    return native(
        ds,
        planes.tobytes(),
        rows=3,
        columns=3,
        bits_allocated=8,
        bits_stored=8,
        samples=3,
        photometric="RGB",
        planar=1,
        frames=2,
    )


@scenario
def rgb8_ow_explicit_be_2frame(name: str) -> Dataset:
    """8-bit RGB in OW, Explicit VR Big Endian, 2 frames of 3×3: bytes come
    in swapped pairs counted from the value's start, so frame 1 starts
    inside a word."""
    ds = secondary(name, SecondaryCaptureImageStorage, ExplicitVRBigEndian)
    pixels = rgb_frames().tobytes()
    swapped = np.frombuffer(pixels, dtype="<u2").byteswap().tobytes()
    return native(
        ds,
        swapped,
        rows=3,
        columns=3,
        bits_allocated=8,
        bits_stored=8,
        samples=3,
        photometric="RGB",
        planar=0,
        frames=2,
        vr="OW",
    )


@scenario
def mono8_signed_bs6_dirty(name: str) -> Dataset:
    """Signed 8-bit with Bits Stored 6 and garbage in the top two bits."""
    ds = secondary(name, SecondaryCaptureImageStorage, ExplicitVRLittleEndian)
    values = pattern(16, 64) - 32
    stored = dirty(values, 6, 8).astype(np.uint8)
    return native(
        ds,
        stored.tobytes(),
        rows=4,
        columns=4,
        bits_allocated=8,
        bits_stored=6,
        signed=True,
    )


@scenario
def ct_bs12_signed_dirty(name: str) -> Dataset:
    """Signed 16-bit CT with Bits Stored 12, garbage in the top four bits,
    and one window."""
    ds = base(name, CTImageStorage, ExplicitVRLittleEndian)
    ds.Modality = "CT"
    ds.RescaleIntercept = "0"
    ds.RescaleSlope = "1"
    ds.WindowCenter = "0"
    ds.WindowWidth = "4096"
    values = pattern(16, 4096) - 2048
    stored = dirty(values, 12, 16).astype("<u2")
    return native(
        ds,
        stored.tobytes(),
        rows=4,
        columns=4,
        bits_allocated=16,
        bits_stored=12,
        signed=True,
    )


def lut_item(
    entries: np.ndarray, first: int, bits: int, *, vr: str, big_endian: bool = False
) -> Dataset:
    """A Modality or VOI LUT item: the descriptor (SS when the first mapped
    value is negative) and the data as US values or OW bytes."""
    item = Dataset()
    descriptor = [len(entries) % 65536, first, bits]
    item.add_new(0x00283002, "SS" if first < 0 else "US", descriptor)
    item.LUTExplanation = "SYNTHETIC CURVE"
    if vr == "OW":
        order = ">u2" if big_endian else "<u2"
        item.add_new(0x00283006, "OW", entries.astype(order).tobytes())
    else:
        item.add_new(0x00283006, "US", [int(e) for e in entries])
    return item


def sqrt_curve(n: int, top: int) -> np.ndarray:
    """`n` entries rising from 0 to `top` along a square root."""
    return np.round(top * np.sqrt(np.linspace(0, 1, n))).astype(np.uint16)


@scenario
def ct_voi_lut_ow(name: str) -> Dataset:
    """CT with a VOI LUT Sequence (4096 16-bit OW entries, first mapped
    -2048) beside its windows."""
    ds = ct(name, ExplicitVRLittleEndian)
    ds.VOILUTSequence = Sequence(
        [lut_item(sqrt_curve(4096, 65535), -2048, 16, vr="OW")]
    )
    return ds


@scenario
def ct_voi_lut_ow_be(name: str) -> Dataset:
    """As ct_voi_lut_ow, in Explicit VR Big Endian: the OW LUT Data too."""
    ds = ct(name, ExplicitVRBigEndian, big_endian=True)
    item = lut_item(sqrt_curve(4096, 65535), -2048, 16, vr="OW", big_endian=True)
    ds.VOILUTSequence = Sequence([item])
    return ds


@scenario
def mr_voi_lut_8bit(name: str) -> Dataset:
    """MR, 12-bit unsigned, with a VOI LUT of 256 8-bit entries (one per US
    value) and no window."""
    ds = base(name, MRImageStorage, ExplicitVRLittleEndian)
    ds.Modality = "MR"
    stored = np.linspace(0, 250, 256).round().astype("<u2").reshape(16, 16)
    entries = np.round(255 * np.linspace(0, 1, 256) ** 2).astype(np.uint16)
    ds.VOILUTSequence = Sequence([lut_item(entries, 0, 8, vr="US")])
    return with_pixels(ds, stored, bits_stored=12)


@scenario
def ct_sigmoid(name: str) -> Dataset:
    """CT with VOI LUT Function SIGMOID and two windows."""
    ds = ct(name, ExplicitVRLittleEndian)
    ds.VOILUTFunction = "SIGMOID"
    return ds


@scenario
def ct_linear_exact(name: str) -> Dataset:
    """CT with VOI LUT Function LINEAR_EXACT; the second window is 0.5 wide,
    which only LINEAR_EXACT allows."""
    ds = ct(name, ExplicitVRLittleEndian)
    ds.VOILUTFunction = "LINEAR_EXACT"
    ds.WindowCenter = ["40", "50"]
    ds.WindowWidth = ["400", "0.5"]
    return ds


@scenario
def mlut_ss_window(name: str) -> Dataset:
    """Signed 12-bit with a Modality LUT Sequence (SS descriptor, first
    mapped -2048, 16-bit US entries) and a window over its output."""
    ds = secondary(name, SecondaryCaptureImageStorage, ExplicitVRLittleEndian)
    item = lut_item(sqrt_curve(4096, 65535), -2048, 16, vr="US")
    item.ModalityLUTType = "US"
    ds.ModalityLUTSequence = Sequence([item])
    ds.WindowCenter = "32768"
    ds.WindowWidth = "65536"
    stored = np.linspace(-2048, 2047, 256).round().astype(np.int16).reshape(16, 16)
    return with_pixels(ds, stored, bits_stored=12)


@scenario
def mlut_8bit(name: str) -> Dataset:
    """8-bit unsigned with an 8-bit Modality LUT (inverting) and a window."""
    ds = secondary(name, SecondaryCaptureImageStorage, ExplicitVRLittleEndian)
    entries = (255 - np.arange(256)).astype(np.uint16)
    item = lut_item(entries, 0, 8, vr="US")
    item.ModalityLUTType = "US"
    ds.ModalityLUTSequence = Sequence([item])
    ds.WindowCenter = "128"
    ds.WindowWidth = "256"
    stored = np.arange(256, dtype=np.uint8).reshape(16, 16)
    return with_pixels(ds, stored, bits_stored=8)


def _macro(**values: object) -> Dataset:
    item = Dataset()
    for keyword, value in values.items():
        setattr(item, keyword, value)
    return item


@scenario
def ect_functional_groups(name: str) -> Dataset:
    """Enhanced CT, 3 frames of 8×8: rescale and window only in functional
    groups, shared by frames 0 and 1; frame 2 overrides both (SIGMOID)."""
    ds = base(name, EnhancedCTImageStorage, ExplicitVRLittleEndian)
    ds.Modality = "CT"
    shared = Dataset()
    shared.PixelValueTransformationSequence = Sequence(
        [_macro(RescaleIntercept="-1024", RescaleSlope="1", RescaleType="HU")]
    )
    shared.FrameVOILUTSequence = Sequence(
        [_macro(WindowCenter="40", WindowWidth="400")]
    )
    ds.SharedFunctionalGroupsSequence = Sequence([shared])
    frames = []
    for i in range(3):
        item = Dataset()
        item.FrameContentSequence = Sequence([_macro(FrameAcquisitionNumber=i)])
        frames.append(item)
    frames[2].PixelValueTransformationSequence = Sequence(
        [_macro(RescaleIntercept="-2048", RescaleSlope="2", RescaleType="HU")]
    )
    frames[2].FrameVOILUTSequence = Sequence(
        [_macro(WindowCenter="-600", WindowWidth="1500", VOILUTFunction="SIGMOID")]
    )
    ds.PerFrameFunctionalGroupsSequence = Sequence(frames)
    stored = (pattern(3 * 64, 4096)).astype(np.uint16).reshape(3, 8, 8)
    return with_pixels(ds, stored, bits_stored=12)
