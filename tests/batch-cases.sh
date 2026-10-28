#!/usr/bin/env bash

assert_batch_refused() {
  local expected="$1" input="$2" message="${3:-}"
  local output
  output="$(printf '%s' "$input" | assert_wrapper_status "$AB" "$expected" batch --bail --json)"
  [ -z "$message" ] || assert_text_contains "$output" "$message"
}

BATCH_EXPECT='[["fill","#input","","","two words","\t","a\"b","a\u0027b","a\\b","Olá 世界 🥔","",""],["snapshot","-i"]]'
BATCH_OUTPUT="$(printf '%s' "$BATCH_EXPECT" | run_wrapper success "$AB" batch --bail --json)"
assert_eq "$BATCH_OUTPUT" "batched"
BATCH_EXPECT="$BATCH_EXPECT" node -e '
const assert = require("node:assert/strict");
const fs = require("node:fs");
assert.deepEqual(JSON.parse(fs.readFileSync(process.argv[1], "utf8")), JSON.parse(process.env.BATCH_EXPECT));
' "$CASE_STATE/batch-stdin"
assert_file_contains "$CASE_LOG" 'batch --bail --json'
assert_file_not_contains "$CASE_LOG" 'two\\ words'
BATCH_OUTPUT="$(printf '[]' | run_wrapper success "$AB" batch)"
assert_eq "$BATCH_OUTPUT" "batched"
assert_eq "$(cat "$CASE_STATE/batch-stdin")" '[]'
BATCH_OUTPUT="$(printf '%s' '[["get","url"]]' | run_wrapper success "$AB" batch --json --omit-command)"
assert_eq "$BATCH_OUTPUT" "batched"
assert_file_contains "$CASE_LOG" 'batch --json --omit-command'
pass "batch preserves exact arrays and keeps flags outside stdin"

assert_batch_refused 2 '[["get","url"],["bringtofront"]]' blocked
assert_batch_refused 2 '[["get","url"],["record","start","/tmp/demo.webm"]]' blocked
assert_batch_refused 2 '[["tab","new","http://forbidden.test"]]' blocked
assert_batch_refused 10 '[["t\u0027ab\u0027","new","http://forbidden.test"]]' allow-list
assert_batch_refused 2 '[["get","url"],["open","http://example.test","--enable","react-devtools"]]' blocked
assert_batch_refused 2 '[["batch","--json"]]' Nested
assert_batch_refused 10 '[["get","url"],["totallynewverb"]]' allow-list
assert_batch_refused 10 '[["snapshot","--brand-new-flag"]]' allow-list
for BATCH_BAD in '' '[' '{}' 'null' '["get url"]' '[[]]' '[["fill",1]]' '[["fill",null]]' '[["get","url"],[]]' '[["fill","x","\u0000"]]' '[["fill","x","\r"]]' '[["fill","x","\n"]]' '[["fill","x","\u001f"]]'; do
  assert_batch_refused 2 "$BATCH_BAD"
done
node -e 'process.stdout.write("[[\"fill\",\"x\",\"\0\"]]")' | assert_wrapper_status "$AB" 2 batch >/dev/null
node -e 'process.stdout.write("[[\"get\",\"url\"]]\0")' | assert_wrapper_status "$AB" 2 batch >/dev/null
node -e 'process.stdout.write(JSON.stringify([["fill","x","x".repeat(8*1024*1024)]]))' | assert_wrapper_status "$AB" 2 batch >/dev/null
MIGRATION_OUTPUT="$(assert_wrapper_status "$AB" 2 batch 'get url' 'snapshot -i')"
assert_text_contains "$MIGRATION_OUTPUT" 'JSON'
assert_text_contains "$MIGRATION_OUTPUT" 'stdin'
assert_wrapper_status "$AB" 2 batch '' >/dev/null
assert_wrapper_status "$AB" 10 batch --brand-new-flag >/dev/null
assert_wrapper_status "$AB" 2 batch --cdp elsewhere >/dev/null
assert_wrapper_status "$AB" 2 batch --max-output 10 >/dev/null
pass "batch validates all members before any native call and rejects retired operands"

cat > "$CASE_DIR/failing-guard-node" <<'ADAPTER'
#!/bin/bash
if [ "${2:-}" = batch-check ]; then
  exec node "$1" batch-check /nonexistent/batch-bash "$4"
fi
exec node "$@"
ADAPTER
chmod +x "$CASE_DIR/failing-guard-node"
printf '#!/bin/bash\nexec bash %q %q %q %q "$@"\n' \
  "$SKILL_DIR/scripts/dispatch.sh" "$CASE_ROOT/$SESSION/session.meta" \
  "$FAKE_BIN/agent-browser" "$CASE_DIR/failing-guard-node" > "$CASE_DIR/failing-guard-wrapper"
chmod +x "$CASE_DIR/failing-guard-wrapper"
GUARD_FAILURE_OUTPUT="$(printf '%s' '[["get","url"]]' | assert_wrapper_status "$CASE_DIR/failing-guard-wrapper" 2 batch)"
assert_text_contains "$GUARD_FAILURE_OUTPUT" 'batch guard could not complete'
pass "guard child execution failure stops dispatch before native access"
