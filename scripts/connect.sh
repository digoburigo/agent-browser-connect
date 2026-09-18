#!/usr/bin/env bash
# Bind this agent to one pinned tab in the user's already-running Chrome.
# Prints a wrapper path; every later agent-browser command goes through it.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
. "$SCRIPT_DIR/lib.sh"

usage() {
  echo "usage: connect.sh [label] [--url <url>] [--port 9222] [--session <existing>] [--slot <name>] [--react]" >&2
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
REACT_HOOK=0

while [ "$#" -gt 0 ]; do
  case "$1" in
    --url|--port|--session|--slot)
      [ "$#" -ge 2 ] || die_usage "$1 requires a value"
      case "$1" in
        --url) URL="$2" ;;
        --port) PORT_RAW="$2" ;;
        --session) REUSE="$2" ;;
        --slot) SLOT="$2" ;;
      esac
      shift 2
      ;;
    --react)
      REACT_HOOK=1
      shift
      ;;
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

case "$URL" in
  -*) die_usage "URL values may not begin with '-'" ;;
esac

# O hook do React DevTools é um init script registrado UMA vez, quando o daemon
# se conecta — não a cada navegação. Exportando aqui, os comandos `react …`
# valem para a sessão inteira e o modo de aprovação do Chrome pergunta uma vez
# só. Passar `--enable react-devtools` num `open` posterior re-registra o hook e
# força o daemon a discar um WebSocket novo (flags de launch diferentes da
# chamada anterior): como o wrapper cerca o comando com `tab list`, são duas
# reconexões — duas aprovações a mais para o usuário — em cada página perfilada.
# Até a 0.37.1 cada um desses sockets ainda ficava pendurado; a 0.38 fecha o
# antigo (upstream #1739), então o custo hoje é o diálogo, não o vazamento.
if [ "$REACT_HOOK" -eq 1 ]; then
  export AGENT_BROWSER_ENABLE="react-devtools"
fi

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
if ! ab_prepare_private_dir "$DIR"; then
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

# Um upgrade do agent-browser deixa o daemon da sessão anterior numa versão
# antiga. O primeiro comando de BROWSER que chegar nele imprime "Daemon version
# mismatch detected, restarting..." e reinicia o daemon — e um daemon reiniciado
# perde a conexão CDP externa: sem os flags de conexão ele LANÇA um Chrome
# próprio no lugar do Chrome do usuário (medido em 16/09/2026, 0.37.1 → 0.38.0).
# `session info` não reinicia nada e já reporta a versão do daemon, então a
# troca é feita aqui, deliberadamente, em vez de virar um relançamento no meio
# de um comando.
DAEMON_VERSION="$AB_SESSION_VERSION"
CLI_VERSION="$(ab_cli_version "$AGENT_BROWSER_BIN" 2>/dev/null || true)"
if [ "$SESSION_WAS_ACTIVE" = "1" ] && [ -n "$DAEMON_VERSION" ] && [ -n "$CLI_VERSION" ] \
  && [ "$DAEMON_VERSION" != "$CLI_VERSION" ]; then
  ab_log_event "$DIR" version-mismatch "daemon=$DAEMON_VERSION cli=$CLI_VERSION action=stopped-stale-daemon"
  cat >&2 <<MSG
! Session $SESSION is held by an agent-browser $DAEMON_VERSION daemon while the CLI is $CLI_VERSION.
  Stopping the stale daemon and attaching once with the current version. Letting a
  browser command hit it instead would restart it and could launch a substitute
  Chrome. Chrome may ask to approve this one new connection.
MSG
  # Só o daemon é parado. Os sidecars de sessão (`<session>.target`) ficam de
  # propósito: é por eles que o daemon novo volta ao MESMO target em vez de
  # abrir mais uma aba na janela do usuário.
  "$AGENT_BROWSER_BIN" --session "$SESSION" close >/dev/null 2>&1 || true
  SESSION_WAS_ACTIVE=0
  STALE_DAEMON_SWAPPED=1
fi

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

COMMITTED=0
ATTACH_ESTABLISHED=0
TARGET_DISCOVERY_SAFE=0
OWNED_TARGET_ID=""
rollback() {
  local status=$?
  local rollback_list rollback_state rollback_target
  trap - EXIT INT TERM
  rm -f "$DIR/attach.err" "$DIR/navigation.err" "$DIR/target.err" "$DIR/rebind.err" "$DIR/ab.tmp.$$" 2>/dev/null || true

  if [ "$COMMITTED" -eq 0 ]; then
    if [ "$SESSION_WAS_ACTIVE" -eq 0 ]; then
      if [ "$ATTACH_ESTABLISHED" -eq 1 ] && [ "$TARGET_DISCOVERY_SAFE" -eq 1 ]; then
        rollback_target="$OWNED_TARGET_ID"
        if [ -z "$rollback_target" ] \
          && rollback_list="$("$AGENT_BROWSER_BIN" --session "$SESSION" tab list --json 2>/dev/null)" \
          && ab_tab_state "$NODE_BIN" "$SCRIPT_DIR/json.mjs" "" "$rollback_list"; then
          rollback_target="$AB_TAB_ACTIVE"
        fi
        if [ -n "$rollback_target" ] && [[ "$rollback_target" =~ ^[A-Za-z0-9_-]+$ ]]; then
          "$AGENT_BROWSER_BIN" --session "$SESSION" tab close "$rollback_target" >/dev/null 2>&1 || true
        else
          echo "! Failed attach left no provable target ID; rollback preserved all Chrome targets." >&2
        fi
      fi
      "$AGENT_BROWSER_BIN" --session "$SESSION" close >/dev/null 2>&1 || true
      ab_remove_session_files "$SOCKET_DIR" "$SESSION" || true
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
} > "$META"
chmod 600 "$META"

if [ "$SESSION_WAS_ACTIVE" -eq 0 ]; then
  echo "• Chrome may show one connection approval. Approve that single prompt; this script will not open retry connections." >&2
fi

browser_command() {
  "$AGENT_BROWSER_BIN" --cdp "$CDP_URL" --pin-tab --session "$SESSION" "$@"
}

TARGET="${URL:-about:blank}"
ATTACH_ERROR=""
if BOUND="$(browser_command get url 2>"$DIR/attach.err")"; then
  ATTACH_ESTABLISHED=1
  TARGET_DISCOVERY_SAFE=1
elif [ "${STALE_DAEMON_SWAPPED:-0}" -eq 1 ] \
  && ! grep -q 'tab_gone' "$DIR/attach.err" 2>/dev/null \
  && sleep 2 \
  && BOUND="$(browser_command get url 2>"$DIR/attach.err")"; then
  # Uma tentativa a mais existe SÓ aqui. Em toda outra situação o script anexa
  # uma vez e não insiste (um diálogo repetido é sinal de que outro processo
  # está reconectando). Mas neste caminho fomos nós que paramos um daemon que
  # estava funcionando, e o primeiro comando de um daemon recém-subido costuma
  # estourar timeout; falhar aqui deixaria o usuário sem sessão nenhuma.
  ATTACH_ESTABLISHED=1
  TARGET_DISCOVERY_SAFE=1
  echo "! The first command after the version swap timed out; the single retry succeeded." >&2
else
  ATTACH_ERROR="$(cat "$DIR/attach.err" 2>/dev/null || true)"
  if printf '%s' "$ATTACH_ERROR" | grep -q 'tab_gone'; then
    ATTACH_ESTABLISHED=1
    if browser_command tab new "$TARGET" >/dev/null 2>"$DIR/attach.err"; then
      TARGET_DISCOVERY_SAFE=1
      ab_log_event "$DIR" tab-new "reason=tab_gone url=$TARGET (Chrome opens new targets in the foreground)"
    fi
    if [ "$TARGET_DISCOVERY_SAFE" -eq 1 ] \
      && BOUND="$(browser_command get url 2>"$DIR/attach.err")"; then
      :
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
rm -f "$DIR/attach.err"

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
  # A pinned session never adopts an existing tab, so the daemon opened a new
  # one during this attach, and Chrome shows new targets in the foreground.
  ab_log_event "$DIR" attach "mode=fresh (daemon opened a new foreground tab)"
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
        # Trocar um daemon obsoleto custa um attach novo, e todo attach novo
        # abre uma aba. Quando o target da sessão sobreviveu, essa aba é nossa e
        # está vazia — fechá-la deixa o upgrade invisível na janela do usuário.
        # Três condições provam a posse: a troca aconteceu nesta execução, a aba
        # é a que este attach vinculou, e ela nunca saiu de about:blank.
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
if ! ab_set_meta_value "$META" owned_target_id "$OWNED_TARGET_ID"; then
  echo "✗ Connected, but could not persist the owned target safely." >&2
  exit 5
fi

REACT_STATUS=""
if [ "$REACT_HOOK" -eq 1 ]; then
  # A checagem é de capacidade, não de presença: `typeof
  # window.__REACT_DEVTOOLS_GLOBAL_HOOK__` dá "object" em qualquer página que
  # já tenha react-scan ou a extensão do React DevTools, então só o `react
  # tree` do próprio agent-browser distingue o hook dele de um homônimo.
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

COMMITTED=1
trap - EXIT INT TERM
rm -f "$AB_BACKUP" "$META_BACKUP" 2>/dev/null || true
release_owner_lock

cat <<INFO
✓ Connected to the user's Chrome on CDP $PORT through one exact WebSocket endpoint
✓ Session:  $SESSION
✓ Own tab:  $BOUND
INFO

if [ "$REACT_HOOK" -eq 1 ]; then
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

cat <<INFO

Run EVERY agent-browser command through this wrapper — never bare 'agent-browser'.
Invoke it with 'bash' so the harness permission rule for bash covers it:
  bash $AB snapshot -i
  bash $AB open <url>
  bash $AB screenshot /tmp/shot.png

When the task is done, detach safely and preserve the tab:
  bash "$SCRIPT_DIR/cleanup.sh" $SESSION

Close the owned tab only when the user explicitly requests it:
  bash "$SCRIPT_DIR/cleanup.sh" --close-tab $SESSION
INFO
