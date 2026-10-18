"""The `fixtures` CLI: build, verify and fetch dartdicom's test data.

Exit codes: 0 OK · 1 stale or failed check · 2 usage error.
"""

import json
import tempfile
from pathlib import Path
from typing import Annotated

import typer

from . import corpus, curated, golden, lut, net_vectors, pydicom_dictionary, scenarios
from .paths import DATA, GOLDEN, LUT, NET, PROVENANCE, PYDICOM, SYNTHETIC, cache_root
from .provenance import Row, render

app = typer.Typer(
    help="Test data for dartdicom: synthetic scenarios, curated pydicom copies, "
    "pydicom's golden reading of each, and pinned corpora.",
    no_args_is_help=True,
    add_completion=False,
)
corpus_app = typer.Typer(help="Large corpora, pinned, in the user cache.")
app.add_typer(corpus_app, name="corpus")


def build_into(data_root: Path) -> list[Row]:
    """Writes the synthetic and curated fixtures, the net vectors, and
    PROVENANCE.md."""
    rows: list[Row] = []
    for group in (SYNTHETIC, PYDICOM):
        (data_root / group).mkdir(parents=True, exist_ok=True)
    for name, fn in scenarios.SCENARIOS.items():
        scenarios.write(name, data_root / SYNTHETIC)
        rows.append(Row(f"{SYNTHETIC}/{name}.dcm", "synthetic", scenarios.describe(fn)))
    for name, note in curated.FILES.items():
        curated.copy(name, data_root / PYDICOM)
        rows.append(Row(f"{PYDICOM}/{name}", "pydicom 3.0.2 test data", note))
    for path in net_vectors.write(data_root / NET):
        rows.append(
            Row(
                f"{NET}/{path.name}",
                "pynetdicom 3.0.4 encodings",
                net_vectors.describe(path.name),
            )
        )
    (data_root / PROVENANCE).write_text(render(rows, data_root))
    return rows


def golden_into(data_root: Path) -> int:
    """Writes golden JSON for every fixture under `data_root`, and the LUT
    goldens of the grayscale native ones (F47)."""
    sources = sorted(
        p for group in (SYNTHETIC, PYDICOM) for p in (data_root / group).glob("*.dcm")
    )
    for src in sources:
        relative = src.relative_to(data_root).with_suffix(".json")
        target = data_root / GOLDEN / relative
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text(golden.golden(src, data_root))
        if (text := lut.golden(src, data_root, strict=True)) is not None:
            (data_root / LUT / relative).parent.mkdir(parents=True, exist_ok=True)
            (data_root / LUT / relative).write_text(text)
    return len(sources)


@app.command()
def build() -> None:
    """Regenerate the synthetic and curated fixtures and PROVENANCE.md."""
    rows = build_into(DATA)
    typer.echo(f"wrote {len(rows)} fixtures and {PROVENANCE}")


def corpus_golden_into(name: str) -> int:
    """Writes golden JSON for every file of corpus `name` into the cache."""
    root = corpus.corpus_dir() / name
    if not (root / ".git").exists():
        raise typer.BadParameter(
            f"corpus {name} isn't fetched; run `fixtures corpus fetch`"
        )
    stamps = {
        "corpus": f"{name}@{corpus.CORPORA[name].commit[:7]}",
        "golden_py": golden.source_hash(),
    }
    lut_stamps = {"corpus": stamps["corpus"], **lut.stamp()}
    sources = sorted(p for p in root.rglob("*.dcm") if ".git" not in p.parts)
    for src in sources:
        relative = src.relative_to(root).with_suffix(".json")
        target = cache_root() / GOLDEN / name / relative
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text(golden.golden_or_error(src, root, **stamps))
        lut_target = cache_root() / LUT / name / relative
        try:
            text = lut.golden(src, root, strict=False, **lut_stamps)
        except Exception as exc:  # unreadable: core's golden records why
            text = json.dumps(
                {"file": relative.as_posix(), "error": type(exc).__name__}
            )
        if text is not None:
            lut_target.parent.mkdir(parents=True, exist_ok=True)
            lut_target.write_text(text)
        elif lut_target.exists():
            lut_target.unlink()
    return len(sources)


def written_golden_into(out: Path) -> int:
    """Writes pydicom's reading of every file `write_all.dart` wrote into
    `out`, beside it as `<target>.json`."""
    manifest = json.loads((out / "manifest.json").read_text())
    count = 0
    for entry in manifest:
        if "written" not in entry:
            continue
        written = Path(entry["written"])
        written.with_suffix(".json").write_text(golden.golden_or_error(written, out))
        count += 1
    return count


@app.command("golden")
def golden_cmd(
    corpora: Annotated[
        bool,
        typer.Option(
            "--corpus",
            help="Export the cached corpora into the cache instead of the fixtures.",
        ),
    ] = False,
    written: Annotated[
        Path | None,
        typer.Option(
            "--written",
            help="Export the files `dart run tool/write_all.dart` wrote into "
            "this directory, beside each one.",
        ),
    ] = None,
) -> None:
    """Regenerate pydicom's golden JSON for every fixture (or corpus file, or
    written file)."""
    if written is not None:
        typer.echo(f"wrote {written_golden_into(written)} golden files")
        return
    if corpora:
        for name in corpus.CORPORA:
            count = corpus_golden_into(name)
            typer.echo(f"wrote {count} golden files for {name} into the cache")
        return
    typer.echo(f"wrote {golden_into(DATA)} golden files")


@app.command()
def check() -> None:
    """Fail unless every fixture, golden file and PROVENANCE.md reproduces
    byte for byte (I-28)."""
    with tempfile.TemporaryDirectory() as tmp:
        fresh = Path(tmp)
        build_into(fresh)
        golden_into(fresh)
        expected = {p.relative_to(fresh) for p in fresh.rglob("*") if p.is_file()}
        actual = {p.relative_to(DATA) for p in DATA.rglob("*") if p.is_file()}
        stale = sorted(
            str(p)
            for p in expected
            if p not in actual or (DATA / p).read_bytes() != (fresh / p).read_bytes()
        )
        extra = sorted(str(p) for p in actual - expected)
    if stale or extra:
        for p in stale:
            typer.echo(f"stale: {p}", err=True)
        for p in extra:
            typer.echo(f"not generated: {p}", err=True)
        typer.echo("run `just fixtures` to regenerate", err=True)
        raise typer.Exit(code=1)
    typer.echo(
        f"fixtures, golden files and provenance are up to date ({len(expected)} files)"
    )


@app.command("list")
def list_cmd() -> None:
    """List the synthetic scenarios and curated files."""
    for name, fn in scenarios.SCENARIOS.items():
        typer.echo(f"{SYNTHETIC}/{name}.dcm  {scenarios.describe(fn)}")
    for name, note in curated.FILES.items():
        typer.echo(f"{PYDICOM}/{name}  {note}")


@corpus_app.command("fetch")
def corpus_fetch() -> None:
    """Check out every corpus at its pinned commit (a no-op when current)."""
    for name, spec in corpus.CORPORA.items():
        path = corpus.fetch(name)
        count = sum(1 for _ in path.rglob("*.dcm"))
        typer.echo(f"{name} @ {spec.commit[:12]}: {count} .dcm files at {path}")


@corpus_app.command("where")
def corpus_where() -> None:
    """Print the corpus cache directory."""
    typer.echo(corpus.corpus_dir())


@app.command("pydicom-dictionary")
def pydicom_dictionary_cmd(
    out: Annotated[
        Path | None, typer.Option(help="Write here instead of stdout.")
    ] = None,
) -> None:
    """Export pydicom's data dictionary as JSON (for `just dict-crosscheck`)."""
    text = json.dumps(pydicom_dictionary.export(), indent=0, sort_keys=True)
    if out is None:
        typer.echo(text)
    else:
        out.parent.mkdir(parents=True, exist_ok=True)
        out.write_text(text)
        typer.echo(f"wrote {out}", err=True)
