#!/usr/bin/env bash
# 04-tunnel.sh (OPTIONAL) — open SSH tunnels so you can run oc/helm from
# your LAPTOP instead of the VM. Foreground; Ctrl-C to close.
#
# Before running this, edit your laptop's /etc/hosts to add:
#   127.0.0.1 api.crc.testing console-openshift-console.apps-crc.testing oauth-openshift.apps-crc.testing default-route-openshift-image-registry.apps-crc.testing
#
# Then in another terminal:
#   oc login -u kubeadmin -p <password> https://api.crc.testing:6443

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

# Detect ports already in use locally — gcloud will fail confusingly otherwise.
check_port() {
  local port="$1" label="$2"
  if command -v ss >/dev/null 2>&1 && ss -ltn "( sport = :$port )" 2>/dev/null | grep -q LISTEN; then
    warn "Local port $port ($label) is already in use. Override LOCAL_${label^^}_PORT in .env."
    return 1
  fi
  return 0
}

err=0
check_port "$LOCAL_API_PORT"   API   || err=1
check_port "$LOCAL_HTTP_PORT"  HTTP  || err=1
check_port "$LOCAL_HTTPS_PORT" HTTPS || err=1
(( err == 0 )) || die "Resolve port conflicts above and rerun." 1

if [[ "$LOCAL_HTTP_PORT" -lt 1024 || "$LOCAL_HTTPS_PORT" -lt 1024 ]] && [[ $EUID -ne 0 ]]; then
  warn "Binding to ports <1024 typically needs sudo. If gcloud fails to bind, override LOCAL_HTTP_PORT/LOCAL_HTTPS_PORT to (e.g.) 8080/8443."
fi

ssh_args=( "$VM_NAME" "--zone=$GCP_ZONE" "--project=$GCP_PROJECT" "--tunnel-through-iap" )
if [[ -n "${SSH_USER}" ]]; then
  ssh_args[0]="${SSH_USER}@${VM_NAME}"
fi

# CRC runs in a nested libvirt VM. The host VM resolves api.crc.testing and
# *.apps-crc.testing via the dnsmasq config CRC installs. Forwarding by
# hostname (rather than 127.0.0.1) lets ssh's gateway resolve the right IP.
APPS_HOST='console-openshift-console.apps-crc.testing'

log "Opening SSH tunnels (Ctrl-C to close):"
log "  localhost:$LOCAL_API_PORT   → VM → api.crc.testing:6443"
log "  localhost:$LOCAL_HTTP_PORT   → VM → $APPS_HOST:80"
log "  localhost:$LOCAL_HTTPS_PORT  → VM → $APPS_HOST:443"

# `-N` = no remote command; tunnel-only.
exec gcloud compute ssh "${ssh_args[@]}" -- \
  -N \
  -L "${LOCAL_API_PORT}:api.crc.testing:6443" \
  -L "${LOCAL_HTTP_PORT}:${APPS_HOST}:80" \
  -L "${LOCAL_HTTPS_PORT}:${APPS_HOST}:443"
