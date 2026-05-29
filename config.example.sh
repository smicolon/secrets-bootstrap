#!/usr/bin/env bash
# config.example.sh — source this file to configure the bootstrap scripts.
# Copy to config.sh, fill in real values, then: source config.sh
#
# Never commit config.sh — it is gitignored.
#
# Usage:
#   cp config.example.sh config.sh
#   $EDITOR config.sh
#   source config.sh
#   bash scripts/bootstrap-infisical.sh

# ── Infisical ────────────────────────────────────────────────────────────────

export INFISICAL_API_URL="https://secrets.example.com"
export PROJECT_NAME="My Project"
export PROJECT_SLUG="my-project"

# Whitespace-separated list of environments to provision.
export ENVIRONMENTS="dev prod"

# Monorepo: space-separated app names (leave empty for single-app).
# export MONOREPO_APPS="api worker frontend"
export MONOREPO_APPS=""

# Re-run: provide to skip project creation.
# export INFISICAL_PROJECT_ID="<uuid>"

# ── 1Password ────────────────────────────────────────────────────────────────
# Requires a 1Password Connect Server (not a bare service account token).
# See README.md "1Password Connect Server" section for setup.

export OP_INSTANCE_URL="https://op-connect.example.com"
export OP_SERVICE_TOKEN="<connect-server-api-token>"
# export OP_CONNECTION_ID="<uuid>"  # reuse existing connection
export VAULT_NAME="$PROJECT_SLUG"
export CONNECTION_NAME="${PROJECT_SLUG}-1p"

# ── Migration ────────────────────────────────────────────────────────────────

export SRC_ENV=".env"
export TARGET_ENV="prod"
export SECRET_PATH="/"
export DRY_RUN="0"
# export SKIP_KEYS="GOOGLE_APPLICATION_CREDENTIALS SOME_OTHER_KEY"
