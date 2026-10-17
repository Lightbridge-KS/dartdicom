from pathlib import Path

from dartdicom_fixtures.golden import normalize, record
from dartdicom_fixtures.paths import DATA


def test_short_bytes_are_kept_as_hex() -> None:
    assert normalize(b"\x01\x02") == {"bytes": "0102"}


def test_long_bytes_become_length_and_digest() -> None:
    value = normalize(bytes(100))
    assert value["bytes_len"] == 100
    assert len(value["sha256"]) == 64


def test_multi_values_normalize_elementwise() -> None:
    assert normalize(["1", 2, 3.5]) == ["1", 2, 3.5]


def test_a_file_without_a_preamble_is_read_with_force(tmp_path: Path) -> None:
    source = DATA / "synthetic" / "ct_signed_explicit_le.dcm"
    bare = tmp_path / "bare.dcm"
    bare.write_bytes(source.read_bytes()[132:])  # no preamble, no DICM
    golden = record(bare, tmp_path)
    assert golden["force"] is True
    assert golden["meta"][0]["tag"] == "00020000"


def test_a_clean_file_records_no_force_and_no_raw() -> None:
    source = DATA / "synthetic" / "ct_signed_explicit_le.dcm"
    golden = record(source, DATA)
    assert "force" not in golden
    assert not any("raw" in e for e in golden["dataset"])
