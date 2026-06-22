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
