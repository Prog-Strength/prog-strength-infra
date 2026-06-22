#!/usr/bin/env bash
# Sourced by deploy scripts (and tests). No top-level execution.
#
# require_env_keys FILE KEY...
#   Asserts every KEY appears in FILE as `KEY=value` with a non-empty value.
#   Prints any missing/empty keys to stderr and returns 1; returns 0 if all
#   present. Values may contain '=' (e.g. base64-padded keys).

require_env_keys() {
  local env_file="$1"; shift
  local key val line found
  local missing=()
  if [ ! -r "$env_file" ]; then
    printf 'Missing or empty required env keys: %s\n' "$*" >&2
    return 1
  fi
  for key in "$@"; do
    found=0
    val=""
    # Literal (non-regex) match on "KEY="; last definition wins, mirroring
    # docker compose .env semantics. Reading line-by-line avoids exposing the
    # key name to grep's regex engine (a '.' in a key would match anything).
    while IFS= read -r line || [ -n "$line" ]; do
      if [ "${line#"${key}="}" != "$line" ]; then
        found=1
        val="${line#"${key}="}"
      fi
    done < "$env_file"
    if [ "$found" -eq 0 ] || [ -z "$val" ]; then
      missing+=("$key")
    fi
  done
  if [ "${#missing[@]}" -gt 0 ]; then
    printf 'Missing or empty required env keys: %s\n' "${missing[*]}" >&2
    return 1
  fi
  return 0
}
