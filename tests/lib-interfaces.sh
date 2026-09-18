#!/usr/bin/env bash
# Unit tests for the structured readers in scripts/lib.sh.
#
# These exist because the things they cover used to have no interface to test.
# Session and tab shapes were decoded by line number at 22 call sites across
# three scripts, and the session.meta ownership invariant was transcribed three
# times. Both now have one implementation, so both can be tested directly: no
# daemon, no mock browser, no session directory.
set -euo pipefail

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname "$TESTS_DIR")"
HELPER="$REPO_DIR/scripts/json.mjs"
NODE_BIN="$(command -v node)"

# shellcheck source=../scripts/lib.sh
. "$REPO_DIR/scripts/lib.sh"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/ab-lib-tests.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT INT TERM

PASSED=0
FAILED=0
ok()  { PASSED=$((PASSED + 1)); }
bad() { FAILED=$((FAILED + 1)); printf '✗ %s\n' "$*" >&2; }
eq()  { if [ "$2" = "$3" ]; then ok; else bad "$1: expected '$3', got '$2'"; fi; }

# ---------------------------------------------------------------------------
# ab__field: the reason the readers are position-independent
# ---------------------------------------------------------------------------
BLOB='active=1
pid=4242
page_count=3
socket_dir=/tmp/sockets
version=0.38.1'
eq "field active"      "$(ab__field "$BLOB" active)"      "1"
eq "field pid"         "$(ab__field "$BLOB" pid)"         "4242"
eq "field version"     "$(ab__field "$BLOB" version)"     "0.38.1"
eq "field socket_dir"  "$(ab__field "$BLOB" socket_dir)"  "/tmp/sockets"

# The regression this whole candidate is about: reorder the producer's output and
# every reader must still be right. Under the old positional decoding this was
# the failure that corrupted three scripts at once and raised no error anywhere.
SHUFFLED='version=0.38.1
socket_dir=/tmp/sockets
active=1
page_count=3
pid=4242'
eq "reordered active"  "$(ab__field "$SHUFFLED" active)"  "1"
eq "reordered pid"     "$(ab__field "$SHUFFLED" pid)"     "4242"
eq "reordered version" "$(ab__field "$SHUFFLED" version)" "0.38.1"

if ab__field "$BLOB" nosuchkey >/dev/null 2>&1; then
  bad "field: absent key should fail"
else
  ok
fi
# A value containing '=' must survive intact.
eq "field with =" "$(ab__field 'cdp_url=ws://h/p?a=b' cdp_url)" "ws://h/p?a=b"

# ---------------------------------------------------------------------------
# ab_tab_state
# ---------------------------------------------------------------------------
TABS='{"success":true,"data":{"tabs":[
  {"targetId":"TARGET-A","active":false},
  {"targetId":"TARGET-B","active":true}
]}}'
if ab_tab_state "$NODE_BIN" "$HELPER" "TARGET-A" "$TABS"; then
  eq "tab active"  "$AB_TAB_ACTIVE"        "TARGET-B"
  eq "tab present" "$AB_TAB_OWNED_PRESENT" "1"
  eq "tab count"   "$AB_TAB_COUNT"         "2"
else
  bad "tab_state: well-formed tab list was rejected"
fi

if ab_tab_state "$NODE_BIN" "$HELPER" "TARGET-GONE" "$TABS"; then
  eq "tab absent" "$AB_TAB_OWNED_PRESENT" "0"
  eq "tab absent keeps active" "$AB_TAB_ACTIVE" "TARGET-B"
else
  bad "tab_state: absent target should still parse"
fi

# No expected target: connect.sh uses this to learn which target it just bound.
if ab_tab_state "$NODE_BIN" "$HELPER" "" "$TABS"; then
  eq "tab no-expected active" "$AB_TAB_ACTIVE" "TARGET-B"
else
  bad "tab_state: empty expected target should parse"
fi

if ab_tab_state "$NODE_BIN" "$HELPER" "X" 'not json at all'; then
  bad "tab_state: malformed JSON should fail"
else
  ok
fi
# Two active tabs is an impossible state and must not be papered over.
if ab_tab_state "$NODE_BIN" "$HELPER" "X" \
  '{"success":true,"data":{"tabs":[{"targetId":"A","active":true},{"targetId":"B","active":true}]}}'; then
  bad "tab_state: two active tabs should fail"
else
  ok
fi

# ---------------------------------------------------------------------------
# ab_session_info — including the property that it never passes --cdp
# ---------------------------------------------------------------------------
STUB="$WORK/agent-browser"
cat > "$STUB" <<'STUBSH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$STUB_LOG"
case "${STUB_MODE:-ok}" in
  fail) echo "daemon unreachable" >&2; exit 1 ;;
  other-session) printf '{"success":true,"data":{"active":true,"pid":1,"session":"somebody-else","socketDir":"/s","version":"0.38.1","runtime":{"pageCount":0}}}\n' ;;
  *) printf '{"success":true,"data":{"active":true,"pid":4242,"session":"%s","socketDir":"/tmp/s","version":"0.38.1","runtime":{"pageCount":2}}}\n' "$STUB_SESSION" ;;
esac
STUBSH
chmod +x "$STUB"
export STUB_LOG="$WORK/stub.log"
export STUB_SESSION="ab-testsession"
: > "$STUB_LOG"

if ab_session_info "$STUB" "$NODE_BIN" "$HELPER" "ab-testsession"; then
  eq "session active"     "$AB_SESSION_ACTIVE"      "1"
  eq "session pid"        "$AB_SESSION_PID"         "4242"
  eq "session pages"      "$AB_SESSION_PAGE_COUNT"  "2"
  eq "session socket dir" "$AB_SESSION_SOCKET_DIR"  "/tmp/s"
  eq "session version"    "$AB_SESSION_VERSION"     "0.38.1"
else
  bad "session_info: healthy session was rejected"
fi

# The rule that used to be a comment at three call sites. `session info` must not
# be able to open a CDP connection, or asking whether a session is alive could
# spawn a browser.
if grep -q -- '--cdp' "$STUB_LOG"; then
  bad "session_info: passed --cdp, which could spawn a connection or a browser"
else
  ok
fi

STUB_MODE=fail ab_session_info "$STUB" "$NODE_BIN" "$HELPER" "ab-testsession" "$WORK/err" \
  && bad "session_info: a failing CLI should not return 0" \
  || eq "session_info CLI failure" "$?" "1"

STUB_MODE=other-session ab_session_info "$STUB" "$NODE_BIN" "$HELPER" "ab-testsession" "$WORK/err2" \
  && bad "session_info: a mismatched session should not return 0" \
  || eq "session_info wrong session" "$?" "2"

# ---------------------------------------------------------------------------
# ab_load_meta — one implementation of the ownership invariant
# ---------------------------------------------------------------------------
PORT=9222
OWNER_ID="owner-abc"
SLOT="default"
GOOD_KEY="$(ab_owner_key "$OWNER_ID" "$SLOT" "$PORT")"
SESSION="ab-${GOOD_KEY:0:24}"

write_meta() {
  local file="$1"
  shift
  {
    printf 'version=%s\n' "${MV:-$AB_META_VERSION}"
    printf 'owner_id=%s\n' "${MOID:-$OWNER_ID}"
    printf 'owner_key=%s\n' "${MKEY:-$GOOD_KEY}"
    printf 'session=%s\n' "${MSESS:-$SESSION}"
    printf 'label=demo\n'
    printf 'slot=%s\n' "${MSLOT:-$SLOT}"
    printf 'port=%s\n' "${MPORT:-$PORT}"
    printf 'cdp_url=%s\n' "${MURL:-ws://127.0.0.1:$PORT/devtools/browser/abc}"
    printf 'socket_dir=/tmp/s\n'
    printf 'owned_target_id=%s\n' "${MTARGET-TARGET-PRIMARY}"
    printf 'created_at=1\n'
  } > "$file"
}

META="$WORK/session.meta"
write_meta "$META"
if ab_load_meta "$META" "$SESSION" 1; then
  eq "meta session" "$AB_META_SESSION"         "$SESSION"
  eq "meta owner"   "$AB_META_OWNER_ID"        "$OWNER_ID"
  eq "meta port"    "$AB_META_PORT"            "$PORT"
  eq "meta target"  "$AB_META_OWNED_TARGET_ID" "TARGET-PRIMARY"
  eq "meta label"   "$AB_META_LABEL"           "demo"
else
  bad "load_meta: a well-formed record was rejected ($AB_META_ERROR)"
fi

for case_name in version session ownerkey ownerid slot port url target; do
  f="$WORK/bad-$case_name.meta"
  case "$case_name" in
    version)  MV=3 write_meta "$f" ;;
    session)  MSESS="ab-someoneelse" write_meta "$f" ;;
    ownerkey) MKEY="deadbeef" write_meta "$f" ;;
    ownerid)  MOID="someone-else" write_meta "$f" ;;
    slot)     MSLOT="other" write_meta "$f" ;;
    port)     MPORT="1234" write_meta "$f" ;;
    url)      MURL="ws://evil.test/devtools/browser/abc" write_meta "$f" ;;
    target)   MTARGET="" write_meta "$f" ;;
  esac
  if ab_load_meta "$f" "$SESSION" 1 2>/dev/null; then
    bad "load_meta: accepted a record with a tampered $case_name"
  elif [ -z "$AB_META_ERROR" ]; then
    bad "load_meta: rejected tampered $case_name without setting AB_META_ERROR"
  else
    ok
  fi
done

# connect.sh writes the record before it knows a target, so that case is only an
# error when the caller says it is. This is the one axis on which the two callers
# legitimately differ, and it is a parameter rather than two implementations.
MTARGET="" write_meta "$WORK/no-target.meta"
if ab_load_meta "$WORK/no-target.meta" "$SESSION" 0; then
  ok
else
  bad "load_meta: require_target=0 should accept a record with no target yet"
fi
if ab_load_meta "$WORK/no-target.meta" "$SESSION" 1 2>/dev/null; then
  bad "load_meta: require_target=1 should reject a record with no target"
else
  ok
fi

# A missing file and a symlinked file are both refused, not crashed on.
if ab_load_meta "$WORK/does-not-exist.meta" "$SESSION" 1 2>/dev/null; then
  bad "load_meta: accepted a missing file"
else
  ok
fi
ln -s "$META" "$WORK/linked.meta"
if ab_load_meta "$WORK/linked.meta" "$SESSION" 1 2>/dev/null; then
  bad "load_meta: accepted a symlinked record"
else
  ok
fi

if [ "$FAILED" -gt 0 ]; then
  printf '\n✗ lib interfaces: %d passed, %d failed\n' "$PASSED" "$FAILED" >&2
  exit 1
fi
printf '✓ lib interfaces: %d checks passed\n' "$PASSED"
