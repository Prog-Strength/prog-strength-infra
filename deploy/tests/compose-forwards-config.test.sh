#!/usr/bin/env bash
# Dependency-free check: every key in compose/api/config.env is forwarded into
# some service in compose/api/docker-compose.yml.
#
# Why this exists. config.env holds the NON-SECRET app config that deploy/api.sh
# folds into the host's .env. Writing a key there is only half the wiring — the
# compose file still has to forward it into the container, or the app never sees
# it. Nothing else catches the gap:
#
#   - api.sh's require_env_keys gate validates the .env FILE on the host, not
#     the container's environment, so a missing forward still passes.
#   - Terraform can create the bucket and grant IAM without the app ever
#     receiving the name.
#   - The app degrades quietly by design (503 / in-memory fallback), so the
#     deploy goes green and the feature is simply dead.
#
# That is exactly how PHOTO_BUCKET_NAME shipped: added to config.env and to
# api.sh's required list, never forwarded in docker-compose.yml, so every photo
# endpoint returned 503 photo_storage_unavailable on a successful deploy.
#
# Run: bash deploy/tests/compose-forwards-config.test.sh
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
CONFIG_ENV="${REPO_ROOT}/compose/api/config.env"
COMPOSE_FILE="${REPO_ROOT}/compose/api/docker-compose.yml"

failures=0

for f in "$CONFIG_ENV" "$COMPOSE_FILE"; do
  if [ ! -r "$f" ]; then
    echo "FAIL: cannot read ${f}"
    exit 1
  fi
done

# Keys are the `KEY=` prefixes of non-comment lines. Substitution may carry a
# default (`${KEY:-...}`), so match the opening `${KEY` prefix rather than an
# exact `${KEY}` — and anchor on the brace so KEY can't match a longer name
# that merely starts with it.
while IFS= read -r key; do
  [ -n "$key" ] || continue
  if grep -qF "\${${key}}" "$COMPOSE_FILE" || grep -qF "\${${key}:-" "$COMPOSE_FILE"; then
    echo "ok: ${key} forwarded"
  else
    echo "FAIL: ${key} is in config.env but never forwarded in compose/api/docker-compose.yml"
    failures=$((failures + 1))
  fi
done < <(grep -oE '^[A-Z_][A-Z0-9_]*=' "$CONFIG_ENV" | tr -d '=')

if [ "$failures" -gt 0 ]; then
  echo "${failures} unforwarded config.env key(s)"
  exit 1
fi

echo "All config.env keys are forwarded."
