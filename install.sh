#!/usr/bin/env bash
# install.sh — one-command installer + guided setup for secrets-bootstrap.
#
# Run this in any project and it sets everything up:
#   curl -fsSL https://raw.githubusercontent.com/smicolon/secrets-bootstrap/main/install.sh | bash
#
# What it does:
#   1. Downloads the toolkit scripts into ./scripts/ and the config templates.
#   2. If run from a terminal: gathers config (smart defaults + auto-detection),
#      ensures you're logged in to Infisical, and runs the full provisioning
#      (project + identities -> migrate .env -> infisical run -> 1Password mirror).
#   3. If there is NO terminal (CI / blind pipe) and RUN_SETUP is not set, it
#      only downloads and prints next steps — never provisions unexpectedly.
#
# Knobs:
#   NO_SETUP=1     download only, even in a terminal
#   RUN_SETUP=1    force provisioning without a terminal (env vars must be set)
#   Any config var (INFISICAL_API_URL, PROJECT_SLUG, ...) set in the environment
#   is used as-is and not prompted for.
#
# Existing files are never overwritten (safe to re-run).
set -euo pipefail

REPO_RAW="https://raw.githubusercontent.com/smicolon/secrets-bootstrap/main"

# Interactive only if /dev/tty can actually be opened (the node exists on macOS
# even with no controlling terminal, so test openability, not existence).
INTERACTIVE=0
if (exec 3</dev/tty) 2>/dev/null; then INTERACTIVE=1; fi

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

# Prompt for VAR with a default, reading from /dev/tty (stdin is the piped
# script). An already-set environment value wins and is never prompted.
ask() {  # ask VAR "Question" "default"
  local __var="$1" __q="$2" __def="${3:-}" __ans=""
  [[ -n "${!__var:-}" ]] && return 0
  if [[ "$INTERACTIVE" == 1 ]]; then
    if [[ -n "$__def" ]]; then printf '%s [%s]: ' "$__q" "$__def" > /dev/tty
    else printf '%s: ' "$__q" > /dev/tty; fi
    IFS= read -r __ans < /dev/tty || __ans=""
  fi
  [[ -z "$__ans" ]] && __ans="$__def"
  printf -v "$__var" '%s' "$__ans"
}

confirm() {  # confirm "Question" -> 0 for yes
  local __ans=""
  [[ "$INTERACTIVE" == 1 ]] || return 1
  printf '%s [y/N]: ' "$1" > /dev/tty
  IFS= read -r __ans < /dev/tty || __ans=""
  [[ "$__ans" =~ ^[Yy] ]]
}

# Read newline-separated stdin into a named array (bash-3.2-safe; no mapfile).
read_array() {  # read_array ARRNAME < input
  local __name="$1" __line; eval "$__name=()"
  while IFS= read -r __line; do [[ -n "$__line" ]] && eval "$__name+=(\"\$__line\")"; done
}

###############################################################################
# Download
###############################################################################
echo ""
echo "=== secrets-bootstrap installer ==="
echo ""
mkdir -p scripts
chmod 755 scripts

for s in bootstrap-infisical bootstrap-1password-sync migrate-env-to-infisical \
         setup-infisical-run run-with-secrets grant-1password-vault setup-all; do
  download "${REPO_RAW}/scripts/${s}.sh" "scripts/${s}.sh"
  chmod 755 "scripts/${s}.sh"
done

download "${REPO_RAW}/config.example.sh" "config.example.sh"
download "${REPO_RAW}/.env.example"      ".env.example"

echo ""
echo "=== Downloaded ==="

###############################################################################
# Decide: guided setup, or download-only.
###############################################################################
if [[ "${NO_SETUP:-0}" == "1" || ( "$INTERACTIVE" != 1 && "${RUN_SETUP:-0}" != "1" ) ]]; then
  cat <<'EOF'

Next steps (no terminal detected, or NO_SETUP=1 — downloaded only):
  1. cp config.example.sh config.sh && $EDITOR config.sh
  2. infisical login --domain=$INFISICAL_API_URL
  3. source config.sh && bash scripts/setup-all.sh      # or: just all

Re-run this installer in a terminal to set everything up interactively.
Docs: https://github.com/smicolon/secrets-bootstrap
EOF
  exit 0
fi

###############################################################################
# Guided setup
###############################################################################
echo ""
echo "=== Guided setup ==="
for bin in infisical jq; do
  command -v "$bin" >/dev/null || { echo "[FATAL] '$bin' is required for setup. Install it and re-run." >&2; exit 1; }
done

if [[ -f config.sh ]]; then
  echo "Found existing config.sh — using it."
  # shellcheck disable=SC1091
  source config.sh
else
  default_slug=$(basename "$PWD" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9]\{1,\}/-/g; s/^-//; s/-$//')
  default_domain=""
  [[ -f "$HOME/.infisical/infisical-config.json" ]] && \
    default_domain=$(jq -r '.LoggedInUserDomain // .loggedInUserDomain // empty' "$HOME/.infisical/infisical-config.json" 2>/dev/null | sed 's#/api/*$##')

  ask INFISICAL_API_URL "Infisical instance URL" "$default_domain"
  ask PROJECT_NAME       "Project name"          "$default_slug"
  ask PROJECT_SLUG       "Project slug"          "$default_slug"
  ask ENVIRONMENTS       "Environments"          "dev staging prod"
  DEFAULT_ENV="${DEFAULT_ENV:-${ENVIRONMENTS%% *}}"

  # 1Password mirror — optional, auto-detected.
  if confirm "Set up the 1Password mirror?"; then
    if ! command -v op >/dev/null; then
      echo "  [warn] 'op' CLI not found — skipping 1Password."
    else
      accts=(); read_array accts < <(op account list --format=json 2>/dev/null | jq -r '.[].url' 2>/dev/null)
      if [[ "${#accts[@]}" -gt 1 ]]; then
        printf '  accounts: %s\n' "${accts[*]}" > /dev/tty
        ask OP_ACCOUNT "1Password account" "${accts[0]}"
      elif [[ "${#accts[@]}" -eq 1 ]]; then OP_ACCOUNT="${accts[0]}"; fi
      opf=(); [[ -n "${OP_ACCOUNT:-}" ]] && opf=(--account "$OP_ACCOUNT")

      srv=(); read_array srv < <(op connect server list "${opf[@]}" --format=json 2>/dev/null | jq -r '.[].name' 2>/dev/null)
      if [[ "${#srv[@]}" -eq 1 ]]; then OP_CONNECT_SERVER="${srv[0]}"
      elif [[ "${#srv[@]}" -gt 1 ]]; then printf '  Connect servers: %s\n' "${srv[*]}" > /dev/tty; ask OP_CONNECT_SERVER "Connect server" "${srv[0]}"
      else echo "  [warn] no Connect server found — skipping 1Password."; fi

      if [[ -n "${OP_CONNECT_SERVER:-}" ]]; then
        _tok=$(infisical user get token --plain --domain="$INFISICAL_API_URL" 2>/dev/null || true)
        conn=(); read_array conn < <(curl -fsS -H "Authorization: Bearer ${_tok}" "$INFISICAL_API_URL/api/v1/app-connections/1password" 2>/dev/null | jq -r '.appConnections[]?.id' 2>/dev/null)
        if [[ "${#conn[@]}" -ge 1 ]]; then OP_CONNECTION_ID="${conn[0]}"
        else echo "  [warn] no Infisical 1Password connection found — create one in the UI first; skipping 1Password."; OP_CONNECT_SERVER=""; fi
      fi
    fi
  fi

  {
    echo "#!/usr/bin/env bash"
    echo "# config.sh — generated by install.sh (gitignored; never commit)"
    echo "export INFISICAL_API_URL=\"${INFISICAL_API_URL}\""
    echo "export PROJECT_NAME=\"${PROJECT_NAME}\""
    echo "export PROJECT_SLUG=\"${PROJECT_SLUG}\""
    echo "export ENVIRONMENTS=\"${ENVIRONMENTS}\""
    echo "export DEFAULT_ENV=\"${DEFAULT_ENV}\""
    echo "export SRC_ENV=\".env\""
    echo "export TARGET_ENV=\"${DEFAULT_ENV}\""
    if [[ -n "${OP_CONNECT_SERVER:-}" ]]; then
      echo "export OP_ACCOUNT=\"${OP_ACCOUNT:-}\""
      echo "export OP_CONNECT_SERVER=\"${OP_CONNECT_SERVER}\""
      echo "export OP_CONNECTION_ID=\"${OP_CONNECTION_ID:-}\""
      echo "export VAULT_NAME=\"${VAULT_NAME:-$PROJECT_SLUG}\""
    fi
  } > config.sh
  chmod 600 config.sh
  echo "  wrote config.sh"
  # shellcheck disable=SC1091
  source config.sh
fi

# Ensure Infisical login.
if ! infisical user get token --plain --domain="$INFISICAL_API_URL" >/dev/null 2>&1; then
  if [[ "$INTERACTIVE" == 1 ]]; then
    echo "Logging in to Infisical (${INFISICAL_API_URL})..."
    infisical login --domain="$INFISICAL_API_URL" < /dev/tty > /dev/tty 2>&1 || { echo "[FATAL] infisical login failed." >&2; exit 1; }
  else
    echo "[FATAL] not logged in to Infisical. Run: infisical login --domain=$INFISICAL_API_URL" >&2
    exit 1
  fi
fi

# Confirm before creating real resources.
echo ""
echo "About to provision:"
echo "  instance : ${INFISICAL_API_URL}"
echo "  project  : ${PROJECT_NAME} (${PROJECT_SLUG})"
echo "  envs     : ${ENVIRONMENTS}"
if [[ -n "${OP_CONNECT_SERVER:-}" ]]; then
  echo "  1Password: vault '${VAULT_NAME:-$PROJECT_SLUG}' via Connect server '${OP_CONNECT_SERVER}'"
else
  echo "  1Password: (skipped)"
fi
if [[ "$INTERACTIVE" == 1 ]] && ! confirm "Proceed?"; then
  echo "Aborted. Re-run later with: source config.sh && bash scripts/setup-all.sh"
  exit 0
fi

bash scripts/setup-all.sh
