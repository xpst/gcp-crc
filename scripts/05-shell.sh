#!/usr/bin/env bash
# 05-shell.sh — primary "use" entrypoint. Drops you into a shell on the VM
# with `oc` and `helm` on PATH and `oc whoami` already returning kubeadmin.
#
# From there you can:
#   helm install my-release ./your-chart
#   oc get pods -A
#   ./your-script.sh

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

ssh_args=( "$VM_NAME" "--zone=$GCP_ZONE" "--project=$GCP_PROJECT" "--tunnel-through-iap" )
if [[ -n "${SSH_USER}" ]]; then
  ssh_args[0]="${SSH_USER}@${VM_NAME}"
fi

# The remote command logs in as kubeadmin and then exec's an interactive bash.
# Using `exec bash -l` so the user lands in a normal login shell.
remote_cmd='
set -euo pipefail
export PATH="$HOME/.local/bin:$PATH"
if ! crc status 2>/dev/null | grep -q "OpenShift:.*Running"; then
  echo "[remote] CRC is not running. Run ./scripts/03-start-crc.sh from your laptop." >&2
  exit 3
fi
eval "$(crc oc-env)"
KUBEADMIN_PW="$(crc console --credentials -o json | python3 -c "import json,sys; print(json.load(sys.stdin)[\"clusterConfig\"][\"adminCredentials\"][\"password\"])" )"
oc login -u kubeadmin -p "$KUBEADMIN_PW" https://api.crc.testing:6443 --insecure-skip-tls-verify=true >/dev/null
echo
echo "  Logged in as: $(oc whoami)"
echo "  API:          https://api.crc.testing:6443"
echo "  Console:      $(crc console --url 2>/dev/null || echo unknown)"
echo "  oc + helm are on PATH. Have fun."
echo
exec bash -l
'

log "Connecting to $VM_NAME..."
exec gcloud compute ssh "${ssh_args[@]}" --command="$remote_cmd" -- -t
