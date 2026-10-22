#!/usr/bin/env bash
# Bind this agent to one pinned tab in the user's already-running Chrome.
# Prints a wrapper path; every later agent-browser command goes through it.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
. "$SCRIPT_DIR/lib.sh"

usage() {
  echo "usage: connect.sh [label] [--url <url>] [--port 9222] [--session <existing>] [--slot <name>] [--[no-]react] [--[no-]persistent] [--[no-]auto-approve] [--idle-timeout <seconds>]" >&2
}

die_usage() {
  printf '✗ %s\n' "$1" >&2
  usage
  exit 2
}

PORT_RAW="${AB_CDP_PORT:-9222}"
LABEL=""
URL=""
REUSE="${AB_SESSION_ID:-}"
SLOT="default"
# Empty means inherit, not disable. User-approved policy belongs to the owner
# session, not to the particular task that happens to call connect again.
REQUEST_REACT=""
REQUEST_PERSISTENT=""
REQUEST_AUTO_APPROVE=""
REQUEST_IDLE_TIMEOUT=""
# Internal: the dispatcher passes the URL a closed tab last had, so a persistent
# heal reopens it there. Unlike --url it never navigates a tab that survived.
REPLACE_URL=""
RECOVER=0

while [ "$#" -gt 0 ]; do
  case "$1" in
    --url|--port|--session|--slot|--replace-url|--idle-timeout)
      [ "$#" -ge 2 ] || die_usage "$1 requires a value"
      case "$1" in
        --url) URL="$2" ;;
        --replace-url) REPLACE_URL="$2" ;;
        --port) PORT_RAW="$2" ;;
        --session) REUSE="$2" ;;
        --slot) SLOT="$2" ;;
        --idle-timeout)
          REQUEST_IDLE_TIMEOUT="$(ab_normalize_idle_timeout "$2")" || die_usage "idle timeout must be an integer from 0 to 2147483647 seconds"
          ;;
      esac
      shift 2
      ;;
    --recover) RECOVER=1; shift ;;
    --react)
      REQUEST_REACT=1
      shift
      ;;
    --persistent)
      REQUEST_PERSISTENT=1
      shift
      ;;
    --auto-approve)
      REQUEST_AUTO_APPROVE=1
      shift
      ;;
    --no-react) REQUEST_REACT=0; shift ;;
    --no-persistent) REQUEST_PERSISTENT=0; shift ;;
    --no-auto-approve) REQUEST_AUTO_APPROVE=0; shift ;;
    -h|--help)
      usage
      exit 0
      ;;
    --)
      shift
      [ "$#" -le 1 ] || die_usage "expected at most one label"
      [ "$#" -eq 0 ] || LABEL="$1"
      break
      ;;
    -*) die_usage "unknown option: $1" ;;
    *)
      [ -z "$LABEL" ] || die_usage "expected at most one label"
      LABEL="$1"
      shift
      ;;
  esac
done

if [ "$RECOVER" -eq 1 ] && { [ -n "$REQUEST_PERSISTENT" ] || [ -n "$REQUEST_REACT" ] \
  || [ -n "$REQUEST_AUTO_APPROVE" ] || [ -n "$REQUEST_IDLE_TIMEOUT" ]; }; then
  die_usage "internal recovery cannot request policy changes"
fi

case "$URL" in
  -*) die_usage "URL values may not begin with '-'" ;;
esac
case "$REPLACE_URL" in
  ''|about:blank|http://*|https://*) ;;
  *) die_usage "--replace-url must be an http(s) URL or about:blank" ;;
esac

# The React DevTools hook is an init script registered ONCE, when the daemon
# connects — not on every navigation. Exporting it here makes the `react …`
# commands work for the whole session at the cost of a single Chrome approval.
# Passing `--enable react-devtools` to a later `open` re-registers the hook and
# forces the daemon to dial a new WebSocket (its launch-affecting flags differ
# from the previous invocation's): since the wrapper brackets the command with
# `tab list`, that is two reconnects — two extra approval dialogs for the user —
# on every page profiled that way. Through 0.37.1 each of those sockets also
# stayed established; 0.38 closes the old one (upstream #1739), so the cost
# today is the dialog, not the leak.
# Exported below, after resolving the saved session policy.

AGENT_BROWSER_BIN="$(command -v agent-browser 2>/dev/null || true)"
if [ -z "$AGENT_BROWSER_BIN" ] || [ "${AGENT_BROWSER_BIN#/}" = "$AGENT_BROWSER_BIN" ] || [ ! -x "$AGENT_BROWSER_BIN" ]; then
  echo "✗ agent-browser is not an executable on PATH. Install it: npm i -g agent-browser && agent-browser install" >&2
  exit 3
fi
NODE_BIN="$(command -v node 2>/dev/null || true)"
if [ -z "$NODE_BIN" ] || [ "${NODE_BIN#/}" = "$NODE_BIN" ] || [ ! -x "$NODE_BIN" ]; then
  echo "✗ node is required to validate agent-browser's structured session and target state." >&2
  exit 3
fi

PORT="$(ab_normalize_port "$PORT_RAW")" || die_usage "invalid CDP port: $PORT_RAW"
ab_validate_slot "$SLOT" || die_usage "invalid slot '$SLOT'; start with an ASCII letter/number and use only letters, numbers, hyphens, or underscores (28 characters max)"
SLOT="$(ab_sanitize_component "$SLOT")"

port_open() { (exec 3<>"/dev/tcp/127.0.0.1/$PORT") 2>/dev/null; }

PORT_READY=0
if port_open; then
  PORT_READY=1
else
  WAIT_ATTEMPTS="${AB_CONNECT_PORT_ATTEMPTS:-10}"
  WAIT_DELAY="${AB_CONNECT_PORT_DELAY_SECONDS:-3}"
  case "$WAIT_ATTEMPTS" in ''|*[!0-9]*) die_usage "port wait attempts must be a non-negative integer" ;; esac
  case "$WAIT_DELAY" in ''|*[!0-9]*) die_usage "port wait delay must be a non-negative integer" ;; esac
  for ((attempt = 0; attempt < WAIT_ATTEMPTS; attempt += 1)); do
    echo "• Waiting for 127.0.0.1:$PORT (attempt $((attempt + 1)) of $WAIT_ATTEMPTS)..." >&2
    sleep "$WAIT_DELAY"
    if port_open; then
      PORT_READY=1
      break
    fi
  done
fi

if [ "$PORT_READY" -eq 0 ]; then
  cat >&2 <<MSG
✗ Nothing is listening on 127.0.0.1:$PORT.

Ask the user to enable their existing Chrome:
  1. Open chrome://inspect/#remote-debugging
  2. Tick "Allow remote debugging for this browser instance"
  3. Wait until it shows "Server running at: 127.0.0.1:$PORT"
  4. Re-run this script

Keep using the user's Chrome; do not launch a substitute browser.
MSG
  exit 4
fi

CDP_URL="$(ab_resolve_cdp_url "$PORT")" || exit 4

if [ -z "$LABEL" ]; then
  LABEL="$(basename "$(git rev-parse --show-toplevel 2>/dev/null || pwd)")"
fi
LABEL="$(ab_sanitize_component "$LABEL")"

if [ -n "$REUSE" ]; then
  SESSION="$REUSE"
  OWNER_ID="explicit:$SESSION"
  OWNER_KEY="$(ab_owner_key "$OWNER_ID" "$SLOT" "$PORT")" || {
    echo "✗ A SHA-256 utility is required to derive the browser owner key." >&2
    exit 3
  }
else
  # Harness session ids, most specific first. The skill's own override wins,
  # then pi, then Claude Code. Codex and opencode export AB_CONNECT_ID once.
  CONNECT_ID="${AB_CONNECT_ID:-${PI_SESSION_ID:-${CLAUDE_CODE_SESSION_ID:-}}}"
  if [ -z "$CONNECT_ID" ]; then
    die_usage "a stable owner id is required: set AB_CONNECT_ID, or run under a harness that exports PI_SESSION_ID or CLAUDE_CODE_SESSION_ID, or pass --session <id>"
  fi
  OWNER_ID="$CONNECT_ID"
  OWNER_KEY="$(ab_owner_key "$OWNER_ID" "$SLOT" "$PORT")" || {
    echo "✗ A SHA-256 utility is required to derive the browser owner key." >&2
    exit 3
  }
  SESSION="ab-${OWNER_KEY:0:24}"
fi

ab_validate_session "$SESSION" || die_usage \
  "invalid session '$SESSION'; start with an ASCII letter/number and use only letters, numbers, hyphens, or underscores (64 characters max)"
SESSION_LOCK_KEY="$(ab_session_lock_key "$SESSION")" || {
  echo "✗ A SHA-256 utility is required to lock the browser session." >&2
  exit 3
}

ROOT="$(ab_wrapper_root)"
case "$ROOT" in
  /*) ;;
  *)
    echo "✗ Wrapper root must be an absolute path: $ROOT" >&2
    exit 2
    ;;
esac

# The default root sits in a cache directory that may not exist yet; only the
# root itself has to be private, its parents are ordinary user directories.
mkdir -p "$(dirname "$ROOT")" 2>/dev/null || true
if ! ab_prepare_private_dir "$ROOT"; then
  echo "✗ Wrapper root is not a private directory owned by this user: $ROOT" >&2
  exit 5
fi

if ! ab_acquire_lock "$ROOT" "$SESSION_LOCK_KEY"; then
  echo "✗ Timed out waiting for another browser operation owned by this session." >&2
  exit 5
fi
release_owner_lock() {
  ab_release_lock || true
}
trap release_owner_lock EXIT
trap 'release_owner_lock; exit 130' INT TERM

DIR="$ROOT/$SESSION"
AB="$DIR/ab"
META="$DIR/session.meta"
DIR_EXISTED=0
[ -d "$DIR" ] && [ ! -L "$DIR" ] && DIR_EXISTED=1
if { [ -e "$DIR" ] || [ -L "$DIR" ]; } && ! ab_owned_directory "$DIR"; then
  echo "✗ Session wrapper path is unsafe or not owned by this user: $DIR" >&2
  exit 5
fi
if [ -L "$AB" ] || [ -L "$META" ]; then
  echo "✗ Refusing to replace a symlink inside the private session directory: $DIR" >&2
  exit 5
fi
EXISTING_OWNER="$(ab_meta_value "$META" owner_key 2>/dev/null || true)"
if [ -n "$EXISTING_OWNER" ] && [ "$EXISTING_OWNER" != "$OWNER_KEY" ]; then
  echo "✗ Session metadata belongs to another browser owner; refusing to reuse $SESSION." >&2
  exit 5
fi
# The target this session owned before this run. A re-run of connect must
# never adopt whatever tab the daemon happens to have active: if the binding
# drifted (a bare agent-browser command switched it), the active tab may belong
# to the user or to another agent, and navigating it would hijack their page.
PREV_OWNED_TARGET_ID="$(ab_meta_value "$META" owned_target_id 2>/dev/null || true)"
[[ "$PREV_OWNED_TARGET_ID" =~ ^[A-Za-z0-9_-]+$ ]] || PREV_OWNED_TARGET_ID=""

SETTINGS_META=/dev/null
if ab_load_meta "$META" "$SESSION" 0 && [ "$AB_META_OWNER_KEY" = "$OWNER_KEY" ]; then
  SETTINGS_META="$META"
fi
if [ "$RECOVER" -eq 1 ] && [ "$SETTINGS_META" = /dev/null ]; then
  echo "✗ Recovery requires current metadata proving this browser owner; no connection was attempted." >&2
  exit 5
fi
if [ "$RECOVER" -eq 1 ] && ab_native_migration_required "$META"; then
  echo "✗ Recovery requires explicit connect to migrate idle configuration; no connection was attempted." >&2
  exit 8
fi
ab_configure_policy "$SETTINGS_META" "$REQUEST_PERSISTENT" "$REQUEST_REACT" "$REQUEST_AUTO_APPROVE" "$REQUEST_IDLE_TIMEOUT" || exit $?
if [ "$RECOVER" -eq 1 ] && [ "$AB_POLICY_PERSISTENT" != 1 ]; then
  echo "✗ Persistent recovery was revoked; no connection was attempted." >&2
  exit 5
fi
# A released owner must not be recreated by a pending recovery.
if ! ab_prepare_private_dir "$DIR"; then
  echo "✗ Session wrapper path is unsafe or not owned by this user: $DIR" >&2
  exit 5
fi
if [ "$AB_POLICY_REACT" -eq 1 ]; then
  export AGENT_BROWSER_ENABLE="react-devtools"
else
  unset AGENT_BROWSER_ENABLE
fi

DESIRED_IDLE_TIMEOUT_MS="$AGENT_BROWSER_IDLE_TIMEOUT_MS"
PRE_TRANSITION_IDLE_TIMEOUT_MS="$DESIRED_IDLE_TIMEOUT_MS"
TIMEOUT_TRANSITION=0
if [ "$SETTINGS_META" != /dev/null ]; then
  SAVED_IDLE_SECONDS="$(ab_meta_value "$META" idle_timeout_seconds 2>/dev/null || true)"
  if grep -Eq '^(lease_token|last_used_at)=' "$META" \
    || ! SAVED_IDLE_SECONDS="$(ab_normalize_idle_timeout "$SAVED_IDLE_SECONDS" 2>/dev/null)"; then
    # Legacy owners have no proof of native configuration. Only diagnostics and
    # daemon-only stop may use this fixed setting before deliberate migration.
    PRE_TRANSITION_IDLE_TIMEOUT_MS=0
    TIMEOUT_TRANSITION=1
  else
    PRE_TRANSITION_IDLE_TIMEOUT_MS="$((SAVED_IDLE_SECONDS * 1000))"
    [ "$PRE_TRANSITION_IDLE_TIMEOUT_MS" = "$DESIRED_IDLE_TIMEOUT_MS" ] || TIMEOUT_TRANSITION=1
  fi
fi
export AGENT_BROWSER_IDLE_TIMEOUT_MS="$PRE_TRANSITION_IDLE_TIMEOUT_MS"

if ! ab_session_info "$AGENT_BROWSER_BIN" "$NODE_BIN" "$SCRIPT_DIR/json.mjs" "$SESSION" "$DIR/session-info.err"; then
  echo "✗ Could not validate agent-browser session state; no browser connection was attempted." >&2
  [ ! -s "$DIR/session-info.err" ] || sed 's/^/  /' "$DIR/session-info.err" >&2
  rm -f "$DIR/session-info.err"
  [ "$DIR_EXISTED" -eq 1 ] || rm -rf "$DIR"
  exit 5
fi
rm -f "$DIR/session-info.err"
SESSION_WAS_ACTIVE="$AB_SESSION_ACTIVE"
SOCKET_DIR="$AB_SESSION_SOCKET_DIR"
[ -n "$SOCKET_DIR" ] || SOCKET_DIR="$(ab_default_socket_dir)"

# Upgrading agent-browser leaves the previous session's daemon on the old
# version. The first BROWSER command to reach it prints "Daemon version mismatch
# detected, restarting..." and restarts the daemon — and a restarted daemon loses
# its external CDP attachment: without the connection flags it LAUNCHES a Chrome
# of its own instead of using the user's (measured 2026-09-16, 0.37.1 → 0.38.0).
# `session info` restarts nothing and already reports the daemon's version, so
# the swap happens here, deliberately, rather than becoming a relaunch in the
# middle of some other command.
DAEMON_VERSION="$AB_SESSION_VERSION"
CLI_VERSION="$(ab_cli_version "$AGENT_BROWSER_BIN" 2>/dev/null || true)"
if [ "$SESSION_WAS_ACTIVE" = 1 ] && [ "$TIMEOUT_TRANSITION" = 1 ]; then
  if ! ab_stop_daemon "$AGENT_BROWSER_BIN" "$NODE_BIN" "$SCRIPT_DIR/json.mjs" "$SESSION"; then
    echo "✗ Could not stop the daemon for an idle configuration change; existing state was retained." >&2
    exit 5
  fi
  SESSION_WAS_ACTIVE=0
  ab_log_event "$DIR" timeout-change "previous=$PRE_TRANSITION_IDLE_TIMEOUT_MS desired=$DESIRED_IDLE_TIMEOUT_MS"
elif [ "$SESSION_WAS_ACTIVE" = "1" ] && [ -n "$DAEMON_VERSION" ] && [ -n "$CLI_VERSION" ] \
  && [ "$DAEMON_VERSION" != "$CLI_VERSION" ]; then
  ab_log_event "$DIR" version-mismatch "daemon=$DAEMON_VERSION cli=$CLI_VERSION action=stopped-stale-daemon"
  cat >&2 <<MSG
! Session $SESSION is held by an agent-browser $DAEMON_VERSION daemon while the CLI is $CLI_VERSION.
  Stopping the stale daemon and attaching once with the current version. Letting a
  browser command hit it instead would restart it and could launch a substitute
  Chrome. Chrome may ask to approve this one new connection.
MSG
  # Only the daemon is stopped. The session sidecars (`<session>.target`) are
  # left in place on purpose: they are what lets the replacement daemon rebind to
  # the SAME target instead of opening another tab in the user's window.
  if ! ab_stop_daemon "$AGENT_BROWSER_BIN" "$NODE_BIN" "$SCRIPT_DIR/json.mjs" "$SESSION"; then
    echo "✗ Could not stop the stale daemon; existing session state was retained." >&2
    exit 5
  fi
  SESSION_WAS_ACTIVE=0
  STALE_DAEMON_SWAPPED=1
fi

export AGENT_BROWSER_IDLE_TIMEOUT_MS="$DESIRED_IDLE_TIMEOUT_MS"

AB_BACKUP=""
META_BACKUP=""
if [ -f "$AB" ]; then
  AB_BACKUP="$DIR/ab.backup.$$"
  if ! cp -p "$AB" "$AB_BACKUP"; then
    rm -f "$AB_BACKUP"
    echo "✗ Could not preserve the existing session wrapper." >&2
    exit 5
  fi
fi
if [ -f "$META" ]; then
  META_BACKUP="$DIR/session.meta.backup.$$"
  if ! cp -p "$META" "$META_BACKUP"; then
    rm -f "$AB_BACKUP"
    echo "✗ Could not preserve existing session metadata." >&2
    exit 5
  fi
fi

# --auto-approve: see ab_start_approver in lib.sh. Scoped to this attach.
start_approver() {
  [ "$AB_POLICY_AUTO_APPROVE" -eq 1 ] || return 0
  if [ "$SESSION_WAS_ACTIVE" -eq 1 ]; then
    # A live reused socket needs no approval. Only cover a redial that lsof
    # positively identifies; unknown connection state is not permission to click.
    local connection_state=0
    ab_is_uint "$AB_SESSION_PID" || return 0
    ab_pid_has_cdp_connection "$AB_SESSION_PID" "$PORT" || connection_state=$?
    [ "$connection_state" -eq 1 ] || return 0
  fi
  ab_start_approver "$DIR" "$SCRIPT_DIR"
}
stop_approver() {
  ab_stop_approver "$DIR"
}

COMMITTED=0
META_PENDING="$DIR/session.meta.pending.$$"
ATTACH_ESTABLISHED=0
ATTACH_DAEMON_PID=""
record_attach_identity() {
  if ab_session_info "$AGENT_BROWSER_BIN" "$NODE_BIN" "$SCRIPT_DIR/json.mjs" "$SESSION" \
    && [ "$AB_SESSION_ACTIVE" = 1 ] && [ "$AB_SESSION_SOCKET_DIR" = "$SOCKET_DIR" ]; then
    ATTACH_DAEMON_PID="$AB_SESSION_PID"
  fi
}
TARGET_DISCOVERY_SAFE=0
OWNED_TARGET_ID=""
rollback() {
  local status=$?
  local rollback_target
  trap - EXIT INT TERM
  stop_approver
  rm -f "$DIR/attach.err" "$DIR/navigation.err" "$DIR/target.err" "$DIR/rebind.err" "$DIR/ab.tmp.$$" "$META_PENDING" 2>/dev/null || true

  if [ "$COMMITTED" -eq 0 ]; then
    if [ "$SESSION_WAS_ACTIVE" -eq 0 ]; then
      if [ "$ATTACH_ESTABLISHED" -eq 1 ] && [ "$TARGET_DISCOVERY_SAFE" -eq 1 ]; then
        rollback_target="$OWNED_TARGET_ID"
        if [ -n "$rollback_target" ] && [ "$rollback_target" = "$PREV_OWNED_TARGET_ID" ]; then
          : # A failed re-attachment must preserve the previously owned page.
        elif ab_session_info "$AGENT_BROWSER_BIN" "$NODE_BIN" "$SCRIPT_DIR/json.mjs" "$SESSION" \
          && [ "$AB_SESSION_ACTIVE" = 1 ] && [ "$AB_SESSION_SOCKET_DIR" = "$SOCKET_DIR" ] \
          && ab_is_uint "$ATTACH_DAEMON_PID" && [ "$ATTACH_DAEMON_PID" -gt 0 ] \
          && [ "$AB_SESSION_PID" = "$ATTACH_DAEMON_PID" ] \
          && ab_pid_has_cdp_connection "$AB_SESSION_PID" "$PORT"; then
          ab_admin_existing "$NODE_BIN" "$SCRIPT_DIR/admin.mjs" "$SESSION" "$AB_SESSION_SOCKET_DIR" "$AB_SESSION_PID" \
            discard-new-attach-target "$rollback_target" "$PREV_OWNED_TARGET_ID" >/dev/null \
            || echo "! Attachment target cleanup is unverified; rollback will still stop the daemon." >&2
        else
          echo "! Failed attach continuity is unproven; rollback preserved all Chrome targets." >&2
        fi
      fi
      if ! ab_stop_daemon "$AGENT_BROWSER_BIN" "$NODE_BIN" "$SCRIPT_DIR/json.mjs" "$SESSION"; then
        # Neither the old policy nor an executable handle may authorize commands
        # against an uncommitted daemon whose shutdown could not be proven.
        [ ! -f "$META" ] || mv -f "$META" "$DIR/session.meta.unverified.$$"
        rm -f "$AB"
        echo "✗ Replacement shutdown is unverified; wrapper disabled and recovery artifacts retained in $DIR." >&2
        release_owner_lock
        exit 5
      fi
      # With a previously owned tab, the `<session>.target` sidecar is what lets
      # the next attempt rebind that same tab instead of opening another one;
      # keep it, as the version-swap path does.
      [ -n "$PREV_OWNED_TARGET_ID" ] || ab_remove_session_files "$SOCKET_DIR" "$SESSION" || true
    fi

    if [ "$DIR_EXISTED" -eq 0 ]; then
      rm -rf "$DIR"
    else
      if [ -n "$AB_BACKUP" ] && [ -f "$AB_BACKUP" ]; then
        mv -f "$AB_BACKUP" "$AB"
      else
        rm -f "$AB"
      fi
      if [ -n "$META_BACKUP" ] && [ -f "$META_BACKUP" ]; then
        mv -f "$META_BACKUP" "$META"
      else
        rm -f "$META"
      fi
    fi
  fi
  release_owner_lock
  exit "$status"
}
trap rollback EXIT
trap 'exit 130' INT TERM

AB_TMP="$DIR/ab.tmp.$$"
{
  printf '%s\n' '#!/usr/bin/env bash'
  printf '# Owner lock and target verification are enforced by the dispatcher.\n'
  printf 'exec bash %q %q %q %q "$@"\n' "$SCRIPT_DIR/dispatch.sh" "$META" "$AGENT_BROWSER_BIN" "$NODE_BIN"
} > "$AB_TMP"
chmod 700 "$AB_TMP"
mv -f "$AB_TMP" "$AB"

CREATED_AT="$(ab_meta_value "$META" created_at 2>/dev/null || true)"
[ -n "$CREATED_AT" ] || CREATED_AT="$(date +%s)"
for META_VALUE in "$OWNER_ID" "$OWNER_KEY" "$SESSION" "$LABEL" "$SLOT" "$CDP_URL" "$SOCKET_DIR"; do
  ab_validate_meta_value "$META_VALUE" || {
    echo "✗ Refusing to write unsafe session metadata." >&2
    exit 5
  }
done
{
  printf 'version=%s\n' "$AB_META_VERSION"
  printf 'owner_id=%s\n' "$OWNER_ID"
  printf 'owner_key=%s\n' "$OWNER_KEY"
  printf 'session=%s\n' "$SESSION"
  printf 'label=%s\n' "$LABEL"
  printf 'slot=%s\n' "$SLOT"
  printf 'port=%s\n' "$PORT"
  printf 'cdp_url=%s\n' "$CDP_URL"
  printf 'socket_dir=%s\n' "$SOCKET_DIR"
  printf 'owned_target_id=\n'
  printf 'created_at=%s\n' "$CREATED_AT"
  printf 'persistent=%s\n' "$AB_POLICY_PERSISTENT"
  printf 'react=%s\n' "$AB_POLICY_REACT"
  printf 'auto_approve=%s\n' "$AB_POLICY_AUTO_APPROVE"
  printf 'idle_timeout_seconds=%s\n' "$AB_POLICY_IDLE_TIMEOUT_SECONDS"
} > "$META_PENDING"
chmod 600 "$META_PENDING"

if [ "$SESSION_WAS_ACTIVE" -eq 0 ]; then
  echo "• Chrome may show one connection approval. Approve that single prompt; this script will not open retry connections." >&2
fi

browser_command() {
  "$AGENT_BROWSER_BIN" --cdp "$CDP_URL" --pin-tab --session "$SESSION" "$@"
}

TARGET="${URL:-${REPLACE_URL:-about:blank}}"
ATTACH_ERROR=""
start_approver
if BOUND="$(browser_command get url 2>"$DIR/attach.err")"; then
  ATTACH_ESTABLISHED=1
  TARGET_DISCOVERY_SAFE=1
elif [ "${STALE_DAEMON_SWAPPED:-0}" -eq 1 ] \
  && ! grep -q 'tab_gone' "$DIR/attach.err" 2>/dev/null \
  && sleep 2 \
  && BOUND="$(browser_command get url 2>"$DIR/attach.err")"; then
  # One extra attempt exists ONLY here. Everywhere else the script attaches once
  # and does not insist (blind retries can stack approval dialogs). On this path we are the ones who stopped a daemon that was
  # working, and a freshly started daemon's first command often times out;
  # failing here would leave the user with no session at all.
  ATTACH_ESTABLISHED=1
  TARGET_DISCOVERY_SAFE=1
  echo "! The first command after the version swap timed out; the single retry succeeded." >&2
else
  ATTACH_ERROR="$(cat "$DIR/attach.err" 2>/dev/null || true)"
  if printf '%s' "$ATTACH_ERROR" | grep -q 'tab_gone'; then
    ATTACH_ESTABLISHED=1
    if browser_command tab new "$TARGET" >/dev/null 2>"$DIR/attach.err"; then
      TARGET_DISCOVERY_SAFE=1
      record_attach_identity
      ab_log_event "$DIR" tab-new "reason=tab_gone url=$TARGET (Chrome opens new targets in the foreground)"
    fi
    if [ "$TARGET_DISCOVERY_SAFE" -eq 1 ] \
      && BOUND="$(browser_command get url 2>"$DIR/attach.err")"; then
      # Read right after `tab new`, the URL is still about:blank while the
      # replacement loads; report where it is going, not the blank moment.
      [ "${BOUND//$'\r'/}" != "about:blank" ] || [ "$TARGET" = "about:blank" ] || BOUND="$TARGET (loading)"
    else
      ATTACH_ERROR="$(cat "$DIR/attach.err" 2>/dev/null || true)"
      echo "✗ Reconnected to Chrome but could not replace the closed pinned tab." >&2
      [ -z "$ATTACH_ERROR" ] || printf '  %s\n' "$ATTACH_ERROR" >&2
      exit 5
    fi
  else
    # A refused connection and a pending approval dialog are different failures
    # with different recoveries, and the port was last probed before the endpoint
    # was resolved. Re-probe it now rather than telling the user to approve a
    # dialog that is not there: a browser that quit, crashed, or had remote
    # debugging switched off produces "Connection refused", not a prompt.
    if printf '%s' "$ATTACH_ERROR" | grep -Eq 'Connection refused|os error 61|ConnectionRefused'; then
      if port_open; then
        cat >&2 <<MSG
✗ Chrome is listening on 127.0.0.1:$PORT, but it refused the CDP connection.
  The endpoint this script resolved is no longer valid, which is what a Chrome
  restart looks like: the browser is back, its DevTools endpoint is not the one
  that was there a moment ago. Re-run this same connect command to resolve the
  current endpoint. No blind retries were made.
MSG
      else
        cat >&2 <<MSG
✗ Nothing is listening on 127.0.0.1:$PORT any more; the connection was refused.
  Chrome quit, crashed, or had remote debugging switched off between the port
  check and the attach. This is not an approval dialog — do not wait for one.
  Ask the user to confirm Chrome is running with remote debugging enabled
  (chrome://inspect/#remote-debugging), then re-run this same connect command.
MSG
      fi
      [ -z "$ATTACH_ERROR" ] || printf '  %s\n' "$ATTACH_ERROR" >&2
      exit 4
    fi
    echo "✗ Chrome is listening, but the single CDP connection did not complete." >&2
    [ -z "$ATTACH_ERROR" ] || printf '  %s\n' "$ATTACH_ERROR" >&2
    cat >&2 <<MSG
  If Chrome is showing an approval dialog, approve it and re-run this same
  connect command. The stable session id will be reused; no blind retries were made.
MSG
    exit 5
  fi
fi
stop_approver
rm -f "$DIR/attach.err"

record_attach_identity
BOUND="${BOUND//$'\r'/}"
if [ -z "$BOUND" ]; then
  echo "✗ agent-browser reported success but returned no bound-tab URL." >&2
  exit 5
fi
if [ "${STALE_DAEMON_SWAPPED:-0}" -eq 1 ]; then
  # The daemon this script stopped left its `<session>.target` sidecar behind,
  # so the replacement rebinds to the same tab instead of opening another one.
  ab_log_event "$DIR" attach "mode=reattach-after-upgrade (rebound to the persisted target)"
elif [ "$SESSION_WAS_ACTIVE" -eq 0 ]; then
  # Logged once the bound target is known: a new daemon for a session that
  # already owned a tab rebinds it through the `<session>.target` sidecar
  # (measured 2026-09-25 on 0.38.1 after a killed daemon), and only a first
  # attach opens a new foreground tab.
  ATTACH_LOG_PENDING=1
else
  ab_log_event "$DIR" attach "mode=reused"
fi

# Re-run of connect on a live session: make sure the daemon is still bound to
# the tab this session owns before touching anything. If that tab exists but
# is not active, the binding drifted; switch back to it (this is the one
# Page.bringToFront the recovery costs) instead of adopting a foreign tab.
if [ -n "$PREV_OWNED_TARGET_ID" ]; then
  if PREV_LIST="$(browser_command tab list --json 2>/dev/null)" \
    && ab_tab_state "$NODE_BIN" "$SCRIPT_DIR/json.mjs" "$PREV_OWNED_TARGET_ID" "$PREV_LIST"; then
    PREV_ACTIVE="$AB_TAB_ACTIVE"
    PREV_PRESENT="$AB_TAB_OWNED_PRESENT"
    if [ "$PREV_PRESENT" = "1" ] && [ "$PREV_ACTIVE" != "$PREV_OWNED_TARGET_ID" ]; then
      ATTACH_BOUND_URL="$BOUND"
      if browser_command tab "$PREV_OWNED_TARGET_ID" --json >/dev/null 2>"$DIR/rebind.err" \
        && REBOUND_URL="$(browser_command get url 2>>"$DIR/rebind.err")"; then
        BOUND="${REBOUND_URL//$'\r'/}"
        ab_log_event "$DIR" drift-restored "phase=connect active=${PREV_ACTIVE:-none} owned=$PREV_OWNED_TARGET_ID (Page.bringToFront)"
        if [ "${STALE_DAEMON_SWAPPED:-0}" -eq 1 ]; then
          echo "! Re-attached after the version swap and switched back to this session's own tab (this brought it to the front of Chrome)." >&2
        else
          echo "! Browser binding had drifted to another tab; switched back to the owned target before continuing (this brought it to the front of Chrome)." >&2
        fi
        # Swapping a stale daemon costs a fresh attach, and every fresh attach
        # opens a tab. When the session's own target survived, that new tab is
        # ours and empty — closing it makes the upgrade invisible in the user's
        # window. Three conditions prove ownership: the swap happened in this
        # run, the tab is the one this attach bound to, and it never left
        # about:blank.
        if [ "${STALE_DAEMON_SWAPPED:-0}" -eq 1 ] \
          && [ -n "$PREV_ACTIVE" ] \
          && [ "$ATTACH_BOUND_URL" = "about:blank" ]; then
          if browser_command tab close "$PREV_ACTIVE" >/dev/null 2>&1; then
            ab_log_event "$DIR" tab-closed "reason=daemon-swap target=$PREV_ACTIVE (empty tab this attach opened)"
          else
            echo "! Left the empty tab this re-attach opened; it could not be closed." >&2
          fi
        fi
      else
        echo "✗ The owned target $PREV_OWNED_TARGET_ID still exists but could not be re-selected; refusing to adopt the tab that is active instead." >&2
        [ ! -s "$DIR/rebind.err" ] || sed 's/^/  /' "$DIR/rebind.err" >&2
        rm -f "$DIR/rebind.err"
        exit 5
      fi
      rm -f "$DIR/rebind.err"
    fi
  fi
fi

if [ -n "$URL" ] && [ "$BOUND" != "$URL" ]; then
  ab_log_event "$DIR" navigate "url=$URL"
  if browser_command open "$URL" >/dev/null 2>"$DIR/navigation.err"; then
    if CURRENT="$(browser_command get url 2>"$DIR/navigation.err")" && [ -n "$CURRENT" ]; then
      BOUND="${CURRENT//$'\r'/}"
    else
      echo "! Connected, but could not verify navigation to $URL." >&2
      [ ! -s "$DIR/navigation.err" ] || sed 's/^/  /' "$DIR/navigation.err" >&2
    fi
  else
    echo "! Connected, but navigation to $URL failed." >&2
    [ ! -s "$DIR/navigation.err" ] || sed 's/^/  /' "$DIR/navigation.err" >&2
  fi
  rm -f "$DIR/navigation.err"
fi

if ! TAB_LIST="$(browser_command tab list --json 2>"$DIR/target.err")" \
  || ! ab_tab_state "$NODE_BIN" "$SCRIPT_DIR/json.mjs" "" "$TAB_LIST"; then
  echo "✗ Connected, but could not record the owned target safely." >&2
  [ ! -s "$DIR/target.err" ] || sed 's/^/  /' "$DIR/target.err" >&2
  exit 5
fi
rm -f "$DIR/target.err"
OWNED_TARGET_ID="$AB_TAB_ACTIVE"
if [ -z "$OWNED_TARGET_ID" ] || [[ ! "$OWNED_TARGET_ID" =~ ^[A-Za-z0-9_-]+$ ]]; then
  echo "✗ Connected, but agent-browser reported no active target to own." >&2
  exit 5
fi
if ! ab_set_meta_value "$META_PENDING" owned_target_id "$OWNED_TARGET_ID"; then
  echo "✗ Connected, but could not persist the owned target safely." >&2
  exit 5
fi
if [ "${ATTACH_LOG_PENDING:-0}" -eq 1 ]; then
  if [ -n "$PREV_OWNED_TARGET_ID" ] && [ "$OWNED_TARGET_ID" = "$PREV_OWNED_TARGET_ID" ]; then
    ab_log_event "$DIR" attach "mode=rebound (new daemon, same tab $OWNED_TARGET_ID)"
  else
    ab_log_event "$DIR" attach "mode=fresh (daemon opened a new foreground tab)"
  fi
fi

REACT_STATUS=""
if [ "$AB_POLICY_REACT" -eq 1 ]; then
  # This is a capability check, not a presence check: `typeof
  # window.__REACT_DEVTOOLS_GLOBAL_HOOK__` is "object" on any page that already
  # has react-scan or the React DevTools extension, so only agent-browser's own
  # `react tree` can tell its hook apart from a namesake.
  if [ -z "$URL" ]; then
    REACT_STATUS="pending"
  else
    for react_attempt in 1 2; do
      if REACT_PROBE="$(browser_command react tree --json 2>/dev/null)" \
        && printf '%s' "$REACT_PROBE" | grep -q '"success":true'; then
        REACT_STATUS="ok"
        break
      fi
      REACT_STATUS="unconfirmed"
      [ "$react_attempt" -eq 2 ] || sleep 2
    done
  fi
fi

if ! mv -f "$META_PENDING" "$META"; then
  echo "✗ Connected, but could not publish the owner policy safely." >&2
  exit 5
fi

COMMITTED=1
trap - EXIT INT TERM
rm -f "$AB_BACKUP" "$META_BACKUP" 2>/dev/null || true
release_owner_lock

cat <<INFO
✓ Connected to the user's Chrome on CDP $PORT through one exact WebSocket endpoint
✓ Session:  $SESSION
✓ Own tab:  $BOUND
✓ Policy:   persistent=$AB_POLICY_PERSISTENT auto-approve=$AB_POLICY_AUTO_APPROVE react=$AB_POLICY_REACT
INFO

if [ "$AB_POLICY_REACT" -eq 1 ]; then
  case "$REACT_STATUS" in
    ok)
      cat <<INFO
✓ React:    DevTools hook confirmed on the bound tab ('react tree' answered).
            Use it through the wrapper (react tree / react inspect <id> /
            react renders start|stop) on every page you navigate to next.
            NEVER pass --enable react-devtools to a later 'open': it re-registers
            the hook and costs two more Chrome approval prompts every time.
INFO
      ;;
    pending)
      cat <<INFO
✓ React:    DevTools hook registered for this session; it installs on the next
            navigation. NEVER pass --enable react-devtools to a later 'open':
            it re-registers the hook and costs two more Chrome approval prompts.
INFO
      ;;
    *)
      cat <<INFO
! React:    could not confirm the hook: 'react tree' did not answer on the bound
            tab. Either the page had not booted React yet (just retry the react
            command), or this session's daemon was already running without the
            hook, which attaching does not fix late. In that case release it and
            connect again with --react:
              bash "$SCRIPT_DIR/cleanup.sh" $SESSION
INFO
      ;;
  esac
fi

if [ "$AB_POLICY_PERSISTENT" -eq 1 ]; then
  cat <<INFO
✓ Mode:     persistent. When the daemon dies, the owned tab closes, Chrome restarts
            or agent-browser is upgraded, the wrapper re-runs this connect by itself
            (at most once per command, never again within ${AB_HEAL_COOLDOWN_SECONDS:-60}s of a failed try) and
            then runs the command. Chrome may ask to approve that one connection.
INFO
fi

cat <<INFO

Run EVERY agent-browser command through this wrapper — never bare 'agent-browser'.
Invoke it with 'bash' so the harness permission rule for bash covers it:
  bash $AB snapshot -i
  bash $AB open <url>
  bash $AB screenshot /tmp/shot.png

After this task, clear routes and keep the approved connection for follow-ups:
  bash "$SCRIPT_DIR/cleanup.sh" --keep-alive $SESSION

Reuse this wrapper in the same conversation; do not ask for browser access again.
Idle parking: ${AB_POLICY_IDLE_TIMEOUT_SECONDS}s (0 disables it); commands renew it, parking retains policy.

When the user asks to disconnect or the conversation ends, release and preserve the tab:
  bash "$SCRIPT_DIR/cleanup.sh" $SESSION

Close the owned tab only when the user explicitly requests it:
  bash "$SCRIPT_DIR/cleanup.sh" --close-tab $SESSION
INFO
