#!/usr/bin/env bash
# Fuzz the parser, the inflater and the force path for longer than the dry
# gates do (they run 2,000 cases per group from seed 0).
#   scripts/fuzz.sh [cases per group] [first seed]
set -euo pipefail
cd "$(dirname "$0")/../dartdicom"
DARTDICOM_FUZZ_CASES="${1:-100000}" DARTDICOM_FUZZ_SEED="${2:-0}" \
  dart test -p vm test/gates/fuzz_test.dart
