# secrets-bootstrap task runner.  Install `just`:  brew install just
#
# Copy config.example.sh to config.sh and fill in values before running.
# These recipes drive the three provisioning scripts in scripts/.
#
# List recipes:  just            (or `just --list`)

set shell := ["bash", "-uc"]

# Show available recipes
default:
    @just --list

# ── Quick setup ───────────────────────────────────────────────────────────────

# Show the bootstrap installer command (curl | bash)
install-url:
    @echo "curl -fsSL https://raw.githubusercontent.com/smicolon/secrets-bootstrap/main/install.sh | bash"

# ── Provisioning (run from your laptop with an active infisical login) ────────

# Create the Infisical project + environments + machine identities
bootstrap:
    bash scripts/bootstrap-infisical.sh

# Migrate .env secrets into Infisical for a target env (default: prod)
migrate env="prod":
    TARGET_ENV={{env}} bash scripts/migrate-env-to-infisical.sh

# Dry-run the migration — prints key names and lengths only, no secret values, no writes
migrate-dry env="prod":
    DRY_RUN=1 TARGET_ENV={{env}} bash scripts/migrate-env-to-infisical.sh

# Create the Infisical -> 1Password vault syncs
onepassword-sync:
    bash scripts/bootstrap-1password-sync.sh

# Grant the Connect server a vault + rotate its token + update Infisical
grant-vault vault:
    VAULT_NAME={{vault}} bash scripts/grant-1password-vault.sh

# Post-provisioning: write .infisical.json so `infisical run` needs no flags
setup-run:
    bash scripts/setup-infisical-run.sh

# Run any command with secrets injected from Infisical, e.g. just run npm run dev
run *cmd:
    bash scripts/run-with-secrets.sh {{cmd}}

# ── Inspection ────────────────────────────────────────────────────────────────

# List secret names for an environment (default: dev)
secrets env="dev":
    infisical secrets --env={{env}} --domain="${INFISICAL_API_URL}"

# ── Linting ───────────────────────────────────────────────────────────────────

# Lint all shell scripts with shellcheck
lint:
    shellcheck scripts/bootstrap-infisical.sh
    shellcheck scripts/bootstrap-1password-sync.sh
    shellcheck scripts/migrate-env-to-infisical.sh
    shellcheck scripts/setup-infisical-run.sh
    shellcheck scripts/run-with-secrets.sh
    shellcheck scripts/grant-1password-vault.sh
    shellcheck install.sh
    @echo "shellcheck passed"

# Syntax-check all scripts (bash -n, no execution)
syntax-check:
    bash -n scripts/bootstrap-infisical.sh
    bash -n scripts/bootstrap-1password-sync.sh
    bash -n scripts/migrate-env-to-infisical.sh
    bash -n scripts/setup-infisical-run.sh
    bash -n scripts/run-with-secrets.sh
    bash -n scripts/grant-1password-vault.sh
    bash -n install.sh
    @echo "syntax check passed"
