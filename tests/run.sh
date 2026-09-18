#!/usr/bin/env bash
set -euo pipefail

SKILL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONNECT="$SKILL_DIR/scripts/connect.sh"
CLEANUP="$SKILL_DIR/scripts/cleanup.sh"
# shellcheck source=../scripts/lib.sh
. "$SKILL_DIR/scripts/lib.sh"
SUITE_TMP="$(mktemp -d "${TMPDIR:-/tmp}/agent-browser-connect-tests.XXXXXX")"
ORIGINAL_PATH="$PATH"
FAKE_BIN="$SUITE_TMP/bin"
mkdir -p "$FAKE_BIN"

SERVER_PID=""
cleanup_suite() {
  [ -z "$SERVER_PID" ] || kill "$SERVER_PID" >/dev/null 2>&1 || true
  rm -rf "$SUITE_TMP"
}
trap cleanup_suite EXIT INT TERM

# The allow-list policy and the structured lib readers are pure functions tested
# without a daemon; run them first so a regression there fails before any of the
# slow mock cases start.
bash "$SKILL_DIR/tests/guard.sh"
bash "$SKILL_DIR/tests/lib-interfaces.sh"

fail() {
  printf 'not ok - %s\n' "$1" >&2
  exit 1
}

pass() {
  printf 'ok - %s\n' "$1"
}

assert_eq() {
  [ "$1" = "$2" ] || fail "expected '$2', got '$1'"
}

assert_file_contains() {
  grep -Fq -- "$2" "$1" || fail "$1 does not contain: $2"
}

assert_file_not_contains() {
  if grep -Fq -- "$2" "$1"; then
    fail "$1 unexpectedly contains: $2"
  fi
}

assert_text_contains() {
  printf '%s' "$1" | grep -Fq -- "$2" || fail "output does not contain: $2"
}

cat > "$SUITE_TMP/server.mjs" <<'JS'
import { writeFileSync } from "node:fs";
import { createServer } from "node:net";

// Deterministic TCP fixture: accept and hold connections so connect.sh sees an
// open port without any HTTP or WebSocket behavior behind it.
const server = createServer((socket) => socket.on("error", () => {}));
server.listen(0, "127.0.0.1", () => {
  writeFileSync(process.env.PORT_FILE, String(server.address().port));
});
process.on("SIGTERM", () => server.close(() => process.exit(0)));
JS

command -v node >/dev/null 2>&1 || fail "node is required to run the deterministic TCP fixture"
PORT_FILE="$SUITE_TMP/port"
PORT_FILE="$PORT_FILE" node "$SUITE_TMP/server.mjs" >/dev/null 2>&1 &
SERVER_PID=$!
for _ in 1 2 3 4 5 6 7 8 9 10; do
  [ -s "$PORT_FILE" ] && break
  sleep 0.1
done
[ -s "$PORT_FILE" ] || fail "TCP fixture did not start"
PORT="$(cat "$PORT_FILE")"
DEFAULT_OWNER_KEY="$(ab_owner_key "01a06851-da51-7ccc-88df-b491dc5ee587" default "$PORT")"
DEFAULT_SESSION="ab-${DEFAULT_OWNER_KEY:0:24}"

cat > "$FAKE_BIN/agent-browser" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail

printf '%q ' "$@" >> "$MOCK_LOG"
printf '\n' >> "$MOCK_LOG"

mkdir -p "$MOCK_STATE_DIR"
if [ "${MOCK_MODE:-success}" = "stress-concurrency" ]; then
  if mkdir "$MOCK_STATE_DIR/inflight" 2>/dev/null; then
    release_mock_inflight() { rmdir "$MOCK_STATE_DIR/inflight" 2>/dev/null || true; }
    trap release_mock_inflight EXIT INT TERM
  else
    touch "$MOCK_STATE_DIR/overlap-detected"
  fi
  sleep "${MOCK_DELAY_SECONDS:-0.02}"
fi

SESSION=""
CDP=""
ARGS=("$@")
INDEX=0
while [ "$INDEX" -lt "${#ARGS[@]}" ]; do
  case "${ARGS[$INDEX]}" in
    --session)
      INDEX=$((INDEX + 1))
      SESSION="${ARGS[$INDEX]}"
      ;;
    --cdp)
      INDEX=$((INDEX + 1))
      CDP="${ARGS[$INDEX]}"
      ;;
  esac
  INDEX=$((INDEX + 1))
done

set -- "${ARGS[@]}"
while [ "$#" -gt 0 ]; do
  case "$1" in
    --session|--cdp) shift 2 ;;
    --pin-tab|--json) shift ;;
    *) break ;;
  esac
done
ACTION="${1:-}"
[ "$#" -eq 0 ] || shift

mkdir -p "$MOCK_STATE_DIR" "$MOCK_SOCKET_DIR"
ACTIVE_FILE="$MOCK_STATE_DIR/active"
URL_FILE="$MOCK_STATE_DIR/url"
REBOUND_FILE="$MOCK_STATE_DIR/rebound"
TAB_CLOSED_FILE="$MOCK_STATE_DIR/tab-closed"
TARGET_FILE="$MOCK_STATE_DIR/target-id"
DRIFTED_FILE="$MOCK_STATE_DIR/drifted"
RESTORED_FILE="$MOCK_STATE_DIR/restored"
EXTRA_TARGET_FILE="$MOCK_STATE_DIR/extra-target"
# swap-new-tab: the daemon that replaces a version-mismatched one attaches
# fresh, which opens one empty tab while the session's own target survives.
SWAP_FILE="$MOCK_STATE_DIR/swap-tab"
SWAP_BOUND_FILE="$MOCK_STATE_DIR/swap-bound-primary"

ensure_target() {
  [ -f "$TARGET_FILE" ] || printf 'TARGET-PRIMARY\n' > "$TARGET_FILE"
}

write_sidecars() {
  [ -n "$SESSION" ] || return
  printf 'binding\n' > "$MOCK_SOCKET_DIR/$SESSION.target"
  printf 'config\n' > "$MOCK_SOCKET_DIR/$SESSION.config"
}

case "$ACTION" in
  --version|-V|version)
    echo "agent-browser 0.36.0"
    ;;
  session)
    SUBACTION="${1:-}"
    if [ "$SUBACTION" = "info" ]; then
      if [ "${MOCK_MODE:-success}" = "info-fail" ]; then
        echo "session daemon diagnostics failed" >&2
        exit 1
      fi
      if [ -f "$ACTIVE_FILE" ]; then
        PAGE_COUNT=1
        if [ -f "$DRIFTED_FILE" ] || [ -f "$EXTRA_TARGET_FILE" ]; then
          PAGE_COUNT=2
        fi
        [ ! -f "$TAB_CLOSED_FILE" ] || PAGE_COUNT=0
        printf '{"data":{"active":true,"pid":4242,"runtime":{"browserLaunched":true,"pageCount":%s,"session":"%s","socketDir":"%s"},"session":"%s","socketDir":"%s","version":"%s"},"success":true}\n' \
          "$PAGE_COUNT" "$SESSION" "$MOCK_SOCKET_DIR" "$SESSION" "$MOCK_SOCKET_DIR" "${MOCK_DAEMON_VERSION:-0.36.0}"
      else
        printf '{"data":{"active":false,"pid":null,"runtime":null,"session":"%s","socketDir":"%s","version":null},"success":true}\n' "$SESSION" "$MOCK_SOCKET_DIR"
      fi
    else
      echo "unsupported session command" >&2
      exit 2
    fi
    ;;
  get)
    [ "${1:-}" = "url" ] || exit 2
    touch "$ACTIVE_FILE"
    ensure_target
    write_sidecars
    if [ "${MOCK_MODE:-success}" = "attach-fail" ]; then
      echo "WebSocket connection timed out while awaiting approval" >&2
      exit 1
    fi
    if { [ "${MOCK_MODE:-success}" = "tab-gone" ] || [ "${MOCK_MODE:-success}" = "tab-gone-new-fail" ]; } \
      && [ ! -f "$REBOUND_FILE" ]; then
      echo 'Pinned target disappeared (code: tab_gone)' >&2
      exit 1
    fi
    if [ "${MOCK_MODE:-success}" = "empty-url" ]; then
      exit 0
    fi
    if [ "${MOCK_MODE:-success}" = "extra-after" ]; then
      touch "$EXTRA_TARGET_FILE"
    fi
    if [ -f "$SWAP_FILE" ] && [ ! -f "$SWAP_BOUND_FILE" ]; then
      echo "about:blank"
      exit 0
    fi
    if [ -f "$URL_FILE" ]; then
      cat "$URL_FILE"
    else
      echo "about:blank"
    fi
    ;;
  open)
    touch "$ACTIVE_FILE"
    ensure_target
    write_sidecars
    if [ "${MOCK_MODE:-success}" = "navigate-fail" ]; then
      echo "navigation failed" >&2
      exit 1
    fi
    printf '%s\n' "${1:-about:blank}" > "$URL_FILE"
    if [ "${MOCK_MODE:-success}" = "drift-after" ]; then
      touch "$DRIFTED_FILE"
    fi
    echo "opened"
    ;;
  tab)
    case "${1:-}" in
      new)
        if [ "${MOCK_MODE:-success}" = "tab-gone-new-fail" ]; then
          echo "replacement failed" >&2
          exit 1
        fi
        touch "$ACTIVE_FILE" "$REBOUND_FILE"
        rm -f "$TAB_CLOSED_FILE"
        printf 'TARGET-RECOVERED\n' > "$TARGET_FILE"
        write_sidecars
        printf '%s\n' "${2:-about:blank}" > "$URL_FILE"
        echo "created"
        ;;
      list)
        ensure_target
        if [ -f "$TAB_CLOSED_FILE" ]; then
          printf '{"data":{"tabs":[]},"success":true}\n'
        else
          TARGET_ID="$(cat "$TARGET_FILE")"
          TAB_URL="$(cat "$URL_FILE" 2>/dev/null || printf 'about:blank')"
          if [ -f "$SWAP_FILE" ]; then
            if [ -f "$SWAP_BOUND_FILE" ]; then
              printf '{"data":{"tabs":[{"active":true,"label":null,"tabId":"t1","targetId":"%s","title":"Owned","type":"page","url":"%s"},{"active":false,"label":null,"tabId":"t2","targetId":"TARGET-SWAP","title":"New","type":"page","url":"about:blank"}]},"success":true}\n' "$TARGET_ID" "$TAB_URL"
            else
              printf '{"data":{"tabs":[{"active":false,"label":null,"tabId":"t1","targetId":"%s","title":"Owned","type":"page","url":"%s"},{"active":true,"label":null,"tabId":"t2","targetId":"TARGET-SWAP","title":"New","type":"page","url":"about:blank"}]},"success":true}\n' "$TARGET_ID" "$TAB_URL"
            fi
            exit 0
          fi
          if { [ "${MOCK_MODE:-success}" = "drift-before" ] && [ ! -f "$RESTORED_FILE" ]; } || [ -f "$DRIFTED_FILE" ]; then
            printf '{"data":{"tabs":[{"active":false,"label":null,"tabId":"t1","targetId":"%s","title":"Owned","type":"page","url":"%s"},{"active":true,"label":null,"tabId":"t2","targetId":"TARGET-FOREIGN","title":"Foreign","type":"page","url":"about:blank"}]},"success":true}\n' "$TARGET_ID" "$TAB_URL"
          elif [ -f "$EXTRA_TARGET_FILE" ]; then
            printf '{"data":{"tabs":[{"active":true,"label":null,"tabId":"t1","targetId":"%s","title":"Owned","type":"page","url":"%s"},{"active":false,"label":null,"tabId":"t2","targetId":"TARGET-FOREIGN","title":"Foreign","type":"page","url":"about:blank"}]},"success":true}\n' "$TARGET_ID" "$TAB_URL"
          else
            printf '{"data":{"tabs":[{"active":true,"label":null,"tabId":"t1","targetId":"%s","title":"Test","type":"page","url":"%s"}]},"success":true}\n' "$TARGET_ID" "$TAB_URL"
          fi
        fi
        ;;
      close)
        [ -f "$ACTIVE_FILE" ] || exit 1
        if [ "${2:-}" = "TARGET-SWAP" ] && [ -f "$SWAP_FILE" ]; then
          rm -f "$SWAP_FILE" "$SWAP_BOUND_FILE"
          echo "closed"
          exit 0
        fi
        touch "$TAB_CLOSED_FILE"
        echo "closed"
        ;;
      TARGET-*)
        if [ -f "$SWAP_FILE" ] && [ "$1" = "$(cat "$TARGET_FILE" 2>/dev/null || true)" ]; then
          touch "$SWAP_BOUND_FILE"
          echo '{"data":{"switched":true},"success":true}'
          exit 0
        fi
        [ "$1" = "$(cat "$TARGET_FILE" 2>/dev/null || true)" ] || exit 1
        rm -f "$DRIFTED_FILE"
        touch "$RESTORED_FILE"
        echo '{"data":{"switched":true},"success":true}'
        ;;
      *) exit 2 ;;
    esac
    ;;
  batch)
    touch "$ACTIVE_FILE"
    ensure_target
    # Record whatever arrived on stdin. Argument-mode batch now re-encodes the
    # guarded words to the JSON stdin form, so the test can assert that what the
    # guard checked is what the CLI was handed.
    [ -t 0 ] || cat > "$MOCK_STATE_DIR/batch-stdin" 2>/dev/null || true
    echo "batched"
    ;;
  network)
    [ "${1:-}" = "unroute" ] || exit 2
    [ -f "$ACTIVE_FILE" ] || exit 1
    echo "unrouted"
    ;;
  close)
    if [ "${MOCK_MODE:-success}" = "close-fail" ]; then
      echo "daemon refused to stop" >&2
      exit 1
    fi
    [ "${MOCK_MODE:-success}" != "swap-new-tab" ] || touch "$SWAP_FILE"
    rm -f "$ACTIVE_FILE"
    echo "closed"
    ;;
  *)
    echo "unsupported mock command: $ACTION" >&2
    exit 2
    ;;
esac
MOCK
chmod +x "$FAKE_BIN/agent-browser"

cat > "$FAKE_BIN/lsof" <<'MOCK'
#!/usr/bin/env bash
if [ "${MOCK_LSOF_LIVE:-0}" = "1" ]; then
  printf 'agent-bro 4242 user 10u IPv4 TCP 127.0.0.1:54000->127.0.0.1:%s (ESTABLISHED)\n' "$MOCK_PORT"
  exit 0
fi
exit 1
MOCK
chmod +x "$FAKE_BIN/lsof"

new_case() {
  CASE_DIR="$SUITE_TMP/$1"
  CASE_STATE="$CASE_DIR/state"
  CASE_SOCKET="$CASE_DIR/socket"
  CASE_ROOT="$CASE_DIR/wrappers"
  CASE_CHROME="$CASE_DIR/chrome"
  CASE_LOG="$CASE_DIR/commands.log"
  mkdir -p "$CASE_STATE" "$CASE_SOCKET" "$CASE_ROOT" "$CASE_CHROME" "$CASE_DIR/home"
  : > "$CASE_LOG"
}

run_connect() {
  local mode="$1"
  shift
  env -u AB_CDP_WS_URL -u AB_DEVTOOLS_ACTIVE_PORT_FILE -u AB_SESSION_ID -u AB_CONNECT_ID -u CLAUDE_CODE_SESSION_ID \
    PATH="$FAKE_BIN:$ORIGINAL_PATH" \
    HOME="$CASE_DIR/home" \
    AB_CONNECT_ROOT="$CASE_ROOT" \
    AB_CHROME_DATA_ROOTS="$CASE_CHROME" \
    AB_CDP_PORT="$PORT" \
    AB_CONNECT_PORT_ATTEMPTS=0 \
    PI_SESSION_ID="01a06851-da51-7ccc-88df-b491dc5ee587" \
    MOCK_LOG="$CASE_LOG" \
    MOCK_MODE="$mode" \
    MOCK_STATE_DIR="$CASE_STATE" \
    MOCK_SOCKET_DIR="$CASE_SOCKET" \
    MOCK_DAEMON_VERSION="${MOCK_DAEMON_VERSION:-}" \
    bash "$CONNECT" "$@"
}

run_cleanup() {
  local live="$1"
  local session="$2"
  local mode="${3:-success}"
  local close_tab="${4:-0}"
  local cleanup_args=("$session")
  [ "$close_tab" -eq 0 ] || cleanup_args=(--close-tab "$session")
  env -u AB_CDP_WS_URL -u AB_DEVTOOLS_ACTIVE_PORT_FILE \
    PATH="$FAKE_BIN:$ORIGINAL_PATH" \
    HOME="$CASE_DIR/home" \
    AB_CONNECT_ROOT="$CASE_ROOT" \
    AB_CDP_PORT="$PORT" \
    MOCK_LOG="$CASE_LOG" \
    MOCK_MODE="$mode" \
    MOCK_STATE_DIR="$CASE_STATE" \
    MOCK_SOCKET_DIR="$CASE_SOCKET" \
    MOCK_LSOF_LIVE="$live" \
    MOCK_PORT="$PORT" \
    MOCK_DAEMON_VERSION="${MOCK_DAEMON_VERSION:-}" \
    bash "$CLEANUP" "${cleanup_args[@]}"
}

run_wrapper() {
  local mode="$1"
  local wrapper="$2"
  shift 2
  PATH="$FAKE_BIN:$ORIGINAL_PATH" \
    HOME="$CASE_DIR/home" \
    MOCK_LOG="$CASE_LOG" \
    MOCK_MODE="$mode" \
    MOCK_STATE_DIR="$CASE_STATE" \
    MOCK_SOCKET_DIR="$CASE_SOCKET" \
    MOCK_DAEMON_VERSION="${MOCK_DAEMON_VERSION:-}" \
    "$wrapper" "$@"
}

# Like assert_wrapper_rejected, but for a denial that is not exit 2: a verb the
# allow-list simply does not know exits 10 so the agent can tell "this is
# forbidden" apart from "this is not listed yet".
assert_wrapper_status() {
  local wrapper="$1"
  local expected="$2"
  shift 2
  local calls_before calls_after output status
  calls_before="$(wc -l < "$CASE_LOG" | tr -d ' ')"
  set +e
  output="$(run_wrapper success "$wrapper" "$@" 2>&1)"
  status=$?
  set -e
  assert_eq "$status" "$expected"
  calls_after="$(wc -l < "$CASE_LOG" | tr -d ' ')"
  assert_eq "$calls_after" "$calls_before"
  printf '%s' "$output"
}

assert_wrapper_rejected() {
  local wrapper="$1"
  shift
  local calls_before calls_after output status
  calls_before="$(wc -l < "$CASE_LOG" | tr -d ' ')"
  set +e
  output="$(run_wrapper success "$wrapper" "$@" 2>&1)"
  status=$?
  set -e
  assert_eq "$status" "2"
  assert_text_contains "$output" "blocked"
  calls_after="$(wc -l < "$CASE_LOG" | tr -d ' ')"
  assert_eq "$calls_after" "$calls_before"
}

# Exact endpoint selection, one initial attach, and stable owner identity across labels.
new_case exact
mkdir -p "$CASE_CHROME/Default"
printf '12345\n/devtools/browser/stale\n' > "$CASE_CHROME/DevToolsActivePort"
printf '%s\n/devtools/browser/exact-uuid\n' "$PORT" > "$CASE_CHROME/Default/DevToolsActivePort"
OUTPUT="$(run_connect success "Geo 360" --url http://example.test)"
SESSION="$DEFAULT_SESSION"
AB="$CASE_ROOT/$SESSION/ab"
[ -x "$AB" ] || fail "wrapper was not created"
assert_eq "$(LC_ALL=C ls -ld "$CASE_ROOT" | cut -c1-10)" "drwx------"
assert_eq "$(LC_ALL=C ls -ld "$CASE_ROOT/$SESSION" | cut -c1-10)" "drwx------"
assert_eq "$(LC_ALL=C ls -l "$AB" | cut -c1-10)" "-rwx------"
assert_eq "$(LC_ALL=C ls -l "$CASE_ROOT/$SESSION/session.meta" | cut -c1-10)" "-rw-------"
assert_file_contains "$AB" "dispatch.sh"
assert_file_contains "$CASE_ROOT/$SESSION/session.meta" "cdp_url=ws://127.0.0.1:$PORT/devtools/browser/exact-uuid"
assert_file_contains "$CASE_ROOT/$SESSION/session.meta" "owned_target_id=TARGET-PRIMARY"
assert_file_not_contains "$AB" "--cdp $PORT"
assert_text_contains "$OUTPUT" "Session:  $SESSION"
CDP_CALLS="$(grep -c -- '--cdp' "$CASE_LOG" || true)"
assert_eq "$CDP_CALLS" "4"
SECOND_OUTPUT="$(run_connect success "Renamed task label")"
assert_text_contains "$SECOND_OUTPUT" "Session:  $SESSION"
[ -x "$AB" ] || fail "stable wrapper path changed"
WRAPPED_OUTPUT="$(run_wrapper success "$AB" get url)"
assert_eq "$WRAPPED_OUTPUT" "http://example.test"
assert_wrapper_rejected "$AB" tab new http://forbidden.test
assert_wrapper_rejected "$AB" tab TARGET-FOREIGN
assert_wrapper_rejected "$AB" window new
assert_wrapper_rejected "$AB" bringtofront
assert_wrapper_rejected "$AB" batch 'get url' 'bringtofront'
assert_wrapper_rejected "$AB" inspect
assert_wrapper_rejected "$AB" record start /tmp/demo.webm
assert_wrapper_rejected "$AB" record restart /tmp/demo.webm http://example.test
assert_wrapper_rejected "$AB" batch 'get url' 'record start /tmp/demo.webm'
assert_wrapper_rejected "$AB" click @e1 --new-tab
assert_wrapper_rejected "$AB" click @e1 --new-tab=true
assert_wrapper_rejected "$AB" batch 'tab new http://forbidden.test'
assert_wrapper_rejected "$AB" batch "t'ab' new http://forbidden.test"
assert_wrapper_rejected "$AB" get url --session foreign
assert_wrapper_rejected "$AB" --enable react-devtools open http://example.test
assert_wrapper_rejected "$AB" open http://example.test --enable=react-devtools
assert_wrapper_rejected "$AB" --input-mode human click @e1
assert_wrapper_rejected "$AB" batch 'get url' 'open http://example.test --enable react-devtools' 
assert_wrapper_rejected "$AB" --json tab new http://forbidden.test
assert_wrapper_rejected "$AB" tab list new http://forbidden.test
assert_wrapper_rejected "$AB" press Meta+t
assert_wrapper_rejected "$AB" press Control+w
assert_wrapper_rejected "$AB" press --json Meta+t
assert_wrapper_rejected "$AB" plugin add npm:whatever
assert_wrapper_rejected "$AB" upgrade
assert_wrapper_rejected "$AB" stream enable --port 9999
assert_wrapper_rejected "$AB" removeinitscript 3
assert_wrapper_rejected "$AB" open http://example.test --proxy http://evil.test
assert_wrapper_rejected "$AB" open http://example.test --extension /tmp/ext
assert_wrapper_rejected "$AB" keydown Meta
assert_wrapper_rejected "$AB" batch '' 'get url'
UNKNOWN_OUTPUT="$(assert_wrapper_status "$AB" 10 totallynewverb)"
assert_text_contains "$UNKNOWN_OUTPUT" "not in this wrapper allow-list"
assert_text_contains "$UNKNOWN_OUTPUT" "Report to the user"
UNKNOWN_OUTPUT="$(assert_wrapper_status "$AB" 10 snapshot --brand-new-flag)"
assert_text_contains "$UNKNOWN_OUTPUT" "not in this wrapper allow-list"
BATCH_OUTPUT="$(run_wrapper success "$AB" batch 'get url' 'snapshot -i')"
assert_eq "$BATCH_OUTPUT" "batched"
# C4: the words the guard checked are the words the CLI runs. Argument mode now
# re-encodes to the JSON stdin form instead of handing back the original string
# for a second, differently-behaved parser to split.
assert_file_contains "$CASE_STATE/batch-stdin" '[["get","url"],["snapshot","-i"]]'
assert_file_not_contains "$CASE_LOG" "snapshot\\ -i"
# A tab inside an argument stays one word end to end. json.mjs does not split on
# it, so a downstream whitespace splitter must never get the chance to.
rm -f "$CASE_STATE/batch-stdin"
BATCH_OUTPUT="$(run_wrapper success "$AB" batch "$(printf 'fill @e1 hello\tworld')")"
assert_eq "$BATCH_OUTPUT" "batched"
assert_file_contains "$CASE_STATE/batch-stdin" '[["fill","@e1","hello\tworld"]]'
# --bail stays a CLI flag; it is not smuggled into the command array.
rm -f "$CASE_STATE/batch-stdin"
BATCH_OUTPUT="$(run_wrapper success "$AB" batch --bail 'get url')"
assert_eq "$BATCH_OUTPUT" "batched"
assert_file_contains "$CASE_STATE/batch-stdin" '[["get","url"]]'
assert_file_contains "$CASE_LOG" "--bail"
BATCH_OUTPUT="$(printf '[["snapshot","-i"],["fill","@e2","hello world"]]' | run_wrapper success "$AB" batch)"
assert_eq "$BATCH_OUTPUT" "batched"
CALLS_BEFORE_STDIN_REJECT="$(wc -l < "$CASE_LOG" | tr -d ' ')"
set +e
BATCH_OUTPUT="$(printf '[["snapshot","-i"],["tab","new","http://forbidden.test"]]' | run_wrapper success "$AB" batch 2>&1)"
STATUS=$?
set -e
assert_eq "$STATUS" "2"
assert_text_contains "$BATCH_OUTPUT" "blocked"
assert_eq "$(wc -l < "$CASE_LOG" | tr -d ' ')" "$CALLS_BEFORE_STDIN_REJECT"
CALLS_BEFORE_OUTDATED="$(wc -l < "$CASE_LOG" | tr -d ' ')"
ab_set_meta_value "$CASE_ROOT/$SESSION/session.meta" version 2
set +e
OUTDATED_OUTPUT="$(run_wrapper success "$AB" get url 2>&1)"
OUTDATED_STATUS=$?
set -e
assert_eq "$OUTDATED_STATUS" "5"
assert_text_contains "$OUTDATED_OUTPUT" "metadata is outdated"
assert_eq "$(wc -l < "$CASE_LOG" | tr -d ' ')" "$CALLS_BEFORE_OUTDATED"
ab_set_meta_value "$CASE_ROOT/$SESSION/session.meta" version 4
pass "exact endpoint, stable session reuse, and guarded dispatch"

# Explicit slots create intentional, stable secondary identities.
new_case slot
printf '%s\n/devtools/browser/slot-uuid\n' "$PORT" > "$CASE_CHROME/DevToolsActivePort"
OUTPUT="$(run_connect success "Secondary view" --slot preview)"
SLOT_OWNER_KEY="$(ab_owner_key "01a06851-da51-7ccc-88df-b491dc5ee587" preview "$PORT")"
SLOT_SESSION="ab-${SLOT_OWNER_KEY:0:24}"
assert_text_contains "$OUTPUT" "Session:  $SLOT_SESSION"
[ "$SLOT_SESSION" != "$DEFAULT_SESSION" ] || fail "explicit slot reused the default identity"
assert_file_contains "$CASE_ROOT/$SLOT_SESSION/session.meta" "slot=preview"
pass "intentional slot identity"

# Missing owner identity fails rather than allocating another random session.
new_case missing-owner
printf '%s\n/devtools/browser/no-owner-uuid\n' "$PORT" > "$CASE_CHROME/DevToolsActivePort"
set +e
OUTPUT="$(env -u AB_SESSION_ID -u AB_CONNECT_ID -u PI_SESSION_ID -u CLAUDE_CODE_SESSION_ID \
  PATH="$FAKE_BIN:$ORIGINAL_PATH" HOME="$CASE_DIR/home" AB_CONNECT_ROOT="$CASE_ROOT" \
  AB_CHROME_DATA_ROOTS="$CASE_CHROME" AB_CDP_PORT="$PORT" AB_CONNECT_PORT_ATTEMPTS=0 \
  MOCK_LOG="$CASE_LOG" MOCK_MODE=success MOCK_STATE_DIR="$CASE_STATE" MOCK_SOCKET_DIR="$CASE_SOCKET" \
  bash "$CONNECT" "No owner" 2>&1)"
STATUS=$?
set -e
assert_eq "$STATUS" "2"
for SOURCE in AB_CONNECT_ID PI_SESSION_ID CLAUDE_CODE_SESSION_ID --session; do
  assert_text_contains "$OUTPUT" "$SOURCE"
done
[ "$(wc -l < "$CASE_LOG" | tr -d ' ')" = "0" ] || fail "missing identity reached agent-browser"
pass "stable owner identity required"

# Claude Code exports its own session id; it must yield the same owner as pi would.
new_case claude-identity
printf '%s\n/devtools/browser/claude-uuid\n' "$PORT" > "$CASE_CHROME/DevToolsActivePort"
OUTPUT="$(env -u AB_SESSION_ID -u AB_CONNECT_ID -u PI_SESSION_ID \
  PATH="$FAKE_BIN:$ORIGINAL_PATH" HOME="$CASE_DIR/home" AB_CONNECT_ROOT="$CASE_ROOT" \
  AB_CHROME_DATA_ROOTS="$CASE_CHROME" AB_CDP_PORT="$PORT" AB_CONNECT_PORT_ATTEMPTS=0 \
  CLAUDE_CODE_SESSION_ID="01a06851-da51-7ccc-88df-b491dc5ee587" \
  MOCK_LOG="$CASE_LOG" MOCK_MODE=success MOCK_STATE_DIR="$CASE_STATE" MOCK_SOCKET_DIR="$CASE_SOCKET" \
  bash "$CONNECT" "Claude Code")"
assert_text_contains "$OUTPUT" "Session:  $DEFAULT_SESSION"
assert_text_contains "$OUTPUT" "bash $CASE_ROOT/$DEFAULT_SESSION/ab snapshot -i"
pass "Claude Code session identity"

# The dispatcher restores a drifted binding before allowing another command.
new_case drift-before
printf '%s\n/devtools/browser/drift-before-uuid\n' "$PORT" > "$CASE_CHROME/DevToolsActivePort"
run_connect success drift --session driftbefore >/dev/null
AB="$CASE_ROOT/driftbefore/ab"
: > "$CASE_LOG"
set +e
OUTPUT="$(run_wrapper drift-before "$AB" get url 2>&1)"
STATUS=$?
set -e
assert_eq "$STATUS" "0"
assert_text_contains "$OUTPUT" "drifted; restored the owned target before running"
assert_text_contains "$OUTPUT" "about:blank"
RESTORE_LINE="$(grep -n -- 'tab TARGET-PRIMARY' "$CASE_LOG" | head -n 1 | cut -d: -f1)"
COMMAND_LINE="$(grep -n -- 'get url' "$CASE_LOG" | head -n 1 | cut -d: -f1)"
[ -n "$RESTORE_LINE" ] || fail "dispatcher did not restore the drifted binding"
[ -n "$COMMAND_LINE" ] || fail "dispatcher did not run the command after restoring"
[ "$RESTORE_LINE" -lt "$COMMAND_LINE" ] || fail "dispatcher ran the command before correcting drift"
assert_text_contains "$OUTPUT" "brought the tab to the front"
assert_file_contains "$CASE_ROOT/driftbefore/events.log" "drift-restored phase=pre"
assert_file_contains "$CASE_ROOT/driftbefore/events.log" "attach mode=fresh"
pass "pre-command binding drift correction proceeds"

# Re-running connect while the binding has drifted must switch back to the
# owned target, never adopt (and navigate) the tab that is active instead.
new_case reconnect-drifted
printf '%s\n/devtools/browser/reconnect-drifted-uuid\n' "$PORT" > "$CASE_CHROME/DevToolsActivePort"
run_connect success first --session redrift >/dev/null
assert_file_contains "$CASE_ROOT/redrift/session.meta" "owned_target_id=TARGET-PRIMARY"
: > "$CASE_LOG"
OUTPUT="$(run_connect drift-before second --session redrift --url http://second.test 2>&1)"
assert_text_contains "$OUTPUT" "drifted to another tab; switched back to the owned target"
assert_text_contains "$OUTPUT" "Own tab:  http://second.test"
assert_file_contains "$CASE_ROOT/redrift/session.meta" "owned_target_id=TARGET-PRIMARY"
assert_file_not_contains "$CASE_ROOT/redrift/session.meta" "TARGET-FOREIGN"
REBIND_LINE="$(grep -n -- 'tab TARGET-PRIMARY' "$CASE_LOG" | head -n 1 | cut -d: -f1)"
NAVIGATE_LINE="$(grep -n -- 'open http://second.test' "$CASE_LOG" | head -n 1 | cut -d: -f1)"
[ -n "$REBIND_LINE" ] || fail "reconnect did not switch back to the owned target"
[ -n "$NAVIGATE_LINE" ] || fail "reconnect did not navigate after rebinding"
[ "$REBIND_LINE" -lt "$NAVIGATE_LINE" ] || fail "reconnect navigated before switching back to the owned target"
assert_file_contains "$CASE_ROOT/redrift/events.log" "drift-restored phase=connect"
assert_file_contains "$CASE_ROOT/redrift/events.log" "navigate url=http://second.test"
pass "reconnect while drifted rebinds to the owned target"

# A command that changes the active binding is detected and restored afterward.
new_case drift-after
printf '%s\n/devtools/browser/drift-after-uuid\n' "$PORT" > "$CASE_CHROME/DevToolsActivePort"
run_connect success drift --session driftafter >/dev/null
AB="$CASE_ROOT/driftafter/ab"
: > "$CASE_LOG"
set +e
OUTPUT="$(run_wrapper drift-after "$AB" open http://drifted.test 2>&1)"
STATUS=$?
set -e
assert_eq "$STATUS" "9"
assert_text_contains "$OUTPUT" "changed the browser binding unexpectedly"
assert_file_contains "$CASE_LOG" "open http://drifted.test"
assert_file_contains "$CASE_LOG" "tab TARGET-PRIMARY"
pass "post-command binding drift correction"

# Missing standard endpoint falls back to one direct generic WebSocket URL.
new_case fallback
OUTPUT="$(run_connect success fallback)"
SESSION="$DEFAULT_SESSION"
assert_file_contains "$CASE_ROOT/$SESSION/session.meta" "cdp_url=ws://127.0.0.1:$PORT/devtools/browser"
assert_file_not_contains "$CASE_ROOT/$SESSION/ab" "--cdp $PORT"
pass "generic direct endpoint fallback"

# Argument parsing rejects missing values and dangerous session names.
new_case parsing
set +e
OUTPUT="$(run_connect success parsing --url 2>&1)"
STATUS=$?
set -e
assert_eq "$STATUS" "2"
assert_text_contains "$OUTPUT" "--url requires a value"
set +e
OUTPUT="$(run_connect success parsing --session '../../danger' 2>&1)"
STATUS=$?
set -e
assert_eq "$STATUS" "2"
assert_text_contains "$OUTPUT" "invalid session"
set +e
OUTPUT="$(run_connect success parsing --session '-danger' 2>&1)"
STATUS=$?
set -e
assert_eq "$STATUS" "2"
assert_text_contains "$OUTPUT" "invalid session"
set +e
OUTPUT="$(run_connect success parsing --port 70000 2>&1)"
STATUS=$?
set -e
assert_eq "$STATUS" "2"
assert_text_contains "$OUTPUT" "invalid CDP port"
set +e
OUTPUT="$(run_connect success parsing --url '--help' 2>&1)"
STATUS=$?
set -e
assert_eq "$STATUS" "2"
assert_text_contains "$OUTPUT" "URL values may not begin"
pass "strict argument, port, URL, and session validation"

# A pre-planted symlink cannot redirect wrapper writes into another directory.
new_case symlink
printf '%s\n/devtools/browser/symlink-uuid\n' "$PORT" > "$CASE_CHROME/DevToolsActivePort"
VICTIM="$CASE_DIR/victim"
mkdir "$VICTIM"
ln -s "$VICTIM" "$CASE_ROOT/unsafe"
set +e
OUTPUT="$(run_connect success unsafe --session unsafe 2>&1)"
STATUS=$?
set -e
assert_eq "$STATUS" "5"
assert_text_contains "$OUTPUT" "wrapper path is unsafe"
[ ! -e "$VICTIM/ab" ] || fail "symlink attack redirected the wrapper write"
pass "private-directory symlink defense"

# Session introspection failure stops before any browser connection is opened.
new_case info-fail
printf '%s\n/devtools/browser/info-fail-uuid\n' "$PORT" > "$CASE_CHROME/DevToolsActivePort"
set +e
OUTPUT="$(run_connect info-fail diagnostics --session diagnostics 2>&1)"
STATUS=$?
set -e
assert_eq "$STATUS" "5"
assert_text_contains "$OUTPUT" "no browser connection was attempted"
assert_file_not_contains "$CASE_LOG" "--cdp"
[ ! -e "$CASE_ROOT/diagnostics" ] || fail "diagnostic failure leaked its wrapper directory"
pass "structured session diagnostic failure"

# Failed approval makes one CDP command, performs no blind retry, and rolls back.
new_case attach-fail
printf '%s\n/devtools/browser/fail-uuid\n' "$PORT" > "$CASE_CHROME/DevToolsActivePort"
set +e
OUTPUT="$(run_connect attach-fail failing --session failcase 2>&1)"
STATUS=$?
set -e
assert_eq "$STATUS" "5"
assert_text_contains "$OUTPUT" "single CDP connection did not complete"
CDP_CALLS="$(grep -c -- '--cdp' "$CASE_LOG" || true)"
assert_eq "$CDP_CALLS" "1"
CLOSE_LINE="$(grep 'close ' "$CASE_LOG" | tail -n 1)"
if printf '%s' "$CLOSE_LINE" | grep -Fq -- '--cdp'; then
  fail "rollback close attempted a new CDP connection"
fi
[ ! -e "$CASE_ROOT/failcase" ] || fail "failed wrapper directory leaked"
[ ! -e "$CASE_SOCKET/failcase.target" ] || fail "failed target binding leaked"
[ ! -e "$CASE_SOCKET/failcase.config" ] || fail "failed config sidecar leaked"
pass "single-attempt failure and transactional rollback"

# Failure after an established attach closes the newly owned tab before rollback.
new_case empty-url
printf '%s\n/devtools/browser/empty-uuid\n' "$PORT" > "$CASE_CHROME/DevToolsActivePort"
set +e
OUTPUT="$(run_connect empty-url empty --session emptycase 2>&1)"
STATUS=$?
set -e
assert_eq "$STATUS" "5"
assert_text_contains "$OUTPUT" "returned no bound-tab URL"
assert_file_contains "$CASE_LOG" "tab close"
assert_file_not_contains "$CASE_LOG" "--cdp ws://127.0.0.1:$PORT/devtools/browser/empty-uuid --pin-tab --session emptycase tab close"
[ ! -e "$CASE_ROOT/emptycase" ] || fail "post-attach rollback leaked its wrapper"
pass "post-attach tab rollback"

# A stale pinned binding is recovered with tab new on the established connection.
new_case tab-gone
printf '%s\n/devtools/browser/tab-gone-uuid\n' "$PORT" > "$CASE_CHROME/DevToolsActivePort"
printf 'old binding\n' > "$CASE_SOCKET/recovercase.target"
OUTPUT="$(run_connect tab-gone recover --session recovercase --url http://recovered.test)"
assert_text_contains "$OUTPUT" "Own tab:  http://recovered.test"
TAB_NEW_CALLS="$(grep -c -- 'tab new' "$CASE_LOG" || true)"
assert_eq "$TAB_NEW_CALLS" "1"
pass "explicit tab_gone recovery"

# Failed tab_gone replacement never guesses a Chrome target during rollback.
new_case tab-gone-new-fail
printf '%s\n/devtools/browser/tab-gone-fail-uuid\n' "$PORT" > "$CASE_CHROME/DevToolsActivePort"
printf 'old binding\n' > "$CASE_SOCKET/recoverfail.target"
set +e
OUTPUT="$(run_connect tab-gone-new-fail recover --session recoverfail --url http://recovered.test 2>&1)"
STATUS=$?
set -e
assert_eq "$STATUS" "5"
assert_text_contains "$OUTPUT" "could not replace the closed pinned tab"
if grep -Fq -- 'tab close' "$CASE_LOG"; then
  fail "failed tab_gone replacement guessed a target during rollback"
fi
pass "failed tab_gone rollback preserves every target"

# A failed reconnect never closes a session that was already active beforehand.
new_case preserve-active
touch "$CASE_STATE/active"
printf 'binding\n' > "$CASE_SOCKET/existing.target"
printf '%s\n/devtools/browser/existing-uuid\n' "$PORT" > "$CASE_CHROME/DevToolsActivePort"
set +e
OUTPUT="$(run_connect attach-fail existing --session existing 2>&1)"
STATUS=$?
set -e
assert_eq "$STATUS" "5"
if grep -Eq -- '(^| )close ' "$CASE_LOG"; then
  fail "pre-existing active session was closed during rollback"
fi
[ -e "$CASE_STATE/active" ] || fail "pre-existing active session state was removed"
[ -e "$CASE_SOCKET/existing.target" ] || fail "pre-existing binding was removed"
pass "pre-existing session preservation"

# Live cleanup uses the existing daemon without --cdp, preserves the tab, and removes sidecars.
new_case cleanup-live
printf '%s\n/devtools/browser/cleanup-uuid\n' "$PORT" > "$CASE_CHROME/DevToolsActivePort"
run_connect success cleanup --session cleanlive >/dev/null
: > "$CASE_LOG"
OUTPUT="$(run_cleanup 1 cleanlive)"
assert_text_contains "$OUTPUT" "pinned tab preserved"
assert_file_contains "$CASE_LOG" "network unroute"
assert_file_not_contains "$CASE_LOG" "tab close"
assert_file_contains "$CASE_LOG" "close"
assert_file_not_contains "$CASE_LOG" "--cdp"
[ ! -e "$CASE_ROOT/cleanlive" ] || fail "cleanup wrapper directory leaked"
[ ! -e "$CASE_SOCKET/cleanlive.target" ] || fail "cleanup target binding leaked"
[ ! -e "$CASE_SOCKET/cleanlive.config" ] || fail "cleanup config sidecar leaked"
pass "live cleanup preserves the tab and stops the daemon"

# Explicit --close-tab retains exact-target closing for callers that request it.
new_case cleanup-close-tab
printf '%s\n/devtools/browser/cleanup-close-tab-uuid\n' "$PORT" > "$CASE_CHROME/DevToolsActivePort"
run_connect success cleanup --session closeowned >/dev/null
: > "$CASE_LOG"
OUTPUT="$(run_cleanup 1 closeowned success 1)"
assert_text_contains "$OUTPUT" "pinned tab closed"
assert_file_contains "$CASE_LOG" "network unroute"
assert_file_contains "$CASE_LOG" "tab close TARGET-PRIMARY"
assert_file_not_contains "$CASE_LOG" "--cdp"
pass "explicit close-tab closes only the owned target"

# Cleanup never closes a target when the ownership metadata is inconsistent.
new_case cleanup-tampered-metadata
printf '%s\n/devtools/browser/tampered-uuid\n' "$PORT" > "$CASE_CHROME/DevToolsActivePort"
run_connect success cleanup --session tampered >/dev/null
ab_set_meta_value "$CASE_ROOT/tampered/session.meta" session foreign
: > "$CASE_LOG"
set +e
OUTPUT="$(run_cleanup 1 tampered success 1 2>&1)"
STATUS=$?
set -e
assert_eq "$STATUS" "6"
assert_text_contains "$OUTPUT" "does not prove exact target ownership"
if grep -Fq -- 'tab close' "$CASE_LOG"; then
  fail "cleanup closed a target using inconsistent ownership metadata"
fi
pass "tampered ownership metadata preserves every target"

# Page-count growth is reported once, never persisted, and never fails cleanup.
new_case unattributed-target
printf '%s\n/devtools/browser/unattributed-uuid\n' "$PORT" > "$CASE_CHROME/DevToolsActivePort"
run_connect success popup --session popupcase >/dev/null
AB="$CASE_ROOT/popupcase/ab"
set +e
OUTPUT="$(run_wrapper extra-after "$AB" get url 2>&1)"
STATUS=$?
set -e
assert_eq "$STATUS" "0"
assert_text_contains "$OUTPUT" "additional page"
assert_file_not_contains "$CASE_ROOT/popupcase/session.meta" "unattributed_target_events"
assert_file_not_contains "$CASE_ROOT/popupcase/session.meta" "last_observed_target_count"
: > "$CASE_LOG"
OUTPUT="$(run_cleanup 1 popupcase 2>&1)"
assert_text_contains "$OUTPUT" "pinned tab preserved"
assert_file_not_contains "$CASE_LOG" "tab close"
pass "page growth is informational and all tabs are preserved"

# Daemon shutdown failure preserves recovery artifacts instead of claiming success.
new_case cleanup-close-fail
printf '%s\n/devtools/browser/close-fail-uuid\n' "$PORT" > "$CASE_CHROME/DevToolsActivePort"
run_connect success cleanup --session closefail >/dev/null
: > "$CASE_LOG"
set +e
OUTPUT="$(run_cleanup 1 closefail close-fail 2>&1)"
STATUS=$?
set -e
assert_eq "$STATUS" "5"
assert_text_contains "$OUTPUT" "retained for recovery"
[ -e "$CASE_ROOT/closefail/ab" ] || fail "close failure removed its recovery wrapper"
[ -e "$CASE_SOCKET/closefail.target" ] || fail "close failure removed its binding"
pass "cleanup shutdown failure preservation"

# Cleanup without exact ownership metadata detaches but preserves every target.
new_case cleanup-no-wrapper
touch "$CASE_STATE/active"
printf 'binding\n' > "$CASE_SOCKET/orphan.target"
printf 'config\n' > "$CASE_SOCKET/orphan.config"
set +e
OUTPUT="$(run_cleanup 1 orphan success 1 2>&1)"
STATUS=$?
set -e
assert_eq "$STATUS" "6"
assert_text_contains "$OUTPUT" "could not be closed without reconnecting"
assert_file_not_contains "$CASE_LOG" "tab close"
assert_file_not_contains "$CASE_LOG" "--cdp"
[ ! -e "$CASE_SOCKET/orphan.target" ] || fail "orphan target binding leaked"
[ ! -e "$CASE_SOCKET/orphan.config" ] || fail "orphan config sidecar leaked"
pass "cleanup without ownership metadata preserves targets"

# An inactive daemon with a stale target cannot prove its tab is gone.
new_case cleanup-inactive-target
printf 'binding\n' > "$CASE_SOCKET/stale.target"
printf 'config\n' > "$CASE_SOCKET/stale.config"
set +e
OUTPUT="$(run_cleanup 0 stale success 1 2>&1)"
STATUS=$?
set -e
assert_eq "$STATUS" "6"
assert_text_contains "$OUTPUT" "previously pinned target was closed"
assert_file_not_contains "$CASE_LOG" "--cdp"
[ ! -e "$CASE_SOCKET/stale.target" ] || fail "stale target binding leaked"
pass "inactive binding reports partial cleanup"

# Disconnected cleanup never reconnects and reports the possibly remaining tab.
new_case cleanup-disconnected
printf '%s\n/devtools/browser/disconnected-uuid\n' "$PORT" > "$CASE_CHROME/DevToolsActivePort"
run_connect success cleanup --session disconnected >/dev/null
: > "$CASE_LOG"
set +e
OUTPUT="$(run_cleanup 0 disconnected success 1 2>&1)"
STATUS=$?
set -e
assert_eq "$STATUS" "6"
assert_text_contains "$OUTPUT" "will not open a new approval"
assert_file_not_contains "$CASE_LOG" "--cdp"
if grep -Fq -- 'tab close' "$CASE_LOG"; then
  fail "disconnected cleanup attempted a browser command"
fi
assert_file_contains "$CASE_LOG" "close"
[ ! -e "$CASE_ROOT/disconnected" ] || fail "disconnected wrapper directory leaked"
pass "disconnected cleanup avoids approval"

# A stale session lock is reclaimed without weakening private-directory checks.
new_case stale-lock
printf '%s\n/devtools/browser/stale-lock-uuid\n' "$PORT" > "$CASE_CHROME/DevToolsActivePort"
DEFAULT_SESSION_LOCK_KEY="$(ab_session_lock_key "$DEFAULT_SESSION")"
mkdir -p "$CASE_ROOT/.locks/$DEFAULT_SESSION_LOCK_KEY.lock"
printf '99999999\n' > "$CASE_ROOT/.locks/$DEFAULT_SESSION_LOCK_KEY.lock/pid"
printf 'stale\n' > "$CASE_ROOT/.locks/$DEFAULT_SESSION_LOCK_KEY.lock/token"
OUTPUT="$(run_connect success stale-lock)"
assert_text_contains "$OUTPUT" "Session:  $DEFAULT_SESSION"
[ ! -e "$CASE_ROOT/.locks/$DEFAULT_SESSION_LOCK_KEY.lock" ] || fail "stale session lock survived connect"
pass "stale session lock recovery"

# Explicit callers cannot race the same daemon under different owner keys.
new_case shared-session-race
printf '%s\n/devtools/browser/shared-session-uuid\n' "$PORT" > "$CASE_CHROME/DevToolsActivePort"
for SLOT_NAME in alpha beta; do
  (
    set +e
    run_connect stress-concurrency "$SLOT_NAME" --session sharedrace --slot "$SLOT_NAME" >"$CASE_DIR/$SLOT_NAME.out" 2>&1
    printf '%s\n' "$?" > "$CASE_DIR/$SLOT_NAME.status"
  ) &
  RACE_PIDS="${RACE_PIDS:-} $!"
done
for RACE_PID in $RACE_PIDS; do
  wait "$RACE_PID" || true
done
SHARED_STATUSES="$(sort "$CASE_DIR/alpha.status" "$CASE_DIR/beta.status" | tr '\n' ' ')"
assert_eq "$SHARED_STATUSES" "0 5 "
[ ! -e "$CASE_STATE/overlap-detected" ] || fail "different owners overlapped operations on one explicit session"
pass "shared explicit session serialization"

# Many simultaneous connects and wrapper commands serialize on one session lock.
new_case concurrency
printf '%s\n/devtools/browser/concurrency-uuid\n' "$PORT" > "$CASE_CHROME/DevToolsActivePort"
PIDS=""
for INDEX in $(seq 1 20); do
  (run_connect stress-concurrency "label-$INDEX" > "$CASE_DIR/connect-$INDEX.out" 2>&1) &
  PIDS="$PIDS $!"
done
for PID_TO_WAIT in $PIDS; do
  if ! wait "$PID_TO_WAIT"; then
    grep -H . "$CASE_DIR"/connect-*.out >&2 || true
    fail "a concurrent connect failed"
  fi
done
[ ! -e "$CASE_STATE/overlap-detected" ] || fail "concurrent connect operations overlapped"
UNIQUE_SESSIONS="$(grep -h 'Session:' "$CASE_DIR"/connect-*.out | awk '{print $3}' | sort -u | wc -l | tr -d ' ')"
assert_eq "$UNIQUE_SESSIONS" "1"
SESSION_DIRS="$(find "$CASE_ROOT" -mindepth 1 -maxdepth 1 -type d ! -name .locks | wc -l | tr -d ' ')"
assert_eq "$SESSION_DIRS" "1"
AB="$CASE_ROOT/$DEFAULT_SESSION/ab"
rm -f "$CASE_STATE/overlap-detected"
PIDS=""
for INDEX in $(seq 1 20); do
  (run_wrapper stress-concurrency "$AB" get url > "$CASE_DIR/wrapper-$INDEX.out" 2>&1) &
  PIDS="$PIDS $!"
done
for PID_TO_WAIT in $PIDS; do
  if ! wait "$PID_TO_WAIT"; then
    grep -H . "$CASE_DIR"/wrapper-*.out >&2 || true
    fail "a concurrent wrapper command failed"
  fi
done
[ ! -e "$CASE_STATE/overlap-detected" ] || fail "concurrent wrapper commands overlapped"
for INDEX in $(seq 1 20); do
  assert_eq "$(cat "$CASE_DIR/wrapper-$INDEX.out")" "about:blank"
done
pass "high-concurrency session serialization"

# An agent-browser upgrade leaves the previous daemon on the old version. The
# first BROWSER command restarts it, and a restarted daemon loses the external
# CDP attachment, so it can launch a substitute Chrome. `session info` is the
# one call that does not restart it, so both scripts catch the mismatch there.
new_case version-mismatch
printf '%s\n/devtools/browser/version-uuid\n' "$PORT" > "$CASE_CHROME/DevToolsActivePort"
run_connect success "Upgrade case" --url http://example.test >/dev/null
AB="$CASE_ROOT/$DEFAULT_SESSION/ab"
[ -x "$AB" ] || fail "wrapper was not created for the upgrade case"

# The wrapper refuses rather than letting the command restart the daemon.
CALLS_BEFORE="$(wc -l < "$CASE_LOG" | tr -d ' ')"
set +e
MISMATCH_OUTPUT="$(MOCK_DAEMON_VERSION=0.37.1 run_wrapper success "$AB" get url 2>&1)"
MISMATCH_STATUS=$?
set -e
assert_eq "$MISMATCH_STATUS" "8"
assert_text_contains "$MISMATCH_OUTPUT" "0.37.1"
assert_text_contains "$MISMATCH_OUTPUT" "0.36.0"
assert_text_contains "$MISMATCH_OUTPUT" "re-run connect.sh"
assert_eq "$(wc -l < "$CASE_LOG" | tr -d ' ')" "$((CALLS_BEFORE + 2))"
assert_file_contains "$CASE_ROOT/$DEFAULT_SESSION/events.log" "version-mismatch"

# A matching daemon version is not disturbed.
MATCHED_OUTPUT="$(MOCK_DAEMON_VERSION=0.36.0 run_wrapper success "$AB" get url)"
assert_eq "$MATCHED_OUTPUT" "http://example.test"

# connect.sh stops the stale daemon itself, then attaches once with the current
# version. The session sidecars survive so the new daemon rebinds to the same
# target instead of opening another tab.
: > "$CASE_LOG"
MISMATCH_CONNECT="$(MOCK_DAEMON_VERSION=0.37.1 run_connect success "Upgrade case" 2>&1)"
assert_text_contains "$MISMATCH_CONNECT" "Stopping the stale daemon"
assert_text_contains "$MISMATCH_CONNECT" "Session:  $DEFAULT_SESSION"
grep -q -- "--session $DEFAULT_SESSION close" "$CASE_LOG" || fail "connect did not stop the stale daemon"
[ -f "$CASE_SOCKET/$DEFAULT_SESSION.target" ] || fail "connect removed the binding sidecar"
POST_OUTPUT="$(run_wrapper success "$AB" get url)"
assert_eq "$POST_OUTPUT" "http://example.test"
pass "upgraded CLI never restarts a stale daemon mid-command"

# The replacement daemon attaches fresh, and a fresh attach opens a tab. When
# the session's own target survived the swap, that empty tab is ours: connect
# rebinds to the owned target and closes it, so an upgrade leaves no residue in
# the user's window.
new_case version-mismatch-tab
printf '%s\n/devtools/browser/swap-uuid\n' "$PORT" > "$CASE_CHROME/DevToolsActivePort"
run_connect success "Swap case" --url http://example.test >/dev/null
assert_file_contains "$CASE_ROOT/$DEFAULT_SESSION/session.meta" "owned_target_id=TARGET-PRIMARY"
: > "$CASE_LOG"
SWAP_OUTPUT="$(MOCK_DAEMON_VERSION=0.37.1 run_connect swap-new-tab "Swap case" 2>&1)"
assert_text_contains "$SWAP_OUTPUT" "Stopping the stale daemon"
assert_text_contains "$SWAP_OUTPUT" "switched back to this session's own tab"
assert_text_contains "$SWAP_OUTPUT" "Own tab:  http://example.test"
grep -q -- "tab close TARGET-SWAP" "$CASE_LOG" || fail "the empty tab from the swap attach was not closed"
assert_file_contains "$CASE_ROOT/$DEFAULT_SESSION/events.log" "tab-closed reason=daemon-swap"
assert_file_contains "$CASE_ROOT/$DEFAULT_SESSION/session.meta" "owned_target_id=TARGET-PRIMARY"
pass "a daemon swap leaves no extra tab behind"

printf '\nAll agent-browser-connect helper tests passed.\n'
