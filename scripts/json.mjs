#!/usr/bin/env node

const readStdin = async () => {
  const chunks = [];
  for await (const chunk of process.stdin) {
    chunks.push(chunk);
  }
  return Buffer.concat(chunks).toString("utf8");
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

const splitShellWords = (input) => {
  if (/[\u001f\r\n]/u.test(input)) {
    fail("batch command contains an unsafe control character");
  }
  const words = [];
  let current = "";
  let inDouble = false;
  let inSingle = false;
  for (let index = 0; index < input.length; index += 1) {
    const character = input[index];
    if (character === "\\" && !inSingle) {
      index += 1;
      if (index < input.length) {
        current += input[index];
      }
    } else if (character === '"' && !inSingle) {
      inDouble = !inDouble;
    } else if (character === "'" && !inDouble) {
      inSingle = !inSingle;
    } else if (character === " " && !inDouble && !inSingle) {
      if (current) {
        words.push(current);
        current = "";
      }
    } else {
      current += character;
    }
  }
  if (current) {
    words.push(current);
  }
  return words;
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
if (command === "batch-argument") {
  process.stdout.write(`${splitShellWords(input).join("\u001f")}\n`);
  process.exit(0);
}
if (command === "batch-encode") {
  // C4: the dispatcher guards the words it parsed, then has to hand agent-browser
  // something to run. Handing back the ORIGINAL string means two parsers decide
  // one policy, and they do not agree on every input (this splitter treats a tab
  // as an ordinary character; a shell does not). Re-encoding the guarded words as
  // the JSON stdin form removes the second parse entirely: what was checked is
  // exactly what runs.
  const commands = input
    .split("\n")
    .filter((line) => line.length > 0)
    .map((line) => line.split("\u001f"));
  if (commands.length === 0) {
    fail("batch-encode received no commands");
  }
  process.stdout.write(`${JSON.stringify(commands)}\n`);
  process.exit(0);
}

const payload = parseInput(input);

if (
  command !== "batch-stdin" &&
  (payload?.success !== true || typeof payload.data !== "object" || payload.data === null)
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

  const active = payload.data.active === true ? "1" : "0";
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
  const versionValue = payload.data.version ?? payload.data.runtime?.version ?? "";
  const version = typeof versionValue === "string" ? validateString(versionValue, "version") : "";
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
    expectedPresent = tabs.some((tab) => tab?.targetId === expected) ? "1" : "0";
  }
  process.stdout.write(
    `active_target=${activeTarget}\nowned_present=${expectedPresent}\ncount=${tabs.length}\n`
  );
  process.exit(0);
}

if (command === "batch-stdin") {
  // Stdin batch mode: an array of string arrays. Print one command per line with
  // words joined by the ASCII unit separator so the dispatcher can guard each one
  // without re-splitting on whitespace.
  if (!Array.isArray(payload)) {
    fail("batch stdin must be a JSON array of string arrays");
  }
  const lines = payload.map((entry, index) => {
    if (!Array.isArray(entry) || entry.length === 0) {
      fail(`batch command ${index} is not a non-empty array`);
    }
    return entry
      .map((word) => {
        if (typeof word !== "string" || /[\u001f\r\n]/u.test(word)) {
          fail(`batch command ${index} contains a non-string or unsafe word`);
        }
        return word;
      })
      .join("\u001f");
  });
  process.stdout.write(`${lines.join("\n")}\n`);
  process.exit(0);
}

fail(`unknown JSON helper command: ${command}`);
