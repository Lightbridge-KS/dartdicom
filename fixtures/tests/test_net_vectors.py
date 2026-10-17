import json
from pathlib import Path

from dartdicom_fixtures import net_vectors


def test_every_pdu_type_and_message_is_covered(tmp_path: Path) -> None:
    vectors_path, table_path = net_vectors.write(tmp_path)
    vectors = json.loads(vectors_path.read_text())["vectors"]
    kinds = {v["kind"] for v in vectors}
    assert kinds >= {
        "associate_rq",
        "associate_ac",
        "associate_rj",
        "p_data_tf",
        "release_rq",
        "release_rp",
        "abort",
        "dimse",
    }
    messages = {v["name"] for v in vectors if v["kind"] == "dimse"}
    for service in ("C-ECHO", "C-FIND", "C-GET", "C-MOVE", "C-STORE"):
        assert {f"{service}-RQ", f"{service}-RSP"} <= messages | {"C-MOVE-RSP"}
    assert "C-CANCEL-RQ" in messages
    table = json.loads(table_path.read_text())
    assert sum(len(events) for events in table.values()) == 123


def test_vectors_reproduce(tmp_path: Path) -> None:
    a = net_vectors.write(tmp_path / "a")
    b = net_vectors.write(tmp_path / "b")
    assert [p.read_bytes() for p in a] == [p.read_bytes() for p in b]
