#!/usr/bin/env bash
# Stress test against the USER'S OWN Chrome (CDP 9222): N owned tabs, each driven
# concurrently through its own wrapper with random navigation, interaction, and
# simulated tab closure. Verifies per-tab isolation and full cleanup.
#
# Gated: AB_RUN_USER_CHROME=1 bash tests/stress-user-chrome.sh [tabs] [rounds]
#
# THIS CAN CRASH THE BROWSER IT IS TESTING. Observed 2026-09-18 at the default
# 10 tabs x 6 rounds against Chrome 153.0.8010.48: the browser process segfaulted
# during round 6 while several sessions were attaching, closing and reconnecting
# targets at once (EXC_BAD_ACCESS / KERN_INVALID_ADDRESS at 0x140, faulting thread
# CrBrowserMain). Chrome relaunched on its own and the helper's cleanup released
# all ten sessions with nothing left behind, but every tab open at that moment
# went with it. That looks like a browser bug rather than a helper defect — a
# browser should not segfault from CDP traffic — but this script is what provokes
# it, so do not run it against a Chrome the user is relying on. Lower the tab
# count for a gentler run; 3 tabs x 3 rounds still exercises isolation.
set -euo pipefail

if [ "${AB_RUN_USER_CHROME:-0}" != "1" ]; then
  echo "skip - set AB_RUN_USER_CHROME=1 to run against the user's real Chrome"
  exit 0
fi

SKILL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONNECT="$SKILL_DIR/scripts/connect.sh"
CLEANUP="$SKILL_DIR/scripts/cleanup.sh"
TABS="${1:-10}"
ROUNDS="${2:-6}"
STRESS_ID="${AB_CONNECT_ID:-stress-user-chrome-$$}"
export AB_CONNECT_ID="$STRESS_ID"

cat >&2 <<'WARN'
! This drives the user's real Chrome hard enough to have crashed it before.
!   Every tab currently open in that browser is at risk. Ctrl-C now if the user
!   is relying on it; see the header of this script for the recorded crash.
WARN

WORK="$(mktemp -d "${TMPDIR:-/tmp}/ab-stress.XXXXXX")"
PORT_FILE="$WORK/server.port"
SERVER_PID=""
FAILURES=0
SESSIONS_FILE="$WORK/sessions"
: > "$SESSIONS_FILE"

log() { printf '%s\n' "$*"; }
note() { printf '  %s\n' "$*"; }
# Actions run in background subshells, so failures are counted through a file.
fail() { printf 'not ok - %s\n' "$*" >&2; printf '%s\n' "$*" >> "$WORK/failures"; }
failure_count() { [ -f "$WORK/failures" ] && wc -l < "$WORK/failures" | tr -d ' ' || echo 0; }

finish() {
  local status=$?
  set +e
  if [ -s "$SESSIONS_FILE" ]; then
    log "--- cleanup of $(wc -l < "$SESSIONS_FILE" | tr -d ' ') sessions"
    while IFS= read -r session; do
      [ -n "$session" ] || continue
      if out="$(bash "$CLEANUP" --close-tab "$session" 2>&1)"; then
        note "ok  $session"
      else
        fail "cleanup $session exit $?: $out"
      fi
    done < "$SESSIONS_FILE"
    leftovers="$(agent-browser session list 2>/dev/null | grep -F -f "$SESSIONS_FILE" || true)"
    [ -z "$leftovers" ] || fail "sessions still alive after cleanup: $leftovers"
  fi
  [ -z "$SERVER_PID" ] || kill "$SERVER_PID" >/dev/null 2>&1 || true
  FAILURES="$(failure_count)"
  if [ "$FAILURES" -eq 0 ] && [ "$status" -eq 0 ]; then
    rm -rf "$WORK"
    log "All stress checks passed."
    exit 0
  fi
  log "$FAILURES failure(s); artifacts kept at $WORK"
  exit 1
}
trap finish EXIT INT TERM

# --- fixture server: /tab/<n>/<page> with a link, an input, and a title per tab
cat > "$WORK/server.mjs" <<'JS'
import { writeFileSync } from "node:fs";
import { createServer } from "node:http";
const portFile = process.argv[2];
const server = createServer((req, res) => {
  const m = req.url.match(/^\/tab\/(\d+)\/([^?]*)/);
  res.setHeader("Cache-Control", "no-store");
  res.setHeader("Content-Type", "text/html; charset=utf-8");
  if (!m) { res.statusCode = 404; res.end("nope"); return; }
  const [, tab, page] = m;
  res.end(`<!doctype html><html><head><title>Tab ${tab} ${page}</title></head><body>
<h1 id="h">tab ${tab} page ${page}</h1>
<a id="go" href="/tab/${tab}/next-${Date.now() % 100000}">go</a>
<input id="name" placeholder="name">
<button id="rename" onclick="document.title='renamed ${tab} '+document.getElementById('name').value">rename</button>
</body></html>`);
});
server.listen(0, "127.0.0.1", () => writeFileSync(portFile, String(server.address().port)));
process.on("SIGTERM", () => server.close(() => process.exit(0)));
JS
node "$WORK/server.mjs" "$PORT_FILE" >"$WORK/server.log" 2>&1 &
SERVER_PID=$!
for _ in $(seq 1 100); do [ -s "$PORT_FILE" ] && break; sleep 0.05; done
[ -s "$PORT_FILE" ] || { fail "fixture server did not start"; exit 1; }
BASE="http://127.0.0.1:$(cat "$PORT_FILE")"

# --- per-tab state lives in files (bash 3.2: no associative arrays)
tab_dir() { printf '%s/tab-%s' "$WORK" "$1"; }
wrapper_of() { cat "$(tab_dir "$1")/wrapper"; }
session_of() { cat "$(tab_dir "$1")/session"; }

connect_tab() {
  local n="$1" url="$2" out
  mkdir -p "$(tab_dir "$n")"
  out="$(bash "$CONNECT" "stress-tab-$n" --slot "t$n" --url "$url" 2>"$(tab_dir "$n")/connect.err")" || {
    fail "tab $n: connect failed: $(cat "$(tab_dir "$n")/connect.err")"
    return 1
  }
  printf '%s\n' "$out" | sed -n 's/^✓ Session:  //p' > "$(tab_dir "$n")/session"
  printf '%s\n' "$out" | sed -n 's/^  bash \(.*\) snapshot -i$/\1/p' > "$(tab_dir "$n")/wrapper"
  [ -s "$(tab_dir "$n")/wrapper" ] || { fail "tab $n: no wrapper path in connect output"; return 1; }
  grep -qxF "$(session_of "$n")" "$SESSIONS_FILE" || session_of "$n" >> "$SESSIONS_FILE"
  printf '%s\n' "$url" > "$(tab_dir "$n")/expected"
}

# Assert the tab's live URL is its own and matches what we last set.
check_tab() {
  local n="$1" where="$2" live expected
  live="$(bash "$(wrapper_of "$n")" get url 2>>"$(tab_dir "$n")/cmd.err")" || { fail "tab $n [$where]: get url failed"; return 1; }
  expected="$(cat "$(tab_dir "$n")/expected")"
  case "$live" in
    "$BASE/tab/$n/"*) ;;
    *) fail "tab $n [$where]: URL leaked to another tab: $live"; return 1 ;;
  esac
  [ "$live" = "$expected" ] || { fail "tab $n [$where]: expected $expected got $live"; return 1; }
}

# One random action on one tab. Records what it did in the tab's log.
act() {
  local n="$1" round="$2" ab pick target live title snap value owned
  ab="$(wrapper_of "$n")"
  pick=$((RANDOM % 8))
  case "$pick" in
    0|1) # navigate somewhere new inside this tab's namespace
      target="$BASE/tab/$n/r${round}-$RANDOM"
      bash "$ab" open "$target" >/dev/null 2>>"$(tab_dir "$n")/cmd.err" || fail "tab $n r$round: open failed"
      printf '%s\n' "$target" > "$(tab_dir "$n")/expected"
      echo "r$round open" >> "$(tab_dir "$n")/log"
      ;;
    2) # click the page's link, then learn the new URL
      bash "$ab" click '#go' >/dev/null 2>>"$(tab_dir "$n")/cmd.err" || fail "tab $n r$round: click failed"
      # A hidden tab is throttled by Chrome: a click there takes ~10 s to take
      # effect (measured 2026-09-04, two sessions, agent-browser 0.36.0), so
      # poll for up to 30 s instead of a fixed wait.
      live=""
      for _ in $(seq 1 60); do
        live="$(bash "$ab" get url 2>>"$(tab_dir "$n")/cmd.err")" || live=""
        case "$live" in "$BASE/tab/$n/next-"*) break ;; esac
        sleep 0.5
      done
      case "$live" in
        "$BASE/tab/$n/next-"*) printf '%s\n' "$live" > "$(tab_dir "$n")/expected" ;;
        *) fail "tab $n r$round: click did not land on own next page: $live" ;;
      esac
      echo "r$round click" >> "$(tab_dir "$n")/log"
      ;;
    3) # fill an input and rename the page through the DOM, then read the title back
      value="v${round}-$RANDOM"
      bash "$ab" fill '#name' "$value" >/dev/null 2>>"$(tab_dir "$n")/cmd.err" || fail "tab $n r$round: fill failed"
      bash "$ab" click '#rename' >/dev/null 2>>"$(tab_dir "$n")/cmd.err" || fail "tab $n r$round: rename click failed"
      # Same throttling caveat as the click above: the onclick handler runs on
      # the tab's own (throttled) main thread, so give the title time to change.
      title=""
      for _ in $(seq 1 60); do
        title="$(bash "$ab" get title 2>>"$(tab_dir "$n")/cmd.err")" || title=""
        [ "$title" = "renamed $n $value" ] && break
        sleep 0.5
      done
      [ "$title" = "renamed $n $value" ] || fail "tab $n r$round: title mismatch: '$title'"
      echo "r$round fill+rename" >> "$(tab_dir "$n")/log"
      ;;
    4) # snapshot must show interactive refs
      snap="$(bash "$ab" snapshot -i 2>>"$(tab_dir "$n")/cmd.err")" || snap=""
      printf '%s' "$snap" | grep -Eq '@e[0-9]|ref=e[0-9]' || fail "tab $n r$round: snapshot had no refs: $(printf '%s' "$snap" | head -c 200)"
      echo "r$round snapshot" >> "$(tab_dir "$n")/log"
      ;;
    5) # batch: several safe commands in one round trip
      bash "$ab" batch 'get url' 'get title' 'get text #h' \
        >"$(tab_dir "$n")/batch.out" 2>>"$(tab_dir "$n")/cmd.err" || fail "tab $n r$round: batch failed"
      grep -q "tab $n page" "$(tab_dir "$n")/batch.out" || fail "tab $n r$round: batch output wrong: $(cat "$(tab_dir "$n")/batch.out")"
      echo "r$round batch" >> "$(tab_dir "$n")/log"
      ;;
    6) # a guarded command must be refused without touching the tab
      if bash "$ab" tab new "$BASE/tab/$n/forbidden" >/dev/null 2>&1; then
        fail "tab $n r$round: guard let 'tab new' through"
      fi
      echo "r$round guard" >> "$(tab_dir "$n")/log"
      ;;
    7) # simulate the user closing this exact tab (by target id), then recover via connect (tab_gone path)
      owned="$(sed -n 's/^owned_target_id=//p' "$(dirname "$ab")/session.meta")"
      agent-browser --session "$(session_of "$n")" tab close "$owned" >/dev/null 2>&1 || true
      target="$BASE/tab/$n/recovered-r$round"
      connect_tab "$n" "$target" || return 0
      echo "r$round close+reconnect" >> "$(tab_dir "$n")/log"
      ;;
  esac
  check_tab "$n" "r$round" || true
}

# --- phase 1: connect N tabs concurrently
log "--- connecting $TABS tabs concurrently (fixture $BASE)"
START=$(date +%s)
JOBS=""
for n in $(seq 1 "$TABS"); do
  connect_tab "$n" "$BASE/tab/$n/start" &
  JOBS="$JOBS $!"
done
for job in $JOBS; do wait "$job" || true; done
for n in $(seq 1 "$TABS"); do
  [ -s "$(tab_dir "$n")/wrapper" ] || { fail "tab $n never connected"; exit 1; }
done
DISTINCT="$(sort -u "$SESSIONS_FILE" | wc -l | tr -d ' ')"
[ "$DISTINCT" = "$TABS" ] || fail "expected $TABS distinct sessions, got $DISTINCT"
note "$TABS tabs connected in $(( $(date +%s) - START ))s"
for n in $(seq 1 "$TABS"); do check_tab "$n" "after-connect" || true; done

# --- phase 2: rounds of random concurrent actions
for round in $(seq 1 "$ROUNDS"); do
  log "--- round $round: random actions on all tabs at once"
  START=$(date +%s)
  JOBS=""
  for n in $(seq 1 "$TABS"); do
    act "$n" "$round" &
    JOBS="$JOBS $!"
  done
  for job in $JOBS; do wait "$job" || true; done
  note "round done in $(( $(date +%s) - START ))s"
done

# --- phase 3: final isolation sweep, all tabs at once
log "--- final isolation sweep"
JOBS=""
for n in $(seq 1 "$TABS"); do check_tab "$n" "final" & JOBS="$JOBS $!"; done
for job in $JOBS; do wait "$job" || true; done
log "--- action mix"
cat "$WORK"/tab-*/log | awk '{print $2}' | sort | uniq -c | sort -rn | sed 's/^/  /'

# --- phase 4: foreground audit. Every event that can move Chrome's visible tab
# is in each session's events.log. In a clean run the only ones allowed are the
# fresh attach and the tab_gone recoveries this script triggered itself
# (action 7); a drift restore means the wrapper's binding moved on its own.
log "--- foreground-moving events across all sessions"
EXPECTED_TAB_NEW="$(cat "$WORK"/tab-*/log | grep -c 'close+reconnect' || true)"
ALL_EVENTS="$WORK/events.all"
: > "$ALL_EVENTS"
for n in $(seq 1 "$TABS"); do
  ev="$(dirname "$(wrapper_of "$n")")/events.log"
  [ -f "$ev" ] && sed "s/^/tab $n: /" "$ev" >> "$ALL_EVENTS"
done
awk '{print $5}' "$ALL_EVENTS" | sort | uniq -c | sort -rn | sed 's/^/  /'
DRIFTS="$(grep -c ' drift-restored ' "$ALL_EVENTS" || true)"
TAB_NEWS="$(grep -c ' tab-new ' "$ALL_EVENTS" || true)"
FRESH="$(grep -c ' attach mode=fresh' "$ALL_EVENTS" || true)"
[ "$DRIFTS" -eq 0 ] || fail "wrapper restored a drifted binding $DRIFTS time(s) in a clean run (each one is a Page.bringToFront): $(grep ' drift-restored ' "$ALL_EVENTS" | head -3)"
[ "$TAB_NEWS" -eq "$EXPECTED_TAB_NEW" ] || fail "expected $EXPECTED_TAB_NEW tab_gone recoveries, events show $TAB_NEWS"
[ "$FRESH" -eq "$TABS" ] || fail "expected $TABS fresh attaches, events show $FRESH"
note "foreground moves: $FRESH fresh attaches + $TAB_NEWS tab_gone recoveries, $DRIFTS drift restores"
[ "$(failure_count)" -eq 0 ] || exit 1
