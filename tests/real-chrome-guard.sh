#!/usr/bin/env bash
# Adversarial probe against a REAL agent-browser daemon bound to the user's own
# Chrome. The allow-list has unit coverage (tests/guard.sh), the lib readers have
# unit coverage (tests/lib-interfaces.sh), and both have mock wrapper coverage
# (tests/run.sh). This checks what none of those can: that the guard really sits
# in front of a live CLI, that a real daemon accepts the batch form the
# dispatcher now sends, that exit codes survive the wrapper, and that a refusal
# leaves the owned tab exactly where it was.
#
# Gated: AB_RUN_USER_CHROME=1 bash tests/real-chrome-guard.sh
#
# Unlike tests/stress-user-chrome.sh this is gentle: one session, no concurrency,
# no tab creation or closure, and it releases with plain cleanup so the tab (and
# therefore the browser) is preserved. Requires Chrome with remote debugging on.
set -euo pipefail

if [ "${AB_RUN_USER_CHROME:-0}" != "1" ]; then
  echo "skip - set AB_RUN_USER_CHROME=1 to probe against the user's real Chrome"
  exit 0
fi

SKILL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LABEL="guard-probe"
export AB_CONNECT_ID="guard-probe-$$"

PASS=0
FAIL=0
note() { printf '  %s\n' "$*"; }
ok()   { PASS=$((PASS + 1)); printf 'ok   %-4s %s\n' "$1" "$2"; }
bad()  { FAIL=$((FAIL + 1)); printf 'FAIL %s\n' "$*" >&2; }

OUT="$(bash "$SKILL_DIR/scripts/connect.sh" "$LABEL" --url 'about:blank' 2>&1)" || {
  printf 'connect failed:\n%s\n' "$OUT" >&2
  exit 1
}
SESSION="$(printf '%s\n' "$OUT" | sed -n 's/^✓ Session:  //p')"
AB="$(printf '%s\n' "$OUT" | sed -n 's/^  bash \(.*\) snapshot -i$/\1/p')"
[ -n "$AB" ] && [ -n "$SESSION" ] || { printf 'could not parse connect output:\n%s\n' "$OUT" >&2; exit 1; }
printf 'session: %s\nwrapper: %s\n\n' "$SESSION" "$AB"

release() { bash "$SKILL_DIR/scripts/cleanup.sh" "$SESSION" 2>&1 | sed 's/^/  /'; }
trap release EXIT INT TERM

URL_BEFORE="$(bash "$AB" get url 2>/dev/null || echo UNKNOWN)"
note "bound tab before probes: $URL_BEFORE"
echo

probe() {
  local expected="$1"; shift
  local out status
  set +e
  out="$(bash "$AB" "$@" 2>&1)"
  status=$?
  set -e
  if [ "$status" = "$expected" ]; then
    ok "$status" "$*"
  else
    bad "expected $expected, got $status: $*"
    printf '     %s\n' "$(printf '%s' "$out" | sed -n '1p')" >&2
  fi
}

echo "--- must still work (0) ---"
probe 0 get url
probe 0 get title
probe 0 snapshot -i
probe 0 tab list
probe 0 console
probe 0 frame main
probe 0 dialog status
probe 0 network requests
probe 0 batch 'get url' 'get title'

echo
echo "--- target creation / ownership (2) ---"
probe 2 tab new http://127.0.0.1:1/forbidden
probe 2 tab TARGET-FOREIGN
probe 2 tab list new http://127.0.0.1:1/forbidden
probe 2 click '#nothing' --new-tab
probe 2 inspect
probe 2 bringtofront
probe 2 record start /tmp/should-not-exist.webm
probe 2 close
probe 2 get url --session foreign
probe 2 --json tab new http://127.0.0.1:1/forbidden

echo
echo "--- launch-affecting flags (2) ---"
probe 2 --enable react-devtools open about:blank
probe 2 --input-mode human click '#nothing'
probe 2 open about:blank --proxy http://127.0.0.1:1
probe 2 open about:blank --extension /tmp/nope
probe 2 open about:blank --init-script /tmp/nope.js
probe 2 snapshot --allow-file-access

echo
echo "--- key chords, including the bypass fixed today (2) ---"
probe 2 press Meta+t
probe 2 press Control+w
probe 2 press --json Meta+t
probe 2 press Meta+t --json

echo
echo "--- outside the containment boundary (2) ---"
probe 2 plugin add npm:definitely-not-installed
probe 2 upgrade
probe 2 install
probe 2 stream enable --port 59999
probe 2 removeinitscript 1
probe 2 clipboard read
probe 2 webmcp invoke tool --params @/etc/passwd
probe 2 auth list
probe 2 state save /tmp/should-not-exist.json
probe 2 keydown Meta
probe 2 upload '#f' /etc/passwd

echo
echo "--- batch cannot smuggle (2) ---"
probe 2 batch 'get url' 'tab new http://127.0.0.1:1/forbidden'
probe 2 batch 'get url' 'record start /tmp/should-not-exist.webm'
probe 2 batch "t'ab' new http://127.0.0.1:1/forbidden"
probe 2 batch '' 'get url'

echo
echo "--- fail-closed, not forbidden (10) ---"
probe 10 totallynewverb
probe 10 snapshot --brand-new-flag
probe 10 react eval 'window.x'

echo
echo "--- C4: argument-mode batch now sends the guarded words as JSON on stdin ---"
# The change that most needs a real daemon: the mock accepted this because I
# wrote the mock. Real agent-browser has to accept `batch` with no command
# arguments and a JSON array on stdin, and produce the same results.
set +e
B1="$(bash "$AB" batch 'get url' 'get title' 2>&1)"; B1S=$?
B2="$(bash "$AB" batch --bail 'get url' 'get title' 2>&1)"; B2S=$?
B3="$(bash "$AB" batch 'get url' 2>&1)"; B3S=$?
set -e
[ "$B1S" = 0 ] && ok 0 "batch 'get url' 'get title'" || { bad "multi-command batch exited $B1S"; printf '     %s\n' "$(printf '%s' "$B1" | head -3)" >&2; }
[ "$B2S" = 0 ] && ok 0 "batch --bail 'get url' 'get title'" || { bad "--bail batch exited $B2S"; printf '     %s\n' "$(printf '%s' "$B2" | head -3)" >&2; }
[ "$B3S" = 0 ] && ok 0 "batch 'get url' (single)" || { bad "single-command batch exited $B3S"; printf '     %s\n' "$(printf '%s' "$B3" | head -3)" >&2; }
if printf '%s' "$B1" | grep -q 'about:blank'; then
  ok 0 "batch results actually came back (about:blank present)"
else
  bad "batch ran but returned no recognisable result: $(printf '%s' "$B1" | head -c 200)"
fi
# stdin JSON mode must still work unchanged.
set +e
B4="$(printf '[["get","url"],["get","title"]]' | bash "$AB" batch 2>&1)"; B4S=$?
set -e
[ "$B4S" = 0 ] && ok 0 "batch via JSON stdin (unchanged path)" || bad "stdin batch exited $B4S: $(printf '%s' "$B4" | head -c 200)"

echo
echo "--- C3: ab_load_meta rejects a tampered record through the wrapper ---"
META_FILE="$(dirname "$AB")/session.meta"
cp -p "$META_FILE" "$META_FILE.probe-backup"
# Break the owner key so H(owner_id|slot|port) no longer matches.
sed 's/^owner_key=.*/owner_key=0000000000000000000000000000000000000000000000000000000000000000/' \
  "$META_FILE.probe-backup" > "$META_FILE"
set +e
TAMPER="$(bash "$AB" get url 2>&1)"; TAMPERS=$?
set -e
[ "$TAMPERS" = 5 ] && ok 5 "tampered owner key refused (exit 5)" || bad "tampered meta gave exit $TAMPERS, expected 5"
printf '%s' "$TAMPER" | grep -q 'ownership is inconsistent' \
  && ok 5 "refusal names the ownership inconsistency" \
  || bad "refusal did not explain itself: $(printf '%s' "$TAMPER" | head -c 160)"
# Version check, from the single AB_META_VERSION constant.
sed 's/^version=.*/version=3/' "$META_FILE.probe-backup" > "$META_FILE"
set +e
TAMPER2="$(bash "$AB" get url 2>&1)"; TAMPER2S=$?
set -e
[ "$TAMPER2S" = 5 ] && ok 5 "outdated metadata version refused" || bad "old version gave exit $TAMPER2S, expected 5"
mv -f "$META_FILE.probe-backup" "$META_FILE"
set +e
RESTORED="$(bash "$AB" get url 2>&1)"; RESTOREDS=$?
set -e
[ "$RESTOREDS" = 0 ] && ok 0 "restored metadata works again" || bad "restore failed ($RESTOREDS): $RESTORED"

echo
URL_AFTER="$(bash "$AB" get url 2>/dev/null || echo UNKNOWN)"
if [ "$URL_AFTER" = "$URL_BEFORE" ]; then
  ok "url" "bound tab unchanged through every refusal ($URL_AFTER)"
else
  bad "bound tab moved during the probes: $URL_BEFORE -> $URL_AFTER"
fi

if [ -f "/tmp/should-not-exist.webm" ] || [ -f "/tmp/should-not-exist.json" ]; then
  bad "a refused command produced a file on disk"
else
  ok "fs" "no refused command wrote to disk"
fi

echo
printf '%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
