# dartdicom: every workflow, in one place. Recipes front the tool/ scripts,
# which stay the implementation (CI calls them directly, so neither CI nor a
# contributor without `just` needs it).
set shell := ["bash", "-euo", "pipefail", "-c"]

members := "dartdicom dartdicom_pixel dartdicom_net dartdicom_web examples"

# The test PACS ports; docker/compose.yaml reads the same variables.
dimse_port := env_var_or_default("ORTHANC_DIMSE_PORT", "14242")
http_port := env_var_or_default("ORTHANC_HTTP_PORT", "18042")
compose := "docker compose -f docker/compose.yaml"

_default:
    @just --list --unsorted

# ── Setup ─────────────────────────────────────────────────────────────────────

# Resolve every workspace member.
get:
    dart pub get

# ── Dry gates (hermetic; CI runs the same scripts) ────────────────────────────

# The whole dry suite: format, analyze, deps, VM + web tests, Wasm, publish dry-run.
dry web="node":
    WEB_PLATFORM={{web}} tool/dry_gates.sh

# Format every member in place.
fmt:
    dart format {{members}}

# Fail if anything isn't formatted.
fmt-check:
    dart format --output=none --set-exit-if-changed {{members}}

# Static analysis, infos included.
analyze:
    dart analyze --fatal-infos

# Package dependencies stay within the import matrix (I-3).
deps:
    tool/check_deps.sh

# Tests on the VM, every member (extra args go to `dart test`).
test *args:
    tool/test_all.sh {{args}}

# Tests compiled to the web (node or chrome), web-capable members only.
test-web platform="node":
    tool/test_all.sh -p {{platform}}

# Replay the CI floor job (Dart 3.6) on a temporary copy of the tree. Needs mise.
floor:
    tool/floor_check.sh

# Run every pre-commit hook on every file.
hooks:
    prek run --all-files

# ── Test PACS (live gates) ────────────────────────────────────────────────────

# Start the Orthanc test PACS (DIMSE :14242, HTTP :18042 by default) and wait for it.
pacs-up:
    {{compose}} up -d
    for i in $(seq 1 45); do curl -sf "http://localhost:{{http_port}}/system" >/dev/null && break; sleep 2; done
    curl -s "http://localhost:{{http_port}}/system" | jq -c '{Name, DicomAet, Version}'

# Stop and remove the test PACS (its data is not persisted).
pacs-down:
    {{compose}} down

# C-ECHO the test PACS with DCMTK's echoscu.
pacs-echo:
    echoscu -aec ORTHANC localhost {{dimse_port}} && echo "C-ECHO OK on :{{dimse_port}}"

# Follow the test PACS logs.
pacs-logs:
    {{compose}} logs -f
