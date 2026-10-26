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
LEGACY_WATCHER_PID=""
REAL_AGENT_BROWSER="$(command -v agent-browser)"
REAL_NODE="$(command -v node)"
echo "Native version: $("$REAL_AGENT_BROWSER" --version)"

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
  if [ -n "$LEGACY_WATCHER_PID" ]; then
    stop_process "$LEGACY_WATCHER_PID"
  fi
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

# The binding a <session>.target sidecar records: target id and URL. Its `pinned`
# flag is agent-browser's own state, and since 0.39.4 an explicit close clears it.
sidecar_binding() {
  node -e 'const t=JSON.parse(require("fs").readFileSync(process.argv[1],"utf8"));console.log(t.targetId);console.log(t.url)' "$1"
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

daemon_socket() {
  lsof -nP -a -p "$1" -iTCP -sTCP:ESTABLISHED | awk -v port=":$CDP_PORT" 'index($0, "->127.0.0.1" port " ") {print $9}' | sort -u
}

process_live() {
  kill -0 "$1" 2>/dev/null || return 1
  local state
  state="$(ps -o stat= -p "$1" 2>/dev/null)" || return 1
  case "$state" in ''|*Z*) return 1 ;; esac
}

await_daemon_exit() {
  local pid="$1" attempt
  for ((attempt=0; attempt<160; attempt+=1)); do
    process_live "$pid" || break
    sleep 0.1
  done
  process_live "$pid" && fail "native idle left daemon $pid running"
  echo "Observed daemon process exit pid=$pid"
}

mkdir -p "$TEMP_ROOT/bin"
export AB_TEST_REAL_CLI="$REAL_AGENT_BROWSER"
export AB_TEST_CLI_LOG="$TEMP_ROOT/cli.log"
export AB_TEST_FAIL_ATTACH="$TEMP_ROOT/fail-attach"
export AB_TEST_FAILED_PID="$TEMP_ROOT/failed.pid"
export AB_TEST_DELAY="$TEMP_ROOT/delay"
export AB_TEST_CLEANUP="$TEMP_ROOT/cleanup-active"
export AB_TEST_UNEXPECTED="$TEMP_ROOT/unexpected-cli.log"
export AB_TEST_BARRIER="$TEMP_ROOT/admin-barrier"
export AB_TEST_ADMIN_LOG="$TEMP_ROOT/admin.log"
export AB_TEST_REAL_NODE="$REAL_NODE"
: > "$AB_TEST_UNEXPECTED"
cat > "$TEMP_ROOT/bin/node" <<'NODE_SHIM'
#!/bin/bash
set -euo pipefail
if [[ "${1:-}" == */scripts/admin.mjs ]]; then
  printf '%s\n' "$*" >> "$AB_TEST_ADMIN_LOG"
  if [ -f "$AB_TEST_BARRIER" ]; then
    read -r operation pid < "$AB_TEST_BARRIER"
    if [ "${2:-}" = "$operation" ]; then
      rm -f "$AB_TEST_BARRIER"
      for ((attempt=0; attempt<160; attempt+=1)); do
        state="$(ps -o stat= -p "$pid" 2>/dev/null || true)"
        case "$state" in ''|*Z*) break ;; esac
        sleep 0.1
      done
      state="$(ps -o stat= -p "$pid" 2>/dev/null || true)"
      case "$state" in ''|*Z*) ;; *) echo "expiry barrier timed out pid=$pid" >&2; exit 1 ;; esac
      echo "Observed pre-admin expiry pid=$pid operation=$operation" >> "$AB_TEST_ADMIN_LOG"
    fi
  fi
fi
exec "$AB_TEST_REAL_NODE" "$@"
NODE_SHIM
chmod +x "$TEMP_ROOT/bin/node"

cleanup_existing() {
  local status=0
  touch "$AB_TEST_CLEANUP"
  bash "$CLEANUP" "$@" || status=$?
  rm -f "$AB_TEST_CLEANUP"
  return "$status"
}
cat > "$TEMP_ROOT/bin/agent-browser" <<'ADAPTER'
#!/bin/bash
set -euo pipefail
SESSION=""
ARGS=("$@")
for ((i=0; i<${#ARGS[@]}; i+=1)); do
  if [ "${ARGS[$i]}" = --session ]; then SESSION="${ARGS[$((i+1))]}"; fi
done
printf '%s ' "${AGENT_BROWSER_IDLE_TIMEOUT_MS:-unset}" >> "$AB_TEST_CLI_LOG"
printf '%q ' "$@" >> "$AB_TEST_CLI_LOG"
printf '\n' >> "$AB_TEST_CLI_LOG"
HAS_CDP=0
for arg in "$@"; do
  case "$arg" in --cdp|--cdp=*) HAS_CDP=1 ;; esac
done
if { [ "$HAS_CDP" -eq 1 ] && [ -f "$AB_TEST_CLEANUP" ]; } ||
   { [ "$HAS_CDP" -eq 0 ] && [[ " $* " != *' session info '* ]] && [[ " $* " != *' --version '* ]]; }; then
  printf '%s\n' "$*" >> "$AB_TEST_UNEXPECTED"
  echo 'test adapter rejected unexpected CLI browser administration' >&2
  exit 91
fi
if [ -f "$AB_TEST_DELAY" ] && [[ " $* " == *' eval '* ]]; then
  rm -f "$AB_TEST_DELAY"
  sleep 6
fi
if [ -f "$AB_TEST_FAIL_ATTACH" ] && [[ " $* " == *' get url '* ]]; then
  rm -f "$AB_TEST_FAIL_ATTACH"
  "$AB_TEST_REAL_CLI" "$@" >/dev/null
  awk 'NR==1 {print;exit}' "$AGENT_BROWSER_SOCKET_DIR/$SESSION.pid" > "$AB_TEST_FAILED_PID"
  echo 'test adapter discarded attachment reply' >&2
  exit 1
fi
exec "$AB_TEST_REAL_CLI" "$@"
ADAPTER
chmod +x "$TEMP_ROOT/bin/agent-browser"
export PATH="$TEMP_ROOT/bin:$PATH"
export AGENT_BROWSER_IDLE_TIMEOUT_MS=17

INITIAL_INSPECTION="$(inspect_json)"
INITIAL_COUNT="$(printf '%s' "$INITIAL_INSPECTION" | page_count)"

CONNECT_OUTPUT="$(bash "$CONNECT" "initial-label" --persistent --idle-timeout 4 --url "$BASE_URL/base")"
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

"$AB" fill '#batch-input' 'nonempty batch fixture' >/dev/null
assert_eq "$("$AB" get value '#batch-input')" 'nonempty batch fixture'
printf '%s\n' '[["fill","#batch-input",""]]' | "$AB" batch --bail --json > "$TEMP_ROOT/empty-batch.json"
assert_eq "$("$AB" get value '#batch-input')" ''
EMPTY_BATCH_VALUE="$("$AB" eval 'document.querySelector("#batch-input").value' --json)"
printf '%s' "$EMPTY_BATCH_VALUE" | node -e '
let input = "";
process.stdin.on("data", chunk => input += chunk).on("end", () => {
  const reply = JSON.parse(input);
  if (reply.success !== true || reply.data.result !== "") process.exit(1);
});
' || fail "batch did not clear the actual input value"
printf '[]' | "$AB" batch --json > "$TEMP_ROOT/empty-outer-batch.json"
echo 'Observed actual JSON batch input value="" after nonempty text; native empty outer array accepted'
pass "JSON batch clears an actual input with an empty string"


ab_configure_policy "$WRAPPER_ROOT/$SESSION/session.meta"
ab_session_info "$(command -v agent-browser)" "$(command -v node)" "$JSON" "$SESSION"
DAEMON_BEFORE="$AB_SESSION_PID"
CONNECTION_BEFORE="$(daemon_socket "$DAEMON_BEFORE")"
[ -n "$CONNECTION_BEFORE" ] || fail "could not prove the daemon's existing CDP socket"
TASK_CLEANUP="$(cleanup_existing --keep-alive "$SESSION")"
assert_contains "$TASK_CLEANUP" "kept alive"
assert_eq "$(ab_meta_value "$WRAPPER_ROOT/$SESSION/session.meta" persistent)" "1"
assert_eq "$("$AB" get url)" "$BASE_URL/base"
bash "$CONNECT" "follow-up" >/dev/null
ab_session_info "$(command -v agent-browser)" "$(command -v node)" "$JSON" "$SESSION"
assert_eq "$AB_SESSION_PID" "$DAEMON_BEFORE"
CONNECTION_AFTER="$(daemon_socket "$DAEMON_BEFORE")"
echo "Follow-up daemon=$DAEMON_BEFORE socket=$CONNECTION_AFTER"
assert_eq "$CONNECTION_AFTER" "$CONNECTION_BEFORE"
assert_eq "$(inspect_json | page_count)" "$AFTER_CONNECT_COUNT"
pass "task cleanup and follow-up preserve the same daemon and CDP socket"

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

META="$WRAPPER_ROOT/$SESSION/session.meta"
"$AB" wait 6000 >/dev/null
ab_session_info "$(command -v agent-browser)" "$(command -v node)" "$JSON" "$SESSION"
assert_eq "$AB_SESSION_PID" "$DAEMON_BEFORE"
assert_eq "$(daemon_socket "$DAEMON_BEFORE")" "$CONNECTION_BEFORE"
echo "Long command completed daemon=$DAEMON_BEFORE socket=$CONNECTION_BEFORE timeout=4000 duration=6000"
pass "long command completes under a shorter native idle timeout without changing socket"

cp "$META" "$TEMP_ROOT/before-idle.meta"
cp "$SOCKET_DIR/$SESSION.target" "$TEMP_ROOT/before-idle.target"
await_daemon_exit "$DAEMON_BEFORE"
kill -0 "$CHROME_PID" || fail "native idle stopped external Chrome"
[ -x "$AB" ] || fail "native idle removed wrapper"
cmp "$META" "$TEMP_ROOT/before-idle.meta" || fail "native idle changed committed policy"
cmp "$SOCKET_DIR/$SESSION.target" "$TEMP_ROOT/before-idle.target" || fail "native idle changed target sidecar"
printf '%s' "$(inspect_json)" | page_exists "$OWNED_TARGET" || fail "native idle closed owned tab"
assert_eq "$(inspect_json | page_count)" "$AFTER_CONNECT_COUNT"
AGENT_BROWSER_IDLE_TIMEOUT_MS=31 bash "$CONNECT" "resume-after-idle" >/dev/null
assert_eq "$(ab_meta_value "$META" owned_target_id)" "$OWNED_TARGET"
assert_eq "$(inspect_json | page_count)" "$AFTER_CONNECT_COUNT"
assert_eq "$("$AB" get url)" "$BASE_URL/base"
pass "autonomous native exit and resume preserve Chrome, owned tab, sidecar and policy"

ab_session_info "$(command -v agent-browser)" "$(command -v node)" "$JSON" "$SESSION"
PREVIOUS_DAEMON="$AB_SESSION_PID"
AGENT_BROWSER_IDLE_TIMEOUT_MS=1 bash "$CONNECT" "disable-idle" --idle-timeout 0 >/dev/null
ab_configure_policy "$META"
ab_session_info "$(command -v agent-browser)" "$(command -v node)" "$JSON" "$SESSION"
ZERO_DAEMON="$AB_SESSION_PID"
[ "$ZERO_DAEMON" != "$PREVIOUS_DAEMON" ] || fail "timeout change reused old daemon"
process_live "$PREVIOUS_DAEMON" && fail "old timeout daemon still lives"
assert_eq "$(ab_meta_value "$META" owned_target_id)" "$OWNED_TARGET"
assert_eq "$(inspect_json | page_count)" "$AFTER_CONNECT_COUNT"
sleep 5
process_live "$ZERO_DAEMON" || fail "explicit zero did not disable native idle"
AGENT_BROWSER_IDLE_TIMEOUT_MS=1 "$AB" get url >/dev/null
AGENT_BROWSER_IDLE_TIMEOUT_MS=1 bash "$CONNECT" "inherit-disabled-idle" >/dev/null
ab_session_info "$(command -v agent-browser)" "$(command -v node)" "$JSON" "$SESSION"
assert_eq "$AB_SESSION_PID" "$ZERO_DAEMON"
echo "Timeout change stopped pid=$PREVIOUS_DAEMON replacement=$ZERO_DAEMON timeout=0"
pass "transactional timeout replacement and explicit zero override conflicting ambient settings"

for ORIGINAL_ACTIVITY in live inactive; do
  if [ "$ORIGINAL_ACTIVITY" = inactive ]; then
    ab_stop_daemon "$(command -v agent-browser)" "$(command -v node)" "$JSON" "$SESSION" || fail "fixture stop failed"
  fi
  cp "$META" "$TEMP_ROOT/rollback.meta"
  cp "$AB" "$TEMP_ROOT/rollback.ab"
  cp "$SOCKET_DIR/$SESSION.target" "$TEMP_ROOT/rollback.target"
  touch "$AB_TEST_FAIL_ATTACH"
  set +e
  bash "$CONNECT" "failed-timeout-change" --idle-timeout 7 >"$TEMP_ROOT/failed-connect.out" 2>&1
  REPLACEMENT_STATUS=$?
  set -e
  assert_eq "$REPLACEMENT_STATUS" 5
  cmp "$META" "$TEMP_ROOT/rollback.meta" || fail "failed replacement changed policy"
  cmp "$AB" "$TEMP_ROOT/rollback.ab" || fail "failed replacement changed wrapper"
  [ "$(sidecar_binding "$SOCKET_DIR/$SESSION.target")" = "$(sidecar_binding "$TEMP_ROOT/rollback.target")" ] \
    || fail "failed replacement changed binding"
  FAILED_PID="$(< "$AB_TEST_FAILED_PID")"
  ab_is_uint "$FAILED_PID" || fail "adapter did not capture replacement PID"
  process_live "$FAILED_PID" && fail "failed replacement daemon survived rollback"
  echo "Failed $ORIGINAL_ACTIVITY replacement stopped pid=$FAILED_PID"
  ab_session_info "$(command -v agent-browser)" "$(command -v node)" "$JSON" "$SESSION"
  assert_eq "$AB_SESSION_ACTIVE" 0
  printf '%s' "$(inspect_json)" | page_exists "$OWNED_TARGET" || fail "rollback closed owned tab"
  bash "$CONNECT" "resume-after-rollback" >/dev/null
  assert_eq "$(ab_meta_value "$META" idle_timeout_seconds)" 0
  assert_eq "$(inspect_json | page_count)" "$AFTER_CONNECT_COUNT"
done
pass "failed live and inactive timeout replacements stop before restoring prior owner artifacts"

bash "$CONNECT" "maximum-native-timeout" --idle-timeout 2147483647 >/dev/null
ab_configure_policy "$META"
assert_eq "$AGENT_BROWSER_IDLE_TIMEOUT_MS" 2147483647000
ab_session_info "$(command -v agent-browser)" "$(command -v node)" "$JSON" "$SESSION"
MAX_DAEMON="$AB_SESSION_PID"
sleep 5
process_live "$MAX_DAEMON" || fail "maximum native timeout overflowed into immediate expiry"
"$AB" get url >/dev/null
ab_session_info "$(command -v agent-browser)" "$(command -v node)" "$JSON" "$SESSION"
assert_eq "$AB_SESSION_PID" "$MAX_DAEMON"
pass "installed CLI accepts maximum converted timeout without immediate expiry"

bash "$CONNECT" "expiry-interleaving" --idle-timeout 4 >/dev/null
ab_configure_policy "$META"
ab_session_info "$(command -v agent-browser)" "$(command -v node)" "$JSON" "$SESSION"
INTERLEAVING_DAEMON="$AB_SESSION_PID"
"$AB" eval 'localStorage.setItem("nativeIdleMutations", "0")' >/dev/null
touch "$AB_TEST_DELAY"
set +e
"$AB" eval 'localStorage.setItem("nativeIdleMutations", String(Number(localStorage.getItem("nativeIdleMutations")) + 1)); "applied-once"' >"$TEMP_ROOT/interleaving.out" 2>"$TEMP_ROOT/interleaving.err"
INTERLEAVING_STATUS=$?
set -e
echo "Expiration interleaving command status=$INTERLEAVING_STATUS output=$(< "$TEMP_ROOT/interleaving.out")"
assert_eq "$INTERLEAVING_STATUS" 0
process_live "$INTERLEAVING_DAEMON" && fail "adapter did not interleave with autonomous exit"
assert_eq "$("$AB" eval 'localStorage.getItem("nativeIdleMutations")')" '"1"'
assert_eq "$(ab_meta_value "$META" owned_target_id)" "$OWNED_TARGET"
assert_eq "$(inspect_json | page_count)" "$AFTER_CONNECT_COUNT"
assert_eq "$(grep -c 'applied-once' "$AB_TEST_CLI_LOG")" 1
pass "expiry after preflight sends mutation once and resumes only the same target"

bash "$CONNECT" "legacy-fixture" --idle-timeout 0 >/dev/null
ab_configure_policy "$META"
ab_set_meta_value "$META" lease_token "$(ab_hash_value legacy)"
ab_set_meta_value "$META" last_used_at "$(date +%s)"
ab_set_meta_value "$META" idle_timeout_seconds 5
if [ -n "${AB_LEGACY_IDLE_SOURCE:-}" ]; then
  node "$AB_LEGACY_IDLE_SOURCE" "$META" "$(ab_meta_value "$META" lease_token)" >"$TEMP_ROOT/legacy-watcher.log" 2>&1 &
  LEGACY_WATCHER_PID=$!
fi
set +e
"$AB" get url >"$TEMP_ROOT/legacy-call.out" 2>&1
LEGACY_STATUS=$?
set -e
assert_eq "$LEGACY_STATUS" 8
ab_session_info "$(command -v agent-browser)" "$(command -v node)" "$JSON" "$SESSION"
LEGACY_DAEMON="$AB_SESSION_PID"
bash "$CONNECT" "deliberate-native-migration" --no-auto-approve --idle-timeout 0 >/dev/null
process_live "$LEGACY_DAEMON" && fail "migration kept an unconfigured legacy daemon"
assert_eq "$(ab_meta_value "$META" auto_approve)" 0
[ -z "$(ab_meta_value "$META" lease_token)" ] || fail "migration retained old watcher authority"
assert_eq "$(ab_meta_value "$META" owned_target_id)" "$OWNED_TARGET"
assert_eq "$(inspect_json | page_count)" "$AFTER_CONNECT_COUNT"
if [ -n "$LEGACY_WATCHER_PID" ]; then
  await_daemon_exit "$LEGACY_WATCHER_PID"
  wait "$LEGACY_WATCHER_PID" || fail "archived watcher did not exit cleanly"
  LEGACY_WATCHER_PID=""
  pass "archived watcher exits after migrated owner removes its authority"
fi
ab_configure_policy "$META"
pass "explicit legacy migration preserves target and negative consent"

agent-browser --cdp "$BROWSER_WS" --pin-tab --session "$SESSION" tab new "$BASE_URL/drift" >/dev/null
DRIFT_TARGET="$(agent-browser --cdp "$BROWSER_WS" --pin-tab --session "$SESSION" tab list --json | node "$JSON" tab-state | sed -n 's/^active_target=//p')"
[ "$DRIFT_TARGET" != "$OWNED_TARGET" ] || fail "test setup did not drift the binding"
set +e
DRIFT_OUTPUT="$("$AB" get url 2>&1)"
DRIFT_STATUS=$?
set -e
assert_eq "$DRIFT_STATUS" "0"
assert_contains "$DRIFT_OUTPUT" "drifted; restored the owned target before running"
assert_contains "$DRIFT_OUTPUT" "$BASE_URL/base"
ACTIVE_AFTER_RESTORE="$(agent-browser --cdp "$BROWSER_WS" --pin-tab --session "$SESSION" tab list --json | node "$JSON" tab-state | sed -n 's/^active_target=//p')"
assert_eq "$ACTIVE_AFTER_RESTORE" "$OWNED_TARGET"
assert_eq "$("$AB" get url)" "$BASE_URL/base"
pass "real-browser binding drift recovery"

CLEANUP_OUTPUT="$(cleanup_existing "$SESSION" 2>&1)"
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

POPUP_CLEANUP_OUTPUT="$(cleanup_existing --close-tab "$POPUP_SESSION" 2>&1)"
assert_contains "$POPUP_CLEANUP_OUTPUT" "pinned tab closed"
AFTER_POPUP_CLEANUP="$(inspect_json)"
if printf '%s' "$AFTER_POPUP_CLEANUP" | page_exists "$POPUP_OWNED_TARGET"; then
  fail "popup cleanup left the exact owned target open"
fi
printf '%s' "$AFTER_POPUP_CLEANUP" | page_exists "$POPUP_TARGET" || fail "popup cleanup closed an opener-attributed but unowned target"
pass "page-created popup is preserved and does not fail cleanup"

for policy_mode in release close-tab; do
  policy_session="realpolicy${policy_mode//-/}$$"
  bash "$CONNECT" "malformed-policy" --session "$policy_session" --idle-timeout 0 --url "$BASE_URL/base" >/dev/null
  policy_meta="$WRAPPER_ROOT/$policy_session/session.meta"
  policy_target="$(ab_meta_value "$policy_meta" owned_target_id)"
  ab_session_info "$(command -v agent-browser)" "$(command -v node)" "$JSON" "$policy_session"
  policy_pid="$AB_SESSION_PID"
  [ -n "$(daemon_socket "$policy_pid")" ] || fail "policy fixture lacks CDP socket"
  policy_count="$(inspect_json | page_count)"
  ab_set_meta_value "$policy_meta" auto_approve broken
  admin_before="$(wc -l < "$AB_TEST_ADMIN_LOG" | tr -d ' ')"
  policy_status=0
  if [ "$policy_mode" = close-tab ]; then
    cleanup_existing --close-tab "$policy_session" >"$TEMP_ROOT/policy-$policy_mode.out" 2>&1 || policy_status=$?
    assert_eq "$policy_status" 6
  else
    cleanup_existing "$policy_session" >"$TEMP_ROOT/policy-$policy_mode.out" 2>&1 || policy_status=$?
    assert_eq "$policy_status" 0
  fi
  process_live "$policy_pid" && fail "invalid policy prevented daemon release"
  [ ! -e "$WRAPPER_ROOT/$policy_session" ] || fail "released policy artifacts remain"
  inspect_json | page_exists "$policy_target" || fail "invalid policy closed target"
  assert_eq "$(inspect_json | page_count)" "$policy_count"
  tail -n "+$((admin_before + 1))" "$AB_TEST_ADMIN_LOG" > "$TEMP_ROOT/policy-$policy_mode.admin"
  grep -q 'close-daemon' "$TEMP_ROOT/policy-$policy_mode.admin" || fail "policy release lacked existing-only stop"
  if grep -Eq 'clear-task-routes|close-owned-target' "$TEMP_ROOT/policy-$policy_mode.admin"; then
    fail "invalid policy authorized browser operations"
  fi
  echo "Observed malformed-policy mode=$policy_mode old_pid=$policy_pid stopped target=$policy_target preserved status=$policy_status"
done
pass "actual malformed policy releases without browser operations; optional closure is partial"

cat > "$TEMP_ROOT/refuse-launch" <<'REFUSE'
#!/bin/bash
echo attempted >> "$AB_TEST_LAUNCH_LOG"
exit 92
REFUSE
chmod +x "$TEMP_ROOT/refuse-launch"
export AB_TEST_LAUNCH_LOG="$TEMP_ROOT/launch-attempts.log"
unset AGENT_BROWSER_EXECUTABLE_PATH
for expiry_mode in keep-alive close-tab release ambient; do
  expiry_session="realexpiry${expiry_mode//-/}$$"
  bash "$CONNECT" "admin-expiry" --session "$expiry_session" --idle-timeout 4 --url "$BASE_URL/base" >/dev/null
  expiry_meta="$WRAPPER_ROOT/$expiry_session/session.meta"
  expiry_target="$(ab_meta_value "$expiry_meta" owned_target_id)"
  ab_session_info "$(command -v agent-browser)" "$(command -v node)" "$JSON" "$expiry_session"
  expiry_pid="$AB_SESSION_PID"
  expiry_socket="$(daemon_socket "$expiry_pid")"
  [ -n "$expiry_socket" ] || fail "expiry fixture lacks CDP socket"
  expiry_count="$(inspect_json | page_count)"
  cp "$expiry_meta" "$TEMP_ROOT/expiry-$expiry_mode.meta"
  cp "$SOCKET_DIR/$expiry_session.target" "$TEMP_ROOT/expiry-$expiry_mode.target"
  operation=clear-task-routes
  [ "$expiry_mode" != release ] || operation=close-daemon
  printf '%s %s\n' "$operation" "$expiry_pid" > "$AB_TEST_BARRIER"
  if [ "$expiry_mode" = ambient ]; then
    export AGENT_BROWSER_EXECUTABLE_PATH="$TEMP_ROOT/refuse-launch"
  fi
  expiry_status=0
  case "$expiry_mode" in
    keep-alive|ambient) cleanup_existing --keep-alive "$expiry_session" >"$TEMP_ROOT/expiry-$expiry_mode.out" 2>&1 || expiry_status=$? ;;
    close-tab) cleanup_existing --close-tab "$expiry_session" >"$TEMP_ROOT/expiry-$expiry_mode.out" 2>&1 || expiry_status=$? ;;
    release) cleanup_existing "$expiry_session" >"$TEMP_ROOT/expiry-$expiry_mode.out" 2>&1 || expiry_status=$? ;;
  esac
  unset AGENT_BROWSER_EXECUTABLE_PATH
  [ ! -f "$AB_TEST_BARRIER" ] || fail "expiry barrier was not reached"
  grep -q "Observed pre-admin expiry pid=$expiry_pid operation=$operation" "$AB_TEST_ADMIN_LOG" || fail "no observed expiry"
  process_live "$expiry_pid" && fail "expiry process still lives"
  inspect_json | page_exists "$expiry_target" || fail "expiry guessed a target to close"
  assert_eq "$(inspect_json | page_count)" "$expiry_count"
  kill -0 "$CHROME_PID" || fail "cleanup stopped external Chrome"
  ab_session_info "$(command -v agent-browser)" "$(command -v node)" "$JSON" "$expiry_session"
  assert_eq "$AB_SESSION_ACTIVE" 0
  case "$expiry_mode" in
    keep-alive|ambient)
      assert_eq "$expiry_status" 5
      cmp "$expiry_meta" "$TEMP_ROOT/expiry-$expiry_mode.meta" || fail "failed keep-alive changed policy"
      cmp "$SOCKET_DIR/$expiry_session.target" "$TEMP_ROOT/expiry-$expiry_mode.target" || fail "failed keep-alive changed sidecar"
      [ -x "$WRAPPER_ROOT/$expiry_session/ab" ] || fail "failed keep-alive silently released"
      cleanup_existing "$expiry_session" >"$TEMP_ROOT/reconcile-$expiry_mode.out" 2>&1
      ;;
    close-tab) assert_eq "$expiry_status" 6 ;;
    release) assert_eq "$expiry_status" 0 ;;
  esac
  [ ! -e "$WRAPPER_ROOT/$expiry_session" ] || fail "plain release did not reconcile inactivity"
  [ ! -e "$SOCKET_DIR/$expiry_session.target" ] || fail "plain release retained sidecar"
  echo "Observed admin expiry mode=$expiry_mode old_pid=$expiry_pid prior_socket=$expiry_socket status=$expiry_status target=$expiry_target preserved"
done
[ ! -e "$AB_TEST_LAUNCH_LOG" ] || fail "ambient launch executable was invoked"
[ ! -s "$AB_TEST_UNEXPECTED" ] || fail "unexpected CLI browser administration was attempted"
pass "expiry-only and separate ambient controls refuse bootstrap and reconcile plain release"
printf '\nAll disposable real-Chrome containment tests passed.\n'
