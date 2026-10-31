// Keeps every tool agent-browser exposes classified against scripts/guard.sh.
//
// tests/mcp-catalog.tsv has one row per tool, recording its input properties, the
// words that reach the same CLI command and the guard status those words get.
//
//   node tests/mcp-catalog.mjs          each row still gets its recorded status
//   node tests/mcp-catalog.mjs --live   also compare rows with the installed CLI
//
// The default needs no CLI, so tests/run.sh runs it on every push. Run --live after
// a version bump: past bumps found new commands and flags only when a task hit exit
// 10. MCP does not expose every CLI flag, so a clean run narrows that gap and does
// not close it.
import { readFileSync } from "node:fs";
import { join, resolve } from "node:path";
import { spawnSync } from "node:child_process";

const root = resolve(import.meta.dirname, "..");
const guard = join(root, "scripts/guard.sh");
const bash = process.env.BASH || "/bin/bash";
const args = process.argv.slice(2);
const live = args.includes("--live");
const catalog = args.find((arg) => arg !== "--live") ?? join(root, "tests/mcp-catalog.tsv");
const toolPrefix = "agent_browser_";
const problems = [];

const parseProps = (field) => (field === "-" ? [] : field.split(","));
const rows = new Map();
let shared = [];
for (const line of readFileSync(catalog, "utf8").split("\n")) {
  if (!line || line.startsWith("#")) continue;
  const [tool, props, expected, ...words] = line.split("\t");
  if (tool === "*") shared = parseProps(props);
  else rows.set(tool, { props: parseProps(props), expected: Number(expected), words });
}

// Nested batch is allowed here because dispatch.sh checks with the same setting.
const guardStatus = (words) => spawnSync(
  bash, ["-c", '. "$1"; shift; ab_guard_command 1 "$@"', "_", guard, ...words],
  { encoding: "utf8" }
).status;

for (const [tool, { expected, words }] of rows) {
  const status = guardStatus(words);
  if (status !== expected) {
    problems.push(`${tool}: '${words.join(" ")}' expected guard status ${expected}, got ${status}`);
  }
}

const listTools = () => {
  const tools = [];
  let cursor;
  do {
    const request = { jsonrpc: "2.0", id: 1, method: "tools/list", params: cursor ? { cursor } : {} };
    const result = spawnSync("agent-browser", ["mcp", "--tools", "all"], {
      input: `${JSON.stringify(request)}\n`,
      encoding: "utf8",
    });
    if (result.status !== 0) {
      throw new Error(`agent-browser mcp failed: ${result.error?.message ?? result.stderr}`);
    }
    const page = JSON.parse(result.stdout.trim().split("\n").pop()).result;
    tools.push(...page.tools);
    cursor = page.nextCursor;
  } while (cursor);
  return tools;
};

const compareProps = (subject, recorded, actual) => {
  const added = actual.filter((prop) => !recorded.includes(prop));
  const removed = recorded.filter((prop) => !actual.includes(prop));
  if (added.length) problems.push(`${subject}: new input ${added.join(",")}; allow or deny its flag in scripts/guard.sh, then record it`);
  if (removed.length) problems.push(`${subject}: input gone ${removed.join(",")}; remove it from the row`);
};

if (live) {
  const tools = listTools().map((tool) => ({
    name: tool.name.replace(toolPrefix, ""),
    props: Object.keys(tool.inputSchema?.properties ?? {}).sort(),
  }));
  const common = tools[0].props.filter((prop) => tools.every((tool) => tool.props.includes(prop)));
  compareProps("every tool", shared, common);
  for (const { name, props } of tools) {
    const own = props.filter((prop) => !common.includes(prop));
    const row = rows.get(name);
    if (row) compareProps(name, row.props, own);
    else problems.push(`${name}: new tool; classify it in scripts/guard.sh, then add a row`);
  }
  const names = new Set(tools.map((tool) => tool.name));
  for (const tool of rows.keys()) {
    if (!names.has(tool)) problems.push(`${tool}: tool gone; remove its row and check its guard entries`);
  }
}

if (problems.length) {
  for (const problem of problems) console.error(`✗ ${problem}`);
  console.error(`\n✗ MCP catalog: ${problems.length} difference(s)`);
  process.exit(1);
}
console.log(`ok - ${rows.size} MCP catalog tools classified${live ? " and matching the installed CLI" : ""}`);
