# Config/secret split + fail-loud deploy gates — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Move non-secret config out of Secrets Manager into a committed `config.env`, and add fail-loud required-value gates to `seed-secrets.yml` and `deploy/api.sh` so a missing value aborts *before* the running stack is torn down.

**Architecture:** A small sourced bash helper (`deploy/lib/require-env.sh`) validates that required keys in an env file are present and non-empty. `deploy/api.sh` assembles `.env` from committed `config.env` + the (now config-free) Secrets Manager blob + deploy echoes, then validates before pull/down. `seed-secrets.yml` asserts its required-secrets subset before writing. CI shellcheck is extended to cover the deploy scripts.

**Tech Stack:** Bash, AWS CLI (Secrets Manager / SSM), jq, docker compose, GitHub Actions, shellcheck.

**Spec:** `docs/superpowers/specs/2026-06-22-config-secret-split-and-deploy-gates-design.md`

---

## File Structure

- **Create** `deploy/lib/require-env.sh` — sourced helper defining `require_env_keys FILE KEY...`. One responsibility: validate an env file has the named keys non-empty.
- **Create** `deploy/tests/require-env.test.sh` — dependency-free bash tests for the helper.
- **Create** `compose/api/config.env` — committed non-secret app config (bucket names, region, OAuth client IDs).
- **Modify** `deploy/api.sh` — source the helper; prepend `config.env` to the `.env` render; validate required keys before pull/down.
- **Modify** `.github/workflows/seed-secrets.yml` — drop config keys from the api seed step; add a required-secrets gate before `put-secret-value`.
- **Modify** `.github/workflows/lint.yml` — shellcheck the deploy scripts/lib/tests, not just `bootstrap.sh`; update stale comment.
- **Modify** `.pre-commit-config.yaml` — `-x` arg for source-following; update stale comment.

---

## Task 1: Env-validation helper (TDD)

**Files:**
- Create: `deploy/lib/require-env.sh`
- Test: `deploy/tests/require-env.test.sh`

- [ ] **Step 1: Write the failing test**

Create `deploy/tests/require-env.test.sh`:

```bash
#!/usr/bin/env bash
# Dependency-free tests for require_env_keys (deploy/lib/require-env.sh).
# Run: bash deploy/tests/require-env.test.sh
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=deploy/lib/require-env.sh
source "${SCRIPT_DIR}/../lib/require-env.sh"

failures=0
check() { # check <expected-rc> <description> <env-file> <keys...>
  local want="$1" desc="$2" file="$3"; shift 3
  require_env_keys "$file" "$@" 2>/dev/null
  local got=$?
  if [ "$got" -eq "$want" ]; then
    echo "ok: ${desc}"
  else
    echo "FAIL: ${desc} (want rc=${want}, got rc=${got})"
    failures=$((failures + 1))
  fi
}

tmp="$(mktemp)"; trap 'rm -f "$tmp"' EXIT

# Case 1: all required present and non-empty -> rc 0
cat >"$tmp" <<'EOF'
JWT_SIGNING_KEY=abc123
LITESTREAM_REPLICA_BUCKET=prog-strength-database-backups
EOF
check 0 "all present passes" "$tmp" JWT_SIGNING_KEY LITESTREAM_REPLICA_BUCKET

# Case 2: a required key entirely absent -> rc 1
cat >"$tmp" <<'EOF'
JWT_SIGNING_KEY=abc123
EOF
check 1 "absent key fails" "$tmp" JWT_SIGNING_KEY LITESTREAM_REPLICA_BUCKET

# Case 3: a required key present but empty -> rc 1
cat >"$tmp" <<'EOF'
JWT_SIGNING_KEY=abc123
LITESTREAM_REPLICA_BUCKET=
EOF
check 1 "empty value fails" "$tmp" JWT_SIGNING_KEY LITESTREAM_REPLICA_BUCKET

# Case 4: value contains '=' (e.g. base64) -> treated as present, rc 0
cat >"$tmp" <<'EOF'
CALENDAR_TOKEN_ENC_KEY=AAAAbbbbCCCCdddd==
EOF
check 0 "value with = passes" "$tmp" CALENDAR_TOKEN_ENC_KEY

# Case 5: only required keys are checked; unrelated lines ignored -> rc 0
cat >"$tmp" <<'EOF'
# a comment
JWT_SIGNING_KEY=abc123
OPTIONAL_THING=
EOF
check 0 "unchecked empty optional ignored" "$tmp" JWT_SIGNING_KEY

if [ "$failures" -gt 0 ]; then
  echo "${failures} test(s) failed"; exit 1
fi
echo "all tests passed"
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash deploy/tests/require-env.test.sh`
Expected: FAIL — `require-env.sh: No such file or directory` (helper not created yet).

- [ ] **Step 3: Write the helper**

Create `deploy/lib/require-env.sh`:

```bash
#!/usr/bin/env bash
# Sourced by deploy scripts (and tests). No top-level execution.
#
# require_env_keys FILE KEY...
#   Asserts every KEY appears in FILE as `KEY=value` with a non-empty value.
#   Prints any missing/empty keys to stderr and returns 1; returns 0 if all
#   present. Values may contain '=' (e.g. base64-padded keys).

require_env_keys() {
  local env_file="$1"; shift
  local key val
  local missing=()
  for key in "$@"; do
    if ! grep -q "^${key}=" "$env_file"; then
      missing+=("$key")
      continue
    fi
    # Last definition wins (matches docker compose .env semantics); strip the
    # key and first '=' only so '=' inside the value survives.
    val="$(grep "^${key}=" "$env_file" | tail -n1 | cut -d= -f2-)"
    if [ -z "$val" ]; then
      missing+=("$key")
    fi
  done
  if [ "${#missing[@]}" -gt 0 ]; then
    printf 'Missing or empty required env keys: %s\n' "${missing[*]}" >&2
    return 1
  fi
  return 0
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bash deploy/tests/require-env.test.sh`
Expected: PASS — ends with `all tests passed`.

- [ ] **Step 5: Shellcheck both files**

Run: `shellcheck -x deploy/lib/require-env.sh deploy/tests/require-env.test.sh`
Expected: no output, exit 0.

- [ ] **Step 6: Commit**

```bash
git add deploy/lib/require-env.sh deploy/tests/require-env.test.sh
git commit -m "feat(deploy): add require_env_keys env-validation helper + tests"
```

---

## Task 2: Committed config file

**Files:**
- Create: `compose/api/config.env`

> **Operator input required:** the real `GOOGLE_CLIENT_ID` and `FATSECRET_CLIENT_ID`
> values currently live only in write-only GitHub secrets. Obtain them (Google
> Cloud console / FatSecret dashboard, or the value last set on the api repo) and
> fill them in before committing. `GOOGLE_CLIENT_ID` is **required** — do not
> commit it empty. `FATSECRET_CLIENT_ID` is optional (leave blank if FatSecret is
> unused). Bucket names and region are known constants, already filled below.

- [ ] **Step 1: Create the config file**

Create `compose/api/config.env`:

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
GOOGLE_CLIENT_ID=REPLACE_WITH_REAL_GOOGLE_CLIENT_ID
FATSECRET_CLIENT_ID=
```

- [ ] **Step 2: Verify it is NOT gitignored**

Run: `git check-ignore compose/api/config.env; echo "rc=$?"`
Expected: no path printed and `rc=1` (not ignored). The `.gitignore` pattern is the exact name `.env`, which does not match `config.env`.

- [ ] **Step 3: Replace the GOOGLE_CLIENT_ID placeholder with the real value**

Edit `compose/api/config.env` and set `GOOGLE_CLIENT_ID=` to the real client ID.
Set `FATSECRET_CLIENT_ID=` too if FatSecret is in use.

Run: `grep -q '^GOOGLE_CLIENT_ID=REPLACE_WITH_REAL' compose/api/config.env && echo "STILL PLACEHOLDER — fix before commit" || echo "ok"`
Expected: `ok`.

- [ ] **Step 4: Commit**

```bash
git add compose/api/config.env
git commit -m "feat(deploy): commit non-secret api config (buckets, region, client IDs)"
```

---

## Task 3: Wire api.sh to config.env + pre-flight validation

**Files:**
- Modify: `deploy/api.sh`

Current relevant structure (for reference): `cd /home/ubuntu/prog-strength-infra` → `git` self-update → `cd compose/api` → ECR login → render `.env` via a `{ aws secretsmanager ... | jq ...; echo AWS_REGION=...; echo APP_VERSION=...; echo ECR_REGISTRY=...; } >.env` block → `COMPOSE_FILES=(...)` → `docker compose pull api` → `docker compose down` → `docker compose up -d`.

- [ ] **Step 1: Source the helper near the top of the script**

In `deploy/api.sh`, immediately after the `set -euo pipefail` line, add:

```bash

# Resolve the script's own directory so the sourced helper path is independent
# of the working directory (the script cd's into compose/api below).
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=deploy/lib/require-env.sh
source "${SCRIPT_DIR}/lib/require-env.sh"
```

- [ ] **Step 2: Prepend config.env to the .env render**

In the `{ ... } >.env` block, add `cat config.env` as the FIRST line inside the
braces (cwd is `compose/api`, where both `config.env` and the generated `.env`
live). The block becomes:

```bash
umask 077
{
  # Non-secret config first (bucket names, region, OAuth client IDs); see
  # config.env. Secret-derived lines and deploy echoes follow and never
  # collide (disjoint keys).
  cat config.env
  aws secretsmanager get-secret-value \
    --secret-id "${SECRET_ID}" --region "${AWS_REGION}" \
    --query SecretString --output text \
    | jq -r 'to_entries[] | "\(.key)=\(.value)"'
  echo "AWS_REGION=${AWS_REGION}"
  echo "APP_VERSION=${RELEASE_VERSION}"
  echo "ECR_REGISTRY=${ECR_REGISTRY}"
} >.env
```

- [ ] **Step 3: Add the pre-flight validation immediately after the .env block**

Directly after the `} >.env` line and before `COMPOSE_FILES=(...)` / `docker compose pull`, add:

```bash

# Fail loud BEFORE pulling or tearing down the running stack: a missing or
# empty required value aborts here with prod still serving. Optional providers
# (FatSecret, USDA, OpenAI/Anthropic) are intentionally absent from this list —
# their endpoints degrade to 503, see the render comment above.
REQUIRED_ENV_KEYS=(
  JWT_SIGNING_KEY
  GOOGLE_CLIENT_ID
  GOOGLE_CLIENT_SECRET
  CALENDAR_TOKEN_ENC_KEY
  LITESTREAM_REPLICA_BUCKET
  ADMIN_EMAILS
  GRAFANA_ADMIN_USER
  GRAFANA_ADMIN_PASSWORD
  TCX_BUCKET_NAME
  AVATAR_BUCKET_NAME
)
require_env_keys .env "${REQUIRED_ENV_KEYS[@]}"
```

(Under `set -e`, a non-zero return from `require_env_keys` aborts the script
before `docker compose down`.)

- [ ] **Step 4: Shellcheck the script**

Run: `shellcheck -x deploy/api.sh`
Expected: no output, exit 0.

- [ ] **Step 5: Smoke-test the render+validate path offline**

This confirms ordering and validation without AWS/docker. Run:

```bash
bash -c '
set -euo pipefail
cd /tmp && rm -rf apitest && mkdir -p apitest/lib && cd apitest
cp /Users/jimmywallace/Desktop/prog-strength/repos/prog-strength-infra/deploy/lib/require-env.sh lib/
source lib/require-env.sh
# Simulate a GOOD .env (config + secrets present)
cat >.env <<EOF
GOOGLE_CLIENT_ID=x
LITESTREAM_REPLICA_BUCKET=b
TCX_BUCKET_NAME=t
AVATAR_BUCKET_NAME=a
JWT_SIGNING_KEY=j
GOOGLE_CLIENT_SECRET=s
CALENDAR_TOKEN_ENC_KEY=c
ADMIN_EMAILS=e
GRAFANA_ADMIN_USER=u
GRAFANA_ADMIN_PASSWORD=p
EOF
KEYS=(JWT_SIGNING_KEY GOOGLE_CLIENT_ID GOOGLE_CLIENT_SECRET CALENDAR_TOKEN_ENC_KEY LITESTREAM_REPLICA_BUCKET ADMIN_EMAILS GRAFANA_ADMIN_USER GRAFANA_ADMIN_PASSWORD TCX_BUCKET_NAME AVATAR_BUCKET_NAME)
require_env_keys .env "${KEYS[@]}" && echo "GOOD .env -> pass (expected)"
# Simulate a BAD .env (empty bucket, as in the v0.72.0 outage)
sed -i.bak "s/^LITESTREAM_REPLICA_BUCKET=b/LITESTREAM_REPLICA_BUCKET=/" .env
if require_env_keys .env "${KEYS[@]}" 2>/tmp/err; then echo "BAD .env -> UNEXPECTED pass"; else echo "BAD .env -> abort (expected): $(cat /tmp/err)"; fi
'
```

Expected: prints `GOOD .env -> pass (expected)` then `BAD .env -> abort (expected): Missing or empty required env keys: LITESTREAM_REPLICA_BUCKET`.

- [ ] **Step 6: Commit**

```bash
git add deploy/api.sh
git commit -m "feat(deploy): render config.env into .env and gate required keys before teardown"
```

---

## Task 4: seed-secrets.yml — drop config keys, add required gate

**Files:**
- Modify: `.github/workflows/seed-secrets.yml`

- [ ] **Step 1: Remove all 6 config keys from the api seed step**

The api seed step today seeds 16 keys. All 6 config keys must be removed so they
are sourced only from `compose/api/config.env` (otherwise the seeded value would
override config.env, since api.sh renders config first). Remove **GOOGLE_CLIENT_ID,
LITESTREAM_REPLICA_BUCKET, LITESTREAM_REPLICA_REGION, TCX_BUCKET_NAME,
AVATAR_BUCKET_NAME, FATSECRET_CLIENT_ID** from three places in the step.

Delete these `env:` lines:

```yaml
          GOOGLE_CLIENT_ID: ${{ secrets.GOOGLE_CLIENT_ID }}
          LITESTREAM_REPLICA_BUCKET: ${{ secrets.LITESTREAM_REPLICA_BUCKET }}
          LITESTREAM_REPLICA_REGION: ${{ secrets.LITESTREAM_REPLICA_REGION }}
          TCX_BUCKET_NAME: ${{ secrets.TCX_BUCKET_NAME }}
          AVATAR_BUCKET_NAME: ${{ secrets.AVATAR_BUCKET_NAME }}
          FATSECRET_CLIENT_ID: ${{ secrets.FATSECRET_CLIENT_ID }}
```

Delete these `--arg` lines:

```yaml
            --arg GOOGLE_CLIENT_ID "${GOOGLE_CLIENT_ID}" \
            --arg LITESTREAM_REPLICA_BUCKET "${LITESTREAM_REPLICA_BUCKET}" \
            --arg LITESTREAM_REPLICA_REGION "${LITESTREAM_REPLICA_REGION}" \
            --arg TCX_BUCKET_NAME "${TCX_BUCKET_NAME}" \
            --arg AVATAR_BUCKET_NAME "${AVATAR_BUCKET_NAME}" \
            --arg FATSECRET_CLIENT_ID "${FATSECRET_CLIENT_ID}" \
```

Delete these jq object lines:

```yaml
              GOOGLE_CLIENT_ID: $GOOGLE_CLIENT_ID,
              LITESTREAM_REPLICA_BUCKET: $LITESTREAM_REPLICA_BUCKET,
              LITESTREAM_REPLICA_REGION: $LITESTREAM_REPLICA_REGION,
              TCX_BUCKET_NAME: $TCX_BUCKET_NAME,
              AVATAR_BUCKET_NAME: $AVATAR_BUCKET_NAME,
              FATSECRET_CLIENT_ID: $FATSECRET_CLIENT_ID,
```

After removal, the jq object's 10 retained keys (in order) are: `JWT_SIGNING_KEY`,
`GOOGLE_CLIENT_SECRET`, `CALENDAR_TOKEN_ENC_KEY`, `ADMIN_EMAILS`,
`GRAFANA_ADMIN_USER`, `GRAFANA_ADMIN_PASSWORD`, `FATSECRET_CLIENT_SECRET`,
`USDA_FDC_API_KEY`, `OPENAI_API_KEY`, `ANTHROPIC_API_KEY`. Verify the last one
(`ANTHROPIC_API_KEY`) has **no** trailing comma and every earlier key **does** —
jq rejects a trailing comma. The `with_entries(select(.value != ""))` line stays.

- [ ] **Step 2: Add the required-secrets gate before put-secret-value**

In the same step's `run:` block, between the `payload="$(...)"` assignment and the
`aws secretsmanager put-secret-value` call, insert:

```bash
          # Fail loud if a required secret is missing/empty rather than writing a
          # thinned blob and reporting success (which silently broke the v0.72.0
          # deploy). Required = the app can't run without it; the config-sourced
          # required keys (GOOGLE_CLIENT_ID, *_BUCKET) come from compose/api/
          # config.env and are validated at deploy time by api.sh, not here.
          required_secrets=(
            JWT_SIGNING_KEY
            GOOGLE_CLIENT_SECRET
            CALENDAR_TOKEN_ENC_KEY
            ADMIN_EMAILS
            GRAFANA_ADMIN_USER
            GRAFANA_ADMIN_PASSWORD
          )
          missing=()
          for k in "${required_secrets[@]}"; do
            if [ -z "${!k:-}" ]; then missing+=("$k"); fi
          done
          if [ "${#missing[@]}" -gt 0 ]; then
            echo "Refusing to seed: missing required secrets: ${missing[*]}" >&2
            exit 1
          fi
```

(`${!k}` indirectly expands the env var named by `$k`, which the step's `env:`
block sets from `${{ secrets.* }}`.)

- [ ] **Step 3: Validate the gate logic locally (reproduce the bash snippet)**

Run:

```bash
bash -c '
set -uo pipefail
run_gate() {
  local required_secrets=(JWT_SIGNING_KEY GOOGLE_CLIENT_SECRET CALENDAR_TOKEN_ENC_KEY ADMIN_EMAILS GRAFANA_ADMIN_USER GRAFANA_ADMIN_PASSWORD)
  local missing=() k
  for k in "${required_secrets[@]}"; do [ -z "${!k:-}" ] && missing+=("$k"); done
  if [ "${#missing[@]}" -gt 0 ]; then echo "missing: ${missing[*]}"; return 1; fi
  echo "all present"; return 0
}
# all set -> pass
JWT_SIGNING_KEY=a GOOGLE_CLIENT_SECRET=b CALENDAR_TOKEN_ENC_KEY=c ADMIN_EMAILS=d GRAFANA_ADMIN_USER=e GRAFANA_ADMIN_PASSWORD=f run_gate && echo "rc=$?"
# one missing -> fail
JWT_SIGNING_KEY=a GOOGLE_CLIENT_SECRET=b CALENDAR_TOKEN_ENC_KEY=c ADMIN_EMAILS=d GRAFANA_ADMIN_USER=e run_gate; echo "rc=$?"
'
```

Expected: `all present` then `rc=0`, then `missing: GRAFANA_ADMIN_PASSWORD` then `rc=1`.

- [ ] **Step 4: Lint the workflow YAML**

Run: `ruby -ryaml -e "YAML.load_file('.github/workflows/seed-secrets.yml'); puts 'valid'"`
Expected: `valid`.

- [ ] **Step 5: Commit**

```bash
git add .github/workflows/seed-secrets.yml
git commit -m "ci(secrets): drop config keys from api seed; gate on required secrets"
```

---

## Task 5: Extend shellcheck coverage to the deploy scripts

**Files:**
- Modify: `.github/workflows/lint.yml`
- Modify: `.pre-commit-config.yaml`

- [ ] **Step 1: Update the lint.yml shellcheck step**

Replace the `shellcheck` step's `run:` and stale comment so it covers every shell
file (with `-x` to follow the sourced helper). The step becomes:

```yaml
      - name: shellcheck
        # shellcheck is preinstalled on ubuntu-latest runners. Covers the
        # Terraform bootstrap templatefile and the on-host deploy scripts +
        # their sourced lib and tests. -x follows `source` directives.
        run: shellcheck -x modules/compute/bootstrap.sh deploy/*.sh deploy/lib/*.sh deploy/tests/*.sh
```

- [ ] **Step 2: Update the pre-commit shellcheck hook**

In `.pre-commit-config.yaml`, update the shellcheck hook to follow sources and fix
the stale comment:

```yaml
  - repo: https://github.com/koalaman/shellcheck-precommit
    rev: v0.10.0
    hooks:
      # Fast — runs on commit. Covers bootstrap.sh and the deploy/ scripts,
      # lib, and tests (shellcheck auto-detects shell files). -x follows
      # `source` directives into deploy/lib/.
      - id: shellcheck
        stages: [pre-commit]
        args: [-x]
```

- [ ] **Step 3: Run shellcheck exactly as CI will**

Run: `shellcheck -x modules/compute/bootstrap.sh deploy/*.sh deploy/lib/*.sh deploy/tests/*.sh`
Expected: no output, exit 0.

- [ ] **Step 4: Lint both YAML/config files**

Run: `ruby -ryaml -e "YAML.load_file('.github/workflows/lint.yml'); YAML.load_file('.pre-commit-config.yaml'); puts 'valid'"`
Expected: `valid`.

- [ ] **Step 5: Commit**

```bash
git add .github/workflows/lint.yml .pre-commit-config.yaml
git commit -m "ci(lint): shellcheck the deploy scripts, lib, and tests"
```

---

## Task 6: Open the PR

- [ ] **Step 1: Push and open PR**

```bash
git push -u origin chore/config-secret-split
gh pr create --base main --head chore/config-secret-split \
  --title "config/secret split + fail-loud deploy gates" \
  --body "See docs/superpowers/specs/2026-06-22-config-secret-split-and-deploy-gates-design.md. Splits non-secret config (bucket names, region, client IDs) into committed compose/api/config.env, drops them from the api Secrets Manager seed, and adds required-value gates to seed-secrets.yml and deploy/api.sh (validate before \`docker compose down\` so a bad value can't take prod down). Root-caused from the v0.72.0 outage."
```

Expected: prints the PR URL.

---

## Rollout (manual, after the PR merges)

This is the "one clean apply" from the spec runbook. Requires prod AWS creds and
GitHub admin on prog-strength-infra; performed by the operator.

- [ ] Create the required GitHub Actions secrets on **prog-strength-infra**:
  `JWT_SIGNING_KEY`, `GOOGLE_CLIENT_SECRET`, `CALENDAR_TOKEN_ENC_KEY`,
  `ADMIN_EMAILS`, `GRAFANA_ADMIN_USER`, `GRAFANA_ADMIN_PASSWORD`, plus any used
  optional provider secrets (`FATSECRET_CLIENT_SECRET`, `USDA_FDC_API_KEY`,
  `OPENAI_API_KEY`, `ANTHROPIC_API_KEY`). Values re-entered by hand (GH secrets
  are write-only). Verify: `gh secret list -R Prog-Strength/prog-strength-infra`.
- [ ] Run the seed workflow: `gh workflow run seed-secrets.yml -R Prog-Strength/prog-strength-infra`.
  With the new gate, a missing required secret fails here, named, before any deploy.
- [ ] Verify the secret has the 10 keys:
  `aws secretsmanager get-secret-value --secret-id prog-strength-backend/prod/api --region us-east-2 --query SecretString --output text | jq 'keys'`.
- [ ] Re-run the api deploy (release re-run or `manual-deploy.yml`). `api.sh`'s
  pre-flight gate guarantees a complete `.env` before touching the running stack.
- [ ] Confirm prod is healthy (caddy + api containers up; site reachable).
```
