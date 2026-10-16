#!/usr/bin/env bash
# The fixtures package (fixtures/, a uv project): lint, types, tests, and the
# committed data reproduces exactly (I-28). Versions come from fixtures/uv.lock.
set -euo pipefail
cd "$(dirname "$0")/../fixtures"

uv run --locked ruff check .
uv run --locked ruff format --check .
uv run --locked pyright
uv run --locked pytest -q
uv run --locked fixtures check
