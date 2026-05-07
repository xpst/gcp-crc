#!/usr/bin/env bash
# 10-stop-crc.sh — stop the CRC cluster on the VM. Pass STOP_VM=1 to also
# stop the GCP VM (saves money; disk persists for a later restart).

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

strict_mode
load_env
require_gcloud
require_var GCP_PROJECT
: "${STOP_VM:=0}"

if ! vm_exists; then
  warn "VM '$VM_NAME' doesn't exist — nothing to stop."
  exit 0
fi

vm_status="$(gc compute instances describe "$VM_NAME" --zone="$GCP_ZONE" --format='value(status)' 2>/dev/null || echo UNKNOWN)"

if [[ "$vm_status" == "RUNNING" ]]; then
  log "Stopping CRC on the VM..."
  # shellcheck disable=SC2016
  run_remote 'export PATH="$HOME/.local/bin:$PATH"; crc stop || true'
  ok "crc stop sent."
else
  warn "VM is in state '$vm_status' — skipping 'crc stop'."
fi

if [[ "$STOP_VM" == "1" ]]; then
  if [[ "$vm_status" == "TERMINATED" ]]; then
    ok "VM is already stopped."
  else
    log "Stopping the GCP VM (disk persists)..."
    run gc compute instances stop "$VM_NAME" --zone="$GCP_ZONE"
    ok "VM stopped. Restart later with: gcloud compute instances start $VM_NAME --zone=$GCP_ZONE --project=$GCP_PROJECT"
  fi
else
  ok "CRC stopped. VM is still running. Re-run with STOP_VM=1 to also stop the VM."
fi
