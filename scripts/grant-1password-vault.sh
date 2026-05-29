#!/usr/bin/env bash
# grant-1password-vault.sh — automate the 1Password Connect "new vault" dance.
#
# THE PROBLEM
#   A 1Password Connect access token's vault scope is IMMUTABLE — you cannot add
#   a vault to an existing token; you must mint a new one. Infisical's 1Password
#   connection stores that token as its apiToken, so every new vault otherwise
#   means: grant server -> new token -> manually paste it into Infisical. Miss
#   the last step and the new vault is unreachable.
#
# WHAT THIS DOES (all scripted)
#   1. Grants the Connect server access to VAULT_NAME (idempotent).
#   2. Computes the FULL vault set this connection needs = union of the vaults on
#      all currently-ACTIVE tokens for the server + the new vault. (Never reduces
#      access, so other projects/syncs sharing this server keep working.)
#   3. Mints ONE new token scoped to that full set.
#   4. PATCHes the Infisical 1Password app connection's apiToken to the new token.
#   5. Optionally revokes the prior auto-minted tokens (REVOKE_OLD=1) — only ones
#      whose name matches TOKEN_NAME, never tokens created for other purposes.
#
# The token value is NEVER printed (only its length).
#
# Requires an `op` session with rights to manage the Connect server (owner of the
# Secrets Automation workflow), plus an interactive `infisical login` session.
#
# Endpoints/commands validated against live tooling 2026-05-29:
#   op connect server list | vault grant | token list | token create | token delete
#   PATCH /api/v1/app-connections/1password/:connectionId
#
# Usage:
#   INFISICAL_API_URL=https://secrets.example.com \
#   OP_CONNECTION_ID=<infisical-connection-uuid> \
#   OP_INSTANCE_URL=https://op-connect.example.com \
#   OP_CONNECT_SERVER="Infisical-connect" \
#   VAULT_NAME=my-project \
#     bash scripts/grant-1password-vault.sh
#
#   # preview only (no mutations):
#   DRY_RUN=1 ... bash scripts/grant-1password-vault.sh
set -euo pipefail

###############################################################################
# Config (override via environment variables)
###############################################################################
: "${INFISICAL_API_URL:?Set INFISICAL_API_URL, e.g. https://secrets.example.com}"
: "${OP_CONNECTION_ID:?Set OP_CONNECTION_ID to the Infisical 1Password connection uuid}"
: "${OP_CONNECT_SERVER:?Set OP_CONNECT_SERVER to the Connect server name or id}"
# Connect Server URL for the Infisical update. Auto-derived from the existing
# connection if not set (Infisical returns instanceUrl, but never the token).
OP_INSTANCE_URL="${OP_INSTANCE_URL:-}"
: "${VAULT_NAME:?Set VAULT_NAME to the vault to grant + sync}"
TOKEN_NAME="${TOKEN_NAME:-infisical-auto}"
REVOKE_OLD="${REVOKE_OLD:-0}"
DRY_RUN="${DRY_RUN:-0}"
# Optional: pin the op CLI account (multi-account machines).
OP_ACCOUNT="${OP_ACCOUNT:-}"

###############################################################################
# Prerequisites
###############################################################################
for bin in curl jq op infisical; do
  command -v "$bin" >/dev/null || { echo "[FATAL] missing required binary: $bin" >&2; exit 1; }
done

# op account flag (array — shellcheck-clean even when empty).
op_args=()
[[ -n "$OP_ACCOUNT" ]] && op_args+=(--account "$OP_ACCOUNT")

###############################################################################
# Auth — reuse the operator's logged-in Infisical CLI session.
###############################################################################
TOKEN="$(infisical user get token --plain --domain="$INFISICAL_API_URL" 2>/dev/null \
  || infisical user get token --domain="$INFISICAL_API_URL" 2>&1 | tail -1)"
[[ -n "$TOKEN" ]] || { echo "[FATAL] could not retrieve Infisical token. Run: infisical login --domain=$INFISICAL_API_URL" >&2; exit 1; }

HTTP_CODE=""; HTTP_BODY=""
api() {
  local method="$1" url="$2" body="${3:-}" raw
  if [[ -n "$body" ]]; then
    raw=$(curl -sS -X "$method" "$url" -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" -d "$body" -w $'\n%{http_code}')
  else
    raw=$(curl -sS -X "$method" "$url" -H "Authorization: Bearer $TOKEN" -w $'\n%{http_code}')
  fi
  HTTP_CODE="${raw##*$'\n'}"; HTTP_BODY="${raw%$'\n'*}"
}

###############################################################################
# Resolve the Connect Server URL from the existing connection if not provided.
###############################################################################
if [[ -z "$OP_INSTANCE_URL" ]]; then
  api GET "${INFISICAL_API_URL}/api/v1/app-connections/1password/${OP_CONNECTION_ID}"
  [[ "$HTTP_CODE" =~ ^2 ]] || { echo "[FATAL] could not read connection [$HTTP_CODE]: $HTTP_BODY" >&2; exit 1; }
  OP_INSTANCE_URL=$(printf '%s' "$HTTP_BODY" | jq -r '.appConnection.credentials.instanceUrl // .credentials.instanceUrl // empty')
  [[ -n "$OP_INSTANCE_URL" ]] || { echo "[FATAL] connection did not expose instanceUrl — set OP_INSTANCE_URL explicitly." >&2; exit 1; }
  echo "[ok] resolved Connect Server URL: $OP_INSTANCE_URL"
fi

###############################################################################
# Step 1 — Resolve the Connect server + the new vault.
###############################################################################
echo "==> Resolving Connect server '${OP_CONNECT_SERVER}'..."
SRV_ID=$(op connect server list "${op_args[@]}" --format=json 2>/dev/null \
  | jq -r --arg n "$OP_CONNECT_SERVER" '.[] | select(.name==$n or .id==$n) | .id' | head -n1 || true)
[[ -n "$SRV_ID" ]] || { echo "[FATAL] Connect server '${OP_CONNECT_SERVER}' not found (op connect server list)." >&2; exit 1; }
echo "[ok] server id: $SRV_ID"

VAULT_ID=$(op vault get "$VAULT_NAME" "${op_args[@]}" --format=json 2>/dev/null | jq -r '.id // empty' || true)
[[ -n "$VAULT_ID" ]] || { echo "[FATAL] vault '${VAULT_NAME}' not found. Create it first (bootstrap-1password-sync.sh)." >&2; exit 1; }
echo "[ok] vault id: $VAULT_ID (${VAULT_NAME})"

###############################################################################
# Step 2 — Compute the full vault set (union of active tokens' vaults + new).
###############################################################################
EXISTING_IDS=$(op connect token list "${op_args[@]}" --format=json 2>/dev/null \
  | jq -r --arg s "$SRV_ID" '.[] | select(.integration_id==$s and .state=="ACTIVE") | .vaults[].id' 2>/dev/null | sort -u || true)
# Filter to vaults that STILL EXIST — active tokens can reference deleted vaults,
# and minting a token over a non-existent vault id fails.
LIVE_VAULTS=$(op vault list "${op_args[@]}" --format=json 2>/dev/null | jq -r '.[].id' 2>/dev/null | sort -u || true)
CANDIDATE=$(printf '%s\n%s\n' "$EXISTING_IDS" "$VAULT_ID" | sed '/^$/d' | sort -u)
ALL_IDS=$(comm -12 <(printf '%s\n' "$CANDIDATE") <(printf '%s\n' "$LIVE_VAULTS"))
# VAULT_ID is guaranteed live (resolved above); ensure it's included.
ALL_IDS=$(printf '%s\n%s\n' "$ALL_IDS" "$VAULT_ID" | sed '/^$/d' | sort -u)
# Transparency: surface any previously-covered vault that was dropped (deleted /
# not visible) so coverage of OLD vaults is never silently reduced.
DROPPED=$(comm -23 <(printf '%s\n' "$CANDIDATE" | sed '/^$/d') <(printf '%s\n' "$ALL_IDS" | sed '/^$/d'))
if [[ -n "$DROPPED" ]]; then
  echo "[WARN] these previously-covered vault ids are not live and were dropped from the token:" >&2
  printf '%s\n' "$DROPPED" | sed 's/^/       /' >&2
fi
VAULT_CSV=$(printf '%s' "$ALL_IDS" | paste -sd, -)
VAULT_COUNT=$(printf '%s\n' "$ALL_IDS" | sed '/^$/d' | wc -l | tr -d ' ')
# `op connect token create` takes ONE --vault flag per vault (the comma form is
# for a per-vault r/w modifier, NOT a vault separator). Build the flag array.
vault_flags=()
while IFS= read -r vid; do [[ -n "$vid" ]] && vault_flags+=(--vault "$vid"); done <<< "$ALL_IDS"
echo "[ok] token will span ${VAULT_COUNT} vault(s): ${VAULT_CSV}"

if [[ "$DRY_RUN" == "1" ]]; then
  echo ""
  echo "=== DRY RUN — no changes made ==="
  echo "  would: op connect vault grant --server $SRV_ID --vault $VAULT_ID"
  echo "  would: op connect token create '${TOKEN_NAME}' --server $SRV_ID --vaults <${VAULT_COUNT} vaults>"
  echo "  would: PATCH ${INFISICAL_API_URL}/api/v1/app-connections/1password/${OP_CONNECTION_ID} (apiToken=<new>)"
  [[ "$REVOKE_OLD" == "1" ]] && echo "  would: revoke prior ACTIVE tokens named '${TOKEN_NAME}'"
  exit 0
fi

###############################################################################
# Step 3 — Grant the server the new vault (idempotent).
###############################################################################
echo "==> Granting server access to vault '${VAULT_NAME}'..."
op connect vault grant --server "$SRV_ID" --vault "$VAULT_ID" "${op_args[@]}" >/dev/null 2>&1 \
  && echo "[ok] granted" \
  || echo "[info] grant returned non-zero (likely already granted) — continuing"

###############################################################################
# Step 4 — Mint a new token covering the full vault set.
###############################################################################
echo "==> Creating new Connect token '${TOKEN_NAME}' (verifying full vault coverage)..."
# op silently drops vaults the server can't see yet (grant-propagation lag), so
# verify the minted token actually covers all requested vaults and retry if not.
NEW_TOKEN=""
ATTEMPTS="${GRANT_RETRIES:-4}"
for attempt in $(seq 1 "$ATTEMPTS"); do
  CANDIDATE_TOKEN=$(op connect token create "$TOKEN_NAME" --server "$SRV_ID" "${vault_flags[@]}" "${op_args[@]}" 2>/dev/null | tail -n1 || true)
  [[ "$CANDIDATE_TOKEN" == eyJ* ]] || { echo "[FATAL] token creation failed — check op rights to manage the Connect server." >&2; exit 1; }
  NEWEST_ID=$(op connect token list "${op_args[@]}" --format=json 2>/dev/null \
    | jq -r --arg s "$SRV_ID" --arg n "$TOKEN_NAME" '[.[]|select(.integration_id==$s and .state=="ACTIVE" and .name==$n)]|sort_by(.created_at)|last|.id // empty')
  GOT=$(op connect token list "${op_args[@]}" --format=json 2>/dev/null \
    | jq -r --arg id "$NEWEST_ID" '[.[]|select(.id==$id)|.vaults[].id]|length')
  if [[ "${GOT:-0}" -ge "$VAULT_COUNT" ]]; then
    NEW_TOKEN="$CANDIDATE_TOKEN"
    echo "[ok] minted token (len=${#NEW_TOKEN}) covering ${GOT}/${VAULT_COUNT} vault(s)"
    break
  fi
  echo "[info] token covers ${GOT:-0}/${VAULT_COUNT} vaults — grant still propagating (attempt ${attempt}/${ATTEMPTS}); revoking + retrying..."
  [[ -n "$NEWEST_ID" ]] && op connect token delete "$NEWEST_ID" --server "$SRV_ID" "${op_args[@]}" >/dev/null 2>&1 || true
  sleep 6
done
[[ -n "$NEW_TOKEN" ]] || {
  echo "[FATAL] could not mint a token covering all ${VAULT_COUNT} vaults after ${ATTEMPTS} attempts." >&2
  echo "  The vault grant has not propagated to the Connect server yet. Re-run in a minute." >&2
  exit 1
}

###############################################################################
# Step 5 — Point the Infisical connection at the new token.
###############################################################################
echo "==> Updating Infisical 1Password connection ${OP_CONNECTION_ID}..."
api PATCH "${INFISICAL_API_URL}/api/v1/app-connections/1password/${OP_CONNECTION_ID}" "$(jq -nc \
  --arg t "$NEW_TOKEN" --arg u "$OP_INSTANCE_URL" \
  '{credentials:{apiToken:$t, instanceUrl:$u}}')"
[[ "$HTTP_CODE" =~ ^2 ]] || {
  echo "[FATAL] connection update [$HTTP_CODE]: $HTTP_BODY" >&2
  echo "  The new token exists but Infisical was not updated. Update it manually:" >&2
  echo "  Org Settings > App Connections > 1Password > edit > paste the new token." >&2
  exit 1
}
echo "[ok] Infisical connection updated"

###############################################################################
# Step 6 — Optionally revoke prior auto-minted tokens.
###############################################################################
if [[ "$REVOKE_OLD" == "1" ]]; then
  echo "==> Revoking prior ACTIVE tokens named '${TOKEN_NAME}' (keeping the new one)..."
  # The newest token is the one we just made; revoke older same-named ACTIVE tokens.
  OLD_IDS=$(op connect token list "${op_args[@]}" --format=json 2>/dev/null \
    | jq -r --arg s "$SRV_ID" --arg n "$TOKEN_NAME" \
      '[.[] | select(.integration_id==$s and .state=="ACTIVE" and .name==$n)] | sort_by(.created_at) | .[:-1][].id' 2>/dev/null || true)
  if [[ -n "$OLD_IDS" ]]; then
    while IFS= read -r tid; do
      [[ -n "$tid" ]] || continue
      op connect token delete "$tid" --server "$SRV_ID" "${op_args[@]}" >/dev/null 2>&1 \
        && echo "  revoked $tid" || echo "  [WARN] could not revoke $tid" >&2
    done <<< "$OLD_IDS"
  else
    echo "  none to revoke"
  fi
fi

echo ""
echo "=== Done ==="
echo "  vault granted : ${VAULT_NAME} (${VAULT_ID})"
echo "  token vaults  : ${VAULT_COUNT}"
echo "  connection    : ${OP_CONNECTION_ID} (updated)"
echo ""
echo "The sync for this vault can now reach 1Password. Trigger it ONCE in Infisical"
echo "if it is not already auto-running."
