"""Large corpora, checked out at pinned commits into the user cache.

Never committed. Pinning by commit means every machine and CI run tests
against the same files.
"""

from __future__ import annotations

import subprocess
from dataclasses import dataclass
from pathlib import Path

from .paths import cache_root


@dataclass(frozen=True)
class Corpus:
    url: str
    commit: str
    license: str


CORPORA = {
    "pydicom-data": Corpus(
        url="https://github.com/pydicom/pydicom-data.git",
        commit="abc42b90985fb6cf385aa4af766d2c9c94a257a4",
        license="MIT (pydicom); files from public samples, de-identified upstream",
    ),
}


def corpus_dir() -> Path:
    return cache_root() / "corpus"


def _git(*args: str, cwd: Path) -> str:
    return subprocess.run(
        ["git", *args], cwd=cwd, check=True, capture_output=True, text=True
    ).stdout.strip()


def fetch(name: str) -> Path:
    """A checkout of corpus `name` at exactly its pinned commit."""
    corpus = CORPORA[name]
    target = corpus_dir() / name
    if (target / ".git").exists() and _git("rev-parse", "HEAD", cwd=target) == (
        corpus.commit
    ):
        return target
    target.mkdir(parents=True, exist_ok=True)
    if not (target / ".git").exists():
        _git("init", "--quiet", cwd=target)
        _git("remote", "add", "origin", corpus.url, cwd=target)
    _git("fetch", "--quiet", "--depth", "1", "origin", corpus.commit, cwd=target)
    _git("checkout", "--quiet", "--force", "FETCH_HEAD", cwd=target)
    return target
