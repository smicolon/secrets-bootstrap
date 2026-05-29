#!/usr/bin/env bash
# bootstrap-1password-sync.sh — provisions Infisical -> 1Password one-way
# secret sync (break-glass mirror) for any project.
#
# GENERALIZED VERSION — single-app and monorepo supported.
#
# What this script does:
#   1. Creates (or reuses) a 1Password vault named $VAULT_NAME.
#   2. Creates (or reuses) a 1Password App Connection in Infisical.
#   3. Creates one secret sync per environment (and per app if MONOREPO_APPS set).
#
# Prerequisites:
#   - `op` CLI authenticated to your 1Password account.
#   - `infisical` CLI authenticated (interactive user session).
#   - 1Password Connect Server deployed at $OP_INSTANCE_URL.
#     See README.md "1Password Connect Server" section for setup details.
#   - A Connect server API token issued for your vault.
#
# IMPORTANT: Infisical's 1Password connection requires a Connect SERVER
# (not a bare Service Account token). You must deploy the Connect server
# containers separately. See README.md for details.
#
# Connection method confirmed against a live Infisical instance (2026-05-29):
#   GET /api/v1/app-connections/options -> {"app":"1password","methods":["api-token"]}
#   POST /api/v1/app-connections/1password requires:
#     method: "api-token"
#     credentials: { instanceUrl: <connect-server-url>, apiToken: <connect-token> }
#
# To reuse an existing connection (skip creation), set OP_CONNECTION_ID.
#
# Usage (single-app):
#   export INFISICAL_API_URL=https://secrets.example.com
#   export INFISICAL_PROJECT_ID=<project-uuid>
#   export OP_INSTANCE_URL=https://your-op-connect.example.com
#   export OP_SERVICE_TOKEN=<connect-server-api-token>
#   export PROJECT_SLUG=my-app
#   export ENVIRONMENTS="dev prod"
#   bash scripts/bootstrap-1password-sync.sh
#
# Usage (monorepo):
#   export MONOREPO_APPS="api worker frontend"
#   # ... plus all vars above
#   bash scripts/bootstrap-1password-sync.sh
#
# Reuse existing connection:
#   OP_CONNECTION_ID=<uuid> bash scripts/bootstrap-1password-sync.sh
set -euo pipefail

###############################################################################
# Config (override via environment variables)
###############################################################################
: "${INFISICAL_API_URL:?Set INFISICAL_API_URL, e.g. https://secrets.example.com}"
: "${INFISICAL_PROJECT_ID:?Set INFISICAL_PROJECT_ID to the project uuid}"
: "${OP_INSTANCE_URL:?Set OP_INSTANCE_URL to your 1Password Connect Server URL}"
: "${OP_SERVICE_TOKEN:?Set OP_SERVICE_TOKEN to the Connect server API token}"

PROJECT_SLUG="${PROJECT_SLUG:-my-project}"
VAULT_NAME="${VAULT_NAME:-${PROJECT_SLUG}}"
CONNECTION_NAME="${CONNECTION_NAME:-${PROJECT_SLUG}-1p}"
ENVIRONMENTS="${ENVIRONMENTS:-dev prod}"
MONOREPO_APPS="${MONOREPO_APPS:-}"
# Optional: provide to skip app connection creation entirely.
OP_CONNECTION_ID="${OP_CONNECTION_ID:-}"

###############################################################################
# Prerequisites
###############################################################################
for bin in curl jq op infisical; do
  command -v "$bin" >/dev/null || {
    echo "[FATAL] missing required binary: $bin" >&2
    exit 1
  }
done

###############################################################################
# Auth — reuse the operator's logged-in Infisical CLI session.
###############################################################################
TOKEN="$(infisical user get token --plain --domain="$INFISICAL_API_URL" 2>/dev/null \
  || infisical user get token --domain="$INFISICAL_API_URL" 2>&1 | tail -1)"
[[ -n "$TOKEN" ]] || {
  echo "[FATAL] Could not retrieve user token. Run:" >&2
  echo "  infisical login --domain=$INFISICAL_API_URL" >&2
  exit 1
}
echo "[ok] Infisical user token retrieved (len=${#TOKEN})"

###############################################################################
# HTTP helper — populates HTTP_CODE and HTTP_BODY after every call.
###############################################################################
HTTP_CODE=""
HTTP_BODY=""
api() {
  local method="$1" url="$2" body="${3:-}"
  local raw
  if [[ -n "$body" ]]; then
    raw=$(curl -sS -X "$method" "$url" \
      -H "Authorization: Bearer $TOKEN" \
      -H "Content-Type: application/json" \
      -d "$body" \
      -w $'\n%{http_code}')
  else
    raw=$(curl -sS -X "$method" "$url" \
      -H "Authorization: Bearer $TOKEN" \
      -w $'\n%{http_code}')
  fi
  HTTP_CODE="${raw##*$'\n'}"
  HTTP_BODY="${raw%$'\n'*}"
}

###############################################################################
# Step 1 — 1Password vault (idempotent via op vault get).
#
# One Connect server serves many vaults; access tokens are vault-scoped.
# Create one token per vault; use one Infisical App Connection per project.
###############################################################################
echo ""
echo "==> Step 1: Ensuring 1Password vault '${VAULT_NAME}' exists..."
if op vault get "$VAULT_NAME" --format=json >/dev/null 2>&1; then
  echo "  vault already exists — reusing"
else
  echo "  vault not found — creating..."
  op vault create "$VAULT_NAME" \
    --description "Infisical-managed mirror for ${PROJECT_SLUG} (break-glass copy)"
fi

OP_VAULT_ID=$(op vault get "$VAULT_NAME" --format=json | jq -r '.id')
[[ -n "$OP_VAULT_ID" ]] || {
  echo "[FATAL] could not retrieve vault id for '${VAULT_NAME}'" >&2
  exit 1
}
echo "[ok] vault id: $OP_VAULT_ID"

###############################################################################
# Step 2 — Infisical App Connection for 1Password.
#
# Confirmed endpoint: POST /api/v1/app-connections/1password (2026-05-29)
# Required body:
#   {
#     name:        string (slug-friendly, max 64 chars)
#     method:      "api-token"
#     credentials: { instanceUrl: string, apiToken: string }
#   }
#
# credentials describe a 1PASSWORD CONNECT SERVER (not a personal account token):
#   instanceUrl: the Connect server base URL (e.g. https://op-connect.example.com)
#   apiToken:    the Connect server token (issued via `op connect server create`)
#
# disableSecretDeletion:true is set on each sync to prevent the sync from
# deleting other items in the vault that Infisical did not create.
#
# DO NOT manually trigger a sync that's also auto-running — this creates
# duplicate vault items. Use the Infisical UI to trigger syncs once only.
#
# UI fallback (if POST fails):
#   Infisical -> Org Settings -> App Connections -> Add -> 1Password
#   Enter instanceUrl + apiToken -> Save
#   Then set OP_CONNECTION_ID=<id> and re-run from Step 3.
###############################################################################
echo ""
echo "==> Step 2: Ensuring 1Password App Connection '${CONNECTION_NAME}'..."

if [[ -n "$OP_CONNECTION_ID" ]]; then
  echo "  reusing existing connection: $OP_CONNECTION_ID"
else
  # Check if a connection with this name already exists.
  api GET "${INFISICAL_API_URL}/api/v1/app-connections/1password"
  if [[ "$HTTP_CODE" =~ ^2 ]]; then
    EXISTING_ID=$(printf '%s' "$HTTP_BODY" | \
      jq -r --arg n "$CONNECTION_NAME" \
      '.appConnections[] | select(.name==$n) | .id // empty' 2>/dev/null || true)
  else
    EXISTING_ID=""
  fi

  if [[ -n "$EXISTING_ID" ]]; then
    echo "  connection already exists — reusing id: $EXISTING_ID"
    OP_CONNECTION_ID="$EXISTING_ID"
  else
    api POST "${INFISICAL_API_URL}/api/v1/app-connections/1password" "$(jq -nc \
      --arg name   "$CONNECTION_NAME" \
      --arg token  "$OP_SERVICE_TOKEN" \
      --arg url    "$OP_INSTANCE_URL" \
      '{
        name:   $name,
        method: "api-token",
        credentials: {
          apiToken:    $token,
          instanceUrl: $url
        }
      }')"
    [[ "$HTTP_CODE" =~ ^2 ]] || {
      echo "[FATAL] app connection create [$HTTP_CODE]: $HTTP_BODY" >&2
      echo "" >&2
      echo "  If the credential shape has changed, confirm at:" >&2
      echo "    ${INFISICAL_API_URL} -> Org Settings -> App Connections -> Add -> 1Password" >&2
      echo "  Live OpenAPI spec: ${INFISICAL_API_URL}/api/docs/json" >&2
      echo "    path: /api/v1/app-connections/1password -> post -> requestBody" >&2
      exit 1
    }
    OP_CONNECTION_ID=$(printf '%s' "$HTTP_BODY" | jq -r '.appConnection.id // empty')
    [[ -n "$OP_CONNECTION_ID" ]] || {
      echo "[FATAL] could not parse appConnection.id from response: $HTTP_BODY" >&2
      exit 1
    }
    echo "[ok] app connection created: $OP_CONNECTION_ID"
  fi
fi

###############################################################################
# Step 3 — Per-environment (and per-app for monorepos) secret syncs.
#
# Confirmed endpoint: POST /api/v1/secret-syncs/1password (2026-05-29)
# Required body:
#   {
#     name:         string
#     projectId:    uuid
#     connectionId: uuid
#     environment:  string (env slug)
#     secretPath:   string ("/" for single-app, "/<app>" for monorepo)
#     isEnabled:    bool
#     syncOptions: {
#       initialSyncBehavior:    "overwrite-destination"
#       keySchema:              string  (uses {{secretKey}} placeholder)
#       disableSecretDeletion:  bool    (true recommended when vault has other items)
#     }
#     destinationConfig: {
#       vaultId:    string
#       valueLabel: "value"
#     }
#   }
#
# keySchema lives inside syncOptions (not destinationConfig).
# {{secretKey}} is the placeholder for the original secret name.
# {{environment}} can also be used in keySchema for disambiguation.
#
# IMPORTANT: disableSecretDeletion:true prevents the sync from pruning vault
# items that Infisical didn't create. Set to false ONLY if this vault is
# dedicated exclusively to Infisical-managed secrets.
#
# DO NOT manually trigger a sync that has isAutoSyncEnabled:true — this
# creates duplicate vault items. Trigger manually only once to seed the vault.
#
# UI fallback:
#   Project -> Integrations -> Secret Syncs -> Add Sync -> 1Password
###############################################################################
create_sync() {
  local env_slug="$1" secret_path="$2" sync_name_suffix="$3"
  local env_upper
  env_upper=$(printf '%s' "$env_slug" | tr '[:lower:]' '[:upper:]')
  local slug_upper
  slug_upper=$(printf '%s' "$PROJECT_SLUG" | tr '[:lower:]' '[:upper:]' | tr '-' '_')
  local sync_name="${PROJECT_SLUG}-${sync_name_suffix}"

  # Key schema: single-app uses SLUG_ENV_{{secretKey}};
  # monorepo uses SLUG_APP_ENV_{{secretKey}} (app derived from secret_path).
  local key_schema
  if [[ -n "$MONOREPO_APPS" && "$secret_path" != "/" ]]; then
    local app_upper
    app_upper=$(printf '%s' "${secret_path#/}" | tr '[:lower:]' '[:upper:]' | tr '-' '_')
    key_schema="${slug_upper}_${app_upper}_${env_upper}_{{secretKey}}"
  else
    key_schema="${slug_upper}_${env_upper}_{{secretKey}}"
  fi

  echo "  -> sync '${sync_name}' (env=${env_slug}, path=${secret_path}, keySchema=${key_schema})..."

  # Check if sync already exists.
  api GET "${INFISICAL_API_URL}/api/v1/secret-syncs/1password?projectId=${INFISICAL_PROJECT_ID}"
  if [[ "$HTTP_CODE" =~ ^2 ]]; then
    local existing_id
    existing_id=$(printf '%s' "$HTTP_BODY" | \
      jq -r --arg n "$sync_name" \
      '.secretSyncs[] | select(.name==$n) | .id // empty' 2>/dev/null || true)
    if [[ -n "$existing_id" ]]; then
      echo "     sync '${sync_name}' already exists (id=${existing_id}) — skipping"
      return 0
    fi
  fi

  api POST "${INFISICAL_API_URL}/api/v1/secret-syncs/1password" "$(jq -nc \
    --arg name       "$sync_name" \
    --arg project_id "$INFISICAL_PROJECT_ID" \
    --arg conn_id    "$OP_CONNECTION_ID" \
    --arg env        "$env_slug" \
    --arg path       "$secret_path" \
    --arg key_schema "$key_schema" \
    --arg vault_id   "$OP_VAULT_ID" \
    '{
      name:              $name,
      projectId:         $project_id,
      connectionId:      $conn_id,
      environment:       $env,
      secretPath:        $path,
      isEnabled:         true,
      syncOptions: {
        initialSyncBehavior:   "overwrite-destination",
        keySchema:             $key_schema,
        disableSecretDeletion: true
      },
      destinationConfig: {
        vaultId:    $vault_id,
        valueLabel: "value"
      }
    }')"
  [[ "$HTTP_CODE" =~ ^2 ]] || {
    echo "[FATAL] sync create for env=${env_slug} path=${secret_path} [$HTTP_CODE]: $HTTP_BODY" >&2
    echo "" >&2
    echo "  UI fallback: ${INFISICAL_API_URL}" >&2
    echo "    Project -> Integrations -> Secret Syncs -> Add Sync -> 1Password" >&2
    echo "    vault:               ${VAULT_NAME} (id: ${OP_VAULT_ID})" >&2
    echo "    environment:         ${env_slug}" >&2
    echo "    secretPath:          ${secret_path}" >&2
    echo "    keySchema:           ${key_schema}" >&2
    echo "    initialSyncBehavior: overwrite-destination" >&2
    return 1
  }
  local sync_id
  sync_id=$(printf '%s' "$HTTP_BODY" | jq -r '.secretSync.id // empty')
  echo "[ok]  sync created: ${sync_id} (env=${env_slug}, path=${secret_path})"
}

echo ""
echo "==> Step 3: Creating per-environment secret syncs..."

if [[ -n "$MONOREPO_APPS" ]]; then
  # Monorepo: one sync per (env, app) combination.
  for ENV_SLUG in $ENVIRONMENTS; do
    for APP in $MONOREPO_APPS; do
      create_sync "$ENV_SLUG" "/${APP}" "${ENV_SLUG}-${APP}"
    done
  done
else
  # Single-app: one sync per env, secrets at /.
  for ENV_SLUG in $ENVIRONMENTS; do
    create_sync "$ENV_SLUG" "/" "$ENV_SLUG"
  done
fi

###############################################################################
# Summary
###############################################################################
echo ""
echo "=== Bootstrap complete ==="
echo "  1Password vault  : ${VAULT_NAME} (id: ${OP_VAULT_ID})"
echo "  App connection   : ${CONNECTION_NAME} (id: ${OP_CONNECTION_ID})"
echo "  Project          : ${INFISICAL_PROJECT_ID}"
echo "  Environments     : ${ENVIRONMENTS}"
if [[ -n "$MONOREPO_APPS" ]]; then
  echo "  Monorepo apps    : ${MONOREPO_APPS}"
fi
echo ""
echo "Next steps:"
echo "  1. Verify syncs in the Infisical UI:"
echo "     ${INFISICAL_API_URL} -> Project -> Integrations -> Secret Syncs"
echo "  2. Trigger a manual sync ONCE (if not auto-syncing) — but do NOT"
echo "     trigger manually if isEnabled:true is auto-running; that creates"
echo "     duplicate vault items."
echo "  3. Confirm secrets appear in 1Password:"
echo "     op item list --vault '${VAULT_NAME}'"
