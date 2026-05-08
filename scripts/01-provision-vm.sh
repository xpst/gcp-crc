#!/usr/bin/env bash
# 01-provision-vm.sh — create the GCP VM with nested virtualization enabled.
# Idempotent: skips creation if the VM already exists.

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

strict_mode
load_env
require_gcloud
require_var GCP_PROJECT

if vm_exists; then
  ok "VM '$VM_NAME' already exists in $GCP_ZONE — skipping create."
else
  create_args=(
    "$VM_NAME"
    --zone="$GCP_ZONE"
    --machine-type="$MACHINE_TYPE"
    --min-cpu-platform="$MIN_CPU_PLATFORM"
    --image-project="$IMAGE_PROJECT"
    --image-family="$IMAGE_FAMILY"
    --boot-disk-size="$BOOT_DISK_SIZE"
    --boot-disk-type="$BOOT_DISK_TYPE"
    --enable-nested-virtualization
    --metadata=enable-oslogin=TRUE
  )
  if is_truthy "$ENABLE_SPOT_VM"; then
    warn "ENABLE_SPOT_VM=true: creating a Spot VM. GCP may preempt it at any time and the boot disk will be DELETED on preemption."
    create_args+=( --provisioning-model=SPOT --instance-termination-action=DELETE )
  fi
  log "Creating VM '$VM_NAME' in $GCP_ZONE..."
  run gc compute instances create "${create_args[@]}"
  ok "VM created."
fi

log "Waiting for SSH to become ready (up to ~3 min)..."
attempts=0
max_attempts=18
until run_remote_quiet 'echo ready'; do
  attempts=$((attempts + 1))
  if (( attempts >= max_attempts )); then
    die "SSH never came up after $((max_attempts * 10))s. Check 'gcloud compute instances describe $VM_NAME'." 3
  fi
  sleep 10
done
ok "SSH is up."

log "Verifying nested virtualization is exposed..."
if run_remote_quiet 'grep -E "vmx|svm" /proc/cpuinfo'; then
  ok "Nested virt CPU flag is present."
else
  warn "Could not detect vmx/svm in /proc/cpuinfo — bootstrap may fail."
fi

ok "Provision done. Next: ./scripts/02-bootstrap.sh"
