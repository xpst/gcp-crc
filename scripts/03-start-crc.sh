#!/usr/bin/env bash
# 03-start-crc.sh — apply CRC config and start the cluster. Print credentials
# and the recommended next step.

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

strict_mode
load_env
require_gcloud
require_var GCP_PROJECT

if ! vm_exists; then
  die "VM '$VM_NAME' doesn't exist. Run ./scripts/01-provision-vm.sh first." 2
fi

log "Configuring and starting CRC on the VM (this can take 10–20 minutes)..."
# shellcheck disable=SC2016
run_remote_script <<REMOTE
set -euo pipefail
export PATH="\$HOME/.local/bin:\$PATH"
if ! command -v crc >/dev/null 2>&1; then
  echo "[remote] crc not found on PATH — did you run 02-bootstrap.sh?" >&2
  exit 2
fi
crc config set cpus "${CRC_CPUS}"
crc config set memory "${CRC_MEMORY_MIB}"
crc config set disk-size "${CRC_DISK_GIB}"
crc config set preset "${CRC_PRESET}"
crc config set pull-secret-file "\$HOME/pull-secret.json"
# crc start is idempotent: if already Running, it just prints status.
crc start
REMOTE
ok "CRC reports started."

log "Fetching cluster credentials..."
# shellcheck disable=SC2016
creds_json="$(gcloud compute ssh "$VM_NAME" \
  --zone="$GCP_ZONE" --project="$GCP_PROJECT" --tunnel-through-iap \
  --command='export PATH="$HOME/.local/bin:$PATH"; crc console --credentials -o json' 2>/dev/null || true)"

if [[ -z "$creds_json" ]]; then
  warn "Could not fetch credentials JSON. Run './scripts/05-shell.sh' and 'crc console --credentials' manually."
else
  cat <<EOF

═══════════════════════════════════════════════════════════════════════
  CRC is up. Connection details:
═══════════════════════════════════════════════════════════════════════
$creds_json

  Recommended next step (drops you into a shell on the VM with oc
  and helm ready, already logged in as kubeadmin):

    ./scripts/05-shell.sh

  Need to push your charts/scripts onto the VM?

    gcloud compute scp --recurse ./your-stuff $VM_NAME:~/work/ \\
      --zone=$GCP_ZONE --project=$GCP_PROJECT --tunnel-through-iap

  When you're done for the day:

    ./scripts/10-stop-crc.sh                  # keep the disk
    STOP_VM=1 ./scripts/10-stop-crc.sh        # also stop the VM (saves \$\$)
    ./scripts/99-destroy.sh                   # delete everything
═══════════════════════════════════════════════════════════════════════
EOF
fi
