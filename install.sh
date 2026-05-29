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

# Make them executable.
chmod 755 scripts/bootstrap-infisical.sh
chmod 755 scripts/bootstrap-1password-sync.sh
chmod 755 scripts/migrate-env-to-infisical.sh

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
echo "  3. Source config and run bootstrap:"
echo "     source config.sh"
echo "     bash scripts/bootstrap-infisical.sh"
echo ""
echo "  4. Migrate your .env secrets:"
echo "     DRY_RUN=1 bash scripts/migrate-env-to-infisical.sh   # dry run first"
echo "     bash scripts/migrate-env-to-infisical.sh             # live migration"
echo ""
echo "  5. (Optional) Set up 1Password sync:"
echo "     bash scripts/bootstrap-1password-sync.sh"
echo ""
echo "See README.md or https://github.com/smicolon/secrets-bootstrap for full docs."
echo ""
