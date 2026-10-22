import assert from "node:assert/strict";
import { mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { spawnSync } from "node:child_process";

const root = resolve(import.meta.dirname, "..");
const helper = join(root, "scripts/json.mjs");
const guard = join(root, "scripts/guard.sh");
const bash = process.env.BASH || "/bin/bash";
const dir = mkdtempSync(join(tmpdir(), "ab-batch-"));
const log = join(dir, "argv.jsonl");
const adapter = join(dir, "guard.sh");
let checks = 0;
const run = (input, bashPath = bash, guardPath = adapter) => spawnSync(
  process.execPath, [helper, "batch-check", bashPath, guardPath],
  { input, encoding: "utf8", env: { ...process.env, BATCH_LOG: log, REAL_GUARD: guard } }
);
const refused = (input, code = 2, bashPath, guardPath) => {
  const result = run(input, bashPath, guardPath);
  assert.equal(result.status, code, result.stderr);
  assert.equal(result.stdout, "");
  assert.ok(result.stderr.length > 0);
  checks++;
};
try {
  writeFileSync(adapter, `#!/bin/bash
node -e 'require("node:fs").appendFileSync(process.env.BATCH_LOG, JSON.stringify(process.argv.slice(1))+"\\n")' "$@"
echo discarded-guard-stdout
. "$REAL_GUARD"
ab_guard_command 0 "$@"
`);
  const commands = [["fill", "#input", "", "", "two words", "\t", "a\"b", "a'b", "a\\b", "Olá 世界 🥔", "", ""], ["snapshot", "-i"]];
  const result = run(JSON.stringify(commands));
  assert.equal(result.status, 0, result.stderr);
  assert.deepEqual(JSON.parse(result.stdout), commands);
  assert.deepEqual(readFileSync(log, "utf8").trim().split("\n").map(JSON.parse), commands);
  checks++;
  assert.equal(run("[]").stdout.trim(), "[]");
  checks++;
  const largeCommands = Array.from({ length: 3 }, () => ["fill", "#input", "x".repeat(32 * 1024)]);
  const largeInput = JSON.stringify(largeCommands);
  writeFileSync(log, "");
  const largeResult = run(largeInput);
  assert.equal(largeResult.status, 0, largeResult.stderr);
  assert.equal(Buffer.byteLength(largeResult.stdout), Buffer.byteLength(largeInput) + 1, "complete JSON must survive output larger than pipe capacity");
  assert.deepEqual(JSON.parse(largeResult.stdout), largeCommands);
  assert.deepEqual(readFileSync(log, "utf8").trim().split("\n").map(JSON.parse), largeCommands);
  checks++;
  const capturedResult = spawnSync(bash, [
    "-c", 'batch="$("$1" "$2" batch-check "$3" "$4")" || exit $?; printf "%s" "$batch"',
    "batch-capture", process.execPath, helper, bash, guard,
  ], { input: largeInput, encoding: "utf8" });
  assert.equal(capturedResult.status, 0, capturedResult.stderr);
  assert.equal(Buffer.byteLength(capturedResult.stdout), Buffer.byteLength(largeInput));
  assert.deepEqual(JSON.parse(capturedResult.stdout), largeCommands);
  checks++;

  for (const input of ["", "[", "{}", "null", '["get url"]', "[[]]", '[["fill",1]]', '[["fill",null]]', '[["get","url"],[]]', '[["fill","x","\\u0000"]]', '[["fill","x","\\r"]]', '[["fill","x","\\n"]]', '[["fill","x","\\u001f"]]', '[["fill","x","\0"]]', '[["get","url"]]\0']) {
    writeFileSync(log, "");
    refused(input);
    assert.equal(readFileSync(log, "utf8"), "", "schema validation must finish before any guard child");
  }
  refused('[["get","url"],["tab","new","x"]]');
  refused('[["batch"]]');
  refused('[["newverb"]]', 10);
  refused('[[""]]', 10);
  refused('[["snapshot","--brand-new-flag"]]', 10);
  refused('[["fill","x","--session=other"]]');
  refused('[["get","url"]]', 2, join(dir, "missing-bash"));
  refused('[["get","url"]]', 2, bash, join(dir, "missing-guard"));
  const signal = join(dir, "signal.sh");
  writeFileSync(signal, 'kill -TERM "$$"\n');
  refused('[["get","url"]]', 2, bash, signal);
  refused(JSON.stringify([["fill", "x", "x".repeat(8 * 1024 * 1024)]]));
  const direct = spawnSync(bash, [guard, "batch"], { encoding: "utf8" });
  assert.equal(direct.status, 2);
  assert.match(direct.stderr, /Nested/);
  checks++;
  console.log(`ok - ${checks} structured batch boundary checks`);
} finally {
  rmSync(dir, { recursive: true, force: true });
}
