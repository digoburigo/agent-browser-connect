#!/usr/bin/env node

import { spawnSync } from "node:child_process";

const readStdin = async () => {
  const chunks = [];
  for await (const chunk of process.stdin) {
    chunks.push(chunk);
  }
  return Buffer.concat(chunks).toString("utf-8");
};

const fail = (message, code = 1) => {
  process.stderr.write(`${message}\n`);
  process.exit(code);
};

const parseInput = (input) => {
  try {
    return JSON.parse(input);
  } catch {
    fail("invalid agent-browser JSON");
  }
};

const parseBatch = (input) => {
  let commands;
  try {
    commands = JSON.parse(input);
  } catch {
    fail("batch stdin must be valid JSON", 2);
  }
  if (!Array.isArray(commands)) {
    fail("batch stdin must be a JSON array of string arrays", 2);
  }
  commands.forEach((entry, index) => {
    if (!Array.isArray(entry) || entry.length === 0) {
      fail(`batch command ${index} must be a nonempty array of strings`, 2);
    }
    for (const word of entry) {
      if (typeof word !== "string" || /[\u0000\u001F\r\n]/u.test(word)) {
        fail(`batch command ${index} contains a non-string or unsafe word`, 2);
      }
    }
  });
  return commands;
};

const guardBatch = (commands, bashPath, guardPath) => {
  for (const words of commands) {
    const child = spawnSync(bashPath, [guardPath, ...words], {
      shell: false,
      stdio: ["ignore", "ignore", "inherit"],
    });
    if (child.error || child.signal || child.status !== 0) {
      if (child.error || child.signal || ![2, 10].includes(child.status)) {
        fail("batch guard could not complete; no browser command was sent", 2);
      }
      process.exit(child.status);
    }
  }
};

const validateString = (value, field) => {
  if (typeof value !== "string" || /[\r\n\t]/u.test(value)) {
    fail(`invalid ${field} in agent-browser JSON`);
  }
  return value;
};

const command = process.argv[2];
const expected = process.argv[3] ?? "";
const input = await readStdin();
if (command === "batch-check") {
  const commands = parseBatch(input);
  guardBatch(commands, process.argv[3], process.argv[4]);
  await new Promise((resolve, reject) => {
    process.stdout.write(`${JSON.stringify(commands)}\n`, (error) => {
      if (error) reject(error);
      else resolve();
    });
  });
  process.exit(0);
}

if (command === "target-url") {
  // agent-browser's `<session>.target` sidecar: {"targetId","url","pinned"}. A
  // persistent heal reopens a closed tab at the URL it last had, so only a URL
  // that is safe to hand `tab new` is printed; anything else prints nothing and
  // the replacement opens at about:blank.
  let sidecar;
  try {
    sidecar = JSON.parse(input);
  } catch {
    process.exit(0);
  }
  const url = typeof sidecar?.url === "string" ? sidecar.url : "";
  if (
    url.length <= 2048 &&
    !/[\s\u0000-\u001F]/u.test(url) &&
    (/^https?:\/\/[^\s]+$/u.test(url) || url === "about:blank")
  ) {
    process.stdout.write(`${url}\n`);
  }
  process.exit(0);
}

const payload = parseInput(input);

if (
  payload?.success !== true ||
  typeof payload.data !== "object" ||
  payload.data === null
) {
  fail("agent-browser JSON did not report success");
}

if (command === "session-info") {
  const session = validateString(
    payload.data.session ?? payload.data.runtime?.session,
    "session"
  );
  if (!expected || session !== expected) {
    fail(`agent-browser returned session '${session}', expected '${expected}'`);
  }

  if (typeof payload.data.active !== "boolean") {
    fail("invalid active in agent-browser JSON");
  }
  const active = payload.data.active ? "1" : "0";
  const pid =
    Number.isSafeInteger(payload.data.pid) && payload.data.pid > 0
      ? String(payload.data.pid)
      : "";
  const pageCountValue = payload.data.runtime?.pageCount ?? 0;
  const pageCount =
    Number.isSafeInteger(pageCountValue) && pageCountValue >= 0
      ? String(pageCountValue)
      : "0";
  const socketDir = validateString(
    payload.data.socketDir ?? payload.data.runtime?.socketDir ?? "",
    "socketDir"
  );
  // The daemon reports the agent-browser version it is running. An upgrade
  // leaves an older daemon holding the session, and the next browser command
  // restarts it; connect and dispatch compare this against the CLI on PATH so
  // that restart never happens mid-command.
  const versionValue =
    payload.data.version ?? payload.data.runtime?.version ?? "";
  const version =
    typeof versionValue === "string"
      ? validateString(versionValue, "version")
      : "";
  // Named fields, not bare lines in a fixed order: three shell scripts read this
  // and a reordering here used to corrupt all of them silently.
  process.stdout.write(
    `active=${active}\npid=${pid}\npage_count=${pageCount}\nsocket_dir=${socketDir}\nversion=${version}\n`
  );
  process.exit(0);
}

if (command === "tab-state") {
  const tabs = payload.data.tabs;
  if (!Array.isArray(tabs)) {
    fail("agent-browser tab JSON did not contain a tabs array");
  }

  const activeTabs = tabs.filter((tab) => tab?.active === true);
  if (activeTabs.length > 1) {
    fail("agent-browser reported more than one active tab");
  }

  const activeTarget =
    activeTabs.length === 1
      ? validateString(activeTabs[0].targetId, "active targetId")
      : "";
  let expectedPresent = "0";
  if (expected) {
    expectedPresent = tabs.some((tab) => tab?.targetId === expected)
      ? "1"
      : "0";
  }
  process.stdout.write(
    `active_target=${activeTarget}\nowned_present=${expectedPresent}\ncount=${tabs.length}\n`
  );
  process.exit(0);
}

fail(`unknown JSON helper command: ${command}`);
