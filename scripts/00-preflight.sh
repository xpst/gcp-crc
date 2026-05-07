#!/usr/bin/env bash
# 00-preflight.sh — verify everything we need before touching GCP.
# Read-only: never mutates project state.

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

strict_mode
load_env
require_gcloud

errors=0
fail() { warn "$*"; errors=$((errors + 1)); }

log "Checking required env vars..."
require_var GCP_PROJECT
require_var PULL_SECRET_PATH
ok "GCP_PROJECT and PULL_SECRET_PATH are set"

log "Checking gcloud authentication..."
if ! gcloud auth list --filter=status:ACTIVE --format='value(account)' | grep -q .; then
  fail "No active gcloud account. Run: gcloud auth login"
else
  ok "gcloud account: $(gcloud auth list --filter=status:ACTIVE --format='value(account)' | head -n1)"
fi

log "Checking GCP project access ($GCP_PROJECT)..."
if ! gc projects describe "$GCP_PROJECT" >/dev/null 2>&1; then
  fail "Cannot describe project $GCP_PROJECT. Check the project ID and your IAM."
else
  ok "Project $GCP_PROJECT is accessible"
fi

log "Checking Compute Engine API..."
if gc services list --enabled --filter='config.name=compute.googleapis.com' --format='value(config.name)' 2>/dev/null | grep -q compute.googleapis.com; then
  ok "compute.googleapis.com is enabled"
else
  fail "compute.googleapis.com is not enabled. Run: gcloud services enable compute.googleapis.com --project=$GCP_PROJECT"
fi

log "Checking pull secret file ($PULL_SECRET_PATH)..."
if [[ ! -f "$PULL_SECRET_PATH" ]]; then
  fail "Pull secret file not found at $PULL_SECRET_PATH"
elif ! python3 -c "import json,sys; json.load(open(sys.argv[1]))" "$PULL_SECRET_PATH" 2>/dev/null \
   && ! command -v jq >/dev/null 2>&1; then
  warn "Cannot validate JSON (no python3 or jq). Trusting file shape."
elif command -v jq >/dev/null 2>&1 && ! jq empty "$PULL_SECRET_PATH" >/dev/null 2>&1; then
  fail "Pull secret at $PULL_SECRET_PATH is not valid JSON"
else
  ok "Pull secret looks like valid JSON"
fi

log "Checking zone $GCP_ZONE supports $MACHINE_TYPE..."
if gc compute machine-types describe "$MACHINE_TYPE" --zone="$GCP_ZONE" >/dev/null 2>&1; then
  ok "$MACHINE_TYPE is available in $GCP_ZONE"
else
  fail "$MACHINE_TYPE not available in $GCP_ZONE. Try a different zone or machine type."
fi

log "Checking image $IMAGE_FAMILY in $IMAGE_PROJECT..."
if gcloud compute images describe-from-family "$IMAGE_FAMILY" --project="$IMAGE_PROJECT" >/dev/null 2>&1; then
  ok "Image family $IMAGE_FAMILY is resolvable"
else
  fail "Image family $IMAGE_FAMILY not found in project $IMAGE_PROJECT"
fi

print_config

if (( errors > 0 )); then
  die "$errors precondition(s) failed. Fix the warnings above before proceeding." 2
fi

ok "Preflight passed. Next: ./scripts/01-provision-vm.sh"
