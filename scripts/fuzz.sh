#!/usr/bin/env bash
# Fuzz the core's parser, inflater and force path, pixel's decode and LUT
# pipeline, and net's PDU decoder, framer, assembler and requestor, for
# longer than the dry gates do (they run 2,000 cases per group from seed 0).
#   scripts/fuzz.sh [cases per group] [first seed]
set -euo pipefail
cd "$(dirname "$0")/.."
export DARTDICOM_FUZZ_CASES="${1:-100000}" DARTDICOM_FUZZ_SEED="${2:-0}"
(cd dartdicom && dart test -p vm test/gates/fuzz_test.dart)
(cd dartdicom_pixel && dart test -p vm --timeout=none test/fuzz_test.dart)
(cd dartdicom_net && dart test -p vm --timeout=none test/fuzz_test.dart)
