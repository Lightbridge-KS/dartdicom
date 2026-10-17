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
    ExplicitVRBigEndian,
    ExplicitVRLittleEndian,
    ImplicitVRLittleEndian,
    MultiFrameGrayscaleWordSecondaryCaptureImageStorage,
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
