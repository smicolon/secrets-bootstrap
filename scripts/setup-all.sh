#!/usr/bin/env bash
# setup-all.sh — one-command orchestrator. Runs the whole provisioning flow in
# order: Infisical project + identities -> migrate .env -> `infisical run` setup
# -> 1Password mirror (when configured). Each step is the same script you'd run
# by hand; this just chains them and threads the project id between them.
#
# Prerequisites:
#   - config sourced (or the equivalent env vars exported): `source config.sh`
#   - `infisical login --domain=$INFISICAL_API_URL` already done
#   - `op` signed in (only if using the 1Password mirror)
#
# Idempotent: safe to re-run. Set INFISICAL_PROJECT_ID (in config) on re-runs so
# it reuses the project instead of creating a new one.
#
# Usage:
#   source config.sh && bash scripts/setup-all.sh
#   # or: just all
set -euo pipefail

: "${INFISICAL_API_URL:?Set INFISICAL_API_URL — run: source config.sh}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUT_DIR="${OUT_DIR:-secrets}"
ENVIRONMENTS="${ENVIRONMENTS:-dev staging prod}"
SRC_ENV="${SRC_ENV:-.env}"
DEFAULT_ENV="${DEFAULT_ENV:-dev}"

echo "==================================================================="
echo " secrets-bootstrap — full setup"
echo "==================================================================="

###############################################################################
# 1/4 — Provision Infisical project, environments, machine identities.
###############################################################################
echo ""
echo ">>> [1/4] Infisical project + machine identities"
bash "${SCRIPT_DIR}/bootstrap-infisical.sh"

# Resolve the project id for downstream steps if config didn't pin it. The
# bootstrap writes it into each generated credential file.
if [[ -z "${INFISICAL_PROJECT_ID:-}" ]]; then
  first_env="${ENVIRONMENTS%% *}"
  cred="${OUT_DIR}/infisical-${first_env}-machine.env"
  if [[ -f "$cred" ]]; then
    INFISICAL_PROJECT_ID=$(grep -E '^INFISICAL_PROJECT_ID=' "$cred" | head -n1 | cut -d= -f2-)
    export INFISICAL_PROJECT_ID
  fi
fi
[[ -n "${INFISICAL_PROJECT_ID:-}" ]] || {
  echo "[FATAL] could not resolve INFISICAL_PROJECT_ID after bootstrap." >&2
  exit 1
}
echo "[ok] project id: ${INFISICAL_PROJECT_ID}"

###############################################################################
# 2/4 — Migrate .env (skipped when there is nothing to migrate).
###############################################################################
echo ""
echo ">>> [2/4] Migrate ${SRC_ENV}"
if [[ -f "$SRC_ENV" ]]; then
  TARGET_ENV="${TARGET_ENV:-$DEFAULT_ENV}" bash "${SCRIPT_DIR}/migrate-env-to-infisical.sh"
else
  echo "[skip] no ${SRC_ENV} found — nothing to migrate"
fi

###############################################################################
# 3/4 — Wire `infisical run` (.infisical.json).
###############################################################################
echo ""
echo ">>> [3/4] Post-provisioning: infisical run setup"
DEFAULT_ENV="$DEFAULT_ENV" bash "${SCRIPT_DIR}/setup-infisical-run.sh"

###############################################################################
# 4/4 — 1Password mirror (only when 1Password is configured).
###############################################################################
echo ""
echo ">>> [4/4] 1Password mirror"
if [[ -n "${OP_CONNECTION_ID:-}" || -n "${OP_INSTANCE_URL:-}" || -n "${OP_SERVICE_TOKEN:-}" ]]; then
  bash "${SCRIPT_DIR}/bootstrap-1password-sync.sh"
else
  echo "[skip] 1Password not configured"
  echo "       (set OP_CONNECTION_ID, or OP_INSTANCE_URL + OP_SERVICE_TOKEN, to enable)"
fi

echo ""
echo "=== All done ==="
echo "  project id : ${INFISICAL_PROJECT_ID}"
echo "  run a command with secrets: just run <cmd>   (e.g. just run npm run dev)"
