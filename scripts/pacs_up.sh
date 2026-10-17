#!/usr/bin/env bash
# Starts the test PACS (docker/compose.yaml) and waits until Orthanc answers.
# Ports come from ORTHANC_DIMSE_PORT / ORTHANC_HTTP_PORT (14242 / 18042).
set -euo pipefail
cd "$(dirname "$0")/.."

http="http://localhost:${ORTHANC_HTTP_PORT:-18042}"
docker compose -f docker/compose.yaml up -d
for _ in $(seq 1 45); do
  curl -sf "$http/system" >/dev/null && break
  sleep 2
done
curl -sf "$http/system" | jq -c '{Name, DicomAet, Version}'
