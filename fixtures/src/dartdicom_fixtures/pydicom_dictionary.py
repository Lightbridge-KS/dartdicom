"""pydicom's data dictionary as JSON, for the Dart generator's cross-check
(`just dict-crosscheck`).

Shape: {"GGGGEEEE": [VR, VM, name, retired, keyword]}, uppercase hex, with
repeater masks such as "60xx3000" as pydicom writes them.
"""

from __future__ import annotations

from pydicom._dicom_dict import (  # pyright: ignore[reportPrivateUsage]
    DicomDictionary,
    RepeatersDictionary,
)


def export() -> dict[str, list[str]]:
    entries: dict[str, list[str]] = {}
    for tag, (vr, vm, name, retired, keyword) in DicomDictionary.items():
        entries[f"{tag:08X}"] = [vr, vm, name, retired, keyword]
    for mask, (vr, vm, name, retired, keyword) in RepeatersDictionary.items():
        entries[mask.upper().replace("X", "x")] = [vr, vm, name, retired, keyword]
    return entries
