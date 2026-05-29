#!/usr/bin/env bash
# setup-infisical-run.sh — post-provisioning step that wires up `infisical run`
# for this project.
#
# Writes .infisical.json (pins workspace + default environment) so that
# `infisical run -- <cmd>` and scripts/run-with-secrets.sh resolve the project
# without --projectId flags. Contains NO secrets (just the workspace id) and is
# safe to commit.
#
# Idempotent: refuses to overwrite an existing .infisical.json unless OVERWRITE=1.
#
# Usage:
#   INFISICAL_PROJECT_ID=<uuid> DEFAULT_ENV=dev bash scripts/setup-infisical-run.sh
set -euo pipefail

###############################################################################
# Config (override via environment variables)
###############################################################################
: "${INFISICAL_PROJECT_ID:?Set INFISICAL_PROJECT_ID to the project uuid}"
DEFAULT_ENV="${DEFAULT_ENV:-dev}"
OVERWRITE="${OVERWRITE:-0}"
OUT_FILE=".infisical.json"

command -v jq >/dev/null 2>&1 || {
  echo "[FATAL] jq not found." >&2
  exit 1
}

###############################################################################
# Write .infisical.json
###############################################################################
if [[ -f "$OUT_FILE" && "$OVERWRITE" != "1" ]]; then
  echo "[skip] $OUT_FILE already exists — set OVERWRITE=1 to regenerate."
else
  jq -nc \
    --arg wid "$INFISICAL_PROJECT_ID" \
    --arg env "$DEFAULT_ENV" \
    '{workspaceId:$wid, defaultEnvironment:$env, gitBranchToEnvironmentMapping:null}' \
    > "$OUT_FILE"
  echo "[ok] wrote $OUT_FILE (workspaceId=$INFISICAL_PROJECT_ID, defaultEnvironment=$DEFAULT_ENV)"
fi

###############################################################################
# Ensure the runtime wrapper is present + executable
###############################################################################
if [[ -f scripts/run-with-secrets.sh ]]; then
  chmod 755 scripts/run-with-secrets.sh
  echo "[ok] scripts/run-with-secrets.sh is executable"
else
  echo "[WARN] scripts/run-with-secrets.sh not found — re-run install.sh to fetch it." >&2
fi

echo ""
echo "Run anything with secrets injected from Infisical:"
echo "  INFISICAL_API_URL=<url> bash scripts/run-with-secrets.sh npm run dev"
echo "  INFISICAL_API_URL=<url> INFISICAL_ENV=prod SECRET_PATH=/api bash scripts/run-with-secrets.sh ./server"
