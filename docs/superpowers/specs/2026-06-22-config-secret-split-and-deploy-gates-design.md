# Config/secret split + fail-loud deploy gates

**Date:** 2026-06-22
**Repo:** prog-strength-infra
**Status:** Design approved, pending spec review

## Problem

The v0.72.0 api release failed: the `restore`/`restore-telemetry` Litestream
one-shots exited 1 because `LITESTREAM_REPLICA_BUCKET` (and every other app
value) was blank in the rendered `.env`. Root cause: the 15 app values live as
GitHub Actions secrets on **prog-strength-api**, but `seed-secrets.yml` now runs
in **prog-strength-infra**, where those secrets don't exist. The seed workflow
read nothing, and because of `... | with_entries(select(.value != ""))` plus an
unconditional `exit 0`, it wrote an empty `{}` blob and reported success. The
deploy then tore down the running stack (`docker compose down`) before failing
at `up`, taking prod down.

Two systemic weaknesses surfaced:
1. **No fail-loud gate** — a missing/empty secret silently produces an empty
   blob and a green checkmark, with the failure deferred to a half-completed
   prod deploy.
2. **Config and secrets are conflated** — bucket names, region, and OAuth client
   IDs are non-secret config but live in the secret store, bloating the set of
   write-only values that must be re-entered and obscuring what is actually
   sensitive.

This is a beta environment with low traffic; a longer controlled downtime to
land the fix cleanly is acceptable (chosen over a fast patch).

## Goals

- Split non-secret config out of the secret store into committed, reviewable config.
- Fail loud and early when required values are missing — never deploy (or tear
  down the running stack) with an incomplete `.env`.
- Land the corrected secret/config shape in a single clean seed + deploy.

## Non-goals

- No new config delivery mechanism (Parameter Store, etc.) — explicitly rejected
  in favor of a committed file, matching the repo's existing "explicit constants,
  no Terraform output round-trip" philosophy for bucket names.
- No change to the agent/mcp secrets beyond what falls out naturally.
- No change to the SSM/OIDC deploy transport (that's PR #65 in the api repo).

## Classification

**Secrets** (stay GitHub secrets → Secrets Manager `prog-strength-backend/prod/api`):
`JWT_SIGNING_KEY`, `GOOGLE_CLIENT_SECRET`, `CALENDAR_TOKEN_ENC_KEY`,
`GRAFANA_ADMIN_PASSWORD`, `FATSECRET_CLIENT_SECRET`, `USDA_FDC_API_KEY`,
`OPENAI_API_KEY`, `ANTHROPIC_API_KEY`, `ADMIN_EMAILS`, `GRAFANA_ADMIN_USER`

**Config** (committed, non-secret):
`LITESTREAM_REPLICA_BUCKET`, `LITESTREAM_REPLICA_REGION`, `TCX_BUCKET_NAME`,
`AVATAR_BUCKET_NAME`, `GOOGLE_CLIENT_ID`, `FATSECRET_CLIENT_ID`

`ADMIN_EMAILS` and `GRAFANA_ADMIN_USER` kept as secrets by user choice (mildly
sensitive / not worth committing to the repo).

## Required vs optional (for the gates)

**Required** (gate fails if absent or empty): `JWT_SIGNING_KEY`,
`GOOGLE_CLIENT_ID`, `GOOGLE_CLIENT_SECRET`, `CALENDAR_TOKEN_ENC_KEY`,
`LITESTREAM_REPLICA_BUCKET`, `ADMIN_EMAILS`, `GRAFANA_ADMIN_USER`,
`GRAFANA_ADMIN_PASSWORD`, `TCX_BUCKET_NAME`, `AVATAR_BUCKET_NAME`

**Optional** (may be absent; endpoints degrade to 503 per `api.sh`'s existing
contract): `FATSECRET_CLIENT_ID`, `FATSECRET_CLIENT_SECRET`, `USDA_FDC_API_KEY`,
`OPENAI_API_KEY`, `ANTHROPIC_API_KEY`

The required/optional list is defined once and shared in intent across the two
gates: `seed-secrets.yml` validates the required **secrets** subset; `api.sh`
validates the full required set in the assembled `.env`.

## Design

### 1. Committed config file

New `compose/api/config.env` (non-secret, committed):

```
# Non-secret app config consumed by deploy/api.sh when it assembles .env.
# Bucket names mirror the defaults in modules/{backup,tcx_storage,avatar_storage}
# variables.tf — that is the canonical source; keep these in sync. They are
# explicit constants by design so they can be referenced cross-repo without a
# Terraform output round-trip. Region matches api.sh's AWS_REGION.
LITESTREAM_REPLICA_BUCKET=prog-strength-database-backups
LITESTREAM_REPLICA_REGION=us-east-2
TCX_BUCKET_NAME=prog-strength-tcx-uploads
AVATAR_BUCKET_NAME=prog-strength-avatars
GOOGLE_CLIENT_ID=<fill from current GH secret value>
FATSECRET_CLIENT_ID=<fill from current GH secret value, or omit if unused>
```

`GOOGLE_CLIENT_ID` / `FATSECRET_CLIENT_ID` values are currently only in
write-only GH secrets; the operator fills them in when creating the file.

Ensure `compose/api/.env` stays gitignored and `compose/api/config.env` is NOT
ignored.

### 2. `deploy/api.sh` changes

Assemble `.env` from three ordered sources, then validate before any teardown:

1. `cat compose/api/config.env` (committed config)
2. secret-derived `KEY=value` lines from Secrets Manager (the 10 secrets)
3. deploy echoes: `AWS_REGION`, `APP_VERSION`, `ECR_REGISTRY`

New ordering (the key safety change):

```
render .env  ->  validate required keys present & non-empty  ->  docker compose pull
  ->  docker compose down  ->  docker compose up -d
```

The validation step runs immediately **after** `.env` is rendered and **before**
the image pull and `down`, so a missing required value aborts the deploy with the
running stack intact (and without even pulling). A small sourced helper
(`deploy/lib/require-env.sh`) reads `.env`, checks each required key has a
non-empty value, and on any miss prints the offending keys to stderr and returns
non-zero (which `set -e` propagates and SSM surfaces as `Failed`).

`SECRET_ID` and the existing umask/secret-render logic are unchanged except that
the secret blob now contains only the 10 secrets (the absent config keys come
from `config.env` instead).

### 3. `seed-secrets.yml` changes

For the `prog-strength-backend/prod/api` step: after building the payload, assert
the required **secrets** subset is present and non-empty. That subset is the
required set minus the config-sourced keys (`GOOGLE_CLIENT_ID`,
`LITESTREAM_REPLICA_BUCKET`, `TCX_BUCKET_NAME`, `AVATAR_BUCKET_NAME` come from
`config.env`, not the seed), i.e.: `JWT_SIGNING_KEY`, `GOOGLE_CLIENT_SECRET`,
`CALENDAR_TOKEN_ENC_KEY`, `ADMIN_EMAILS`, `GRAFANA_ADMIN_USER`,
`GRAFANA_ADMIN_PASSWORD`. On any miss, print the missing names and exit non-zero
— no `put-secret-value`. This converts a silent empty seed into a hard, named
failure. The existing `with_entries(select(.value != ""))` (which drops optional
empties) stays for the optional keys; the new gate runs against the required
subset specifically.

The config keys (`LITESTREAM_REPLICA_*`, `*_BUCKET_NAME`, `*_CLIENT_ID`) are
removed from the api seed step entirely — they are no longer secrets.

The agent and mcp seed steps are unchanged.

## Operational runbook (the "one clean apply")

Executed after the code changes merge:

1. Create the GitHub Actions secrets on **prog-strength-infra**: the 6 required
   secrets (`JWT_SIGNING_KEY`, `GOOGLE_CLIENT_SECRET`, `CALENDAR_TOKEN_ENC_KEY`,
   `ADMIN_EMAILS`, `GRAFANA_ADMIN_USER`, `GRAFANA_ADMIN_PASSWORD`) plus any of the
   4 optional provider secrets (`FATSECRET_CLIENT_SECRET`, `USDA_FDC_API_KEY`,
   `OPENAI_API_KEY`, `ANTHROPIC_API_KEY`) that are in use. Values are re-entered
   by the operator; GH secrets are write-only so they cannot be copied from the
   api repo programmatically.
2. Fill real values into `compose/api/config.env` for the two client IDs and
   commit (bucket names/region already correct).
3. Run `seed-secrets.yml` (workflow_dispatch) on prog-strength-infra. With the
   new gate, a missing required secret fails here, loudly, before any deploy.
4. Verify the secret: `aws secretsmanager get-secret-value --secret-id
   prog-strength-backend/prod/api --region us-east-2 --query SecretString
   --output text | jq 'keys'` shows the 10 secret keys.
5. Re-run the api deploy (release re-run or manual-deploy). `api.sh`'s pre-flight
   gate now guarantees a complete `.env` before it touches the running stack.

## Testing

- **`api.sh` validation helper**: unit-test the required-key check against
  fixtures — complete `.env` passes; `.env` missing a required key or with an
  empty value fails with that key named; optional keys absent still passes.
- **Ordering**: verify (by reading / a dry-run harness) that validation precedes
  `docker compose down` so a bad `.env` cannot tear down the stack.
- **`seed-secrets.yml` gate**: validate the jq/shell assertion logic locally with
  a complete payload (passes) and one missing a required key (exits non-zero,
  names the key, no `put`).
- **End-to-end**: the runbook itself is the integration test — a deliberately
  missing required secret should fail at step 3, not step 5.

## Risks / trade-offs

- **Bucket-name duplication** between `variables.tf` and `config.env`. Accepted:
  they are stable explicit constants and the repo already chose this over TF
  output round-trips. A sync comment points at the canonical source.
- **Operator must re-enter 10 secrets** on the infra repo. Unavoidable — GH
  secrets are write-only. The reduced set (config removed) makes this smaller.
- **`git pull --ff-only` in the pull-guard** (api repo PR #65) assumes a clean
  host checkout; unrelated to this change but part of the same deploy path.
