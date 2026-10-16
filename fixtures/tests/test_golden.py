from dartdicom_fixtures.golden import normalize


def test_short_bytes_are_kept_as_hex() -> None:
    assert normalize(b"\x01\x02") == {"bytes": "0102"}


def test_long_bytes_become_length_and_digest() -> None:
    value = normalize(bytes(100))
    assert value["bytes_len"] == 100
    assert len(value["sha256"]) == 64


def test_multi_values_normalize_elementwise() -> None:
    assert normalize(["1", 2, 3.5]) == ["1", 2, 3.5]
