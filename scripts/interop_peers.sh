#!/usr/bin/env bash
# The live gates' interop peers beside Orthanc (M3 decision 2): DCMTK's
# dcmqrscp and storescp, and pynetdicom's qrscp and storescp. Each is
# configured and seeded in a temporary directory; then the given command
# runs, from the caller's directory, with the peers' ports in INTEROP_*;
# then they all stop.
#
#   scripts/interop_peers.sh <command> [args...]
#
# A peer whose tool is missing isn't started, and its tests skip (outside
# CI). pynetdicom comes from fixtures/'s uv environment, called as
# `python -m pynetdicom`: its own storescp/storescu commands would shadow
# DCMTK's, so DCMTK is found on PATH outside uv. Test ports avoid 11112.
set -euo pipefail
caller="$PWD"
cd "$(dirname "$0")/.."
root="$PWD"

dir="$(mktemp -d)"
pids=()
cleanup() {
  for pid in "${pids[@]:-}"; do kill "$pid" 2>/dev/null || true; done
  wait 2>/dev/null || true
  rm -rf "$dir"
}
trap cleanup EXIT
# The live gates' deadline (perl's alarm) and Ctrl-C stop the peers too.
trap 'exit 1' ALRM INT TERM

# The instances every peer holds: the files the Orthanc seed uses.
seed=(
  "$root/fixtures/data/pydicom/CT_small.dcm"
  "$root/fixtures/data/synthetic/ct_signed_explicit_le.dcm"
  "$root/fixtures/data/synthetic/ct_implicit_le.dcm"
  "$root/fixtures/data/synthetic/ct_unsigned_intercept.dcm"
  "$root/fixtures/data/synthetic/dx_monochrome1.dcm"
)

# Waits until something listens on 127.0.0.1:$1 (or fails, naming $2).
wait_port() {
  for _ in $(seq 1 100); do
    if (exec 3<>"/dev/tcp/127.0.0.1/$1") 2>/dev/null; then return 0; fi
    sleep 0.1
  done
  echo "interop: $2 did not start on port $1; its log:" >&2
  cat "$dir/$2.log" >&2 || true
  exit 1
}

# ── DCMTK ────────────────────────────────────────────────────────────────────

if dcmqrscp="$(command -v dcmqrscp)" && dcmqridx="$(command -v dcmqridx)"; then
  mkdir -p "$dir/dcmqrscp-db"
  # Peers ANY: any calling AE title. The HostTable entry makes our
  # StorageScp (DARTDICOM on 14112) a C-MOVE destination. The quota is
  # large: dcmqrscp deletes the oldest studies past it.
  cat >"$dir/dcmqrscp.cfg" <<EOF
NetworkTCPPort  = 14105
MaxPDUSize      = 16384
MaxAssociations = 16
HostTable BEGIN
dartdicom = (DARTDICOM, localhost, 14112)
HostTable END
VendorTable BEGIN
VendorTable END
AETable BEGIN
DCMQRSCP $dir/dcmqrscp-db RW (200, 1024mb) ANY
AETable END
EOF
  "$dcmqridx" "$dir/dcmqrscp-db" "${seed[@]}"
  "$dcmqrscp" -s -c "$dir/dcmqrscp.cfg" 14105 >"$dir/dcmqrscp.log" 2>&1 &
  pids+=("$!")
  wait_port 14105 dcmqrscp
  export INTEROP_DCMQRSCP=14105
  echo "interop: DCMTK dcmqrscp (DCMQRSCP) on 14105"
fi

if storescp="$(command -v storescp)"; then
  mkdir -p "$dir/storescp"
  "$storescp" -aet STORESCP -od "$dir/storescp" +xa -pm 14113 \
    >"$dir/storescp.log" 2>&1 &
  pids+=("$!")
  wait_port 14113 storescp
  export INTEROP_STORESCP=14113 INTEROP_STORESCP_DIR="$dir/storescp"
  export INTEROP_STORESCU="$(command -v storescu || true)"
  echo "interop: DCMTK storescp (STORESCP) on 14113"
fi

# ── pynetdicom ───────────────────────────────────────────────────────────────

if command -v uv >/dev/null; then
  (cd fixtures && uv sync --locked --quiet)
  py="$root/fixtures/.venv/bin/python"
  mkdir -p "$dir/qrscp" "$dir/pystorescp"
  # Absolute paths: relative ones resolve inside the installed package.
  cat >"$dir/qrscp.ini" <<EOF
[DEFAULT]
    ae_title: QRSCP
    port: 14106
    max_pdu: 16382
    acse_timeout: 30
    dimse_timeout: 30
    network_timeout: 30
    bind_address: 127.0.0.1
    instance_location: $dir/qrscp
    database_location: $dir/qrscp.sqlite
    log_identifier: False

[DARTDICOM]
    address: 127.0.0.1
    port: 14112
EOF
  "$py" -m pynetdicom qrscp -c "$dir/qrscp.ini" >"$dir/qrscp.log" 2>&1 &
  pids+=("$!")
  wait_port 14106 qrscp
  "$py" -m pynetdicom storescu 127.0.0.1 14106 "${seed[@]}" \
    -aet SEEDER -aec QRSCP -cx >"$dir/qrscp-seed.log" 2>&1
  "$py" -m pynetdicom storescp 14107 -aet PYSTORESCP -od "$dir/pystorescp" \
    >"$dir/pystorescp.log" 2>&1 &
  pids+=("$!")
  wait_port 14107 pystorescp
  export INTEROP_QRSCP=14106 INTEROP_PYSTORESCP=14107
  export INTEROP_PYSTORESCP_DIR="$dir/pystorescp" INTEROP_PYTHON="$py"
  echo "interop: pynetdicom qrscp (QRSCP) on 14106, storescp (PYSTORESCP) on 14107"
fi

cd "$caller"
"$@"
