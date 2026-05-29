#!/usr/bin/env bash
# install.sh — bootstrap installer for secrets-bootstrap.
#
# Fetches the toolkit into the current project directory so any project can
# use it without cloning this repo manually.
#
# Usage (from your project root):
#   curl -fsSL https://raw.githubusercontent.com/smicolon/secrets-bootstrap/main/install.sh | bash
#
# What it does:
#   1. Creates ./scripts/ if it does not exist.
#   2. Downloads bootstrap-infisical.sh, bootstrap-1password-sync.sh,
#      migrate-env-to-infisical.sh into ./scripts/.
#   3. Downloads config.example.sh and .env.example into the project root.
#   4. Makes the scripts executable.
#   5. Prints next-step guidance.
#
# It does NOT overwrite files that already exist (safe to re-run).
# It does NOT execute any provisioning — you run the scripts yourself.
set -euo pipefail

REPO_RAW="https://raw.githubusercontent.com/smicolon/secrets-bootstrap/main"

###############################################################################
# Helpers
###############################################################################
download() {
  local url="$1" dest="$2"
  if [[ -f "$dest" ]]; then
    echo "  [skip] already exists: $dest"
    return 0
  fi
  echo "  [fetch] $dest"
  if command -v curl >/dev/null 2>&1; then
    curl -fsSL "$url" -o "$dest"
  elif command -v wget >/dev/null 2>&1; then
    wget -q "$url" -O "$dest"
  else
    echo "[FATAL] curl or wget required" >&2
    exit 1
  fi
}

###############################################################################
# Main
###############################################################################
echo ""
echo "=== secrets-bootstrap installer ==="
echo ""

# Create scripts/ directory.
mkdir -p scripts
chmod 755 scripts

# Download the three provisioning scripts.
download "${REPO_RAW}/scripts/bootstrap-infisical.sh"       "scripts/bootstrap-infisical.sh"
download "${REPO_RAW}/scripts/bootstrap-1password-sync.sh"  "scripts/bootstrap-1password-sync.sh"
download "${REPO_RAW}/scripts/migrate-env-to-infisical.sh"  "scripts/migrate-env-to-infisical.sh"
download "${REPO_RAW}/scripts/setup-infisical-run.sh"       "scripts/setup-infisical-run.sh"
download "${REPO_RAW}/scripts/run-with-secrets.sh"          "scripts/run-with-secrets.sh"
download "${REPO_RAW}/scripts/grant-1password-vault.sh"     "scripts/grant-1password-vault.sh"
download "${REPO_RAW}/scripts/setup-all.sh"                 "scripts/setup-all.sh"

# Make them executable.
chmod 755 scripts/bootstrap-infisical.sh
chmod 755 scripts/bootstrap-1password-sync.sh
chmod 755 scripts/migrate-env-to-infisical.sh
chmod 755 scripts/setup-infisical-run.sh
chmod 755 scripts/run-with-secrets.sh
chmod 755 scripts/grant-1password-vault.sh
chmod 755 scripts/setup-all.sh

# Download config template and .env.example.
download "${REPO_RAW}/config.example.sh" "config.example.sh"
download "${REPO_RAW}/.env.example"      ".env.example"

echo ""
echo "=== Done! ==="
echo ""
echo "Next steps:"
echo ""
echo "  1. Copy and edit the config template:"
echo "     cp config.example.sh config.sh"
echo "     \$EDITOR config.sh"
echo ""
echo "  2. Authenticate to Infisical:"
echo "     infisical login --domain=\$INFISICAL_API_URL"
echo ""
echo "  3. Provision EVERYTHING in one command:"
echo "     source config.sh && bash scripts/setup-all.sh   # (or: just all)"
echo ""
echo "     This chains: project + identities -> migrate .env -> infisical run"
echo "     setup -> 1Password mirror (when configured). Run individual steps"
echo "     instead with: just bootstrap | just migrate | just onepassword-sync"
echo ""
echo "See README.md or https://github.com/smicolon/secrets-bootstrap for full docs."
echo ""

###############################################################################
# Optional: provision in the same command.
# Run the full setup right now when RUN_SETUP=1 (config.sh present or required
# env vars already exported, and logins done). Off by default so a blind
# curl | bash only ever downloads.
###############################################################################
if [[ "${RUN_SETUP:-0}" == "1" ]]; then
  echo "=== RUN_SETUP=1 — provisioning now ==="
  # shellcheck disable=SC1091
  [[ -f config.sh ]] && source config.sh
  bash scripts/setup-all.sh
fi
