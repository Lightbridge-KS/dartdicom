#!/usr/bin/env bash
# The dry gate suite (hermetic), the same one CI runs on every PR.
#   scripts/dry_gates.sh            everything, web tests on node
#   WEB_PLATFORM=chrome scripts/dry_gates.sh
set -euo pipefail
cd "$(dirname "$0")/.."

dirs="dartdicom dartdicom_pixel dartdicom_net dartdicom_web examples"
web="${WEB_PLATFORM:-node}"

step() { echo; echo "### $*"; }

step "format";   dart format --output=none --set-exit-if-changed $dirs
step "analyze";  dart analyze --fatal-infos
step "deps";     scripts/check_deps.sh
step "test vm";  scripts/test_all.sh
step "test $web"; scripts/test_all.sh -p "$web"
step "wasm";     out="$(mktemp -d)"
for pkg in dartdicom dartdicom_pixel; do
  dart compile wasm "$pkg/example/${pkg}_example.dart" -o "$out/$pkg.wasm" >/dev/null && echo "$pkg compiles to Wasm"
done
step "fixtures (python)"
if command -v uv >/dev/null; then
  scripts/check_fixtures.sh
elif [ -n "${CI:-}" ]; then
  echo "uv is required in CI"; exit 1
else
  echo "skipped (uv not installed; CI runs it)"
fi
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
