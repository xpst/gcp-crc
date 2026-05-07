#!/usr/bin/env bash
# 02-bootstrap.sh — install KVM/libvirt, CRC, helm, and copy the pull secret
# onto the VM. Runs `crc setup`. Idempotent.

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

strict_mode
load_env
require_gcloud
require_var GCP_PROJECT
require_var PULL_SECRET_PATH

if [[ ! -f "$PULL_SECRET_PATH" ]]; then
  die "Pull secret not found at $PULL_SECRET_PATH" 1
fi

if ! vm_exists; then
  die "VM '$VM_NAME' doesn't exist. Run ./scripts/01-provision-vm.sh first." 2
fi

log "Step 1/4: install KVM, libvirt, NetworkManager, jq on the VM..."
run_remote_script <<'REMOTE'
set -euo pipefail
if rpm -q libvirt qemu-kvm NetworkManager jq >/dev/null 2>&1; then
  echo "[remote] base packages already installed"
else
  sudo dnf install -y libvirt qemu-kvm NetworkManager jq tar
fi
sudo systemctl enable --now libvirtd
sudo usermod -aG libvirt "$USER" || true
# virt-host-validate may print warnings; only fail on the kvm check.
if command -v virt-host-validate >/dev/null 2>&1; then
  virt-host-validate qemu | grep -E "^\s*QEMU: Checking for hardware virtualization" || true
fi
REMOTE
ok "Base packages installed."

log "Step 2/4: install CRC ($CRC_VERSION) on the VM..."
# shellcheck disable=SC2016
run_remote_script <<REMOTE
set -euo pipefail
mkdir -p "\$HOME/.local/bin"
case ":\$PATH:" in *":\$HOME/.local/bin:"*) ;; *)
  echo 'export PATH="\$HOME/.local/bin:\$PATH"' >> "\$HOME/.bashrc"
  export PATH="\$HOME/.local/bin:\$PATH"
  ;;
esac
WANT="${CRC_VERSION}"
HAVE=""
if command -v crc >/dev/null 2>&1; then
  HAVE="\$(crc version 2>/dev/null | awk '/CRC version/ {print \$3; exit}')"
fi
if [[ "\$WANT" != "latest" && -n "\$HAVE" && "\$HAVE" == "\$WANT" ]]; then
  echo "[remote] CRC \$HAVE already installed — skipping download"
else
  if [[ "\$WANT" == "latest" ]]; then
    URL="https://mirror.openshift.com/pub/openshift-v4/clients/crc/latest/crc-linux-amd64.tar.xz"
  else
    URL="https://mirror.openshift.com/pub/openshift-v4/clients/crc/\$WANT/crc-linux-amd64.tar.xz"
  fi
  TMP="\$(mktemp -d)"
  echo "[remote] downloading \$URL"
  curl -fsSL -o "\$TMP/crc.tar.xz" "\$URL"
  tar -xJf "\$TMP/crc.tar.xz" -C "\$TMP"
  install -m 0755 "\$(find "\$TMP" -name crc -type f | head -n1)" "\$HOME/.local/bin/crc"
  rm -rf "\$TMP"
  echo "[remote] installed: \$(\$HOME/.local/bin/crc version | head -n1)"
fi
REMOTE
ok "CRC installed."

log "Step 3/4: install Helm ($HELM_VERSION) on the VM..."
# shellcheck disable=SC2016
run_remote_script <<REMOTE
set -euo pipefail
mkdir -p "\$HOME/.local/bin"
WANT="${HELM_VERSION}"
HAVE=""
if command -v helm >/dev/null 2>&1; then
  HAVE="\$(helm version --short 2>/dev/null | awk -F'+' '{print \$1}')"
fi
if [[ "\$WANT" != "latest" && -n "\$HAVE" && "\$HAVE" == "\$WANT" ]]; then
  echo "[remote] helm \$HAVE already installed — skipping download"
else
  TMP="\$(mktemp -d)"
  if [[ "\$WANT" == "latest" ]]; then
    # Use the official installer to fetch the latest stable.
    curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 -o "\$TMP/get-helm-3"
    chmod +x "\$TMP/get-helm-3"
    HELM_INSTALL_DIR="\$HOME/.local/bin" USE_SUDO=false "\$TMP/get-helm-3"
  else
    curl -fsSL -o "\$TMP/helm.tgz" "https://get.helm.sh/helm-\${WANT}-linux-amd64.tar.gz"
    tar -xzf "\$TMP/helm.tgz" -C "\$TMP"
    install -m 0755 "\$TMP/linux-amd64/helm" "\$HOME/.local/bin/helm"
  fi
  rm -rf "\$TMP"
  echo "[remote] installed: \$(\$HOME/.local/bin/helm version --short)"
fi
REMOTE
ok "Helm installed."

log "Step 4/4: copy pull secret and run 'crc setup'..."
scp_to_vm "$PULL_SECRET_PATH" '~/pull-secret.json'
# shellcheck disable=SC2016
run_remote_script <<'REMOTE'
set -euo pipefail
chmod 0600 "$HOME/pull-secret.json"
export PATH="$HOME/.local/bin:$PATH"
crc config set consent-telemetry no >/dev/null
# Idempotent — `crc setup` is safe to re-run.
crc setup

# Pre-create the conventional drop-zone for user-supplied scripts/charts
# referenced in INSTALL.md, so `scp --recurse … :~/work/` behaves predictably.
mkdir -p "$HOME/work"

# Make `oc` and KUBECONFIG available in every future shell (no-op until
# `crc start` succeeds — the 2>/dev/null hides the "cluster not running"
# error so login shells open cleanly even when CRC is stopped).
OC_LINE='eval "$(crc oc-env 2>/dev/null)"'
if ! grep -Fxq "$OC_LINE" "$HOME/.bashrc" 2>/dev/null; then
  printf '\n# Added by 02-bootstrap.sh — auto-load CRC oc/kubeconfig\n%s\n' "$OC_LINE" >> "$HOME/.bashrc"
fi
REMOTE
ok "Bootstrap complete. Next: ./scripts/03-start-crc.sh"
