#!/usr/bin/env bash
# Replays the CI floor job locally: the floor SDK, on a temporary copy of the
# tree, so the working copy's lockfile and .dart_tool stay untouched.
# The floor version is read from .github/workflows/ci.yml (one source of truth).
# Needs mise (it installs that Dart on first use) and yq.
set -euo pipefail
cd "$(dirname "$0")/.."

sdk="$(yq -r '.jobs.floor.steps[] | select(.with.sdk) | .with.sdk' .github/workflows/ci.yml)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

# Tracked files plus new, not-ignored ones: what CI would see after a commit.
git ls-files -z --cached --others --exclude-standard | rsync -a --from0 --files-from=- ./ "$tmp/"

cd "$tmp"
echo "== floor: Dart $sdk"
mise exec "dart@$sdk" -- bash -euo pipefail -c '
  dart --version
  dart pub get >/dev/null
  dart analyze --fatal-infos
  scripts/test_all.sh
'
