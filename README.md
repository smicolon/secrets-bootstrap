# secrets-bootstrap

Reusable provisioning toolkit for wiring up [Infisical](https://infisical.com) secret management and an optional [1Password](https://1password.com) break-glass mirror for any project — single-app or monorepo.

All scripts are `set -euo pipefail`, pass `shellcheck`, and gate every mutation on HTTP 2xx with body-on-failure output. No secret values are ever printed; `DRY_RUN=1` shows key names and lengths only.

---

## Quick start — any project

```bash
# From your project root:
curl -fsSL https://raw.githubusercontent.com/smicolon/secrets-bootstrap/main/install.sh | bash
```

This downloads the three scripts into `./scripts/` and drops `config.example.sh` and `.env.example` in the project root. It does not execute any provisioning.

Then:

```bash
cp config.example.sh config.sh
$EDITOR config.sh          # fill in INFISICAL_API_URL, PROJECT_NAME, etc.
source config.sh

infisical login --domain="$INFISICAL_API_URL"
bash scripts/bootstrap-infisical.sh
```

---

## What the toolkit contains

| File | Purpose |
|---|---|
| `scripts/bootstrap-infisical.sh` | Create project, environments, monorepo folders, machine identities |
| `scripts/bootstrap-1password-sync.sh` | Wire Infisical → 1Password one-way sync |
| `scripts/migrate-env-to-infisical.sh` | Push `.env` secrets into Infisical |
| `scripts/setup-infisical-run.sh` | Post-provisioning: write `.infisical.json` so `infisical run` needs no flags |
| `scripts/run-with-secrets.sh` | Universal entrypoint — run any command with secrets injected |
| `scripts/grant-1password-vault.sh` | Grant Connect server a vault + rotate its token + update Infisical (automates the immutable-token dance) |
| `install.sh` | curl-pipe installer (downloads scripts into any project) |
| `config.example.sh` | Documented config template — source before running |
| `.env.example` | env-var reference for all config knobs |
| `justfile` | Task runner recipes |

---

## Single-app vs monorepo

### Single-app

All secrets live at the root path `/` in each environment.

```bash
export PROJECT_NAME="My App"
export PROJECT_SLUG="my-app"
export ENVIRONMENTS="dev staging prod"
# MONOREPO_APPS is unset

bash scripts/bootstrap-infisical.sh
```

Machine identities created: `my-app-dev`, `my-app-staging`, `my-app-prod`.

Credential files written to `secrets/infisical-dev-machine.env`, `secrets/infisical-staging-machine.env`, and `secrets/infisical-prod-machine.env`.

1Password key schema (if sync enabled): `MY_APP_DEV_{{secretKey}}`, `MY_APP_STAGING_{{secretKey}}`, `MY_APP_PROD_{{secretKey}}`.

### Monorepo

A `/<app>` folder is created per app per environment. Each app's secrets are isolated under its own path.

```bash
export PROJECT_NAME="My Monorepo"
export PROJECT_SLUG="my-monorepo"
export ENVIRONMENTS="dev staging prod"
export MONOREPO_APPS="api worker frontend"

bash scripts/bootstrap-infisical.sh
```

Folders created: `/api`, `/worker`, `/frontend` in each of `dev`, `staging`, and `prod`.

To migrate an app's `.env`:

```bash
SECRET_PATH=/api TARGET_ENV=prod bash scripts/migrate-env-to-infisical.sh
```

1Password key schema per sync: `MY_MONOREPO_API_DEV_{{secretKey}}`, `MY_MONOREPO_WORKER_PROD_{{secretKey}}`, etc.

---

## Full provisioning flow

```
bootstrap-infisical.sh
  -> creates project + environments + folders (monorepo)
  -> creates machine identities (Universal Auth)
  -> writes secrets/<env>-machine.env (gitignored, mode 600)

migrate-env-to-infisical.sh
  -> reads .env (or SRC_ENV) and pushes all non-empty scalars
  -> supports DRY_RUN=1 to preview without writing
  -> supports SKIP_KEYS to exclude specific variables
  -> supports SECRET_PATH for monorepo folder targeting

bootstrap-1password-sync.sh
  -> creates (or reuses) a 1Password vault
  -> creates an Infisical App Connection (Connect server creds)
  -> creates one sync per (env, app) pair
```

### `just bootstrap` step-by-step

`just bootstrap` runs `scripts/bootstrap-infisical.sh`. With the default
`ENVIRONMENTS="dev staging prod"`, a single-app run does this:

```
just bootstrap
   │
   ▼
PREFLIGHT      load env config · require curl/jq/infisical
               infisical user get token  →  Bearer JWT
   │
   ▼
GET  /api/v1/workspace                    →  orgId
   │
   ▼
POST /api/v2/workspace (default envs)     →  project.id      (skipped if INFISICAL_PROJECT_ID set)
   │
   ▼
GET  /api/v1/workspace/:id                →  verify envs (⚠ warn if a target env missing)
   │
   ▼
[monorepo only] POST /api/v2/folders      →  /app per env × app   (single-app skips: secrets at /)
   │
   ▼
MACHINE IDENTITIES   idempotent — existing identity of same name is reused
                     (set OVERWRITE_IDENTITIES=1 to delete + recreate)
   for ENV in [ dev, staging, prod ]:
     ① POST /identities                          → identity.id
     ② POST …/identity-memberships/:id           (attach to project)
     ③ POST …/universal-auth/identities/:id      → clientId
     ④ POST …/client-secrets                     → clientSecret (returned once)
        → writes secrets/infisical-<env>-machine.env   (mode 600, gitignored)
   │
   ▼
Bootstrap complete
   ⚠ identities = role:member (project-wide). Isolate via a custom
     env-scoped Project Role in the UI.
```

Net result for the default config: 1 project, default envs verified, and
**3 machine identities** (`<slug>-dev`, `<slug>-staging`, `<slug>-prod`),
each written to its own `secrets/infisical-<env>-machine.env`.

An editable diagram of this flow lives at
[`docs/just-bootstrap-flow.excalidraw`](docs/just-bootstrap-flow.excalidraw)
(open in [Excalidraw](https://excalidraw.com)).

---

## Post-provisioning: running with secrets

Provisioning gets secrets *into* Infisical. To make your app *run with* them,
wire up `infisical run` once:

```bash
# Pin project + default env into .infisical.json (no secrets; safe to commit).
INFISICAL_PROJECT_ID=<uuid> DEFAULT_ENV=dev bash scripts/setup-infisical-run.sh
# or: just setup-run
```

Then run any command — Node, Python, Go, a bare binary — through the universal
wrapper, which injects secrets as environment variables:

```bash
# Local dev (uses your interactive `infisical login` session):
INFISICAL_API_URL=<url> bash scripts/run-with-secrets.sh npm run dev
# or: just run npm run dev

# Non-default env / monorepo app path:
INFISICAL_ENV=prod SECRET_PATH=/api bash scripts/run-with-secrets.sh ./server
```

On a **server**, source the machine-identity credential file first; the wrapper
detects the creds and logs in via Universal Auth automatically (no interactive
session needed):

```bash
set -a; . /etc/<slug>/infisical.env; set +a   # INFISICAL_CLIENT_ID/SECRET + URL
bash scripts/run-with-secrets.sh ./server
```

The same `run-with-secrets.sh` entrypoint therefore works in dev and in
production — only the auth source differs. This avoids editing `package.json`
(Node-only) and keeps the toolkit language-agnostic; the prefix lives in your
Dockerfile `CMD`, systemd unit, or process manager instead.

---

## Environment variables reference

All scripts are configured via environment variables. See `config.example.sh` for a full annotated template.

| Variable | Default | Used by |
|---|---|---|
| `INFISICAL_API_URL` | — | all (required) |
| `PROJECT_NAME` | `My Project` | bootstrap-infisical |
| `PROJECT_SLUG` | `my-project` | bootstrap-infisical, bootstrap-1password-sync |
| `ENVIRONMENTS` | `dev staging prod` | bootstrap-infisical, bootstrap-1password-sync |
| `MONOREPO_APPS` | `""` | bootstrap-infisical, bootstrap-1password-sync |
| `INFISICAL_PROJECT_ID` | `""` | all (skip project creation on re-runs) |
| `OVERWRITE_IDENTITIES` | `0` | bootstrap-infisical (`1` = delete + recreate existing identity) |
| `ORG_ID` | auto-detected | bootstrap-infisical |
| `OUT_DIR` | `secrets` | bootstrap-infisical |
| `DEFAULT_ENV` | `dev` | setup-infisical-run (baked into `.infisical.json`) |
| `INFISICAL_ENV` | `dev` | run-with-secrets (environment to inject) |
| `OP_INSTANCE_URL` | — | bootstrap-1password-sync (required) |
| `OP_SERVICE_TOKEN` | — | bootstrap-1password-sync (required) |
| `OP_CONNECTION_ID` | `""` | bootstrap-1password-sync (skip connection creation) |
| `VAULT_NAME` | `$PROJECT_SLUG` | bootstrap-1password-sync, grant-1password-vault |
| `CONNECTION_NAME` | `$PROJECT_SLUG-1p` | bootstrap-1password-sync |
| `OP_CONNECT_SERVER` | `""` | grant-1password-vault (Connect server name/id; enables auto grant + rotate) |
| `TOKEN_NAME` | `infisical-auto` | grant-1password-vault (name of the auto-minted token) |
| `REVOKE_OLD` | `0` | grant-1password-vault (`1` = revoke prior auto tokens) |
| `SRC_ENV` | `.env` | migrate-env-to-infisical |
| `TARGET_ENV` | — | migrate-env-to-infisical (required) |
| `SECRET_PATH` | `/` | migrate-env-to-infisical |
| `DRY_RUN` | `0` | migrate-env-to-infisical |
| `SKIP_KEYS` | `""` | migrate-env-to-infisical |

---

## API endpoint reference (live-verified 2026-05-29)

All endpoints were verified against a self-hosted Infisical instance. The live API is canonical — always re-verify before modifying connector code.

### Infisical endpoints

| Method | Path | Purpose |
|---|---|---|
| `GET` | `/api/v1/workspace` | List workspaces + resolve `orgId` |
| `POST` | `/api/v2/workspace` | Create project |
| `GET` | `/api/v1/workspace/:id` | Get project + environment list |
| `GET` | `/api/v2/folders` | List folders (idempotency check) |
| `POST` | `/api/v2/folders` | Create monorepo folder |
| `GET` | `/api/v2/organizations/:orgId/identity-memberships` | List identities (idempotency lookup by name) — ⚠ re-verify |
| `POST` | `/api/v1/identities` | Create org-level machine identity |
| `DELETE` | `/api/v1/identities/:identityId` | Delete identity (`OVERWRITE_IDENTITIES=1`) — ⚠ re-verify |
| `POST` | `/api/v2/workspace/:projectId/identity-memberships/:identityId` | Attach identity to project (`identityId` in PATH) |
| `POST` | `/api/v1/auth/universal-auth/identities/:identityId` | Enable Universal Auth |
| `POST` | `/api/v1/auth/universal-auth/identities/:identityId/client-secrets` | Mint client secret |
| `GET` | `/api/v1/app-connections/1password` | List 1Password connections |
| `GET` | `/api/v1/app-connections/1password/:id` | Get connection (exposes `instanceUrl`, never the token) |
| `POST` | `/api/v1/app-connections/1password` | Create 1Password connection |
| `PATCH` | `/api/v1/app-connections/1password/:id` | Update connection token (vault-rotation) |
| `GET` | `/api/v1/secret-syncs/1password` | List 1Password syncs |
| `POST` | `/api/v1/secret-syncs/1password` | Create 1Password sync |

1Password Connect side (via `op` CLI): `op connect server list`,
`op connect vault grant`, `op connect token list/create/delete`.

### Key gotchas (hard-won)

**Identity membership — `identityId` goes in the PATH, not the body.**
The endpoint is `POST /api/v2/workspace/:projectId/identity-memberships/:identityId` and the body is just `{role:"member"}`. Putting `identityId` in the body silently creates the membership with the wrong structure.

**Identity creation is idempotent (by name).**
`POST /api/v1/identities` itself always creates a new identity, so `bootstrap-infisical.sh` first looks one up by name via `GET /api/v2/organizations/:orgId/identity-memberships` and reuses it. Re-runs do not duplicate. `OVERWRITE_IDENTITIES=1` deletes (`DELETE /api/v1/identities/:id`) and recreates.

**1Password Connect token vault-scope is immutable.**
You cannot add a vault to an existing Connect token — it must be revoked and recreated, then the new token pushed into Infisical (`PATCH /api/v1/app-connections/1password/:id`). `grant-1password-vault.sh` automates this. See "1Password Connect: the immutable-token problem" above.

**`op connect token create` uses `--vault` (repeatable), and the comma means permission — not a vault list.**
`--vault "X,r"` is vault X *read-only*; `--vaults "a,b"` is misread as one vault `a` with bogus modifier `b`. Pass one `--vault` per vault. Worse, **op silently drops vaults the server can't reach yet** (grant-propagation lag) instead of erroring — so `grant-1password-vault.sh` verifies the minted token's vault count and retries, never shipping an under-scoped token.

**`role:"member"` is not env-isolated.**
A `member` identity has project-wide access to ALL environments. True per-env isolation requires a custom Project Role with an environment condition, applied in the UI:
`Project > Access Control > Project Roles > New Role > add environment condition`

**`keySchema` lives inside `syncOptions`, not `destinationConfig`.**
A common mistake is putting `keySchema` inside `destinationConfig`. The correct structure is:
```json
{
  "syncOptions": { "keySchema": "PREFIX_ENV_{{secretKey}}" },
  "destinationConfig": { "vaultId": "...", "valueLabel": "value" }
}
```

**`disableSecretDeletion:true` is mandatory when the vault contains other items.**
Without this, Infisical will prune vault items it didn't create during a sync. Only set to `false` if the vault is exclusively Infisical-managed.

---

## 1Password Connect Server

Infisical's 1Password integration requires a **Connect Server**, not a bare Service Account token. The Connect server acts as a gateway between Infisical and your 1Password account.

### Deploy with Docker Compose

```yaml
services:
  op-connect-api:
    image: 1password/connect-api:latest
    ports:
      - "8080:8080"
    volumes:
      - op_data:/home/opuser/.op/data
      - ./1password-credentials.json:/home/opuser/.op/1password-credentials.json:ro
    environment:
      OP_SESSION: ""

  op-connect-sync:
    image: 1password/connect-sync:latest
    ports:
      - "8081:8081"
    volumes:
      - op_data:/home/opuser/.op/data
      - ./1password-credentials.json:/home/opuser/.op/1password-credentials.json:ro

volumes:
  op_data:
```

### Critical gotcha: credentials file ownership

The `1password-credentials.json` file **must be owned by uid 999** (the container user), not root. If it is root-owned, the Connect server will start but fail all API calls with `"permission denied"`.

Fix on the host before starting:

```bash
sudo chown 999:999 ./1password-credentials.json
chmod 600 ./1password-credentials.json
```

### Critical gotcha: internal IP connections

If Infisical and your Connect server are on the same host (or same private network), Infisical will reject the connection with `"Local IPs not allowed"` by default.

Fix: set `ALLOW_INTERNAL_IP_CONNECTIONS=true` on the Infisical backend container, **OR** expose the Connect server via a public HTTPS hostname (e.g. via Cloudflare Tunnel or nginx proxy) and use that URL as `OP_INSTANCE_URL`.

### Create a Connect server token

One Connect server can serve many vaults. Tokens are vault-scoped — create one token per vault:

```bash
# Create the Connect server (one time)
op connect server create "my-connect-server" --vaults "my-vault"

# This outputs a credentials.json file and a token.
# The credentials.json goes on the server (mount it as shown above).
# The token is OP_SERVICE_TOKEN in your config.
```

### Architecture

```
Infisical (cloud or self-hosted)
    |
    | POST /api/v1/app-connections/1password
    | credentials: { instanceUrl, apiToken }
    v
1Password Connect Server  (your deployment)
    |
    | internal API
    v
1Password cloud (your account)
    |
    | vault read/write
    v
1Password vault (break-glass copy)
```

One Infisical App Connection per project. The connection stores the Connect server URL and token. Each secret sync references the connection + a vault ID.

---

## 1Password Connect: the immutable-token problem (automated)

A 1Password Connect access token's **vault scope is immutable** — you cannot add
a vault to an existing token. Adding a new vault means: grant the Connect server
the vault → mint a *new* token spanning all vaults → update the token stored in
Infisical's 1Password connection. Miss the last step and Infisical can't reach
the new vault. Infisical does **not** auto-rotate this token, so per-project
vaults otherwise break automation.

`scripts/grant-1password-vault.sh` automates the whole dance:

1. `op connect vault grant` — give the Connect server the new vault (idempotent).
2. Compute the **union** of vaults on all currently-active tokens + the new one
   (so rotating never strips access from other projects sharing the server).
3. `op connect token create` — mint one token spanning that full set.
4. `PATCH /api/v1/app-connections/1password/:id` — point Infisical at the new token.
5. (Optional, `REVOKE_OLD=1`) revoke prior auto-minted tokens.

```bash
# Standalone (token value is never printed):
INFISICAL_API_URL=… OP_CONNECTION_ID=<uuid> OP_CONNECT_SERVER="Infisical-connect" \
  VAULT_NAME=my-project bash scripts/grant-1password-vault.sh
# or: just grant-vault my-project

# Preview without changing anything:
DRY_RUN=1 … bash scripts/grant-1password-vault.sh
```

`bootstrap-1password-sync.sh` calls this automatically at the end **when
`OP_CONNECT_SERVER` is set** — so a single run creates the vault, the syncs, and
a working token. Requires an `op` session with rights to manage the Connect
server. `OP_INSTANCE_URL` is auto-derived from the existing connection if unset.

> **Alternative — one shared vault.** Because the sync `keySchema` already
> namespaces keys (`SLUG_ENV_{{secretKey}}`), you can instead point every project
> at a single shared vault and mint the Connect token once. That avoids rotation
> entirely, at the cost of per-project vault isolation.

---

## Do not double-trigger syncs

If a sync has `isEnabled:true` (auto-running), do **not** also trigger it manually from the Infisical UI or API. This creates duplicate vault items (one per trigger). To seed the vault for the first time, either:
- Let the auto-sync run on its first cycle, or
- Trigger manually exactly once before enabling auto-sync.

---

## Re-running safely

| Scenario | What to do |
|---|---|
| Project already exists | Set `INFISICAL_PROJECT_ID=<uuid>` — bootstrap skips project creation |
| Machine identities already exist | Reused automatically (looked up by name). Set `OVERWRITE_IDENTITIES=1` to delete + recreate (rotates the secret) |
| App connection already exists | Set `OP_CONNECTION_ID=<uuid>` — skip connection creation |
| Syncs already exist | Script checks by name and skips existing syncs automatically |

---

## Commit history convention

Scripts in this repo follow [Conventional Commits](https://www.conventionalcommits.org/):

- `feat:` new capability
- `fix:` bug fix
- `docs:` documentation only
- `chore:` maintenance (deps, CI, etc.)
