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
  ab_release_lock || true
}
trap release_owner_lock EXIT
trap 'release_owner_lock; exit 130' INT TERM

if ! ab_load_meta "$META" "$PATH_SESSION" 1; then
  echo "✗ Browser wrapper metadata is outdated or unusable ($AB_META_ERROR); re-run connect.sh." >&2
  case "$AB_META_ERROR" in
    *"owned target"*) exit 8 ;;
    *) exit 5 ;;
  esac
fi
SESSION="$AB_META_SESSION"
PORT="$AB_META_PORT"
CDP_URL="$AB_META_CDP_URL"
OWNED_TARGET_ID="$AB_META_OWNED_TARGET_ID"

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

# `|| STATUS=$?` rather than a bare call: a non-zero return from a standalone
# statement would trip `set -e` before the status could be inspected.
SESSION_INFO_STATUS=0
ab_session_info "$AGENT_BROWSER_BIN" "$NODE_BIN" "$SCRIPT_DIR/json.mjs" "$SESSION" || SESSION_INFO_STATUS=$?
if [ "$SESSION_INFO_STATUS" -eq 1 ]; then
  echo "✗ Could not inspect browser session $SESSION; re-run connect.sh." >&2
  exit 8
fi
if [ "$SESSION_INFO_STATUS" -ne 0 ]; then
  echo "✗ Browser diagnostics did not match session $SESSION; re-run connect.sh." >&2
  exit 8
fi
if [ "$AB_SESSION_ACTIVE" != "1" ]; then
  echo "✗ Browser session $SESSION is inactive; re-run connect.sh instead of letting this wrapper reconnect implicitly." >&2
  exit 8
fi

# `session info` is the one call that does not restart a version-mismatched
# daemon, so it is where the mismatch gets caught. The next browser command
# would restart the daemon mid-dispatch, which drops the CDP attachment and can
# launch a substitute Chrome; connect.sh does the swap deliberately instead.
DAEMON_VERSION="$AB_SESSION_VERSION"
CLI_VERSION="$(ab_cli_version "$AGENT_BROWSER_BIN" 2>/dev/null || true)"
if [ -n "$DAEMON_VERSION" ] && [ -n "$CLI_VERSION" ] && [ "$DAEMON_VERSION" != "$CLI_VERSION" ]; then
  ab_log_event "$DIR" version-mismatch "daemon=$DAEMON_VERSION cli=$CLI_VERSION command=${1:-}"
  echo "✗ agent-browser was upgraded ($DAEMON_VERSION → $CLI_VERSION) while session $SESSION stayed attached. Running this command would restart the daemon and could launch a substitute Chrome; re-run connect.sh to re-attach once, deliberately." >&2
  exit 8
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

if ! read_tab_state; then
  echo "✗ Could not verify the pinned target; re-run connect.sh to recover it safely." >&2
  exit 8
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
    ab_log_event "$DIR" drift-restored "phase=pre active=${PRE_ACTIVE:-none} owned=$OWNED_TARGET_ID command=${1:-} (Page.bringToFront)"
    echo "! Browser binding had drifted; restored the owned target before running the command. This brought the tab to the front of Chrome. Drift means a bare agent-browser command touched session $SESSION; find and stop it." >&2
  else
    ab_log_event "$DIR" target-gone "phase=pre owned=$OWNED_TARGET_ID command=${1:-}"
    echo "✗ The owned browser target is gone; re-run connect.sh to create exactly one replacement." >&2
    exit 8
  fi
fi

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
