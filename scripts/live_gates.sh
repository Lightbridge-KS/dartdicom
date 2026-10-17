#!/usr/bin/env bash
# The live gate suite (blueprint §9): needs a running test PACS
# (scripts/pacs_up.sh). Seeds it, runs the interop matrix (Orthanc, DCMTK,
# pynetdicom), then the retrieve_and_render example both ways, and checks
# the image it wrote. Every step
# also has a deadline, a backstop behind the protocol's own timers (N-13).
set -euo pipefail
cd "$(dirname "$0")/.."

# `timeout` isn't on macOS by default; perl's alarm is everywhere.
deadline() { local s="$1"; shift; perl -e 'alarm shift; exec @ARGV' "$s" "$@"; }

http="http://localhost:${ORTHANC_HTTP_PORT:-18042}"
curl -sf "$http/system" >/dev/null || {
  echo "no test PACS at $http; start one with scripts/pacs_up.sh (just pacs-up)" >&2
  exit 1
}

echo "### seed"
scripts/pacs_seed.sh

# The interop matrix: Orthanc, plus the DCMTK and pynetdicom peers that
# scripts/interop_peers.sh starts. One file at a time: the C-MOVE tests all
# take the StorageScp port.
echo "### live tests (dartdicom_net): Orthanc, DCMTK, pynetdicom"
(cd dartdicom_net && DARTDICOM_LIVE=1 deadline 300 ../scripts/interop_peers.sh \
  dart test --concurrency=1 test/live/)

# The example both ways: C-GET (the default), then C-MOVE into its own
# StorageScp.
for via in get move; do
  echo "### examples/bin/retrieve_and_render.dart --via=$via"
  out="$(mktemp -d)"
  (cd examples && deadline 120 dart run bin/retrieve_and_render.dart \
    --patient-id=1CT1 --out="$out" --via="$via")
  header="$(head -c 15 "$out/frame0.pgm")"
  expected="$(printf 'P5\n128 128\n255\n')"
  if [ "$header" != "$expected" ]; then
    echo "the example's PGM header is wrong: $(printf '%q' "$header")" >&2
    exit 1
  fi
  size="$(wc -c <"$out/frame0.pgm" | tr -d ' ')"
  [ "$size" -eq $((15 + 128 * 128)) ] || { echo "the PGM is $size bytes" >&2; exit 1; }
done
echo "live gates: OK"
