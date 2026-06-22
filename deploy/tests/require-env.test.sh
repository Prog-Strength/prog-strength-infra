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
