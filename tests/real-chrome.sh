#!/usr/bin/env bash
# Gated end-to-end containment tests against a disposable Chrome profile.
set -euo pipefail

if [ "${AB_RUN_REAL_CHROME:-0}" != "1" ]; then
  echo "skip - set AB_RUN_REAL_CHROME=1 to run disposable real-Chrome tests"
  exit 0
fi

SKILL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONNECT="$SKILL_DIR/scripts/connect.sh"
CLEANUP="$SKILL_DIR/scripts/cleanup.sh"
JSON="$SKILL_DIR/scripts/json.mjs"
INSPECT="$SKILL_DIR/tests/real-chrome-inspect.mjs"
SERVER="$SKILL_DIR/tests/real-chrome-server.mjs"
CHROME_BIN="${CHROME_BIN:-/Applications/Google Chrome.app/Contents/MacOS/Google Chrome}"

fail() {
  echo "not ok - $*" >&2
  exit 1
}

pass() {
  echo "ok - $*"
}

assert_eq() {
  [ "$1" = "$2" ] || fail "expected '$2', got '$1'"
}

assert_contains() {
  case "$1" in
    *"$2"*) ;;
    *) fail "expected output to contain '$2'" ;;
  esac
}

for dependency in agent-browser lsof node; do
  command -v "$dependency" >/dev/null 2>&1 || fail "missing dependency: $dependency"
done
[ -x "$CHROME_BIN" ] || fail "Chrome executable not found: $CHROME_BIN"

# Keep this path short: agent-browser's Unix-domain socket has a 103-byte macOS limit.
TEMP_ROOT="$(mktemp -d "/tmp/abcr.XXXXXX")"
PROFILE="$TEMP_ROOT/chrome-profile"
HOME_DIR="$TEMP_ROOT/home"
SOCKET_DIR="$TEMP_ROOT/socket"
WRAPPER_ROOT="$TEMP_ROOT/wrappers"
PORT_FILE="$TEMP_ROOT/server.port"
SERVER_LOG="$TEMP_ROOT/server.log"
CHROME_LOG="$TEMP_ROOT/chrome.log"
SERVER_PID=""
CHROME_PID=""

stop_process() {
  local pid="$1"
  local attempt
  kill "$pid" >/dev/null 2>&1 || true
  for attempt in $(seq 1 50); do
    if ! kill -0 "$pid" 2>/dev/null; then
      wait "$pid" >/dev/null 2>&1 || true
      return 0
    fi
    sleep 0.1
  done
  kill -KILL "$pid" >/dev/null 2>&1 || true
  wait "$pid" >/dev/null 2>&1 || true
}

finish() {
  local status=$?
  local socket_file daemon_pid
  trap - EXIT INT TERM
  set +e
  for socket_file in "$SOCKET_DIR"/*.sock; do
    [ -S "$socket_file" ] || continue
    for daemon_pid in $(lsof -t "$socket_file" 2>/dev/null | sort -u); do
      stop_process "$daemon_pid"
    done
  done
  if [ -n "$CHROME_PID" ]; then
    stop_process "$CHROME_PID"
  fi
  if [ -n "$SERVER_PID" ]; then
    stop_process "$SERVER_PID"
  fi
  if [ "${AB_KEEP_REAL_CHROME_ARTIFACTS:-0}" = "1" ]; then
    echo "Real-Chrome artifacts: $TEMP_ROOT" >&2
  else
    rm -rf "$TEMP_ROOT"
  fi
  exit "$status"
}
trap finish EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

mkdir -p "$PROFILE" "$HOME_DIR" "$SOCKET_DIR" "$WRAPPER_ROOT"
chmod 700 "$TEMP_ROOT" "$PROFILE" "$HOME_DIR" "$SOCKET_DIR" "$WRAPPER_ROOT"

node "$SERVER" "$PORT_FILE" >"$SERVER_LOG" 2>&1 &
SERVER_PID=$!
for _ in $(seq 1 100); do
  [ -s "$PORT_FILE" ] && break
  sleep 0.05
done
[ -s "$PORT_FILE" ] || fail "fixture server did not start"
SERVER_PORT="$(awk 'NR == 1 { print; exit }' "$PORT_FILE")"
BASE_URL="http://127.0.0.1:$SERVER_PORT"

CHROME_ARGS=(
  --user-data-dir="$PROFILE"
  --remote-debugging-address=127.0.0.1
  --remote-debugging-port=0
  --no-first-run
  --no-default-browser-check
  --disable-background-networking
  --disable-component-update
  --disable-default-apps
  --disable-extensions
  --disable-sync
  about:blank
)
if [ "${AB_REAL_CHROME_HEADLESS:-1}" != "0" ]; then
  CHROME_ARGS=(--headless=new "${CHROME_ARGS[@]}")
fi

"$CHROME_BIN" "${CHROME_ARGS[@]}" >"$CHROME_LOG" 2>&1 &
CHROME_PID=$!
ACTIVE_PORT_FILE="$PROFILE/DevToolsActivePort"
for _ in $(seq 1 200); do
  [ -s "$ACTIVE_PORT_FILE" ] && break
  kill -0 "$CHROME_PID" 2>/dev/null || fail "Chrome exited before exposing CDP; see $CHROME_LOG"
  sleep 0.05
done
[ -s "$ACTIVE_PORT_FILE" ] || fail "Chrome did not expose DevToolsActivePort"
CDP_PORT="$(awk 'NR == 1 { print; exit }' "$ACTIVE_PORT_FILE")"
CDP_PATH="$(awk 'NR == 2 { print; exit }' "$ACTIVE_PORT_FILE")"
BROWSER_WS="ws://127.0.0.1:$CDP_PORT$CDP_PATH"

export HOME="$HOME_DIR"
export AGENT_BROWSER_SOCKET_DIR="$SOCKET_DIR"
export AB_CONNECT_ROOT="$WRAPPER_ROOT"
export AB_CHROME_DATA_ROOTS="$PROFILE"
export AB_DEVTOOLS_ACTIVE_PORT_FILE="$ACTIVE_PORT_FILE"
export AB_CDP_PORT="$CDP_PORT"
export AB_CONNECT_ID="real-chrome-containment-$$"
unset PI_SESSION_ID AB_SESSION_ID

# shellcheck source=../scripts/lib.sh
source "$SKILL_DIR/scripts/lib.sh"
OWNER_KEY="$(ab_owner_key "$AB_CONNECT_ID" default "$CDP_PORT")"
SESSION="ab-${OWNER_KEY:0:24}"

inspect_json() {
  node "$INSPECT" "$BROWSER_WS"
}

page_count() {
  node -e 'let s="";process.stdin.on("data",c=>s+=c).on("end",()=>console.log(JSON.parse(s).pages.length))'
}

window_count() {
  node -e 'let s="";process.stdin.on("data",c=>s+=c).on("end",()=>{const p=JSON.parse(s).pages;console.log(new Set(p.map(x=>x.windowId).filter(x=>x!==null)).size)})'
}

page_ids() {
  node -e 'let s="";process.stdin.on("data",c=>s+=c).on("end",()=>{for(const p of JSON.parse(s).pages)console.log(p.targetId)})'
}

page_exists() {
  local target_id="$1"
  node -e 'const id=process.argv[1];let s="";process.stdin.on("data",c=>s+=c).on("end",()=>process.exit(JSON.parse(s).pages.some(p=>p.targetId===id)?0:1))' "$target_id"
}

assert_blocked_without_growth() {
  local wrapper="$1"
  shift
  local before after output status
  before="$(inspect_json | page_count)"
  set +e
  output="$("$wrapper" "$@" 2>&1)"
  status=$?
  set -e
  assert_eq "$status" "2"
  assert_contains "$output" "blocked"
  after="$(inspect_json | page_count)"
  assert_eq "$after" "$before"
}

INITIAL_INSPECTION="$(inspect_json)"
INITIAL_COUNT="$(printf '%s' "$INITIAL_INSPECTION" | page_count)"

CONNECT_OUTPUT="$(bash "$CONNECT" "initial-label" --url "$BASE_URL/base")"
assert_contains "$CONNECT_OUTPUT" "Session:  $SESSION"
AB="$WRAPPER_ROOT/$SESSION/ab"
[ -x "$AB" ] || fail "guarded wrapper was not created"
OWNED_TARGET="$(ab_meta_value "$WRAPPER_ROOT/$SESSION/session.meta" owned_target_id)"
[ -n "$OWNED_TARGET" ] || fail "connect did not record an owned target"
AFTER_CONNECT_COUNT="$(inspect_json | page_count)"
assert_eq "$AFTER_CONNECT_COUNT" "$((INITIAL_COUNT + 1))"

RENAMED_OUTPUT="$(bash "$CONNECT" "renamed-label" --url "$BASE_URL/base")"
assert_contains "$RENAMED_OUTPUT" "Session:  $SESSION"
assert_eq "$(ab_meta_value "$WRAPPER_ROOT/$SESSION/session.meta" owned_target_id)" "$OWNED_TARGET"
assert_eq "$(inspect_json | page_count)" "$AFTER_CONNECT_COUNT"
assert_blocked_without_growth "$AB" tab new "$BASE_URL/forbidden"
assert_blocked_without_growth "$AB" window new
assert_blocked_without_growth "$AB" inspect
assert_blocked_without_growth "$AB" click @e1 --new-tab
assert_blocked_without_growth "$AB" --json tab new "$BASE_URL/forbidden"
assert_blocked_without_growth "$AB" press Meta+t
pass "label churn and guarded target creation"

PIDS=""
for index in $(seq 1 12); do
  ("$AB" get url > "$TEMP_ROOT/command-$index.out" 2>&1) &
  PIDS="$PIDS $!"
done
for pid_to_wait in $PIDS; do
  wait "$pid_to_wait" || fail "a concurrent real-browser command failed"
done
for index in $(seq 1 12); do
  assert_eq "$(cat "$TEMP_ROOT/command-$index.out")" "$BASE_URL/base"
done
assert_eq "$(inspect_json | page_count)" "$AFTER_CONNECT_COUNT"
pass "real-browser command serialization"

agent-browser --session "$SESSION" tab new "$BASE_URL/drift" >/dev/null
DRIFT_TARGET="$(agent-browser --session "$SESSION" tab list --json | node "$JSON" tab-state | awk 'NR == 1 { print; exit }')"
[ "$DRIFT_TARGET" != "$OWNED_TARGET" ] || fail "test setup did not drift the binding"
set +e
DRIFT_OUTPUT="$("$AB" get url 2>&1)"
DRIFT_STATUS=$?
set -e
assert_eq "$DRIFT_STATUS" "0"
assert_contains "$DRIFT_OUTPUT" "drifted; restored the owned target before running"
assert_contains "$DRIFT_OUTPUT" "$BASE_URL/base"
ACTIVE_AFTER_RESTORE="$(agent-browser --session "$SESSION" tab list --json | node "$JSON" tab-state | awk 'NR == 1 { print; exit }')"
assert_eq "$ACTIVE_AFTER_RESTORE" "$OWNED_TARGET"
assert_eq "$("$AB" get url)" "$BASE_URL/base"
pass "real-browser binding drift recovery"

CLEANUP_OUTPUT="$(bash "$CLEANUP" "$SESSION" 2>&1)"
assert_contains "$CLEANUP_OUTPUT" "pinned tab preserved"
AFTER_CLEANUP="$(inspect_json)"
printf '%s' "$AFTER_CLEANUP" | page_exists "$OWNED_TARGET" || fail "cleanup closed the preserved owned target"
printf '%s' "$AFTER_CLEANUP" | page_exists "$DRIFT_TARGET" || fail "cleanup closed an unattributed target"
assert_eq "$(printf '%s' "$AFTER_CLEANUP" | page_count)" "$((INITIAL_COUNT + 2))"
pass "default cleanup preserves all Chrome tabs"

POPUP_SESSION="realpopup$$"
POPUP_BEFORE_CONNECT="$(inspect_json | page_count)"
bash "$CONNECT" "popup" --session "$POPUP_SESSION" --url "$BASE_URL/base" >/dev/null
POPUP_AB="$WRAPPER_ROOT/$POPUP_SESSION/ab"
POPUP_OWNED_TARGET="$(ab_meta_value "$WRAPPER_ROOT/$POPUP_SESSION/session.meta" owned_target_id)"
assert_eq "$(inspect_json | page_count)" "$((POPUP_BEFORE_CONNECT + 1))"
BEFORE_POPUP="$(inspect_json)"
BEFORE_POPUP_COUNT="$(printf '%s' "$BEFORE_POPUP" | page_count)"
BEFORE_POPUP_WINDOWS="$(printf '%s' "$BEFORE_POPUP" | window_count)"
BEFORE_POPUP_IDS="$TEMP_ROOT/before-popup.ids"
AFTER_POPUP_IDS="$TEMP_ROOT/after-popup.ids"
printf '%s' "$BEFORE_POPUP" | page_ids > "$BEFORE_POPUP_IDS"

set +e
POPUP_OUTPUT="$("$POPUP_AB" click "#popup-button" 2>&1)"
POPUP_STATUS=$?
set -e
assert_eq "$POPUP_STATUS" "0"
sleep 0.5
"$POPUP_AB" get url >/dev/null 2>&1
AFTER_POPUP="$(inspect_json)"
AFTER_POPUP_COUNT="$(printf '%s' "$AFTER_POPUP" | page_count)"
[ "$AFTER_POPUP_COUNT" -gt "$BEFORE_POPUP_COUNT" ] || fail "page-created popup did not create a target"
printf '%s' "$AFTER_POPUP" | page_ids > "$AFTER_POPUP_IDS"
POPUP_TARGET="$(comm -13 "$BEFORE_POPUP_IDS" "$AFTER_POPUP_IDS" | head -n 1)"
[ -n "$POPUP_TARGET" ] || fail "could not identify the popup target"
printf '%s' "$AFTER_POPUP" | node -e 'const owner=process.argv[1],popup=process.argv[2];let s="";process.stdin.on("data",c=>s+=c).on("end",()=>{const p=JSON.parse(s).pages.find(x=>x.targetId===popup);process.exit(p?.openerId===owner?0:1)})' "$POPUP_OWNED_TARGET" "$POPUP_TARGET" \
  || fail "raw CDP did not attribute the popup to the owned target"
AFTER_POPUP_WINDOWS="$(printf '%s' "$AFTER_POPUP" | window_count)"
[ "$AFTER_POPUP_WINDOWS" -ge "$BEFORE_POPUP_WINDOWS" ] || fail "popup unexpectedly reduced the Chrome window count"
if grep -q 'unattributed_target_events\|last_observed_target_count' "$WRAPPER_ROOT/$POPUP_SESSION/session.meta"; then
  fail "dispatcher persisted page-count bookkeeping into session metadata"
fi

POPUP_CLEANUP_OUTPUT="$(bash "$CLEANUP" --close-tab "$POPUP_SESSION" 2>&1)"
assert_contains "$POPUP_CLEANUP_OUTPUT" "pinned tab closed"
AFTER_POPUP_CLEANUP="$(inspect_json)"
if printf '%s' "$AFTER_POPUP_CLEANUP" | page_exists "$POPUP_OWNED_TARGET"; then
  fail "popup cleanup left the exact owned target open"
fi
printf '%s' "$AFTER_POPUP_CLEANUP" | page_exists "$POPUP_TARGET" || fail "popup cleanup closed an opener-attributed but unowned target"
pass "page-created popup is preserved and does not fail cleanup"

printf '\nAll disposable real-Chrome containment tests passed.\n'
