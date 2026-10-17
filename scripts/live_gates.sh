#!/usr/bin/env bash
# The live gate suite (blueprint §9): needs a running test PACS
# (scripts/pacs_up.sh). Seeds it, runs the live tests, then the
# retrieve_and_render example, and checks the image it wrote. Every step
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

echo "### live tests (dartdicom_net)"
(cd dartdicom_net && DARTDICOM_LIVE=1 deadline 120 dart test test/live_test.dart)

echo "### examples/bin/retrieve_and_render.dart"
out="$(mktemp -d)"
(cd examples && deadline 120 dart run bin/retrieve_and_render.dart \
  --patient-id=1CT1 --out="$out")
header="$(head -c 15 "$out/frame0.pgm")"
expected="$(printf 'P5\n128 128\n255\n')"
if [ "$header" != "$expected" ]; then
  echo "the example's PGM header is wrong: $(printf '%q' "$header")" >&2
  exit 1
fi
size="$(wc -c <"$out/frame0.pgm" | tr -d ' ')"
[ "$size" -eq $((15 + 128 * 128)) ] || { echo "the PGM is $size bytes" >&2; exit 1; }
echo "live gates: OK"
