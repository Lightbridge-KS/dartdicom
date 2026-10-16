from pathlib import Path

import pydicom
import pytest

from dartdicom_fixtures import scenarios


def test_uids_are_deterministic_and_valid() -> None:
    a = scenarios.uid("ct", "study")
    assert a == scenarios.uid("ct", "study")
    assert a != scenarios.uid("ct", "series")
    assert a.startswith("2.25.") and len(a) <= 64


def test_every_scenario_has_a_description() -> None:
    assert scenarios.SCENARIOS
    for fn in scenarios.SCENARIOS.values():
        assert scenarios.describe(fn)


@pytest.mark.parametrize("name", sorted(scenarios.SCENARIOS))
def test_scenario_writes_a_readable_part10_file(name: str, tmp_path: Path) -> None:
    ds = pydicom.dcmread(scenarios.write(name, tmp_path))
    assert ds.SOPInstanceUID == scenarios.uid(name, "instance")
    assert str(ds.PatientName).startswith(("Synthetic", "Müller", "Çelik"))
    if "PixelData" in ds:
        assert ds.pixel_array.size > 0
