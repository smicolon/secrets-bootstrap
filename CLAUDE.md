# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

A reusable, **dependency-free Bash toolkit** for provisioning Infisical secret
management (plus an optional one-way 1Password break-glass mirror) into any
project — single-app or monorepo. There is no application to build or run; the
"product" is the three scripts in `scripts/`, which an operator copies into
their own project (via `install.sh`'s curl-pipe) and executes against a live
Infisical instance. The scripts talk to the Infisical/1Password REST APIs
directly with `curl` + `jq`.

## Commands

```bash
just                      # list recipes (default)
just lint                 # shellcheck all scripts + install.sh — MUST pass
just syntax-check         # bash -n all scripts (no execution)

# Provisioning (require a live infisical login + sourced config.sh):
just bootstrap            # bootstrap-infisical.sh   — project, envs, folders, identities
just migrate [env]        # migrate-env-to-infisical.sh (default env=prod)
just migrate-dry [env]    # DRY_RUN=1 migration (prints key names + lengths, never values)
just onepassword-sync     # bootstrap-1password-sync.sh
just secrets [env]        # list secret names for an env (default dev)
```

There is no test suite. **`shellcheck` is the gate** — every change to a `.sh`
file must keep `just lint` green. Scripts are validated by running against a
live Infisical instance, not by mocks.

## Architecture & conventions

The three scripts are independent entry points but share a deliberate, uniform
structure. **When editing one, mirror the pattern in the others** — they are
meant to read identically.

- **Config via environment variables only.** Each script opens with a config
  block: required vars use `: "${VAR:?message}"` (hard fail with guidance),
  optional vars use `"${VAR:-default}"`. The operator sets these by copying
  `config.example.sh` → `config.sh` (gitignored) and `source`-ing it.
- **Shared `api()` HTTP helper** (identical in the two API-driven scripts):
  every call sets globals `HTTP_CODE` and `HTTP_BODY`. The invariant is that
  **every mutation is gated on `[[ "$HTTP_CODE" =~ ^2 ]]`**, and on failure the
  script prints the response body plus a UI-fallback hint. Preserve this gate
  on any new endpoint call.
- **Auth reuses the operator's CLI session**, not a token in config:
  `infisical user get token --plain --domain=...` yields a Bearer JWT.
- **Idempotency is per-resource and intentional.** Project creation, folders,
  app connections, and syncs all check-then-create (or accept a `*_ID` env var
  to skip). The one exception is **machine-identity creation, which is NOT
  idempotent** — `POST /api/v1/identities` always makes a new identity.
  Re-running `bootstrap-infisical.sh` without `INFISICAL_PROJECT_ID` set
  produces duplicates. This is documented loudly in the script; keep it that way.
- **Secret hygiene is a hard rule.** No script ever prints a secret value.
  `DRY_RUN=1` in the migration prints only `KEY (len=N)`. Credential output
  files go to `secrets/` (mode 600, gitignored) and `config.sh` is gitignored.
- **Single-app vs monorepo** is driven entirely by `MONOREPO_APPS`. Empty =
  single-app (secrets at `/`). Set = a `/<app>` folder per app per env, and the
  1Password key schema gains an app segment
  (`SLUG_APP_ENV_{{secretKey}}` vs `SLUG_ENV_{{secretKey}}`).

## API gotchas (live-verified 2026-05-29 — re-verify before changing connector code)

These are hard-won and easy to get wrong. The README has the full table; the
load-bearing ones:

- **Identity membership: `identityId` goes in the URL PATH, not the body.**
  `POST /api/v2/workspace/:projectId/identity-memberships/:identityId`, body is
  just `{role:"member"}`.
- **`role:"member"` is project-wide**, NOT env-isolated. Every machine identity
  can read all environments until a custom env-scoped Project Role is applied in
  the UI. Scripts warn about this; don't silently "fix" it by changing the role.
- **1Password sync `keySchema` lives inside `syncOptions`, not
  `destinationConfig`.** Misplacing it is the classic bug.
- **`disableSecretDeletion:true`** is mandatory on syncs unless the vault is
  exclusively Infisical-managed, or the sync prunes other vault items.
- **1Password needs a Connect *Server*** (deployed containers), not a bare
  service-account token. `OP_INSTANCE_URL` is the Connect server URL.

When an endpoint shape is uncertain, the live OpenAPI spec at
`${INFISICAL_API_URL}/api/docs/json` is canonical.

## Commit conventions

Conventional Commits (`feat:`, `fix:`, `docs:`, `chore:`), first line < 72
chars, no attribution/footers. Make reversible commits; do not push without
asking.
