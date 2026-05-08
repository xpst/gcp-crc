#!/usr/bin/env bash
# Shared helpers for the CRC-on-GCP scripts.
# Source this from each script: `source "$(dirname "$0")/lib/common.sh"`

strict_mode() {
  set -euo pipefail
}

# Resolve repo root. common.sh lives at <repo>/scripts/lib/common.sh, so go up
# two levels from this file's own location. Using BASH_SOURCE[0] (this file)
# is stable regardless of the call stack.
_repo_root() {
  local lib_dir
  lib_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  cd "$lib_dir/../.." && pwd
}

# Logging
log()  { printf '\033[1;34m[INFO]\033[0m %s\n'  "$*" >&2; }
warn() { printf '\033[1;33m[WARN]\033[0m %s\n'  "$*" >&2; }
ok()   { printf '\033[1;32m[ OK ]\033[0m %s\n'  "$*" >&2; }
die()  { printf '\033[1;31m[FAIL]\033[0m %s\n'  "$*" >&2; exit "${2:-2}"; }

# Show the exact command, then run it.
run() {
  printf '\033[2m$ %s\033[0m\n' "$*" >&2
  "$@"
}

# Load .env from repo root and export every variable.
load_env() {
  local repo_root env_file
  repo_root="$(_repo_root)"
  env_file="$repo_root/.env"
  if [[ ! -f "$env_file" ]]; then
    die "No .env file at $env_file. Run: cp .env.example .env && \$EDITOR .env" 1
  fi
  set -a
  # shellcheck disable=SC1090
  source "$env_file"
  set +a
  apply_defaults
}

# Defaults applied after .env is sourced. Anything set in .env wins.
apply_defaults() {
  : "${GCP_ZONE:=us-central1-a}"
  : "${VM_NAME:=openshift-test-bench}"
  : "${MACHINE_TYPE:=n2-standard-16}"
  : "${MIN_CPU_PLATFORM:=Intel Cascade Lake}"
  : "${BOOT_DISK_SIZE:=200GB}"
  : "${BOOT_DISK_TYPE:=pd-ssd}"
  : "${ENABLE_SPOT_VM:=false}"
  : "${IMAGE_FAMILY:=rocky-linux-9-optimized-gcp}"
  : "${IMAGE_PROJECT:=rocky-linux-cloud}"
  : "${SSH_USER:=}"
  : "${CRC_VERSION:=latest}"
  : "${CRC_CPUS:=12}"
  : "${CRC_MEMORY_MIB:=32768}"
  : "${CRC_DISK_GIB:=80}"
  : "${CRC_PRESET:=openshift}"
  : "${HELM_VERSION:=latest}"
  : "${LOCAL_API_PORT:=6443}"
  : "${LOCAL_HTTP_PORT:=80}"
  : "${LOCAL_HTTPS_PORT:=443}"
}

# Truthiness check for boolean-ish env vars. Accepts true|1|yes|on (any case).
is_truthy() {
  case "${1,,}" in
    true|1|yes|on) return 0 ;;
    *)             return 1 ;;
  esac
}

# Fail with a clear message if a required var is empty.
require_var() {
  local name="$1"
  if [[ -z "${!name:-}" ]]; then
    die "Required variable \$$name is not set. Edit your .env file." 1
  fi
}

# Fail if `gcloud` is missing.
require_gcloud() {
  command -v gcloud >/dev/null 2>&1 || die "gcloud SDK not found on PATH. See INSTALL.md step 3." 2
}

# gcloud wrapper that always passes --project and --zone where applicable.
gc() {
  gcloud --project="$GCP_PROJECT" "$@"
}

# Common gcloud-ssh prefix builder.
_ssh_args() {
  local args=( "$VM_NAME" "--zone=$GCP_ZONE" "--project=$GCP_PROJECT" "--tunnel-through-iap" )
  if [[ -n "${SSH_USER}" ]]; then
    args[0]="${SSH_USER}@${VM_NAME}"
  fi
  printf '%s\n' "${args[@]}"
}

# Run a command on the VM over SSH.
# Usage: run_remote 'one-line shell command'
run_remote() {
  local cmd="$1"
  local ssh_args
  mapfile -t ssh_args < <(_ssh_args)
  run gcloud compute ssh "${ssh_args[@]}" --command="$cmd"
}

# Like run_remote but quiet (no command echo). Used for retry probes.
run_remote_quiet() {
  local cmd="$1"
  local ssh_args
  mapfile -t ssh_args < <(_ssh_args)
  gcloud compute ssh "${ssh_args[@]}" --command="$cmd" >/dev/null 2>&1
}

# Run a command on the VM, streaming stdin from a heredoc.
# Usage: run_remote_script <<'EOF'
#   set -euo pipefail
#   ...
# EOF
run_remote_script() {
  local ssh_args
  mapfile -t ssh_args < <(_ssh_args)
  printf '\033[2m$ gcloud compute ssh %s --command=<<heredoc>>\033[0m\n' "${ssh_args[*]}" >&2
  gcloud compute ssh "${ssh_args[@]}" --command="bash -s"
}

# Copy a local file to the VM.
# Usage: scp_to_vm /local/path remote/path
scp_to_vm() {
  local src="$1" dst="$2"
  local target="$VM_NAME:$dst"
  if [[ -n "${SSH_USER}" ]]; then target="${SSH_USER}@${target}"; fi
  run gcloud compute scp \
    --zone="$GCP_ZONE" --project="$GCP_PROJECT" --tunnel-through-iap \
    "$src" "$target"
}

# Check whether the VM exists. Returns 0 if it does.
vm_exists() {
  gc compute instances describe "$VM_NAME" --zone="$GCP_ZONE" >/dev/null 2>&1
}

# Print resolved configuration as a one-block summary.
print_config() {
  cat >&2 <<EOF
─── Resolved configuration ─────────────────────────────────────────
  GCP_PROJECT       = ${GCP_PROJECT:-<unset>}
  GCP_ZONE          = $GCP_ZONE
  VM_NAME           = $VM_NAME
  MACHINE_TYPE      = $MACHINE_TYPE  (min CPU: $MIN_CPU_PLATFORM)
  PROVISIONING      = $(is_truthy "$ENABLE_SPOT_VM" && echo 'spot (terminate: DELETE)' || echo 'standard')
  BOOT_DISK         = $BOOT_DISK_SIZE / $BOOT_DISK_TYPE
  IMAGE             = $IMAGE_FAMILY ($IMAGE_PROJECT)
  SSH_USER          = ${SSH_USER:-<gcloud default>}
  PULL_SECRET_PATH  = ${PULL_SECRET_PATH:-<unset>}
  CRC               = v${CRC_VERSION}, ${CRC_CPUS} cpu / ${CRC_MEMORY_MIB} MiB / ${CRC_DISK_GIB} GiB / preset=${CRC_PRESET}
  HELM              = ${HELM_VERSION}
────────────────────────────────────────────────────────────────────
EOF
}
