# dartdicom-fixtures

The test data for dartdicom, and the small Python package that makes it. Never published.

| Path | What |
|---|---|
| `data/synthetic/` | Named scenarios built from scratch with pydicom. Every patient field is synthetic. |
| `data/pydicom/` | Unchanged copies of pydicom's bundled test files (MIT). |
| `data/golden/` | pydicom's reading of every fixture: each element (tag, VR, normalized value) plus the pixel array's shape, dtype and SHA-256. The Dart tests compare against these. |
| `data/PROVENANCE.md` | Source and checksum of every file (generated). |

Everything in `data/` is generated and reproduces byte for byte. UIDs are name-based and dates fixed, and pydicom and numpy are pinned in `uv.lock`.

## CLI

From this directory (or use the `just` recipes at the repo root):

```bash
uv run fixtures list                 # scenarios and curated files
uv run fixtures build                # regenerate data/ fixtures + PROVENANCE.md   (just fixtures)
uv run fixtures golden               # regenerate data/golden/                     (just fixtures)
uv run fixtures check                # fail unless data/ reproduces exactly (I-28) (just fixtures-check)
uv run fixtures corpus fetch         # pinned corpora into the user cache          (just corpus)
uv run fixtures pydicom-dictionary   # pydicom's dictionary as JSON                (just dict-crosscheck)
```

Exit codes: `0` OK, `1` stale or failed check, `2` usage error. Corpora go to `$DARTDICOM_CACHE`, else `$XDG_CACHE_HOME/dartdicom`, else `~/.cache/dartdicom`.

## Adding a scenario

1. Write a function in `src/dartdicom_fixtures/scenarios.py`, decorated with `@scenario`, whose docstring's first line describes it.
2. Run `just fixtures`, then `just fixtures-check`.
3. Commit the new `.dcm`, its golden JSON and the updated `PROVENANCE.md` together.

Synthetic data only: no real patient data, ever.
