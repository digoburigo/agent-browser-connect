#!/usr/bin/env bash
# Allow-list policy tests for scripts/guard.sh.
#
# The guard is a pure function, so these run with no daemon, no session
# directory, no Chrome and no mock: source the module, call it, check the status.
# That is the point of the module having its own interface — the wiring (that
# dispatch.sh actually consults it, and that a rejection costs zero CLI calls) is
# proved separately by the wrapper cases in tests/run.sh.
set -euo pipefail

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname "$TESTS_DIR")"
CASES="${1:-$TESTS_DIR/guard-cases.tsv}"

# shellcheck source=../scripts/guard.sh
. "$REPO_DIR/scripts/guard.sh"

[ -f "$CASES" ] || {
  echo "✗ Case file not found: $CASES" >&2
  exit 1
}

PASSED=0
FAILED=0

while IFS= read -r LINE || [ -n "$LINE" ]; do
  case "$LINE" in
    ''|'#'*) continue ;;
  esac

  IFS=$'\t' read -ra FIELDS <<< "$LINE"
  [ "${#FIELDS[@]}" -ge 2 ] || {
    echo "✗ Malformed case (need an expected status and at least one word): $LINE" >&2
    FAILED=$((FAILED + 1))
    continue
  }

  EXPECTED="${FIELDS[0]}"
  ALLOW_BATCH=1
  case "$EXPECTED" in
    B*)
      ALLOW_BATCH=0
      EXPECTED="${EXPECTED#B}"
      ;;
  esac

  set +e
  OUTPUT="$(ab_guard_command "$ALLOW_BATCH" "${FIELDS[@]:1}" 2>&1)"
  STATUS=$?
  set -e

  if [ "$STATUS" = "$EXPECTED" ]; then
    PASSED=$((PASSED + 1))
    continue
  fi

  FAILED=$((FAILED + 1))
  printf '✗ expected %s, got %s: %s\n' "$EXPECTED" "$STATUS" "${FIELDS[*]:1}" >&2
  [ -z "$OUTPUT" ] || printf '  %s\n' "$(printf '%s' "$OUTPUT" | sed -n '1p')" >&2
done < "$CASES"

# A denial the operator can act on is part of the contract: every forbidden verb
# family and flag in the policy must carry an explanation, or the agent is told
# "no" with nothing to do about it.
while IFS= read -r KEY; do
  [ -n "$KEY" ] || continue
  if ! ab__guard_explain "$KEY" >/dev/null; then
    printf '✗ %s is denied without an explanation in AB_DENY_EXPLAIN\n' "$KEY" >&2
    FAILED=$((FAILED + 1))
  fi
done <<'KEYS'
record
tab
window
bringtofront
inspect
connect
close
plugin
upgrade
keydown
--enable
--input-mode
--proxy
--extension
--init-script
--new-tab
--cdp
--session
KEYS

if [ "$FAILED" -gt 0 ]; then
  printf '\n✗ guard policy: %d passed, %d failed\n' "$PASSED" "$FAILED" >&2
  exit 1
fi
printf '✓ guard policy: %d cases passed\n' "$PASSED"
