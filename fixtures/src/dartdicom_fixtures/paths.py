"""Where things live: the committed data and the user cache."""

from __future__ import annotations

import os
from pathlib import Path

# fixtures/src/dartdicom_fixtures/paths.py → fixtures/ (uv installs the project
# in editable mode, so this resolves to the checkout).
PROJECT = Path(__file__).resolve().parents[2]
DATA = PROJECT / "data"

# Layout inside a data root (the committed DATA, or a temporary one for `check`).
SYNTHETIC = "synthetic"
PYDICOM = "pydicom"
GOLDEN = "golden"
LUT = "lut"
NET = "net"
PROVENANCE = "PROVENANCE.md"


def cache_root() -> Path:
    """$DARTDICOM_CACHE, else $XDG_CACHE_HOME/dartdicom, else ~/.cache/dartdicom."""
    if root := os.environ.get("DARTDICOM_CACHE"):
        return Path(root)
    xdg = os.environ.get("XDG_CACHE_HOME")
    return Path(xdg) / "dartdicom" if xdg else Path.home() / ".cache" / "dartdicom"
