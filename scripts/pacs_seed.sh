#!/usr/bin/env bash
# Uploads a fixed set of fixtures to the test PACS over its REST API: one
# study per file, each with its own SOP Instance UID (the MR_small* and
# SC_rgb* files share UIDs, so they are left out). Re-running is harmless:
# Orthanc answers AlreadyStored.
set -euo pipefail
cd "$(dirname "$0")/.."

http="http://localhost:${ORTHANC_HTTP_PORT:-18042}"
files=(
  fixtures/data/pydicom/CT_small.dcm
  fixtures/data/synthetic/ct_signed_explicit_le.dcm
  fixtures/data/synthetic/ct_implicit_le.dcm
  fixtures/data/synthetic/ct_unsigned_intercept.dcm
  fixtures/data/synthetic/dx_monochrome1.dcm
)
ids=()
for f in "${files[@]}"; do
  reply="$(curl -sf -X POST "$http/instances" --data-binary "@$f")"
  status="$(jq -r .Status <<<"$reply")"
  case "$status" in
    Success | AlreadyStored) ;;
    *) echo "seed: $f: unexpected status '$status'" >&2; exit 1 ;;
  esac
  ids+=("$(jq -r .ID <<<"$reply")")
  echo "seed: $f ($status)"
done
distinct="$(printf '%s\n' "${ids[@]}" | sort -u | wc -l | tr -d ' ')"
if [ "$distinct" -ne "${#files[@]}" ]; then
  echo "seed: two fixtures share an instance; pick files with distinct UIDs" >&2
  exit 1
fi
