#!/usr/bin/env bash
# Sourced by run.sh: exercise the real scripts through its isolated mock daemon.

assert_native_timeout() {
  local expected="$1"
  [ -s "$CASE_LOG.timeouts" ] || fail "no native timeout observations"
  awk -F '\t' -v expected="$expected" '$1 != expected {exit 1}' "$CASE_LOG.timeouts" \
    || fail "CLI did not consistently receive native timeout $expected"
}

# IV-C focused caller regressions.
for BAD_KEY in persistent react auto_approve idle_timeout_seconds; do
  new_case "malformed-release-$BAD_KEY"
  printf '%s\n/devtools/browser/policy-release\n' "$PORT" > "$CASE_CHROME/DevToolsActivePort"
  run_connect success "Malformed release" --persistent >/dev/null 2>&1
  META="$CASE_ROOT/$DEFAULT_SESSION/session.meta"
  ab_set_meta_value "$META" "$BAD_KEY" malformed
  : > "$CASE_LOG"
  : > "$CASE_LOG.events"
  STATUS=0
  run_cleanup 1 "$DEFAULT_SESSION" success 0 --keep-alive >/dev/null 2>&1 || STATUS=$?
  assert_eq "$STATUS" 5
  assert_eq "$(wc -l < "$CASE_LOG" | tr -d ' ')" 0
  [ -f "$META" ] && [ -f "$CASE_STATE/active" ] || fail "invalid keep-alive released state"
  STATUS=0
  AB_STOP_ATTEMPTS=0 run_cleanup 1 "$DEFAULT_SESSION" close-no-exit >/dev/null 2>&1 || STATUS=$?
  assert_eq "$STATUS" 5
  [ -f "$META" ] && [ -f "$CASE_STATE/active" ] || fail "unverified malformed-policy stop discarded recovery state"
  : > "$CASE_LOG.events"
  run_cleanup 1 "$DEFAULT_SESSION" >/dev/null 2>&1
  assert_socket_action close 1
  assert_socket_action unroute absent
  assert_socket_action tab_list absent
  assert_socket_action tab_close absent
  assert_file_not_contains "$CASE_LOG" --cdp
  [ ! -f "$CASE_STATE/active" ] || fail "malformed policy blocked daemon release"
  [ ! -e "$CASE_ROOT/$DEFAULT_SESSION" ] || fail "verified release retained wrapper"
  pass "malformed $BAD_KEY denies keep-alive but permits daemon-only release"
done

new_case invalid-policy-close-tab
printf '%s\n/devtools/browser/invalid-close\n' "$PORT" > "$CASE_CHROME/DevToolsActivePort"
run_connect success "Invalid optional closure" >/dev/null 2>&1
META="$CASE_ROOT/$DEFAULT_SESSION/session.meta"
ab_set_meta_value "$META" auto_approve malformed
: > "$CASE_LOG.events"
STATUS=0
run_cleanup 1 "$DEFAULT_SESSION" success 1 >"$CASE_DIR/cleanup.out" 2>&1 || STATUS=$?
assert_eq "$STATUS" 6
assert_file_not_contains "$CASE_DIR/cleanup.out" "The daemon version changed"
assert_socket_action close 1
assert_socket_action unroute absent
assert_socket_action tab_list absent
assert_socket_action tab_close absent
[ ! -f "$CASE_STATE/tab-closed" ] || fail "invalid policy closed a target"
[ ! -f "$CASE_STATE/active" ] || fail "optional closure failure blocked stop"
pass "invalid-policy close-tab preserves targets and returns partial release"

for LEGACY_KIND in lease_token last_used_at missing-timeout; do
  new_case "legacy-missing-$LEGACY_KIND"
  printf '%s\n/devtools/browser/legacy-missing\n' "$PORT" > "$CASE_CHROME/DevToolsActivePort"
  run_connect success "Legacy missing target" --persistent >/dev/null 2>&1
  META="$CASE_ROOT/$DEFAULT_SESSION/session.meta"
  AB="$CASE_ROOT/$DEFAULT_SESSION/ab"
  ab_set_meta_value "$META" owned_target_id ""
  if [ "$LEGACY_KIND" = missing-timeout ]; then
    awk '!/^idle_timeout_seconds=/' "$META" > "$CASE_DIR/legacy.meta"
    mv "$CASE_DIR/legacy.meta" "$META"
  else
    ab_set_meta_value "$META" "$LEGACY_KIND" 1
  fi
  : > "$CASE_LOG"
  : > "$CASE_LOG.events"
  assert_wrapper_status "$AB" 8 get url >/dev/null
  STATUS=0
  run_connect success "Refused internal migration" --recover >/dev/null 2>&1 || STATUS=$?
  assert_eq "$STATUS" 8
  assert_eq "$(wc -l < "$CASE_LOG" | tr -d ' ')" 0
  assert_socket_action session_info absent
  pass "legacy $LEGACY_KIND plus missing target refuses cached and internal recovery"
done

new_case failed-list-close
printf '%s\n/devtools/browser/failed-list\n' "$PORT" > "$CASE_CHROME/DevToolsActivePort"
run_connect success "Failed list" >/dev/null 2>&1
: > "$CASE_LOG.events"
STATUS=0
run_cleanup 1 "$DEFAULT_SESSION" tab-list-fail 1 >/dev/null 2>&1 || STATUS=$?
assert_eq "$STATUS" 6
assert_socket_action tab_list 1
assert_socket_action tab_close absent
assert_socket_action close 1
[ ! -f "$CASE_STATE/tab-closed" ] || fail "failed list authorized closure"
[ ! -f "$CASE_STATE/active" ] || fail "failed optional list prevented release"
pass "failed target list preserves every target and still stops the daemon"

new_case expire-before-admin
printf '%s\n/devtools/browser/expired-admin\n' "$PORT" > "$CASE_CHROME/DevToolsActivePort"
run_connect success "Expiry boundary" >/dev/null 2>&1
META="$CASE_ROOT/$DEFAULT_SESSION/session.meta"
: > "$CASE_LOG"
: > "$CASE_LOG.events"
STATUS=0
run_cleanup 1 "$DEFAULT_SESSION" expire-before-admin 0 --keep-alive >/dev/null 2>&1 || STATUS=$?
assert_eq "$STATUS" 5
assert_socket_action unroute absent
assert_socket_action tab_close absent
assert_socket_action close absent
assert_file_not_contains "$CASE_LOG" --cdp
[ ! -f "$CASE_STATE/active" ] || fail "expiry recreated daemon"
[ ! -f "$CASE_STATE/tab-closed" ] || fail "expiry mutated target"
[ -f "$META" ] || fail "uncertain route cleanup discarded metadata"
: > "$CASE_LOG.events"
run_cleanup 0 "$DEFAULT_SESSION" success 0 --keep-alive >/dev/null
assert_socket_action unroute absent
assert_socket_action close absent
pass "expiry after preflight never bootstraps and later inactivity reconciles without replay"
# End IV-C focused caller regressions.

new_case native-timeout
printf '%s\n/devtools/browser/native\n' "$PORT" > "$CASE_CHROME/DevToolsActivePort"
AGENT_BROWSER_IDLE_TIMEOUT_MS=17 run_connect success "Native owner" --idle-timeout 4 >/dev/null 2>&1
assert_native_timeout 4000
AB="$CASE_ROOT/$DEFAULT_SESSION/ab"
AGENT_BROWSER_IDLE_TIMEOUT_MS=19 run_wrapper success "$AB" get url >/dev/null
AGENT_BROWSER_IDLE_TIMEOUT_MS=23 run_cleanup 1 "$DEFAULT_SESSION" success 0 --keep-alive >/dev/null
AGENT_BROWSER_IDLE_TIMEOUT_MS=29 run_connect success "Same timeout" >/dev/null 2>&1
assert_native_timeout 4000
assert_file_not_contains "$CASE_LOG" ' close'
pass "owner timeout overrides ambient settings across connect, wrapper and task cleanup"

# Intercept only the recovery child, after dispatch has released its lock.
# The competing command is a separate real connect or cleanup, never a meta edit.
policy_handoff_case() {
  local policy="$1" status=0
  new_case "handoff-$policy"
  printf '%s\n/devtools/browser/handoff\n' "$PORT" > "$CASE_CHROME/DevToolsActivePort"
  run_connect success "Initial consent" --persistent --auto-approve --react --idle-timeout 4 --url http://example.test >/dev/null 2>&1
  META="$CASE_ROOT/$DEFAULT_SESSION/session.meta"
  AB="$CASE_ROOT/$DEFAULT_SESSION/ab"
  cat > "$FAKE_BIN/bash" <<'INTERCEPT'
#!/bin/bash
set -euo pipefail
if [ "${1:-}" = "$HANDOFF_CONNECT" ] && [ -f "$HANDOFF_TRIGGER" ]; then
  rm -f "$HANDOFF_TRIGGER"
  if [ "$HANDOFF_POLICY" = release ]; then
    /bin/bash "$HANDOFF_CLEANUP" "$HANDOFF_SESSION" >/dev/null 2>&1
    [ ! -e "$HANDOFF_META" ]
  elif [ "$HANDOFF_POLICY" = timeout ]; then
    /bin/bash "$1" "Concurrent timeout change" --port "$MOCK_PORT" --idle-timeout 7 --no-auto-approve >/dev/null 2>&1
    awk -F= '$1 == "idle_timeout_seconds" {print $2}' "$HANDOFF_META" > "$HANDOFF_REVOKED"
  else
    /bin/bash "$1" "Explicit revocation" --port "$MOCK_PORT" "--no-$HANDOFF_POLICY" --idle-timeout 0 >/dev/null 2>&1
    key="${HANDOFF_POLICY//-/_}"
    awk -F= -v key="$key" '$1 == key {print $2}' "$HANDOFF_META" > "$HANDOFF_REVOKED"
  fi
  rm -f "$MOCK_STATE_DIR/active"
  : > "$MOCK_LOG"
  : > "$MOCK_LOG.timeouts"
  : > "$MOCK_LOG.events"
fi
exec /bin/bash "$@"
INTERCEPT
  chmod +x "$FAKE_BIN/bash"
  touch "$CASE_DIR/handoff"
  rm -f "$CASE_STATE/active"
  HANDOFF_CONNECT="$CONNECT" HANDOFF_CLEANUP="$CLEANUP" HANDOFF_SESSION="$DEFAULT_SESSION" \
    HANDOFF_TRIGGER="$CASE_DIR/handoff" HANDOFF_POLICY="$policy" HANDOFF_META="$META" \
    HANDOFF_REVOKED="$CASE_DIR/revoked" MOCK_PORT="$PORT" AB_HEAL_TIMEOUT_SECONDS=15 \
    run_wrapper success "$AB" get url >"$CASE_DIR/result" 2>"$CASE_DIR/heal.err" || status=$?
  rm -f "$FAKE_BIN/bash"
  [ ! -e "$CASE_DIR/handoff" ] || fail "recovery did not hand off to the competing command"
  if [ "$policy" = release ]; then
    assert_eq "$status" 8
    [ ! -e "$META" ] || fail "pending recovery recreated a released owner"
    [ ! -e "$CASE_ROOT/$DEFAULT_SESSION" ] || fail "pending recovery recreated the released directory"
    assert_eq "$(wc -l < "$CASE_LOG" | tr -d ' ')" 0
    assert_socket_action close absent
    assert_socket_action tab_close absent
    assert_socket_action unroute absent
  elif [ "$policy" = timeout ]; then
    assert_eq "$status" 0
    assert_eq "$(< "$CASE_DIR/revoked")" 7
    assert_file_contains "$META" idle_timeout_seconds=7
    assert_file_contains "$META" auto_approve=0
    assert_file_not_contains "$CASE_LOG" osascript
    assert_native_timeout 7000
  else
    assert_eq "$(< "$CASE_DIR/revoked")" 0
    assert_eq "$(ab_meta_value "$META" "${policy//-/_}")" 0
    if [ "$policy" = persistent ]; then
      assert_eq "$status" 8
      assert_eq "$(wc -l < "$CASE_LOG" | tr -d ' ')" 0
      assert_socket_action close absent
      assert_socket_action tab_close absent
      assert_socket_action unroute absent
    else
      assert_eq "$status" 0
      assert_native_timeout 0
      assert_file_contains "$META" "persistent=1"
      if [ "$policy" = auto-approve ]; then
        assert_file_not_contains "$CASE_LOG" osascript
        assert_file_contains "$META" "react=1"
      else
        assert_file_contains "$META" "auto_approve=1"
      fi
    fi
  fi
  pass "recovery respects concurrent $policy revocation under connect's lock"
}

for HANDOFF_POLICY_CASE in auto-approve react persistent release timeout; do
  policy_handoff_case "$HANDOFF_POLICY_CASE"
done

new_case sticky-settings
printf '%s\n/devtools/browser/sticky\n' "$PORT" > "$CASE_CHROME/DevToolsActivePort"
run_connect success "First task" --persistent --auto-approve --react --url http://example.test >/dev/null 2>&1
META="$CASE_ROOT/$DEFAULT_SESSION/session.meta"
TARGET_BEFORE="$(ab_meta_value "$META" owned_target_id)"
: > "$CASE_LOG"
: > "$CASE_LOG.events"
MOCK_LSOF_LIVE=1 MOCK_PORT="$PORT" run_connect success "Follow-up task" >/dev/null 2>&1
assert_file_contains "$META" "persistent=1"
assert_file_contains "$META" "auto_approve=1"
assert_file_contains "$META" "react=1"
assert_eq "$(ab_meta_value "$META" owned_target_id)" "$TARGET_BEFORE"
assert_file_not_contains "$CASE_LOG" "osascript"
assert_file_not_contains "$CASE_LOG" " close"
assert_file_contains "$CASE_ROOT/$DEFAULT_SESSION/events.log" "attach mode=reused"
pass "a follow-up preserves settings and reuses the connection without an approver"

: > "$CASE_LOG"
: > "$CASE_LOG.events"
MOCK_DAEMON_PID=null MOCK_LSOF_LIVE=0 MOCK_PORT="$PORT" run_connect success "Unknown socket state" >/dev/null 2>&1
assert_file_not_contains "$CASE_LOG" "osascript"
assert_file_contains "$META" "auto_approve=1"
pass "unknown daemon PID preserves opt-in but does not authorize an approval clicker"

run_connect success "Explicit opt-out" --no-persistent --no-auto-approve --no-react >/dev/null 2>&1
run_connect success "Another follow-up" >/dev/null 2>&1
assert_file_contains "$META" "persistent=0"
assert_file_contains "$META" "auto_approve=0"
assert_file_contains "$META" "react=0"
pass "only explicit negative flags turn saved settings off"

# An old record may have no settings. It must not imply consent to auto-approve.
ab_set_meta_value "$META" auto_approve "invalid"
: > "$CASE_LOG"
: > "$CASE_LOG.events"
set +e
OUTPUT="$(run_connect success "Invalid consent" 2>&1)"
STATUS=$?
set -e
assert_eq "$STATUS" "5"
assert_text_contains "$OUTPUT" "auto_approve"
assert_eq "$(wc -l < "$CASE_LOG" | tr -d ' ')" "0"
run_connect success "Repair opt-out" --no-auto-approve >/dev/null 2>&1
assert_file_contains "$META" "auto_approve=0"
pass "malformed saved approval policy fails before touching the daemon"

for POLICY_KEY in persistent react auto_approve; do
  ab_set_meta_value "$META" "$POLICY_KEY" malformed
  assert_wrapper_status "$CASE_ROOT/$DEFAULT_SESSION/ab" 5 get url >/dev/null
  : > "$CASE_LOG"
  : > "$CASE_LOG.events"
  set +e
  OUTPUT="$(run_connect success "Malformed policy" 2>&1)"
  STATUS=$?
  set -e
  assert_eq "$STATUS" 5
  assert_text_contains "$OUTPUT" "$POLICY_KEY"
  assert_eq "$(wc -l < "$CASE_LOG" | tr -d ' ')" 0
  run_connect success "Repair negative" "--no-${POLICY_KEY//_/-}" >/dev/null 2>&1
  assert_eq "$(ab_meta_value "$META" "$POLICY_KEY")" 0
done
pass "all malformed booleans refuse dispatch and inherit, and matching negatives repair them"

# Removing keys models an older version-4 owner, not a new owner.
awk '!/^(persistent|react|auto_approve|idle_timeout_seconds)=/' "$META" > "$CASE_DIR/legacy.meta"
mv "$CASE_DIR/legacy.meta" "$META"
: > "$CASE_LOG"
: > "$CASE_LOG.events"
AB_IDLE_TIMEOUT_SECONDS=7 run_connect success "Legacy defaults" >/dev/null 2>&1
assert_file_contains "$META" "persistent=0"
assert_file_contains "$META" "react=0"
assert_file_contains "$META" "auto_approve=0"
assert_file_contains "$META" "idle_timeout_seconds=3600"
assert_file_not_contains "$CASE_LOG" osascript
run_connect success "Disable native idle" --idle-timeout 0 >/dev/null 2>&1
pass "missing policy keys disable booleans and use a fixed legacy timeout"

ab_set_meta_value "$META" idle_timeout_seconds malformed
assert_wrapper_status "$CASE_ROOT/$DEFAULT_SESSION/ab" 5 get url >/dev/null
: > "$CASE_LOG"
: > "$CASE_LOG.events"
set +e
run_connect success "Malformed timeout" >/dev/null 2>&1
STATUS=$?
set -e
assert_eq "$STATUS" 2
assert_eq "$(wc -l < "$CASE_LOG" | tr -d ' ')" 0
run_connect success "Repair timeout" --idle-timeout 0 >/dev/null 2>&1
assert_file_contains "$META" "idle_timeout_seconds=0"
pass "malformed saved timeout fails closed and explicit zero repairs it"

: > "$CASE_LOG"
: > "$CASE_LOG.events"
set +e
run_connect success "Recovery is not intent" --recover --persistent >/dev/null 2>&1
STATUS=$?
set -e
assert_eq "$STATUS" 2
assert_file_contains "$META" "persistent=0"
assert_eq "$(wc -l < "$CASE_LOG" | tr -d ' ')" 0
pass "internal recovery cannot turn explicit policy requests into renewed consent"

new_case missing-target-policy
printf '%s\n/devtools/browser/missing-target\n' "$PORT" > "$CASE_CHROME/DevToolsActivePort"
run_connect success "Verified owner" --persistent --react >/dev/null 2>&1
META="$CASE_ROOT/$DEFAULT_SESSION/session.meta"
AB="$CASE_ROOT/$DEFAULT_SESSION/ab"
ab_set_meta_value "$META" owned_target_id ""
ab_set_meta_value "$META" auto_approve malformed
assert_wrapper_status "$AB" 5 get url >/dev/null
ab_set_meta_value "$META" auto_approve 0
cp "$META" "$CASE_DIR/verified.meta"
ab_set_meta_value "$META" owner_key "$(ab_hash_value foreign)"
assert_wrapper_status "$AB" 5 get url >/dev/null
cp "$CASE_DIR/verified.meta" "$META"
OUTPUT="$(AB_CDP_PORT="$PORT" AB_CHROME_DATA_ROOTS="$CASE_CHROME" run_wrapper success "$AB" get url 2>"$CASE_DIR/heal.err")"
assert_eq "$OUTPUT" about:blank
assert_file_contains "$META" "owned_target_id=A1111111111111111111111111111111"
assert_file_contains "$META" "react=1"
assert_file_contains "$CASE_ROOT/$DEFAULT_SESSION/events.log" "heal-ok reason=no-owned-target"
pass "missing-target recovery requires verified owner and valid policy, then inherits React"

new_case keep-alive
printf '%s\n/devtools/browser/keep-alive\n' "$PORT" > "$CASE_CHROME/DevToolsActivePort"
run_connect success "First task" --persistent --url http://example.test >/dev/null
META="$CASE_ROOT/$DEFAULT_SESSION/session.meta"
AB="$CASE_ROOT/$DEFAULT_SESSION/ab"
TARGET_BEFORE="$(ab_meta_value "$META" owned_target_id)"
: > "$CASE_LOG"
: > "$CASE_LOG.events"
OUTPUT="$(run_cleanup 1 "$DEFAULT_SESSION" success 0 --keep-alive)"
assert_text_contains "$OUTPUT" "kept alive"
assert_socket_action unroute 1
assert_file_not_contains "$CASE_LOG" " close"
assert_file_not_contains "$CASE_LOG" "--cdp"
[ -f "$CASE_STATE/active" ] || fail "task cleanup stopped the live daemon"
[ -f "$CASE_SOCKET/$DEFAULT_SESSION.target" ] || fail "task cleanup removed the pin"
[ -x "$AB" ] || fail "task cleanup removed the wrapper"
assert_file_contains "$META" "persistent=1"
assert_eq "$(run_wrapper success "$AB" get url)" "http://example.test"
MOCK_LSOF_LIVE=1 MOCK_PORT="$PORT" run_connect success "Follow-up task" >/dev/null
assert_eq "$(ab_meta_value "$META" owned_target_id)" "$TARGET_BEFORE"
assert_eq "$(grep -c 'attach mode=fresh' "$CASE_ROOT/$DEFAULT_SESSION/events.log")" "1"
pass "task cleanup clears routes but retains the connection, wrapper, settings and pin"

set +e
OUTPUT="$(run_cleanup 1 "$DEFAULT_SESSION" unroute-fail 0 --keep-alive 2>&1)"
STATUS=$?
set -e
assert_eq "$STATUS" "5"
assert_text_contains "$OUTPUT" "routes"
[ -f "$CASE_STATE/active" ] || fail "failed task cleanup stopped the daemon"
[ -f "$META" ] || fail "failed task cleanup removed metadata"
pass "failed route cleanup is reported without disconnecting"

: > "$CASE_LOG"
: > "$CASE_LOG.events"
set +e
OUTPUT="$(run_cleanup 0 "$DEFAULT_SESSION" success 0 --keep-alive 2>&1)"
STATUS=$?
set -e
assert_eq "$STATUS" "5"
assert_text_contains "$OUTPUT" "without reconnecting"
assert_file_not_contains "$CASE_LOG" "network unroute"
assert_file_not_contains "$CASE_LOG" " close"
pass "task cleanup does not reconnect a dropped socket to clear routes"

: > "$CASE_LOG"
: > "$CASE_LOG.events"
set +e
OUTPUT="$(run_cleanup 1 "$DEFAULT_SESSION" success 1 --keep-alive 2>&1)"
STATUS=$?
set -e
assert_eq "$STATUS" "2"
assert_eq "$(wc -l < "$CASE_LOG" | tr -d ' ')" "0"
pass "keeping a connection and closing its tab are mutually exclusive"

# After a CLI upgrade even unroute could restart the daemon and launch a browser.
: > "$CASE_LOG"
: > "$CASE_LOG.events"
OUTPUT="$(MOCK_DAEMON_VERSION=0.35.0 run_cleanup 1 "$DEFAULT_SESSION" 2>&1)"
assert_file_not_contains "$CASE_LOG" "network unroute"
assert_socket_action close 1
assert_text_contains "$OUTPUT" "released"
pass "release after an upgrade skips browser commands and only stops the stale daemon"

new_case delayed-shutdown
printf '%s\n/devtools/browser/delayed-shutdown\n' "$PORT" > "$CASE_CHROME/DevToolsActivePort"
run_connect success "Delayed shutdown" >/dev/null
: > "$CASE_LOG"
: > "$CASE_LOG.events"
run_cleanup 1 "$DEFAULT_SESSION" close-delayed >/dev/null
[ ! -f "$CASE_STATE/active" ] || fail "release returned while the daemon was still shutting down"
[ "$(grep -c 'session info' "$CASE_LOG")" -ge 4 ] || fail "release did not verify asynchronous shutdown"
assert_file_not_contains "$CASE_LOG" "--cdp"
assert_socket_action close 1
pass "release waits for asynchronous daemon shutdown without reconnecting"

new_case lost-close-response
printf '%s\n/devtools/browser/lost-close\n' "$PORT" > "$CASE_CHROME/DevToolsActivePort"
run_connect success "Lost close reply" >/dev/null 2>&1
: > "$CASE_LOG.events"
run_cleanup 1 "$DEFAULT_SESSION" close-lost-response >/dev/null
assert_socket_action close 1
[ ! -f "$CASE_STATE/active" ] || fail "lost close reply did not reconcile verified inactivity"
assert_file_contains "$CASE_LOG.events" '"kind":"response-lost"'
pass "lost close reply reconciles inactivity without mutation replay"

new_case inactive-stop
printf '%s\n/devtools/browser/inactive-stop\n' "$PORT" > "$CASE_CHROME/DevToolsActivePort"
run_connect success "Inactive stop" >/dev/null 2>&1
rm -f "$CASE_STATE/active"
: > "$CASE_LOG.events"
run_cleanup 0 "$DEFAULT_SESSION" >/dev/null
assert_socket_action close absent
pass "already inactive release sends no socket mutation"

new_case incomplete-shutdown
printf '%s\n/devtools/browser/incomplete-shutdown\n' "$PORT" > "$CASE_CHROME/DevToolsActivePort"
run_connect success "Incomplete shutdown" >/dev/null
META="$CASE_ROOT/$DEFAULT_SESSION/session.meta"
set +e
OUTPUT="$(AB_STOP_ATTEMPTS=0 run_cleanup 1 "$DEFAULT_SESSION" close-no-exit 2>&1)"
STATUS=$?
set -e
assert_eq "$STATUS" "5"
[ -f "$META" ] || fail "unverified shutdown discarded recovery state"
[ -f "$CASE_STATE/active" ] || fail "test did not leave a live daemon"
assert_socket_action close 1
: > "$CASE_LOG"
: > "$CASE_LOG.events"
set +e
OUTPUT="$(AB_STOP_ATTEMPTS=0 MOCK_DAEMON_VERSION=0.35.0 run_connect close-no-exit "Failed upgrade stop" 2>&1)"
STATUS=$?
set -e
assert_eq "$STATUS" "5"
assert_file_not_contains "$CASE_LOG" "--cdp"
[ -f "$META" ] || fail "failed version-swap shutdown discarded metadata"
run_cleanup 1 "$DEFAULT_SESSION" >/dev/null
pass "unverified shutdown retains state and cannot proceed into a version-swap attach"

new_case timeout-transition
printf '%s\n/devtools/browser/timeout-transition\n' "$PORT" > "$CASE_CHROME/DevToolsActivePort"
run_connect success "Saved timeout" --persistent --idle-timeout 4 >/dev/null 2>&1
META="$CASE_ROOT/$DEFAULT_SESSION/session.meta"
AB="$CASE_ROOT/$DEFAULT_SESSION/ab"
cp "$META" "$CASE_DIR/before.meta"
cp "$CASE_SOCKET/$DEFAULT_SESSION.target" "$CASE_DIR/before.target"
: > "$CASE_LOG"
: > "$CASE_LOG.events"
: > "$CASE_LOG.timeouts"
MOCK_LSOF_LIVE=1 MOCK_PORT="$PORT" run_connect success "Changed timeout" --idle-timeout 7 >/dev/null 2>&1
assert_file_contains "$META" idle_timeout_seconds=7
assert_socket_action close 1
assert_socket_order 4000 7000




cmp "$CASE_SOCKET/$DEFAULT_SESSION.target" "$CASE_DIR/before.target" || fail "timeout replacement changed target binding"
assert_eq "$(ab_meta_value "$META" owned_target_id)" A1111111111111111111111111111111
: > "$CASE_LOG"
: > "$CASE_LOG.events"
: > "$CASE_LOG.timeouts"
run_wrapper success "$AB" get url >/dev/null
run_cleanup 1 "$DEFAULT_SESSION" success 0 --keep-alive >/dev/null
run_connect success "Unchanged explicit timeout" --idle-timeout 7 >/dev/null 2>&1
assert_native_timeout 7000
assert_file_not_contains "$CASE_LOG" ' close'
pass "changed timeout replaces deliberately and unchanged timeout retains transport"

for INITIAL_STATE in live inactive; do
  cp "$META" "$CASE_DIR/rollback.meta"
  cp "$AB" "$CASE_DIR/rollback.ab"
  [ "$INITIAL_STATE" = live ] || rm -f "$CASE_STATE/active"
  : > "$CASE_LOG"
  : > "$CASE_LOG.events"
  : > "$CASE_LOG.timeouts"
  set +e
  run_connect attach-fail "Failed timeout change" --idle-timeout 9 >/dev/null 2>&1
  STATUS=$?
  set -e
  assert_eq "$STATUS" 5
  cmp "$META" "$CASE_DIR/rollback.meta" || fail "failed timeout change replaced committed policy"
  cmp "$AB" "$CASE_DIR/rollback.ab" || fail "failed timeout change replaced wrapper"
  cmp "$CASE_SOCKET/$DEFAULT_SESSION.target" "$CASE_DIR/before.target" || fail "failed timeout change lost target binding"
  [ ! -e "$CASE_STATE/active" ] || fail "uncommitted replacement survived rollback"
  assert_file_not_contains "$CASE_LOG" 'tab close'
  assert_file_contains "$CASE_LOG.timeouts" '9000'
  run_connect success "Resume saved policy" >/dev/null 2>&1
  assert_file_contains "$META" idle_timeout_seconds=7
done
pass "failed timeout replacements stop before restoring live or inactive owner artifacts"

: > "$CASE_LOG"
: > "$CASE_LOG.events"
: > "$CASE_LOG.timeouts"
cp "$META" "$CASE_DIR/stop.meta"
set +e
AB_STOP_ATTEMPTS=0 run_connect close-no-exit "Unverified stop" --idle-timeout 8 >/dev/null 2>&1
STATUS=$?
set -e
assert_eq "$STATUS" 5
cmp "$META" "$CASE_DIR/stop.meta" || fail "unverified stop changed saved policy"
assert_file_not_contains "$CASE_LOG" --cdp
assert_native_timeout 7000
pass "unverified old daemon shutdown refuses timeout replacement"

: > "$CASE_LOG"
: > "$CASE_LOG.events"
: > "$CASE_LOG.timeouts"
MOCK_DAEMON_VERSION=0.35.0 run_connect success "Version replacement" >/dev/null 2>&1
assert_native_timeout 7000
assert_socket_action close 1
pass "version replacement and its diagnostics inherit the committed native timeout"

AGENT_BROWSER_IDLE_TIMEOUT_MS=1 run_connect success "Disable native idle" --idle-timeout 0 >/dev/null 2>&1
: > "$CASE_LOG.timeouts"
AGENT_BROWSER_IDLE_TIMEOUT_MS=1 run_wrapper success "$AB" get url >/dev/null
AGENT_BROWSER_IDLE_TIMEOUT_MS=1 run_connect success "Inherited disabled idle" >/dev/null 2>&1
AGENT_BROWSER_IDLE_TIMEOUT_MS=1 run_cleanup 1 "$DEFAULT_SESSION" success 0 --keep-alive >/dev/null
assert_native_timeout 0
pass "explicit zero remains disabled under conflicting ambient native configuration"

run_connect success "Maximum timeout" --idle-timeout 2147483647 >/dev/null 2>&1
: > "$CASE_LOG.timeouts"
run_wrapper success "$AB" get url >/dev/null
run_connect success "Inherited maximum" >/dev/null 2>&1
run_cleanup 1 "$DEFAULT_SESSION" success 0 --keep-alive >/dev/null
assert_native_timeout 2147483647000
pass "maximum accepted seconds convert without overflow"

new_case legacy-native-migration
printf '%s\n/devtools/browser/migration\n' "$PORT" > "$CASE_CHROME/DevToolsActivePort"
run_connect success "Legacy owner fixture" --idle-timeout 4 --auto-approve >/dev/null 2>&1
META="$CASE_ROOT/$DEFAULT_SESSION/session.meta"
AB="$CASE_ROOT/$DEFAULT_SESSION/ab"
ab_set_meta_value "$META" lease_token "$(ab_hash_value legacy)"
ab_set_meta_value "$META" last_used_at 1
assert_wrapper_status "$AB" 8 get url >/dev/null
ab_set_meta_value "$META" auto_approve malformed
: > "$CASE_LOG"
: > "$CASE_LOG.events"
: > "$CASE_LOG.timeouts"
run_connect success "Deliberate migration and consent repair" --no-auto-approve >/dev/null 2>&1
assert_socket_action close 1
assert_file_not_contains "$META" lease_token
assert_file_not_contains "$META" last_used_at
assert_file_contains "$META" auto_approve=0
assert_file_contains "$META" idle_timeout_seconds=4
assert_file_not_contains "$CASE_LOG" osascript
assert_socket_order 0 4000

: > "$CASE_LOG"
: > "$CASE_LOG.events"
: > "$CASE_LOG.timeouts"
run_wrapper success "$AB" get url >/dev/null
assert_native_timeout 4000
assert_file_not_contains "$CASE_LOG" ' close'
pass "legacy live owners require deliberate migration and retain explicit consent repair"

new_case failed-replacement-shutdown
printf '%s\n/devtools/browser/failed-replacement\n' "$PORT" > "$CASE_CHROME/DevToolsActivePort"
run_connect success "Original owner" --idle-timeout 4 >/dev/null 2>&1
META="$CASE_ROOT/$DEFAULT_SESSION/session.meta"
AB="$CASE_ROOT/$DEFAULT_SESSION/ab"
set +e
AB_STOP_ATTEMPTS=0 run_connect attach-fail-close-no-exit "Unsafe rollback" --idle-timeout 8 >/dev/null 2>&1
STATUS=$?
set -e
assert_eq "$STATUS" 5
[ ! -f "$META" ] || fail "old policy still authorizes uncommitted replacement"
[ ! -x "$AB" ] || fail "wrapper still authorizes uncommitted replacement"
[ -f "$CASE_STATE/active" ] || fail "fixture did not leave an unverified replacement"
[ -f "$CASE_SOCKET/$DEFAULT_SESSION.target" ] || fail "unverified shutdown discarded target proof"
pass "unverified replacement shutdown disables commands instead of restoring misleading policy"

# Invalid timeouts fail before state is allocated or Chrome is touched.
new_case invalid-idle-timeout
for INVALID_TIMEOUT in '' -1 nope 2147483648; do
  set +e
  OUTPUT="$(run_connect success "Invalid timeout" --idle-timeout "$INVALID_TIMEOUT" 2>&1)"
  STATUS=$?
  set -e
  assert_eq "$STATUS" "2"
  assert_text_contains "$OUTPUT" "idle timeout"
done
assert_eq "$(wc -l < "$CASE_LOG" | tr -d ' ')" "0"
pass "invalid idle timeouts fail without browser commands"
