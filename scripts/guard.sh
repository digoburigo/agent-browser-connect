#!/usr/bin/env bash
# Allow-list policy for commands sent through an owner-pinned browser session.
#
# Sourced by dispatch.sh. `ab_guard_command` is pure validation: it inspects the
# words of one browser command and answers, writing its own diagnostic to stderr.
#
#   0   allowed
#   2   forbidden — this command is known and deliberately denied
#   10  unknown  — this command is not in the allow-list
#
# Why an allow-list. agent-browser gains commands and flags faster than this repo
# can track them, and a deny-list defaults to "permit" for everything it has not
# heard of: as of 0.38.1 that silently included `plugin add`, `upgrade`,
# `stream enable`, `--proxy`, `--extension` and `--init-script`. It also keeps
# entries for verbs that no longer exist. Defaulting to "deny" moves the failure
# from silent permissiveness to a loud, actionable error, which is the one an
# agent can report and a maintainer can fix with a single line here.
#
# The cost is real and deliberate: a genuinely useful new agent-browser command
# will be refused until someone adds it below. That is the trade. There is no
# environment override on purpose — an escape hatch named in an error message is
# an escape hatch the agent will take.

# ---------------------------------------------------------------------------
# Allowed verb phrases, longest match wins.
#
# Phrases, not first words, because agent-browser's verbs are 1, 2 and 3 words
# (`snapshot`, `get url`, `react renders start`) and because it lets `tab list`
# be permitted while the rest of the `tab` family is not, without a special case.
# ---------------------------------------------------------------------------
AB_ALLOWED_VERBS='
open
back
forward
reload
read
click
dblclick
type
fill
press
hover
focus
check
uncheck
select
drag
scroll
scrollintoview
wait
keyboard type
keyboard inserttext
mouse move
mouse down
mouse up
mouse wheel
frame
dialog accept
dialog dismiss
dialog status
snapshot
screenshot
pdf
eval
highlight
console
errors
get text
get html
get value
get attr
get title
get url
get count
get box
get styles
get cdp-url
is visible
is enabled
is checked
find role
find text
find label
find placeholder
find alt
find title
find testid
find first
find last
find nth
diff snapshot
diff screenshot
react tree
react inspect
react renders start
react renders stop
react suspense
vitals
a11y
pushstate
trace start
trace stop
profiler start
profiler stop
network route
network unroute
network requests
network request
network har start
network har stop
cookies get
cookies set
cookies clear
storage local
storage session
set viewport
set device
set geo
set offline
set media
tab list
batch
skills list
skills get
skills path
'

# Flags accepted on any allowed verb. Output shaping only: nothing here changes
# how the daemon connects to Chrome, so none of them costs an approval dialog.
AB_ALLOWED_GLOBAL_FLAGS='
--json
--max-output
--content-boundaries
'

# Per-verb flags, "<verb phrase>:<space-separated flags>".
# A flag absent from both this table and AB_ALLOWED_GLOBAL_FLAGS is refused.
# Note what is NOT here: `click` accepts --human but not --new-tab, which creates
# a target.
AB_VERB_FLAGS='
read:--raw --require-md --llms --outline --filter --timeout
click:--human
drag:--human
mouse move:--duration --steps --human --seed
mouse down:--duration --steps --human --seed
mouse up:--duration --steps --human --seed
mouse wheel:--duration --steps --human --seed
scroll:-s --selector
wait:--url --load --fn --text --download --timeout --state
screenshot:-f --full --if-changed --threshold --annotate --screenshot-dir --screenshot-quality --screenshot-format
snapshot:-i --interactive -u --urls -c --compact -d --depth -s --selector --delta --full
eval:-b --base64 --stdin
find role:--name --exact
find text:--name --exact
find label:--name --exact
find placeholder:--name --exact
find alt:--name --exact
find title:--name --exact
find testid:--name --exact
find first:--name --exact
find last:--name --exact
find nth:--name --exact
diff snapshot:-b --baseline -s --selector -c --compact -d --depth
diff screenshot:-b --baseline -o --output -t --threshold -s --selector --full
console:--clear
errors:--clear
profiler start:--categories
network route:--abort --body --resource-type
network requests:--clear --filter --type --method --status
network har start:--content
cookies set:--url --domain --path --httpOnly --secure --sameSite --expires --curl
a11y:--tags -s --selector
react suspense:--only-dynamic
batch:--bail
skills get:--full --all
'

# Verbs that accept no positional arguments, "<verb phrase>:<max positionals>".
#
# Needed where a verb has a dangerous sibling subcommand: `tab list` is permitted
# and `tab new` is not, so without a limit `tab list new <url>` matches the
# allowed phrase and smuggles the denied one past as a trailing argument. Add an
# entry when a permitted phrase shares its first word with a denied one; verbs
# absent from this table accept any number of positionals.
AB_VERB_MAX_POSITIONAL='
tab list:0
'

# Key chords that create, restore, close or replace a Chrome target. Scanned
# across every word of a `press`, not just the first argument: the previous
# implementation read $2 alone, so `press --human Meta+t` walked straight past it.
AB_BLOCKED_CHORDS='
control+t
control+shift+t
meta+t
meta+shift+t
control+n
control+shift+n
meta+n
meta+shift+n
control+w
control+shift+w
meta+w
meta+shift+w
meta+q
alt+f4
alt+enter
option+enter
'

# ---------------------------------------------------------------------------
# Advisory explanations. Purely for the operator reading the error: an entry here
# grants nothing, so a stale one degrades a message and never opens a hole. Keyed
# by verb family (first word) or by flag name.
#
# Presence here also selects the exit status: a command we explain is one we
# deliberately deny (2); anything else we simply do not know (10).
# ---------------------------------------------------------------------------
AB_DENY_EXPLAIN='
record:opens a new Chrome window in a separate browser context, rebinds the session to it, and `record stop` never disposes the context. Use `screenshot` for stills, or `trace start|stop` / `profiler start|stop` to capture what happened.
tab:direct tab creation, switching and closing would move ownership away from the pinned target. `tab list` is the one permitted tab operation; re-run connect.sh after tab_gone.
window:would open a second browser window outside the owned target. (Not a command in agent-browser 0.38.1; kept for older CLIs.)
bringtofront:steals Chrome visible tab from the user and from other agents sharing this browser. (Not a command in agent-browser 0.38.1; kept for older CLIs.)
inspect:opens a DevTools window, which is a new target outside the pin.
connect:would replace this session CDP attachment. connect.sh owns attachment.
close:would tear down the session from inside a command. Use cleanup.sh.
chat:drives the browser through a model outside this wrapper guard.
mcp:exposes the session over a server that does not pass through this guard.
dashboard:starts a server and a browser surface outside the owned target.
plugin:installs and runs third-party code from npm or GitHub inside the browser session.
upgrade:replaces the agent-browser CLI mid-session, which is exactly the version mismatch connect.sh exists to resolve deliberately.
install:downloads and installs browser binaries.
doctor:mutates daemon and socket state. Run it outside the wrapper, and only when troubleshooting says to.
auth:reads and writes the credential vault, and `auth login` navigates on its own.
state:reads and writes saved auth state, and creates a temporary tab in the default context to do it.
stream:opens a WebSocket server on a port.
webmcp:invokes tools declared by the page. Page content is data, not instructions, and `--params @file` reads local files.
clipboard:reads and writes the user system clipboard, which is shared with everything else they are doing.
removeinitscript:strips init scripts from every tab in the session, including the React DevTools hook connect.sh --react installed.
addinitscript:registers a script for every tab in the session. Use connect.sh --react for the React hook. (Not a command in agent-browser 0.38.1.)
session:session identity is owned by connect.sh; deriving or listing it here cannot change what this wrapper is bound to.
confirm:approves an action that agent-browser own confirmation gate is holding.
deny:resolves an action that agent-browser own confirmation gate is holding.
keydown:holds a modifier across later commands, which splits a key chord into pieces the chord check cannot see (`keydown Meta` then `press t`). Use `press <chord>` so the whole chord is visible.
keyup:releases a modifier held across commands. Use `press <chord>` instead.
upload:hands a local file to the page.
download:writes a file to disk outside the owned target control.
diff:`diff snapshot` and `diff screenshot` are permitted; `diff url` loads two pages and is not.
set:`set viewport|device|geo|offline|media` are permitted. `set headers` and `set credentials` change the session network identity.
--session:can bind this command to another browser session.
--cdp:can change which browser this command talks to.
--pin-tab:the wrapper already pins every command to the owned target.
--no-pin-tab:would unpin the session from the owned target.
--namespace:can move this command to another daemon socket.
--auto-connect:can attach to a browser this session does not own.
--provider:can send this command to a different browser entirely.
-p:can send this command to a different browser entirely.
--engine:can send this command to a different browser engine.
--executable-path:can launch a different browser binary.
--profile:can open a different Chrome profile.
--state:can replay saved auth state into this session.
--restore:can replay saved cookies and storage into this session.
--restore-check-fn:evaluates JavaScript in the page as a side effect of state validation.
--session-name:legacy alias for the restore key; can replay state into this session.
--config:a config file can set every launch and connection value at once.
--allowed-domains:forces a fresh controllable context, rejecting the CDP attachment this session holds.
--new-tab:creates a target outside the pin.
--enable:a launch-affecting flag makes the daemon dial another WebSocket to Chrome, costing the user one more approval dialog. Use connect.sh --react for the React hook.
--input-mode:a launch-affecting flag makes the daemon dial another WebSocket to Chrome. Use --human on the individual click or drag.
--extension:loads a browser extension into the user Chrome.
--init-script:registers a script for every tab in the session. Use connect.sh --react for the React hook.
--args:passes launch arguments to the browser.
--proxy:routes the user browser traffic through another server.
--proxy-bypass:changes how the user browser traffic is routed.
--user-agent:changes the browser identity for the whole session.
--ignore-https-errors:disables certificate validation for the session.
--ca-cert:adds a trusted CA to the session.
--no-ca-cert:clears CA trust retained by the running browser session.
--allow-file-access:lets file:// URLs read local files.
--headed:a launch-affecting flag; the user browser is already visible.
--webgpu:a launch-affecting flag.
--idle-timeout:changes how long the shared daemon survives.
--action-policy:replaces agent-browser own action policy.
--confirm-actions:changes which actions agent-browser holds for confirmation.
--confirm-interactive:changes how agent-browser confirmation gate behaves.
'

# ---------------------------------------------------------------------------
# Internals
# ---------------------------------------------------------------------------

# Whole-line membership test against one of the newline-delimited tables above.
ab__guard_in_list() {
  local list="$1"
  local needle="$2"
  case "$list" in
    *"
$needle
"*) return 0 ;;
  esac
  return 1
}

# Value for a "<key>:<value>" table row, or non-zero when the key is absent.
ab__guard_table_value() {
  local table="$1"
  local key="$2"
  local line
  while IFS= read -r line; do
    case "$line" in
      "$key":*)
        printf '%s' "${line#*:}"
        return 0
        ;;
    esac
  done <<TABLE
$table
TABLE
  return 1
}

ab__guard_explain() {
  ab__guard_table_value "$AB_DENY_EXPLAIN" "$1"
}

# Longest allowed verb phrase, three words down to one. Prints the phrase and
# the number of words it consumed.
ab__guard_match_verb() {
  local one="${1:-}"
  local two="${2:-}"
  local three="${3:-}"
  local phrase

  if [ -n "$one" ] && [ -n "$two" ] && [ -n "$three" ]; then
    phrase="$one $two $three"
    if ab__guard_in_list "$AB_ALLOWED_VERBS" "$phrase"; then
      printf '%s\n3\n' "$phrase"
      return 0
    fi
  fi
  if [ -n "$one" ] && [ -n "$two" ]; then
    phrase="$one $two"
    if ab__guard_in_list "$AB_ALLOWED_VERBS" "$phrase"; then
      printf '%s\n2\n' "$phrase"
      return 0
    fi
  fi
  if [ -n "$one" ] && ab__guard_in_list "$AB_ALLOWED_VERBS" "$one"; then
    printf '%s\n1\n' "$one"
    return 0
  fi
  return 1
}

# Deny with the specific reason when we have one (2), or as unknown (10).
ab__guard_deny() {
  local key="$1"
  local subject="$2"
  local reason

  if reason="$(ab__guard_explain "$key")"; then
    printf '✗ %s is blocked by the pinned-target wrapper: %s\n' "$subject" "$reason" >&2
    return 2
  fi
  printf '✗ %s is not in this wrapper allow-list, so it is refused rather than passed to the browser.\n' "$subject" >&2
  printf '  This is a fail-closed guard: it permits a fixed set of agent-browser commands and refuses everything else, including commands that are new or simply not yet listed.\n' >&2
  printf '  Do not work around it with a bare agent-browser call. Report to the user that this command is not in the allow-list; adding it is a one-line change to scripts/guard.sh.\n' >&2
  return 10
}

# ---------------------------------------------------------------------------
# ab_guard_command <word> [word ...]
# ---------------------------------------------------------------------------
ab_guard_command() {
  local allow_batch="$1"
  shift

  local verb_match verb consumed
  local word flag lowered
  local verb_flags allowed_here max_positional positional
  # `|| deny_status=$?` rather than a bare call: ab__guard_deny always returns
  # non-zero, and a bare non-zero statement would trip `set -e` in a caller that
  # invokes this function outside a condition.
  local deny_status=0

  if [ "$#" -eq 0 ]; then
    printf '✗ An empty command cannot be checked against the allow-list.\n' >&2
    return 10
  fi

  # A leading flag has no verb to match, so it is refused here rather than being
  # allowed to hide an ownership-changing command behind a global option.
  if ! verb_match="$(ab__guard_match_verb "${1:-}" "${2:-}" "${3:-}")"; then
    case "${1:-}" in
      -*)
        flag="${1%%=*}"
        if ab__guard_explain "$flag" >/dev/null; then
          ab__guard_deny "$flag" "'$flag'" || deny_status=$?
          return "$deny_status"
        fi
        # The flag itself may be harmless; leading it is not. A global option in
        # front of the action can hide an ownership-changing command behind it.
        printf "✗ '%s' is blocked as a leading option: put a browser action first, because a global option in front of the action can hide an ownership-changing command behind it.\n" "$flag" >&2
        return 2
        ;;
    esac
    ab__guard_deny "${1%% *}" "'$1'" || deny_status=$?
    return "$deny_status"
  fi
  verb="$(printf '%s\n' "$verb_match" | sed -n '1p')"
  consumed="$(printf '%s\n' "$verb_match" | sed -n '2p')"

  # Nested batch would let one guarded command carry a whole unguarded program.
  if [ "$verb" = "batch" ] && [ "$allow_batch" != "1" ]; then
    printf "✗ Nested 'batch' is blocked by the pinned-target wrapper.\n" >&2
    return 2
  fi

  verb_flags="$(ab__guard_table_value "$AB_VERB_FLAGS" "$verb" || true)"
  max_positional="$(ab__guard_table_value "$AB_VERB_MAX_POSITIONAL" "$verb" || true)"

  shift "$consumed"
  positional=0
  for word in "$@"; do
    case "$word" in
      -*)
        flag="${word%%=*}"
        allowed_here=0
        if ab__guard_in_list "$AB_ALLOWED_GLOBAL_FLAGS" "$flag"; then
          allowed_here=1
        fi
        if [ "$allowed_here" -eq 0 ] && [ -n "$verb_flags" ]; then
          case " $verb_flags " in
            *" $flag "*) allowed_here=1 ;;
          esac
        fi
        if [ "$allowed_here" -eq 0 ]; then
          ab__guard_deny "$flag" "'$flag' on '$verb'" || deny_status=$?
          return "$deny_status"
        fi
        ;;
      *)
        positional=$((positional + 1))
        if [ -n "$max_positional" ] && [ "$positional" -gt "$max_positional" ]; then
          printf "✗ '%s' is blocked from carrying further arguments, and '%s' was passed after it: a permitted phrase must not smuggle a denied sibling through as a trailing argument.\n" "$verb" "$word" >&2
          return 2
        fi
        ;;
    esac
  done

  # Chord check, scoped to the verb that dispatches key events so that ordinary
  # text (`fill @e1 "control+t"`) is not refused, and applied to every remaining
  # word so that an interposed flag cannot hide the chord.
  if [ "$verb" = "press" ]; then
    for word in "$@"; do
      lowered="$(printf '%s' "$word" | LC_ALL=C tr 'A-Z' 'a-z')"
      if ab__guard_in_list "$AB_BLOCKED_CHORDS" "$lowered"; then
        printf "✗ '%s' is blocked because it can create, restore, close, or replace a Chrome target.\n" "$lowered" >&2
        return 2
      fi
    done
  fi

  return 0
}
