#!/usr/bin/env bash
# Release this agent's exact owned target and task-owned session state.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
. "$SCRIPT_DIR/lib.sh"

usage() {
  echo "usage: cleanup.sh [--close-tab] <session>" >&2
}

SESSION=""
CLOSE_TAB=0
while [ "$#" -gt 0 ]; do
  case "$1" in
    --close-tab) CLOSE_TAB=1 ;;
    -*) usage; exit 2 ;;
    *)
      if [ -n "$SESSION" ]; then
        usage
        exit 2
      fi
      SESSION="$1"
      ;;
  esac
  shift
done
if [ -z "$SESSION" ]; then
  usage
  exit 2
fi
if ! ab_validate_session "$SESSION"; then
  echo "✗ Invalid session '$SESSION'; refusing to construct cleanup paths." >&2
  exit 2
fi

ROOT="$(ab_wrapper_root)"
case "$ROOT" in
  /*) ;;
  *)
    echo "✗ Wrapper root must be an absolute path: $ROOT" >&2
    exit 2
    ;;
esac
if ! ab_prepare_private_dir "$ROOT"; then
  echo "✗ Wrapper root is unsafe or not owned by this user: $ROOT" >&2
  exit 5
fi

DIR="$ROOT/$SESSION"
META="$DIR/session.meta"
if { [ -e "$DIR" ] || [ -L "$DIR" ]; } && ! ab_owned_directory "$DIR"; then
  echo "✗ Session wrapper path is unsafe or not owned by this user: $DIR" >&2
  exit 5
fi
if [ -L "$META" ]; then
  echo "✗ Refusing to read symlinked session metadata: $META" >&2
  exit 5
fi
SESSION_LOCK_KEY="$(ab_session_lock_key "$SESSION")" || {
  echo "✗ A SHA-256 utility is required to lock this browser session." >&2
  exit 3
}
if ! ab_acquire_lock "$ROOT" "$SESSION_LOCK_KEY"; then
  echo "✗ Timed out waiting for another command in browser session $SESSION." >&2
  exit 5
fi
release_owner_lock() {
  ab_release_lock || true
}
trap release_owner_lock EXIT
trap 'release_owner_lock; exit 130' INT TERM

# Exactly the same ownership check dispatch.sh makes, from the same
# implementation. The two used to be separate transcriptions of one invariant
# that had already drifted apart: dispatch hard-failed on a malformed CDP URL
# where cleanup silently treated it as merely unproven.
PROVEN_TARGET_ID=""
OWNED_TARGET_ID=""
PORT=""
META_SOCKET_DIR=""
if ab_load_meta "$META" "$SESSION" 1; then
  PROVEN_TARGET_ID="$AB_META_OWNED_TARGET_ID"
  OWNED_TARGET_ID="$AB_META_OWNED_TARGET_ID"
  PORT="$AB_META_PORT"
  META_SOCKET_DIR="$AB_META_SOCKET_DIR"
else
  # Unproven is not the same as absent: a target id may still be recorded in a
  # file whose ownership cannot be verified, and the operator should hear that
  # every Chrome target is being preserved rather than that nothing was found.
  OWNED_TARGET_ID="$(ab_meta_value "$META" owned_target_id 2>/dev/null || true)"
  META_SOCKET_DIR="$(ab_meta_value "$META" socket_dir 2>/dev/null || true)"
  PORT="$(ab_normalize_port "$(ab_meta_value "$META" port 2>/dev/null || printf '%s' "${AB_CDP_PORT:-9222}")" 2>/dev/null || true)"
fi
if [ "$CLOSE_TAB" -eq 1 ] && [ -n "$OWNED_TARGET_ID" ] && [ -z "$PROVEN_TARGET_ID" ]; then
  echo "! Session metadata does not prove exact target ownership; every Chrome target will be preserved." >&2
fi
AGENT_BROWSER_BIN="$(command -v agent-browser 2>/dev/null || true)"
if [ -z "$AGENT_BROWSER_BIN" ] || [ "${AGENT_BROWSER_BIN#/}" = "$AGENT_BROWSER_BIN" ] || [ ! -x "$AGENT_BROWSER_BIN" ]; then
  echo "✗ agent-browser is not an executable on PATH; the live session cannot be detached safely." >&2
  echo "  Wrapper retained at $DIR for recovery." >&2
  exit 3
fi
NODE_BIN="$(command -v node 2>/dev/null || true)"
if [ -z "$NODE_BIN" ] || [ "${NODE_BIN#/}" = "$NODE_BIN" ] || [ ! -x "$NODE_BIN" ]; then
  echo "✗ node is required to validate browser session ownership; recovery artifacts were retained." >&2
  exit 3
fi

# A temp file rather than a process substitution: output from `2> >(...)` can
# arrive after the script has already moved on, so a diagnostic could be lost or
# interleaved with the line that replaced it.
SESSION_INFO_ERR="$ROOT/.cleanup-$SESSION.$$.err"
: > "$SESSION_INFO_ERR"
SESSION_INFO_STATUS=0
ab_session_info "$AGENT_BROWSER_BIN" "$NODE_BIN" "$SCRIPT_DIR/json.mjs" "$SESSION" "$SESSION_INFO_ERR" \
  || SESSION_INFO_STATUS=$?
if [ "$SESSION_INFO_STATUS" -eq 1 ]; then
  echo "✗ Could not inspect session $SESSION; wrapper and bindings were retained." >&2
  [ ! -s "$SESSION_INFO_ERR" ] || sed 's/^/  /' "$SESSION_INFO_ERR" >&2
  rm -f "$SESSION_INFO_ERR"
  exit 5
fi
rm -f "$SESSION_INFO_ERR"
if [ "$SESSION_INFO_STATUS" -ne 0 ]; then
  echo "✗ agent-browser returned mismatched session diagnostics; wrapper and bindings were retained." >&2
  exit 5
fi
ACTIVE="$AB_SESSION_ACTIVE"
PID="$AB_SESSION_PID"
PAGE_COUNT="$AB_SESSION_PAGE_COUNT"
SOCKET_DIR="$AB_SESSION_SOCKET_DIR"
[ -n "$SOCKET_DIR" ] || SOCKET_DIR="$META_SOCKET_DIR"
[ -n "$SOCKET_DIR" ] || SOCKET_DIR="$(ab_default_socket_dir)"

HAD_TARGET_BINDING=0
[ ! -e "$SOCKET_DIR/$SESSION.target" ] || HAD_TARGET_BINDING=1
TAB_CLOSED=0
TAB_MAY_REMAIN=0
ROUTE_COMMAND_FAILED=0

if [ "$ACTIVE" = "1" ] && [ -n "$PID" ] && [ -n "$PORT" ]; then
  CONNECTION_STATE=1
  if ab_pid_has_cdp_connection "$PID" "$PORT"; then
    CONNECTION_STATE=0
  else
    CONNECTION_STATE=$?
  fi

  if [ "$CONNECTION_STATE" -eq 0 ]; then
    # Omit --cdp during teardown. Cleanup must use the already-running daemon
    # rather than creating a new Chrome approval merely to close an old target.
    if ! "$AGENT_BROWSER_BIN" --session "$SESSION" network unroute >/dev/null 2>&1; then
      ROUTE_COMMAND_FAILED=1
    fi

    if [ "$CLOSE_TAB" -eq 1 ]; then
      if [ -n "$PROVEN_TARGET_ID" ]; then
        OWNED_PRESENT=""
        if TAB_LIST="$("$AGENT_BROWSER_BIN" --session "$SESSION" tab list --json 2>/dev/null)" \
          && ab_tab_state "$NODE_BIN" "$SCRIPT_DIR/json.mjs" "$PROVEN_TARGET_ID" "$TAB_LIST"; then
          OWNED_PRESENT="$AB_TAB_OWNED_PRESENT"
        fi
        if [ "$OWNED_PRESENT" = "0" ]; then
          : # The exact owned target is already gone; foreign targets stay untouched.
        elif "$AGENT_BROWSER_BIN" --session "$SESSION" tab close "$PROVEN_TARGET_ID" >/dev/null 2>&1; then
          TAB_CLOSED=1
        else
          TAB_MAY_REMAIN=1
        fi
      else
        # Missing, legacy, or inconsistent metadata is insufficient ownership proof.
        # Detach the daemon, but preserve every Chrome target for manual recovery.
        TAB_MAY_REMAIN=1
      fi
    fi
  elif [ "$CLOSE_TAB" -eq 1 ] && [ "$PAGE_COUNT" -gt 0 ]; then
    TAB_MAY_REMAIN=1
    if [ "$CONNECTION_STATE" -eq 2 ]; then
      echo "! lsof is unavailable, so cleanup will not risk reconnecting to Chrome." >&2
    else
      echo "! The daemon no longer has a CDP connection; cleanup will not open a new approval." >&2
    fi
  fi
elif [ "$CLOSE_TAB" -eq 1 ] && { [ "$PAGE_COUNT" -gt 0 ] || [ "$HAD_TARGET_BINDING" -eq 1 ]; }; then
  TAB_MAY_REMAIN=1
  if [ "$ACTIVE" = "0" ]; then
    echo "! No live daemon remains to prove that the previously pinned target was closed." >&2
  fi
fi

CLOSE_OK=1
if [ "$ACTIVE" = "1" ]; then
  if ! "$AGENT_BROWSER_BIN" --session "$SESSION" close >/dev/null 2>&1; then
    CLOSE_OK=0
  fi
fi
if [ "$CLOSE_OK" -eq 0 ]; then
  echo "✗ Could not stop session $SESSION; wrapper and bindings were retained for recovery." >&2
  exit 5
fi

ARTIFACTS_OK=1
if ! ab_remove_session_files "$SOCKET_DIR" "$SESSION"; then
  ARTIFACTS_OK=0
fi

# Summarize and archive the session's event log before the directory goes.
# Each counted event is one that could have moved Chrome's visible tab, which
# is what a user sharing the browser with several agents wants to audit.
EVENTS_SUMMARY=""
if [ -f "$DIR/events.log" ] && [ ! -L "$DIR/events.log" ]; then
  EVENTS_SUMMARY="$(awk '
    { counts[$3]++ }
    END {
      printf "attach=%d tab-new=%d drift-restored=%d target-gone=%d page-count-grew=%d",
        counts["attach"], counts["tab-new"], counts["drift-restored"], counts["target-gone"], counts["page-count-grew"]
    }' "$DIR/events.log" 2>/dev/null || true)"
  HISTORY_DIR="$ROOT/.history"
  if ab_prepare_private_dir "$HISTORY_DIR"; then
    cp -p "$DIR/events.log" "$HISTORY_DIR/$SESSION-$(date -u +%Y%m%dT%H%M%SZ).log" 2>/dev/null || true
  fi
fi
[ ! -e "$DIR" ] || rm -rf "$DIR"

if [ "$TAB_MAY_REMAIN" -eq 1 ]; then
  echo "! Session $SESSION was detached and routes are inactive, but its owned target could not be closed without reconnecting." >&2
  echo "  Close that target manually if it is still visible; no new Chrome approval was requested." >&2
  [ "$ARTIFACTS_OK" -eq 1 ] || echo "  Persistent binding files also require manual removal from: $SOCKET_DIR" >&2
  exit 6
fi
if [ "$ARTIFACTS_OK" -eq 0 ]; then
  echo "✗ Session stopped, but its socket directory was unsafe or not owned by this user: $SOCKET_DIR" >&2
  exit 7
fi
if [ "$ROUTE_COMMAND_FAILED" -eq 1 ]; then
  echo "! Explicit route removal failed, but detaching the CDP session disabled its interception." >&2
fi

if [ "$CLOSE_TAB" -eq 0 ]; then
  echo "✓ Session $SESSION released (routes cleared, daemon stopped, pinned tab preserved)"
elif [ "$TAB_CLOSED" -eq 1 ]; then
  echo "✓ Session $SESSION released (routes cleared, pinned tab closed, user's Chrome untouched)"
else
  echo "✓ Session $SESSION released (owned target was already gone, user's Chrome untouched)"
fi
[ -z "$EVENTS_SUMMARY" ] || echo "  foreground-moving events this session: $EVENTS_SUMMARY (log archived under $ROOT/.history)"
