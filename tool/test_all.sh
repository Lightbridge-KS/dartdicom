#!/usr/bin/env bash
# Runs `dart test` in every workspace member that has tests.
#   tool/test_all.sh               VM, every member
#   tool/test_all.sh -p chrome     a web platform: web-capable members only
#                                  (dartdicom_net needs dart:io, so it is skipped)
set -euo pipefail
cd "$(dirname "$0")/.."

members="dartdicom dartdicom_pixel dartdicom_net dartdicom_web examples"
if [ "${1:-}" = "-p" ] && [ "${2:-vm}" != "vm" ]; then
  members="dartdicom dartdicom_pixel dartdicom_web"
fi

for m in $members; do
  [ -d "$m/test" ] || continue
  echo "== $m: dart test $*"
  (cd "$m" && dart test "$@")
done
