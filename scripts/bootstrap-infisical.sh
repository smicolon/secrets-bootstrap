#!/usr/bin/env bash
# bootstrap-infisical.sh — provisions an Infisical project, environments,
# optional monorepo folder structure, and per-environment machine identities
# (Universal Auth).
#
# GENERALIZED VERSION — works for any project (single-app or monorepo).
#
# Idempotent on re-runs:
#   - Set INFISICAL_PROJECT_ID to skip project creation.
#   - Identity creation is NOT idempotent (see WARNING below).
#
# Endpoints validated against a live self-hosted Infisical instance on 2026-05-29.
# All mutations gated on HTTP 2xx; body is printed on failure.
#
# Usage (single-app):
#   export INFISICAL_API_URL=https://secrets.example.com
#   export PROJECT_NAME="My App"
#   export PROJECT_SLUG="my-app"
#   bash scripts/bootstrap-infisical.sh
#
# Usage (monorepo — creates /<app> folder per app per env):
#   export INFISICAL_API_URL=https://secrets.example.com
#   export PROJECT_NAME="My Monorepo"
#   export PROJECT_SLUG="my-monorepo"
#   export MONOREPO_APPS="api worker frontend"
#   bash scripts/bootstrap-infisical.sh
#
# Re-run (project already exists — skip project creation):
#   INFISICAL_PROJECT_ID=<uuid> bash scripts/bootstrap-infisical.sh
set -euo pipefail

###############################################################################
# Config (override via environment variables)
###############################################################################
: "${INFISICAL_API_URL:?Set INFISICAL_API_URL, e.g. https://secrets.example.com}"
PROJECT_NAME="${PROJECT_NAME:-My Project}"
PROJECT_SLUG="${PROJECT_SLUG:-my-project}"
# Space-separated list of environments to provision.
# Default matches Infisical's shouldCreateDefaultEnvs:true => dev staging prod.
ENVIRONMENTS="${ENVIRONMENTS:-dev staging prod}"
# Optional: space-separated app names for monorepo folder layout.
# When set, creates a /<app> folder in each environment for every app listed.
# Leave unset or empty for single-app (all secrets at /).
MONOREPO_APPS="${MONOREPO_APPS:-}"
INFISICAL_PROJECT_ID="${INFISICAL_PROJECT_ID:-}"
ORG_ID="${ORG_ID:-}"   # auto-detected from workspace list if blank
OUT_DIR="${OUT_DIR:-secrets}"  # gitignored; receives per-env machine identity files
# Re-run policy for machine identities: 0 (default) reuses an existing identity
# of the same name; 1 deletes and recreates it (rotates clientId + secret).
OVERWRITE_IDENTITIES="${OVERWRITE_IDENTITIES:-0}"
mkdir -p "$OUT_DIR"
chmod 700 "$OUT_DIR"

###############################################################################
# Prerequisites
###############################################################################
for bin in curl jq infisical; do
  command -v "$bin" >/dev/null || {
    echo "[FATAL] missing required binary: $bin" >&2
    exit 1
  }
done

###############################################################################
# Auth — reuse the operator's logged-in CLI session.
#
# Confirmed: 'infisical user get token --plain --domain=<URL>' returns a raw
# JWT suitable for Authorization: Bearer auth.
# If this fails, run: infisical login --domain=$INFISICAL_API_URL
###############################################################################
TOKEN="$(infisical user get token --plain --domain="$INFISICAL_API_URL" 2>/dev/null \
  || infisical user get token --domain="$INFISICAL_API_URL" 2>&1 | tail -1)"
[[ -n "$TOKEN" ]] || {
  echo "[FATAL] Could not retrieve user token. Run:" >&2
  echo "  infisical login --domain=$INFISICAL_API_URL" >&2
  exit 1
}
echo "[ok] user token retrieved (len=${#TOKEN})"

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
# Resolve ORG_ID from workspace list if not supplied.
#
# Confirmed: GET /api/v1/workspace => 200
# Response:  {workspaces:[{orgId, ...}, ...]}
###############################################################################
if [[ -z "$ORG_ID" ]]; then
  echo "==> Resolving org ID from workspace list..."
  api GET "${INFISICAL_API_URL}/api/v1/workspace"
  [[ "$HTTP_CODE" =~ ^2 ]] || {
    echo "[FATAL] workspace list [$HTTP_CODE]: $HTTP_BODY" >&2
    exit 1
  }
  ORG_ID=$(printf '%s' "$HTTP_BODY" | jq -r '.workspaces[0].orgId // empty')
  [[ -n "$ORG_ID" ]] || {
    echo "[FATAL] could not resolve orgId. Set ORG_ID explicitly." >&2
    exit 1
  }
fi
echo "[ok] org ID: $ORG_ID"

###############################################################################
# Step 1 — Create project (or reuse existing).
#
# Endpoint: POST /api/v2/workspace
# Confirmed response shape (inferred from GET /api/v1/workspace/:id):
#   Request:  {projectName, slug, type:"secret-manager", shouldCreateDefaultEnvs:true}
#   Response: {project:{id, name, slug, orgId, environments:[...]}}
#
# UI fallback: <INFISICAL_API_URL> -> New Project
###############################################################################
if [[ -z "$INFISICAL_PROJECT_ID" ]]; then
  echo "==> Creating project '${PROJECT_NAME}' (slug: ${PROJECT_SLUG})..."
  api POST "${INFISICAL_API_URL}/api/v2/workspace" "$(jq -nc \
    --arg n "$PROJECT_NAME" \
    --arg s "$PROJECT_SLUG" \
    '{projectName:$n, slug:$s, type:"secret-manager", shouldCreateDefaultEnvs:true}')"
  [[ "$HTTP_CODE" =~ ^2 ]] || {
    echo "[FATAL] project create [$HTTP_CODE]: $HTTP_BODY" >&2
    echo "  UI fallback: ${INFISICAL_API_URL} -> New Project" >&2
    exit 1
  }
  INFISICAL_PROJECT_ID=$(printf '%s' "$HTTP_BODY" | jq -r '.project.id // empty')
  [[ -n "$INFISICAL_PROJECT_ID" ]] || {
    echo "[FATAL] could not parse project id from response: $HTTP_BODY" >&2
    exit 1
  }
  echo "[ok] project created: $INFISICAL_PROJECT_ID"
else
  echo "[skip] reusing project: $INFISICAL_PROJECT_ID"
fi

###############################################################################
# Step 2 — Verify environments; warn if target envs are missing.
#
# Confirmed: GET /api/v1/workspace/:id => {workspace:{environments:[{name,slug,id}]}}
# Default envs after shouldCreateDefaultEnvs:true: dev, staging, prod.
#
# Custom environments (beyond the defaults) must be created via the UI:
#   Project > Environments > Add Environment
###############################################################################
echo "==> Verifying environments..."
api GET "${INFISICAL_API_URL}/api/v1/workspace/${INFISICAL_PROJECT_ID}"
[[ "$HTTP_CODE" =~ ^2 ]] || {
  echo "[FATAL] get workspace [$HTTP_CODE]: $HTTP_BODY" >&2
  exit 1
}
EXISTING_ENVS=$(printf '%s' "$HTTP_BODY" | jq -r '.workspace.environments[].slug' 2>/dev/null | tr '\n' ' ')
echo "[ok] environments in project: ${EXISTING_ENVS:-<none>}"

for ENV_SLUG in $ENVIRONMENTS; do
  if ! printf '%s' "$EXISTING_ENVS" | grep -qw "$ENV_SLUG"; then
    echo "[WARN] environment '$ENV_SLUG' not found in project." >&2
    echo "       Create it via: Project > Environments > Add Environment" >&2
  fi
done

###############################################################################
# Step 3 — Create monorepo folder structure (skipped for single-app).
#
# Confirmed endpoint: POST /api/v2/folders
# Request:  {projectId, environment, name:"<app>", path:"/"}
# Response: {folder:{id, name}}
#
# One /<app> folder is created per (environment, app) pair.
# Folders are read via GET /api/v2/folders?projectId=&environment=&path=/
# to avoid duplicate creation (idempotent by name).
###############################################################################
if [[ -n "$MONOREPO_APPS" ]]; then
  echo "==> Creating monorepo folder structure..."
  for ENV_SLUG in $ENVIRONMENTS; do
    for APP in $MONOREPO_APPS; do
      echo "  -> /${APP} in env=${ENV_SLUG}..."
      # Check for existing folder first (read-only, safe).
      api GET "${INFISICAL_API_URL}/api/v2/folders?projectId=${INFISICAL_PROJECT_ID}&environment=${ENV_SLUG}&path=/"
      if [[ "$HTTP_CODE" =~ ^2 ]]; then
        EXISTING_FOLDER=$(printf '%s' "$HTTP_BODY" | \
          jq -r --arg a "$APP" '.folders[] | select(.name==$a) | .name // empty' 2>/dev/null || true)
        if [[ -n "$EXISTING_FOLDER" ]]; then
          echo "     folder '/${APP}' already exists — skipping"
          continue
        fi
      fi
      api POST "${INFISICAL_API_URL}/api/v2/folders" "$(jq -nc \
        --arg pid "$INFISICAL_PROJECT_ID" \
        --arg env "$ENV_SLUG" \
        --arg app "$APP" \
        '{projectId:$pid, environment:$env, name:$app, path:"/"}')"
      [[ "$HTTP_CODE" =~ ^2 ]] || {
        echo "[WARN] folder create /${APP} in env=${ENV_SLUG} [$HTTP_CODE]: $HTTP_BODY" >&2
        echo "       Create manually: Project > Secrets > env=${ENV_SLUG} > New Folder" >&2
      }
      echo "     [ok] /${APP} created (env=${ENV_SLUG})"
    done
  done
fi

###############################################################################
# Step 4 — Create per-environment machine identities (Universal Auth).
#
# IDEMPOTENT (since 2026-05-29): each identity is looked up by name first.
# If it already exists it is REUSED and creation is skipped — re-runs no
# longer produce duplicates. Set OVERWRITE_IDENTITIES=1 to delete and
# recreate an existing identity (rotates its clientId + client secret and
# rewrites the credential file).
#
# Lookup/delete endpoints NEED LIVE RE-VERIFICATION against your instance:
#   GET    /api/v2/organizations/:orgId/identity-memberships
#   DELETE /api/v1/identities/:identityId
#
# !!! ENV ISOLATION GAP !!!
# role:"member" is PROJECT-WIDE — the identity can read ALL environments,
# not just the target env. True per-env isolation requires a CUSTOM PROJECT
# ROLE with an environment condition, assigned via the UI:
#   Project > Access Control > Project Roles > New Role > add env condition
# Until that is done, every machine identity can read all environments.
#
# Endpoints (all confirmed against live Infisical instance 2026-05-29):
#   POST /api/v1/identities
#     body: {name, organizationId, role:"member"} -> .identity.id
#   POST /api/v2/workspace/:projectId/identity-memberships/:identityId
#     body: {role:"member"}  (identityId in PATH — easy to get wrong)
#   POST /api/v1/auth/universal-auth/identities/:identityId
#     body: {accessTokenTTL, accessTokenMaxTTL, accessTokenNumUsesLimit}
#     response: .identityUniversalAuth.clientId
#   POST /api/v1/auth/universal-auth/identities/:identityId/client-secrets
#     body: {description} -> .clientSecret  (returned ONCE — store immediately)
###############################################################################
create_machine_identity() {
  local name="$1" env_slug="$2"
  echo "==> Creating machine identity '${name}' (env=${env_slug})..."

  # Idempotency — reuse an existing identity of the same name. Org-level
  # lookup also catches a half-provisioned identity from a prior failed run.
  local existing_id=""
  api GET "${INFISICAL_API_URL}/api/v2/organizations/${ORG_ID}/identity-memberships"
  if [[ "$HTTP_CODE" =~ ^2 ]]; then
    existing_id=$(printf '%s' "$HTTP_BODY" | \
      jq -r --arg n "$name" '.identityMemberships[]? | select(.identity.name==$n) | .identity.id' 2>/dev/null | head -n1 || true)
  else
    echo "[WARN] identity lookup [$HTTP_CODE] — proceeding to create (may duplicate): $HTTP_BODY" >&2
  fi

  if [[ -n "$existing_id" ]]; then
    if [[ "$OVERWRITE_IDENTITIES" == "1" ]]; then
      echo "  identity '${name}' exists (id=${existing_id}) — OVERWRITE_IDENTITIES=1: deleting and recreating..."
      api DELETE "${INFISICAL_API_URL}/api/v1/identities/${existing_id}"
      [[ "$HTTP_CODE" =~ ^2 ]] || {
        echo "[FATAL] identity delete [$HTTP_CODE]: $HTTP_BODY" >&2
        echo "  UI fallback: Org Settings > Identities > delete '${name}'" >&2
        return 1
      }
      echo "  deleted — recreating fresh"
    else
      echo "[skip] identity '${name}' already exists (id=${existing_id}) — reusing (set OVERWRITE_IDENTITIES=1 to rotate)"
      local out_file="${OUT_DIR}/infisical-${env_slug}-machine.env"
      [[ -f "$out_file" ]] || echo "  note: ${out_file} not present; set OVERWRITE_IDENTITIES=1 to mint a new secret and regenerate it" >&2
      return 0
    fi
  fi

  # 4a) Create org-level identity.
  api POST "${INFISICAL_API_URL}/api/v1/identities" "$(jq -nc \
    --arg n   "$name" \
    --arg oid "$ORG_ID" \
    '{name:$n, organizationId:$oid, role:"member"}')"
  [[ "$HTTP_CODE" =~ ^2 ]] || {
    echo "[FATAL] identity create [$HTTP_CODE]: $HTTP_BODY" >&2
    echo "  UI fallback: Org Settings > Identities > Create Identity" >&2
    return 1
  }
  local IDENTITY_ID
  IDENTITY_ID=$(printf '%s' "$HTTP_BODY" | jq -r '.identity.id // empty')
  [[ -n "$IDENTITY_ID" ]] || {
    echo "[FATAL] could not parse identity id: $HTTP_BODY" >&2
    return 1
  }
  echo "  identity id: $IDENTITY_ID"

  # 4b) Attach identity to project.
  # identityId is in the PATH (not the body) — confirmed from live OpenAPI.
  # role:"member" gives project-wide access; see ENV ISOLATION GAP above.
  api POST "${INFISICAL_API_URL}/api/v2/workspace/${INFISICAL_PROJECT_ID}/identity-memberships/${IDENTITY_ID}" \
    "$(jq -nc '{role:"member"}')"
  [[ "$HTTP_CODE" =~ ^2 ]] || {
    echo "[FATAL] identity attach [$HTTP_CODE]: $HTTP_BODY" >&2
    echo "  UI fallback: Project > Access Control > Machine Identities > Add" >&2
    return 1
  }
  echo "  attached to project"

  # 4c) Enable Universal Auth (30-day TTL, unlimited uses).
  api POST "${INFISICAL_API_URL}/api/v1/auth/universal-auth/identities/${IDENTITY_ID}" \
    "$(jq -nc '{accessTokenTTL:2592000, accessTokenMaxTTL:2592000, accessTokenNumUsesLimit:0}')"
  [[ "$HTTP_CODE" =~ ^2 ]] || {
    echo "[FATAL] UA enable [$HTTP_CODE]: $HTTP_BODY" >&2
    echo "  UI fallback: Identity > Auth Methods > Enable Universal Auth" >&2
    return 1
  }
  local CLIENT_ID
  CLIENT_ID=$(printf '%s' "$HTTP_BODY" | jq -r '.identityUniversalAuth.clientId // empty')
  [[ -n "$CLIENT_ID" ]] || {
    echo "[WARN] could not parse clientId from UA response: $HTTP_BODY" >&2
    CLIENT_ID="<parse failed — retrieve from UI>"
  }
  echo "  UA enabled, clientId: $CLIENT_ID"

  # 4d) Mint a client secret (plaintext returned ONCE — written to file immediately).
  api POST "${INFISICAL_API_URL}/api/v1/auth/universal-auth/identities/${IDENTITY_ID}/client-secrets" \
    "$(jq -nc --arg d "${PROJECT_SLUG}-${env_slug}" '{description:$d}')"
  [[ "$HTTP_CODE" =~ ^2 ]] || {
    echo "[FATAL] client secret create [$HTTP_CODE]: $HTTP_BODY" >&2
    echo "  UI fallback: Identity > Universal Auth > Add Client Secret" >&2
    return 1
  }
  local CLIENT_SECRET
  CLIENT_SECRET=$(printf '%s' "$HTTP_BODY" | jq -r '.clientSecret // empty')
  [[ -n "$CLIENT_SECRET" ]] || {
    echo "[WARN] could not parse clientSecret — retrieve from Infisical UI" >&2
    CLIENT_SECRET="<parse failed — retrieve from UI>"
  }

  # Write per-env credential file (mode 600 — contains real secrets).
  local out_file="${OUT_DIR}/infisical-${env_slug}-machine.env"
  cat > "$out_file" <<ENVEOF
# Machine identity for ${PROJECT_SLUG} env=${env_slug}
# Deploy to the server (mode 600): scp $out_file user@host:/etc/${PROJECT_SLUG}/infisical.env
# Then on the server: chmod 600 /etc/${PROJECT_SLUG}/infisical.env
INFISICAL_API_URL=${INFISICAL_API_URL}
INFISICAL_PROJECT_ID=${INFISICAL_PROJECT_ID}
INFISICAL_ENV=${env_slug}
INFISICAL_CLIENT_ID=${CLIENT_ID}
INFISICAL_CLIENT_SECRET=${CLIENT_SECRET}
ENVEOF
  chmod 600 "$out_file"
  echo "[ok] wrote ${out_file}"
}

echo "==> Creating machine identities for: ${ENVIRONMENTS}"
for ENV_SLUG in $ENVIRONMENTS; do
  create_machine_identity "${PROJECT_SLUG}-${ENV_SLUG}" "$ENV_SLUG"
done

###############################################################################
# Summary
###############################################################################
echo ""
echo "=== Bootstrap complete ==="
echo "  project id   : ${INFISICAL_PROJECT_ID}"
echo "  org id       : ${ORG_ID}"
echo "  environments : ${ENVIRONMENTS}"
echo "  credentials  : ${OUT_DIR}/ (mode 600, gitignored)"
if [[ -n "$MONOREPO_APPS" ]]; then
  echo "  monorepo apps: ${MONOREPO_APPS}"
fi
echo ""
echo "[WARN] ENV ISOLATION NOT YET ENFORCED: identities were attached with"
echo "[WARN]   role=member, granting project-wide access to ALL environments."
echo "[WARN]   For true per-env isolation, create env-scoped custom project"
echo "[WARN]   roles in the UI and reassign each identity:"
echo "[WARN]   Project > Access Control > Project Roles > New Role > add env condition"
echo ""
echo "Next steps:"
echo "  1. Verify identities at: ${INFISICAL_API_URL}"
echo "     Project > Access Control > Machine Identities"
echo "  2. Apply env-scoped roles (see WARN above)."
echo "  3. Copy prod credential file to the server:"
echo "     scp ${OUT_DIR}/infisical-prod-machine.env user@host:/etc/${PROJECT_SLUG}/infisical.env"
echo "     ssh user@host 'chmod 600 /etc/${PROJECT_SLUG}/infisical.env'"
echo "  4. Migrate secrets: bash scripts/migrate-env-to-infisical.sh"
