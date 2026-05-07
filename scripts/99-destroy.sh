#!/usr/bin/env bash
# 99-destroy.sh — best-effort 'crc stop' then delete the GCP VM.
# Interactive confirmation required. Pass FORCE=1 to skip the prompt.

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

strict_mode
load_env
require_gcloud
require_var GCP_PROJECT
: "${FORCE:=0}"

if ! vm_exists; then
  ok "VM '$VM_NAME' doesn't exist in $GCP_ZONE — nothing to destroy."
  exit 0
fi

cat >&2 <<EOF

  ⚠  About to DELETE the VM and its boot disk:
       project: $GCP_PROJECT
       zone:    $GCP_ZONE
       name:    $VM_NAME

     This is irreversible. CRC state, the pull secret on the VM, and any
     scripts/charts you uploaded to ~/work will be lost.

EOF

if [[ "$FORCE" != "1" ]]; then
  printf '  Type the VM name (%s) to confirm: ' "$VM_NAME" >&2
  read -r answer
  if [[ "$answer" != "$VM_NAME" ]]; then
    die "Confirmation did not match. Aborted." 1
  fi
fi

vm_status="$(gc compute instances describe "$VM_NAME" --zone="$GCP_ZONE" --format='value(status)' 2>/dev/null || echo UNKNOWN)"
if [[ "$vm_status" == "RUNNING" ]]; then
  log "Best-effort 'crc stop' before deletion..."
  # shellcheck disable=SC2016
  run_remote 'export PATH="$HOME/.local/bin:$PATH"; crc stop || true' || warn "crc stop failed — proceeding anyway."
fi

log "Deleting VM..."
run gc compute instances delete "$VM_NAME" --zone="$GCP_ZONE" --quiet
ok "VM '$VM_NAME' deleted."
