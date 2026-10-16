#!/usr/bin/env bash
# The dry gate suite (hermetic), the same one CI runs on every PR.
#   tool/dry_gates.sh            everything, web tests on node
#   WEB_PLATFORM=chrome tool/dry_gates.sh
set -euo pipefail
cd "$(dirname "$0")/.."

dirs="dartdicom dartdicom_pixel dartdicom_net dartdicom_web examples"
web="${WEB_PLATFORM:-node}"

step() { echo; echo "### $*"; }

step "format";   dart format --output=none --set-exit-if-changed $dirs
step "analyze";  dart analyze --fatal-infos
step "deps";     tool/check_deps.sh
step "test vm";  tool/test_all.sh
step "test $web"; tool/test_all.sh -p "$web"
step "wasm";     out="$(mktemp -d)"; dart compile wasm dartdicom/example/dartdicom_example.dart -o "$out/core.wasm" >/dev/null && echo "core compiles to Wasm"
step "publish dry-run"
for p in dartdicom dartdicom_pixel dartdicom_net dartdicom_web; do
  # pub warns (exit 65) about uncommitted changes. Locally, skip a dirty
  # package; CI checks out a clean tree, so it always runs there.
  if [ -z "${CI:-}" ] && [ -n "$(git status --porcelain -- "$p" 2>/dev/null)" ]; then
    echo "$p: skipped (uncommitted changes; CI runs it)"
    continue
  fi
  (cd "$p" && dart pub publish --dry-run >/dev/null 2>&1) || { echo "publish dry-run failed: $p"; (cd "$p" && dart pub publish --dry-run); exit 1; }
  echo "$p: OK"
done
