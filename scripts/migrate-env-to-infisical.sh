#!/usr/bin/env bash
# migrate-env-to-infisical.sh — push .env file secrets into Infisical for
# a target environment. Works for any project (single-app or monorepo).
#
# GENERALIZED VERSION — no project-specific skip lists.
#
# DRY_RUN=1 prints "would set KEY (len=N)" — NEVER prints secret values.
#
# Usage (dry run — safe, no mutations):
#   DRY_RUN=1 INFISICAL_API_URL=https://secrets.example.com TARGET_ENV=prod \
#     bash scripts/migrate-env-to-infisical.sh
#
# Usage (live migration, single-app — secrets at /):
#   INFISICAL_API_URL=https://secrets.example.com TARGET_ENV=prod \
#     bash scripts/migrate-env-to-infisical.sh
#
# Usage (monorepo — secrets at /<app>):
#   INFISICAL_API_URL=https://secrets.example.com TARGET_ENV=prod \
#   SECRET_PATH=/api \
#     bash scripts/migrate-env-to-infisical.sh
#
# Usage with explicit project ID (machine-identity contexts):
#   INFISICAL_PROJECT_ID=abc123 INFISICAL_API_URL=... TARGET_ENV=prod \
#     bash scripts/migrate-env-to-infisical.sh
#
# Skip specific keys:
#   Set SKIP_KEYS to a space-separated list of keys to exclude from migration.
#   Example: SKIP_KEYS="GOOGLE_APPLICATION_CREDENTIALS TMP_DEBUG_FLAG"
set -euo pipefail

###############################################################################
# Config (override via environment variables)
###############################################################################
: "${INFISICAL_API_URL:?Set INFISICAL_API_URL, e.g. https://secrets.example.com}"
: "${TARGET_ENV:?Set TARGET_ENV to the target Infisical environment, e.g. dev or prod}"
# Source .env file (default: .env in current directory).
SRC_ENV="${SRC_ENV:-.env}"
# Secret path in Infisical (default: / for single-app; set to /<app> for monorepo).
SECRET_PATH="${SECRET_PATH:-/}"
INFISICAL_PROJECT_ID="${INFISICAL_PROJECT_ID:-}"
DRY_RUN="${DRY_RUN:-0}"
# Space-separated list of key names to skip (optional).
# Example: SKIP_KEYS="PATH HOME GOOGLE_APPLICATION_CREDENTIALS"
SKIP_KEYS="${SKIP_KEYS:-}"

###############################################################################
# Prerequisites
###############################################################################
command -v infisical >/dev/null 2>&1 || {
  echo "[FATAL] 'infisical' CLI not found." >&2
  echo "  Install: https://infisical.com/docs/cli/overview" >&2
  exit 1
}

[[ -f "$SRC_ENV" ]] || {
  echo "[FATAL] source env file not found: $SRC_ENV" >&2
  exit 1
}

###############################################################################
# Helper: check if a key is in the SKIP_KEYS list.
###############################################################################
is_skipped() {
  local key="$1"
  local k
  for k in $SKIP_KEYS; do
    [[ "$key" == "$k" ]] && return 0
  done
  return 1
}

###############################################################################
# set_secret KEY VALUE
#   - empty value  -> skip with notice
#   - DRY_RUN=1    -> print key + length only (NEVER the value)
#   - live         -> call infisical secrets set
###############################################################################
set_secret() {
  local key="$1"
  local value="$2"

  if [[ -z "$value" ]]; then
    echo "  skip empty $key"
    return
  fi

  if [[ "$DRY_RUN" == "1" ]]; then
    echo "  would set $key (len=${#value})"
    return
  fi

  # Build optional --projectId arg (shellcheck-clean array expansion).
  local extra_args=()
  [[ -n "$INFISICAL_PROJECT_ID" ]] && extra_args+=(--projectId "$INFISICAL_PROJECT_ID")

  infisical secrets set "${key}=${value}" \
    --env="$TARGET_ENV" \
    --path="$SECRET_PATH" \
    --domain="$INFISICAL_API_URL" \
    "${extra_args[@]}" \
    >/dev/null

  echo "  set $key"
}

###############################################################################
# Main: parse and migrate scalars from $SRC_ENV
###############################################################################
echo "==> Migrating ${SRC_ENV} -> Infisical env=${TARGET_ENV} path=${SECRET_PATH} (dry_run=${DRY_RUN})"
if [[ -n "$SKIP_KEYS" ]]; then
  echo "    skipping keys: ${SKIP_KEYS}"
fi

MIGRATED=0
SKIPPED=0

while IFS= read -r line || [[ -n "$line" ]]; do
  # Skip blank lines and comment lines.
  [[ -z "$line" || "$line" =~ ^[[:space:]]*# ]] && continue

  # Must contain '='.
  [[ "$line" != *"="* ]] && continue

  # Split on the FIRST '=' only (supports values containing '=').
  key="${line%%=*}"
  raw_value="${line#*=}"

  # Skip keys in the exclusion list.
  if is_skipped "$key"; then
    echo "  skip (excluded) $key"
    SKIPPED=$((SKIPPED + 1))
    continue
  fi

  # Strip a trailing inline comment (space-hash-space guard avoids breaking
  # values that legitimately contain '#', e.g. colour codes or URL fragments).
  value="${raw_value%% # *}"

  # Strip surrounding double-quotes.
  if [[ "$value" == '"'*'"' ]]; then
    value="${value#\"}"
    value="${value%\"}"
  fi

  # Strip leading/trailing whitespace.
  value="${value#"${value%%[![:space:]]*}"}"
  value="${value%"${value##*[![:space:]]}"}"

  set_secret "$key" "$value"
  MIGRATED=$((MIGRATED + 1))

done < "$SRC_ENV"

echo ""
echo "done -> env=${TARGET_ENV} path=${SECRET_PATH} dry_run=${DRY_RUN}"
echo "  processed: $((MIGRATED + SKIPPED)) keys | migrated: ${MIGRATED} | skipped: ${SKIPPED}"
