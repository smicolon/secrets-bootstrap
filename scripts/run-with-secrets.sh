#!/usr/bin/env bash
# run-with-secrets.sh — universal entrypoint that runs ANY command with secrets
# injected from Infisical (`infisical run --`). Language-agnostic: wraps node,
# python, go binaries, shell — anything.
#
# Works in two contexts with the SAME entrypoint:
#   - dev:    relies on your interactive `infisical login` session.
#   - server: if machine-identity creds are present in the environment
#             (INFISICAL_CLIENT_ID + INFISICAL_CLIENT_SECRET, e.g. sourced from
#             secrets/infisical-<env>-machine.env), it logs in via Universal
#             Auth to mint a token first, then runs non-interactively.
#
# Context (project + env) comes from .infisical.json (see setup-infisical-run.sh)
# plus the env vars below.
#
# Usage (dev):
#   INFISICAL_API_URL=https://secrets.example.com \
#     bash scripts/run-with-secrets.sh npm run dev
#
# Usage (non-default env / monorepo app path):
#   INFISICAL_API_URL=... INFISICAL_ENV=prod SECRET_PATH=/api \
#     bash scripts/run-with-secrets.sh ./server
#
# Usage (server, machine identity):
#   set -a; . /etc/<slug>/infisical.env; set +a   # provides CLIENT_ID/SECRET
#   bash scripts/run-with-secrets.sh ./server
set -euo pipefail

###############################################################################
# Config (override via environment variables)
###############################################################################
: "${INFISICAL_API_URL:?Set INFISICAL_API_URL, e.g. https://secrets.example.com}"
INFISICAL_ENV="${INFISICAL_ENV:-dev}"
SECRET_PATH="${SECRET_PATH:-/}"
INFISICAL_PROJECT_ID="${INFISICAL_PROJECT_ID:-}"

###############################################################################
# Prerequisites
###############################################################################
[[ $# -gt 0 ]] || {
  echo "[FATAL] no command given." >&2
  echo "  Usage: run-with-secrets.sh <command> [args...]" >&2
  exit 1
}
command -v infisical >/dev/null 2>&1 || {
  echo "[FATAL] 'infisical' CLI not found." >&2
  echo "  Install: https://infisical.com/docs/cli/overview" >&2
  exit 1
}

###############################################################################
# Server path — mint a token from machine-identity creds when present.
###############################################################################
if [[ -n "${INFISICAL_CLIENT_ID:-}" && -n "${INFISICAL_CLIENT_SECRET:-}" ]]; then
  echo "[info] machine-identity creds detected — logging in via Universal Auth" >&2
  INFISICAL_TOKEN="$(infisical login --method=universal-auth \
    --client-id="$INFISICAL_CLIENT_ID" \
    --client-secret="$INFISICAL_CLIENT_SECRET" \
    --domain="$INFISICAL_API_URL" --plain --silent)"
  export INFISICAL_TOKEN
fi

###############################################################################
# Run — inject secrets and exec the command.
###############################################################################
extra_args=()
[[ -n "$INFISICAL_PROJECT_ID" ]] && extra_args+=(--projectId="$INFISICAL_PROJECT_ID")

exec infisical run \
  --env="$INFISICAL_ENV" \
  --path="$SECRET_PATH" \
  --domain="$INFISICAL_API_URL" \
  "${extra_args[@]}" \
  -- "$@"
