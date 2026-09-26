#!/usr/bin/env bash
# Guard every command sent through a connected, owner-pinned browser session.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
. "$SCRIPT_DIR/lib.sh"
# shellcheck source=guard.sh
. "$SCRIPT_DIR/guard.sh"

META="${1:-}"
AGENT_BROWSER_BIN="${2:-}"
NODE_BIN="${3:-}"
if [ "$#" -lt 4 ] || [ -z "$META" ] || [ -z "$AGENT_BROWSER_BIN" ] || [ -z "$NODE_BIN" ]; then
  echo "✗ This internal dispatcher must be invoked through a generated browser wrapper." >&2
  exit 2
fi
shift 3

DIR="$(dirname "$META")"
ROOT="$(dirname "$DIR")"
if ! ab_owned_directory "$ROOT" || ! ab_owned_directory "$DIR" || [ ! -f "$META" ] || [ -L "$META" ]; then
  echo "✗ Browser wrapper metadata is missing or unsafe; re-run connect.sh." >&2
  exit 5
fi
PATH_SESSION="$(basename "$DIR")"
ab_validate_session "$PATH_SESSION" || {
  echo "✗ Browser wrapper path contains an invalid session." >&2
  exit 5
}
SESSION_LOCK_KEY="$(ab_session_lock_key "$PATH_SESSION")" || {
  echo "✗ A SHA-256 utility is required to lock the browser session." >&2
  exit 3
}
if ! ab_acquire_lock "$ROOT" "$SESSION_LOCK_KEY"; then
  echo "✗ Timed out waiting for another command in this browser session." >&2
  exit 5
fi
release_owner_lock() {
  ab_stop_approver "$DIR"
  ab_release_lock || true
}
trap release_owner_lock EXIT
trap 'release_owner_lock; exit 130' INT TERM

# A failed check records what failed and, when a persistent session could fix
# it by re-running connect.sh, why (HEAL_REASON). Empty HEAL_REASON = not healable.
FAIL_CODE=0
FAIL_MSG=""
HEAL_REASON=""
preflight_fail() {
  FAIL_CODE="$1"
  FAIL_MSG="$2"
  HEAL_REASON="${3:-}"
  return 1
}

load_meta() {
  if ! ab_load_meta "$META" "$PATH_SESSION" 1; then
    case "$AB_META_ERROR" in
      # connect.sh writes the file before it knows its target, so a record
      # without one is an interrupted connect — the one metadata failure a
      # re-run fixes. Every other one is a tampered or foreign file.
      *"owned target"*)
        preflight_fail 8 "✗ Browser wrapper metadata is outdated or unusable ($AB_META_ERROR); re-run connect.sh." no-owned-target
        ;;
      *)
        preflight_fail 5 "✗ Browser wrapper metadata is outdated or unusable ($AB_META_ERROR); re-run connect.sh."
        ;;
    esac
    return 1
  fi
  SESSION="$AB_META_SESSION"
  PORT="$AB_META_PORT"
  CDP_URL="$AB_META_CDP_URL"
  OWNED_TARGET_ID="$AB_META_OWNED_TARGET_ID"
}

# Read straight from the file, not through load_meta: the flag must be known
# even when the record fails validation for a healable reason.
PERSISTENT="$(ab_meta_value "$META" persistent 2>/dev/null || true)"

META_OK=1
if ! load_meta; then
  if [ -z "$HEAL_REASON" ] || [ "$PERSISTENT" != "1" ]; then
    echo "$FAIL_MSG" >&2
    exit "$FAIL_CODE"
  fi
  META_OK=0
fi

if [ "${AGENT_BROWSER_BIN#/}" = "$AGENT_BROWSER_BIN" ] || [ ! -x "$AGENT_BROWSER_BIN" ]; then
  echo "✗ The agent-browser executable recorded by connect.sh is unavailable." >&2
  exit 3
fi
if [ "${NODE_BIN#/}" = "$NODE_BIN" ] || [ ! -x "$NODE_BIN" ]; then
  echo "✗ The node executable recorded by connect.sh is unavailable." >&2
  exit 3
fi

# Every command is checked against the allow-list in guard.sh before the daemon
# is touched at all. Applied to the top-level command and to every line inside a
# batch; exit 2 means deliberately forbidden, exit 10 means not in the allow-list.
ab_guard_command 1 "$@" || exit $?
COMMAND_NAME="${1:-}"

# A batch is forwarded only after every line inside it passes the same guard.
# Argument mode: each quoted argument is one command string. Stdin mode: a JSON
# array of string arrays, read fully here so nothing is sent before scanning.
BATCH_STDIN=""
if [ "${1:-}" = "batch" ]; then
  BATCH_HAS_COMMANDS=0
  BATCH_GUARDED=""
  BATCH_FLAGS=()
  for argument in "${@:2}"; do
    case "$argument" in
      --bail|--json)
        BATCH_FLAGS+=("$argument")
        continue
        ;;
    esac
    BATCH_HAS_COMMANDS=1
    if ! BATCH_LINE="$(printf '%s' "$argument" | "$NODE_BIN" "$SCRIPT_DIR/json.mjs" batch-argument 2>&1)"; then
      echo "✗ batch argument was rejected: $BATCH_LINE" >&2
      exit 2
    fi
    if [ -z "$BATCH_LINE" ]; then
      # Expanding an empty array under `set -u` is a hard error on bash 3.2, the
      # bash `#!/usr/bin/env bash` resolves to on stock macOS, so this is caught
      # here rather than crashing the dispatcher with `unbound variable`.
      echo "✗ An empty batch argument is blocked: it is not a command." >&2
      exit 2
    fi
    IFS=$'\x1f' read -ra BATCH_WORDS <<< "$BATCH_LINE"
    ab_guard_command 0 "${BATCH_WORDS[@]}" || exit $?
    BATCH_GUARDED="$BATCH_GUARDED$BATCH_LINE
"
  done
  if [ "$BATCH_HAS_COMMANDS" -eq 1 ]; then
    # Forward the words that were guarded, not the strings they were parsed from.
    # Handing agent-browser the original argument would make two parsers decide
    # one policy, and they disagree: json.mjs splits on spaces and treats a tab as
    # an ordinary character, so `batch $'tab\tnew http://x'` guards as the single
    # unknown verb "tab<TAB>new" while a whitespace-splitting parser downstream
    # could read it as `tab new`. Re-encoding to the JSON stdin form, which is
    # already the shape the stdin path uses, removes the second parse entirely.
    if ! BATCH_STDIN="$(printf '%s' "$BATCH_GUARDED" | "$NODE_BIN" "$SCRIPT_DIR/json.mjs" batch-encode 2>&1)"; then
      echo "✗ batch commands could not be re-encoded safely: $BATCH_STDIN" >&2
      exit 2
    fi
    set -- batch ${BATCH_FLAGS[@]+"${BATCH_FLAGS[@]}"}
  fi
  if [ "$BATCH_HAS_COMMANDS" -eq 0 ]; then
    if [ -t 0 ]; then
      echo "✗ 'batch' needs quoted command arguments or a JSON array on stdin." >&2
      exit 2
    fi
    BATCH_STDIN="$(cat)"
    if ! BATCH_LINES="$(printf '%s' "$BATCH_STDIN" | "$NODE_BIN" "$SCRIPT_DIR/json.mjs" batch-stdin 2>&1)"; then
      echo "✗ batch stdin was rejected: $BATCH_LINES" >&2
      exit 2
    fi
    while IFS= read -r BATCH_LINE; do
      [ -n "$BATCH_LINE" ] || continue
      IFS=$'\x1f' read -ra BATCH_WORDS <<< "$BATCH_LINE"
      ab_guard_command 0 "${BATCH_WORDS[@]}" || exit $?
    done <<< "$BATCH_LINES"
  fi
fi

browser_command() {
  "$AGENT_BROWSER_BIN" --cdp "$CDP_URL" --pin-tab --session "$SESSION" "$@"
}

# Publishes AB_TAB_ACTIVE / AB_TAB_OWNED_PRESENT / AB_TAB_COUNT.
read_tab_state() {
  local output
  output="$(browser_command tab list --json 2>/dev/null)" || return 1
  ab_tab_state "$NODE_BIN" "$SCRIPT_DIR/json.mjs" "$OWNED_TARGET_ID" "$output"
}

restore_owned_target() {
  browser_command tab "$OWNED_TARGET_ID" --json >/dev/null 2>&1
}

# Everything that must hold before the command runs. Returns 1 through
# preflight_fail instead of exiting, so a persistent session can heal and ask
# again; outside persistent mode the caller exits exactly as before.
preflight() {
  # `|| status=$?` rather than a bare call: a non-zero return from a standalone
  # statement would trip `set -e` before the status could be inspected.
  local status=0
  ab_session_info "$AGENT_BROWSER_BIN" "$NODE_BIN" "$SCRIPT_DIR/json.mjs" "$SESSION" || status=$?
  if [ "$status" -eq 1 ]; then
    preflight_fail 8 "✗ Could not inspect browser session $SESSION; re-run connect.sh." session-info-failed
    return 1
  fi
  if [ "$status" -ne 0 ]; then
    preflight_fail 8 "✗ Browser diagnostics did not match session $SESSION; re-run connect.sh."
    return 1
  fi
  if [ "$AB_SESSION_ACTIVE" != "1" ]; then
    preflight_fail 8 "✗ Browser session $SESSION is inactive; re-run connect.sh instead of letting this wrapper reconnect implicitly." daemon-inactive
    return 1
  fi

  # `session info` is the one call that does not restart a version-mismatched
  # daemon, so it is where the mismatch gets caught. The next browser command
  # would restart the daemon mid-dispatch, which drops the CDP attachment and can
  # launch a substitute Chrome; connect.sh does the swap deliberately instead.
  local daemon_version="$AB_SESSION_VERSION" cli_version
  cli_version="$(ab_cli_version "$AGENT_BROWSER_BIN" 2>/dev/null || true)"
  if [ -n "$daemon_version" ] && [ -n "$cli_version" ] && [ "$daemon_version" != "$cli_version" ]; then
    ab_log_event "$DIR" version-mismatch "daemon=$daemon_version cli=$cli_version command=${COMMAND_NAME}"
    preflight_fail 8 "✗ agent-browser was upgraded ($daemon_version → $cli_version) while session $SESSION stayed attached. Running this command would restart the daemon and could launch a substitute Chrome; re-run connect.sh to re-attach once, deliberately." version-mismatch
    return 1
  fi

  # A daemon with no established socket to Chrome redials on the next CDP call
  # (measured 2026-09-25: after the socket dropped it reconnected by itself, one
  # approval dialog). With --auto-approve that redial is a connection this
  # session opens, so the approver covers exactly that call and no other.
  if [ "$(ab_meta_value "$META" auto_approve 2>/dev/null || true)" = "1" ] && ab_is_uint "$AB_SESSION_PID"; then
    local connected=0
    ab_pid_has_cdp_connection "$AB_SESSION_PID" "$PORT" || connected=$?
    if [ "$connected" -eq 1 ]; then
      ab_log_event "$DIR" socket-down "pid=$AB_SESSION_PID command=${COMMAND_NAME} (daemon will redial)"
      ab_start_approver "$DIR" "$SCRIPT_DIR"
    fi
  fi

  # A failure here with a live daemon is what a Chrome restart looks like: the
  # recorded browser WebSocket no longer exists. connect.sh resolves the new one.
  local tab_state_ok=1
  read_tab_state || tab_state_ok=0
  ab_stop_approver "$DIR"
  if [ "$tab_state_ok" -eq 0 ]; then
    preflight_fail 8 "✗ Could not verify the pinned target; re-run connect.sh to recover it safely." tab-list-failed
    return 1
  fi
  PRE_ACTIVE="$AB_TAB_ACTIVE"
  PRE_OWNED_PRESENT="$AB_TAB_OWNED_PRESENT"
  PRE_COUNT="$AB_TAB_COUNT"
  if [ "$PRE_ACTIVE" != "$OWNED_TARGET_ID" ]; then
    if [ "$PRE_OWNED_PRESENT" = "1" ] && restore_owned_target; then
      # The owned target still exists, so the binding is back where it belongs
      # and the command can run. Drift means a bare agent-browser call happened.
      # The restore is a tab switch, and agent-browser always sends
      # Page.bringToFront on a switch, so this is one of the few wrapped paths
      # that changes Chrome's visible tab. Log it so a shared browser can be
      # audited.
      ab_log_event "$DIR" drift-restored "phase=pre active=${PRE_ACTIVE:-none} owned=$OWNED_TARGET_ID command=${COMMAND_NAME} (Page.bringToFront)"
      echo "! Browser binding had drifted; restored the owned target before running the command. This brought the tab to the front of Chrome. Drift means a bare agent-browser command touched session $SESSION; find and stop it." >&2
    else
      ab_log_event "$DIR" target-gone "phase=pre owned=$OWNED_TARGET_ID command=${COMMAND_NAME}"
      preflight_fail 8 "✗ The owned browser target is gone; re-run connect.sh to create exactly one replacement." target-gone
      return 1
    fi
  fi
  return 0
}

# Persistent mode: re-run connect.sh for this exact owner, slot and port, the
# same thing the agent is told to do by hand. Bounded on purpose. Each attempt
# can cost the user one Chrome approval dialog, so there is one attempt per
# command, and none at all within AB_HEAL_COOLDOWN_SECONDS of a failed one —
# a heal that failed because nobody approved must not become a dialog loop.
HEAL_STATE="$DIR/heal.state"
heal_session() {
  local reason="$1"
  local cooldown="${AB_HEAL_COOLDOWN_SECONDS:-60}"
  local now last_at last_status replace_url="" label status=0
  local args=()

  ab_is_uint "$cooldown" || cooldown=60
  now="$(date +%s)"
  last_at="$(ab_meta_value "$HEAL_STATE" at 2>/dev/null || true)"
  last_status="$(ab_meta_value "$HEAL_STATE" status 2>/dev/null || true)"
  if ab_is_uint "$last_at" && [ -n "$last_status" ] && [ "$last_status" != "0" ] \
    && [ "$now" -ge "$last_at" ] && [ "$((now - last_at))" -lt "$cooldown" ]; then
    ab_log_event "$DIR" heal-skipped "reason=$reason cooldown=${cooldown}s last_status=$last_status"
    HEAL_ERROR="  persistent mode did not reconnect: the last attempt failed $((now - last_at))s ago (exit $last_status) and the cooldown is ${cooldown}s. Re-run connect.sh by hand, or wait."
    return 1
  fi

  # A closed tab comes back at the URL it last had. agent-browser keeps it in
  # the session's `.target` sidecar; json.mjs prints it only if it is http(s)
  # or about:blank, and connect.sh uses it only when it must open a new tab.
  local socket_dir="${AB_META_SOCKET_DIR:-$(ab_default_socket_dir)}"
  local sidecar="$socket_dir/$PATH_SESSION.target"
  if [ -f "$sidecar" ] && [ ! -L "$sidecar" ]; then
    replace_url="$("$NODE_BIN" "$SCRIPT_DIR/json.mjs" target-url < "$sidecar" 2>/dev/null || true)"
  fi

  label="${AB_META_LABEL:-browser}"
  args=("$label" --persistent --slot "$AB_META_SLOT" --port "$AB_META_PORT")
  [ "$(ab_meta_value "$META" react 2>/dev/null || true)" != "1" ] || args+=(--react)
  [ "$(ab_meta_value "$META" auto_approve 2>/dev/null || true)" != "1" ] || args+=(--auto-approve)
  [ -z "$replace_url" ] || args+=(--replace-url "$replace_url")

  ab_log_event "$DIR" heal-start "reason=$reason command=${COMMAND_NAME}"
  local what="lost its browser connection"
  [ "$reason" != "target-gone" ] || what="lost its tab (it was closed)"
  echo "! Session $PATH_SESSION $what ($reason); persistent mode is reconnecting. Chrome may ask to approve one connection." >&2

  # connect.sh takes this same session lock. Hand it over for the re-run and
  # take it back before touching the session again.
  ab_release_lock || true
  local timeout="${AB_HEAL_TIMEOUT_SECONDS:-90}" heal_pid watchdog_pid timed_out="$DIR/heal.timed-out"
  ab_is_uint "$timeout" && [ "$timeout" -gt 0 ] || timeout=90
  rm -f "$timed_out"
  if [ "${AB_META_OWNER_ID#explicit:}" != "$AB_META_OWNER_ID" ]; then
    args+=(--session "${AB_META_OWNER_ID#explicit:}")
  fi
  # The attach blocks until the user answers Chrome's dialog, and agent-browser
  # itself only gives up after ~5 minutes (measured 2026-09-25, 0.38.1:
  # "Failed to read ... after 5 retries"), far past an agent's command timeout.
  # connect.sh runs in its own process group so the watchdog can stop it and the
  # CLI client it is blocked in; the TERM runs connect's rollback. The daemon is
  # not in that group (it is its own session leader) — if the user approves
  # after the timeout, it finishes attaching and the next command finds it live.
  set -m
  if [ "${AB_META_OWNER_ID#explicit:}" != "$AB_META_OWNER_ID" ]; then
    env -u AB_CONNECT_ID -u AB_SESSION_ID AB_CONNECT_ROOT="$ROOT" \
      bash "$SCRIPT_DIR/connect.sh" "${args[@]}" >"$DIR/heal.out" 2>"$DIR/heal.err" &
  else
    env -u AB_SESSION_ID AB_CONNECT_ID="$AB_META_OWNER_ID" AB_CONNECT_ROOT="$ROOT" \
      bash "$SCRIPT_DIR/connect.sh" "${args[@]}" >"$DIR/heal.out" 2>"$DIR/heal.err" &
  fi
  heal_pid=$!
  set +m
  (
    waited=0
    while kill -0 "$heal_pid" 2>/dev/null; do
      if [ "$waited" -ge "$timeout" ]; then
        : > "$timed_out"
        # The daemon blocked on the approval is what holds everything up: while
        # it waits, connect's rollback `close` blocks on it too (measured
        # 2026-09-25). Stop it first — only this session's, proven by its pid
        # file and process name — so the TERM below runs a rollback that
        # finishes and restores session.meta. Its `.target` sidecar stays, so
        # the next heal rebinds the same tab.
        daemon_pid="$(sed -n '1p' "$socket_dir/$PATH_SESSION.pid" 2>/dev/null || true)"
        if ab_is_uint "$daemon_pid" && ps -o comm= -p "$daemon_pid" 2>/dev/null | grep -q 'agent-browser'; then
          kill -KILL "$daemon_pid" 2>/dev/null || true
        fi
        kill -TERM -- "-$heal_pid" 2>/dev/null || kill -TERM "$heal_pid" 2>/dev/null || true
        for _ in 1 2 3 4 5 6 7 8 9 10; do
          kill -0 "$heal_pid" 2>/dev/null || exit 0
          sleep 1
        done
        kill -KILL -- "-$heal_pid" 2>/dev/null || true
        exit 0
      fi
      sleep 1
      waited=$((waited + 1))
    done
  ) &
  watchdog_pid=$!
  wait "$heal_pid" || status=$?
  kill "$watchdog_pid" 2>/dev/null || true
  wait "$watchdog_pid" 2>/dev/null || true
  if [ -f "$timed_out" ]; then
    rm -f "$timed_out"
    [ "$status" -ne 0 ] || status=124
    printf '✗ No connection within %ss: Chrome is most likely still showing its approval dialog.\n' "$timeout" >> "$DIR/heal.err"
    printf '  The waiting connection was stopped, so that dialog is now stale: cancel it. The next command reconnects after the cooldown.\n' >> "$DIR/heal.err"
  fi
  if ! ab_acquire_lock "$ROOT" "$SESSION_LOCK_KEY"; then
    echo "✗ Reconnected, but timed out waiting to take the browser session lock back." >&2
    exit 5
  fi

  if printf 'at=%s\nstatus=%s\nreason=%s\n' "$now" "$status" "$reason" > "$HEAL_STATE.tmp.$$"; then
    chmod 600 "$HEAL_STATE.tmp.$$" 2>/dev/null || true
    mv -f "$HEAL_STATE.tmp.$$" "$HEAL_STATE" 2>/dev/null || rm -f "$HEAL_STATE.tmp.$$"
  fi
  if [ "$status" -eq 0 ]; then
    ab_log_event "$DIR" heal-ok "reason=$reason"
    # The reason is on stderr so the agent knows a new tab may have appeared.
    sed -n 's/^✓ Own tab:  /! Reconnected; own tab: /p' "$DIR/heal.out" >&2
    rm -f "$DIR/heal.out" "$DIR/heal.err"
    return 0
  fi
  ab_log_event "$DIR" heal-failed "reason=$reason status=$status"
  HEAL_ERROR="$(sed 's/^/  /' "$DIR/heal.err" 2>/dev/null || true)"
  rm -f "$DIR/heal.out" "$DIR/heal.err"
  return 1
}

HEALED=0
HEAL_ERROR=""
while :; do
  if [ "$META_OK" -eq 1 ] && preflight; then
    break
  fi
  if [ "$PERSISTENT" = "1" ] && [ "$HEALED" -eq 0 ] && [ -n "$HEAL_REASON" ]; then
    HEALED=1
    if heal_session "$HEAL_REASON"; then
      if load_meta; then
        META_OK=1
        continue
      fi
      META_OK=0
    fi
  fi
  echo "$FAIL_MSG" >&2
  [ -z "$HEAL_ERROR" ] || printf '%s\n' "$HEAL_ERROR" >&2
  exit "$FAIL_CODE"
done

set +e
if [ -n "$BATCH_STDIN" ]; then
  printf '%s' "$BATCH_STDIN" | browser_command "$@"
else
  browser_command "$@"
fi
COMMAND_STATUS=$?
set -e

if ! read_tab_state; then
  echo "✗ The pinned target could not be verified after the command; re-run connect.sh." >&2
  exit 9
fi
POST_ACTIVE="$AB_TAB_ACTIVE"
POST_OWNED_PRESENT="$AB_TAB_OWNED_PRESENT"
POST_COUNT="$AB_TAB_COUNT"
if [ "$POST_ACTIVE" != "$OWNED_TARGET_ID" ]; then
  if [ "$POST_OWNED_PRESENT" = "1" ]; then
    restore_owned_target || true
    ab_log_event "$DIR" drift-restored "phase=post active=${POST_ACTIVE:-none} owned=$OWNED_TARGET_ID command=${1:-} (Page.bringToFront)"
  else
    ab_log_event "$DIR" target-gone "phase=post owned=$OWNED_TARGET_ID command=${1:-}"
  fi
  echo "✗ Command changed the browser binding unexpectedly; the owned target was restored when possible (that restore brought the tab to the front of Chrome)." >&2
  exit 9
fi
# Informational only. The count covers every page in Chrome, including the
# user's own tabs, so growth is worth a note (a popup may have opened) but is
# never treated as a failure and never persisted.
if [ "$POST_COUNT" -gt "$PRE_COUNT" ]; then
  ab_log_event "$DIR" page-count-grew "from=$PRE_COUNT to=$POST_COUNT command=${1:-}"
  echo "! Chrome reported $((POST_COUNT - PRE_COUNT)) additional page(s) during this command (a popup, or the user opened a tab). They were left untouched." >&2
fi
[ "$COMMAND_STATUS" -eq 0 ] || exit "$COMMAND_STATUS"
