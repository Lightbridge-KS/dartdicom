#!/usr/bin/env bash
# The written-file gate (M2 step 6; PRD C-11, I-18): dartdicom writes every
# fixture (with --corpus, every cached pydicom-data file) in each transfer
# syntax it can; pydicom reads what it wrote; test/written_test.dart compares
# that with dartdicom's reading and the source, and runs DCMTK's dcmdump.
#   scripts/written_gate.sh             the committed fixtures (a dry gate)
#   scripts/written_gate.sh --corpus    the corpus (the CI corpus job)
set -euo pipefail
cd "$(dirname "$0")/.."
root="$PWD"

if [ "${1:-}" = "--corpus" ]; then
  # The cache layout corpus_test.dart reads.
  cache="${DARTDICOM_CACHE:-${XDG_CACHE_HOME:-$HOME/.cache}/dartdicom}"
  sources=("$cache/corpus/pydicom-data=$cache/golden/pydicom-data")
else
  sources=(
    "$root/fixtures/data/synthetic=$root/fixtures/data/golden/synthetic"
    "$root/fixtures/data/pydicom=$root/fixtures/data/golden/pydicom"
  )
fi

out="$(mktemp -d)"
trap '[ -n "${KEEP_WRITTEN:-}" ] && echo "kept $out" || rm -rf "$out"' EXIT

(cd dartdicom && dart run tool/write_all.dart --out "$out" "${sources[@]}")
(cd fixtures && uv run --locked fixtures golden --written "$out")
(cd dartdicom && DARTDICOM_WRITTEN="$out" dart test --reporter=failures-only test/written_test.dart)
echo "written files: pydicom, dartdicom and DCMTK agree"
