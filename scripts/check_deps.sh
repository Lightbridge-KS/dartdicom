#!/usr/bin/env bash
# I-3: each published package's `dependencies` stay within its row of the
# import matrix (docs/structure/01-codebase-blueprint.md §4). Needs yq (v4).
set -euo pipefail
cd "$(dirname "$0")/.."

allowed_for() {
  case "$1" in
    dartdicom) echo "" ;;
    dartdicom_pixel | dartdicom_net) echo "dartdicom" ;;
    dartdicom_web) echo "dartdicom http" ;;
    *) echo "unknown package: $1" >&2; exit 2 ;;
  esac
}

status=0
for pkg in dartdicom dartdicom_pixel dartdicom_net dartdicom_web; do
  allowed=" $(allowed_for "$pkg") "
  for dep in $(yq -r '(.dependencies // {}) | keys | .[]' "$pkg/pubspec.yaml"); do
    case "$allowed" in
      *" $dep "*) ;;
      *) echo "I-3: $pkg must not depend on '$dep' (allowed:${allowed% })"; status=1 ;;
    esac
  done
done
[ "$status" -eq 0 ] && echo "I-3: dependencies OK"
exit "$status"
