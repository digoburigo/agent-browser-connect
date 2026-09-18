# agent-browser-connect troubleshooting

Read this reference when connection approval repeats, port 9222 is unavailable, Chrome restarts, a pin disappears, commands reach the wrong page, or stale daemons accumulate.

## Connection approval and port diagnostics

Chrome's remote-debugging toggle and connection approval are separate:

- `chrome://inspect/#remote-debugging` remembers that the server is enabled.
- Approval mode still asks once for each incoming WebSocket connection.
- Another connected agent does not authorize a new connection.

A new helper session should show at most one approval dialog. Approve that one while `connect.sh` waits. The helper performs one attach and does not silently retry; repeated dialogs mean another process is reconnecting.

### Repeated dialogs during React profiling

On a `--cdp`-attached session the daemon dials a **new** WebSocket to Chrome whenever one
invocation's launch-affecting flags differ from the previous one's, and approval mode
prompts once per connection. `--enable react-devtools` is the flag that trips it here:
the wrapper runs `tab list` (no flag), then your command (with the flag), then `tab list`
again, so one hooked `open` costs **two** reconnects. Repeating identical flags is free.

Measured on 0.38.0 (2026-09-16, the user's Chrome): the daemon holds exactly **one**
established socket to 9222 in steady state, and each flag flip replaces it — the local
port changes (`:57287` → `:57332` → `:57338`) and nothing accumulates. Through 0.37.1 the
old socket was stranded instead: a session that profiled six pages that way held 11
established sockets, one that never used `--enable` held 1. That leak is fixed upstream
(PR #1739, shipped in 0.38.0, closes #1726); the dialogs are not.

Connect with `--react` instead (`connect.sh <label> --react --url <url>`). It exports
`AGENT_BROWSER_ENABLE=react-devtools`, so the hook is registered as a session init script
at attach time, survives every later navigation, and costs one dialog for the whole
session. The hook cannot be added to a daemon that is already running: release it with
`cleanup.sh <session>` and connect again with `--react`.

`/json/version` and `/json/list` return HTTP 404 when approval mode is active, so they are not health checks. `connect.sh` checks raw TCP, reads the matching `DevToolsActivePort` file without opening a WebSocket, and passes the exact URL to agent-browser. If no standard file is visible, it passes the generic browser WebSocket directly without a discovery probe.

Avoid `--cdp 9222` and `--auto-connect` because agent-browser's discovery path may probe and reconnect.

If the TCP port is not listening after the bounded wait, ask the user to:

1. Open `chrome://inspect/#remote-debugging`.
2. Tick “Allow remote debugging for this browser instance”.
3. Wait for `Server running at: 127.0.0.1:9222`.
4. Re-run `connect.sh`.

Keep using the existing Chrome rather than launching a substitute.

## Failure recovery

| Symptom | Meaning | Recovery |
|---|---|---|
| `tab_gone` | The owned pinned target was closed | Re-run `connect.sh <any-label> --url <url>` for the same owner/slot. The helper creates one controlled replacement. |
| First connection times out | Approval was not completed or attachment failed | Approve the one Chrome dialog and re-run connect for the same owner/slot or explicit session. |
| Wrapper reports corrected drift | The persisted binding changed while the owned target still existed | The dispatcher restores the target before running the requested command. Continue through the same wrapper and stop using any bare browser command. |
| Commands reach the wrong page | A bare agent-browser command bypassed the guard | Return to the wrapper. `tab list` is the only public tab-management operation it permits. |
| Chrome keeps switching between two agents' tabs | Something brought a tab to the front: a fresh connect (new tabs open in the foreground), a `tab_gone` recovery, a drift restore (`tab <id>` always sends `Page.bringToFront`), or a bare `bringtofront` | Read `events.log` in each agent's wrapper directory (the path `connect.sh` printed, minus `/ab`). Zero `drift-restored` lines means the wrapper is not the cause; look for bare `agent-browser` calls or repeated reconnects. `cleanup.sh` prints the same counts and archives the log under `<wrapper root>/.history/`. |
| A second Chrome window appeared and stayed after the task | `record start` ran on the session (through a wrapper older than 2026-09-04, or bare). It creates a new browser context, which Chrome shows as its own window, and `record stop` does not close it | Close that window by hand. The wrapper now rejects `record`; use `screenshot` for stills, or `trace start|stop` / `profiler start|stop` to capture what happened. A fresh attach can also land in a new window when Chrome has no normal window open for the default profile; that one is Chrome's placement rule, not the skill |
| `Ref not found: @eN` | The page changed after a snapshot | Run `bash <wrapper> snapshot -i` again and use fresh refs. |
| Chrome restarted | The exact browser WebSocket changed | Re-run connect for the same owner/slot or explicit session. |
| `agent-browser was upgraded (X → Y)` from the wrapper, exit 8 | A live session is still held by a daemon running the previous version | Re-run `connect.sh`. It stops the stale daemon and attaches once with the current version, keeping the same tab. Never work around it by calling `agent-browser` directly: the restart that a browser command triggers drops the CDP attachment and can launch a substitute Chrome (reproduced 2026-09-16, 0.37.1 → 0.38.0, `⚠ Daemon version mismatch detected, restarting...` followed by `[agent-browser] launched browser` and a full Chrome for Testing process tree). |
| Unexpected behavior after an upgrade | Daemon or socket state may be stale | Re-run `connect.sh` for each session you own, then `agent-browser doctor`; add `--fix` only when it recommends doing so. |
| Every new session times out while the port remains open | Too many browser-attached daemons may be active | Inspect and close only sessions proven stale. |
| `Connection refused (os error 61)` from connect, exit 4 | Chrome quit, crashed, or had remote debugging switched off between the port check and the attach; or it restarted and the resolved endpoint is stale | **Not an approval dialog — do not wait for one.** Connect re-probes the port and says which case it is. If the port is still open, re-run the same connect to resolve the current endpoint. If it is closed, ask the user to confirm Chrome is running with remote debugging on, then re-run. |
| Chrome died during a stress run | `tests/stress-user-chrome.sh` at a high tab count can segfault the browser (recorded 2026-09-18, Chrome 153, `CrBrowserMain`) | Expected hazard of that script, not of ordinary use. Sessions still release cleanly; verify with `agent-browser session list`. Re-run with fewer tabs, or against a browser you can afford to lose. |
| `Can't assign requested address (os error 49)` | The machine is out of ephemeral ports | Identify the leaking process and tell the user; do not kill it without permission. |

## Exit statuses

| Status | Meaning | Next step |
|---|---|---|
| `0` | Operation completed with exact ownership intact | Continue through the wrapper, or report cleanup success. |
| `2` | A command the guard deliberately forbids | The message names the reason and the sanctioned alternative. Use it; do not bypass the wrapper. Distinct from `10`, which means the command is merely unlisted. |
| `3` | A required executable is unavailable | Restore `agent-browser` or Node on `PATH`. |
| `4` | Chrome is not listening or its endpoint cannot be resolved | Enable remote debugging and re-run connect. |
| `5` | Session state, locking, diagnostics, or shutdown could not be validated | Preserve artifacts and follow the emitted recovery instruction. |
| `6` | Cleanup was asked to `--close-tab`, detached safely, but could not prove the owned target closed | The tab may remain open; close it manually only if requested, without touching unknown targets. |
| `7` | The daemon stopped, but unsafe socket artifacts were preserved | Inspect the reported private socket directory manually. |
| `8` | The owned target/session is inactive or gone | Re-run connect for the same owner and slot. |
| `9` | A command ran but post-command target ownership drifted | The guard restored the owned target when possible; inspect the command's effects before continuing. Pre-command drift is restored silently and the command proceeds (exit follows the command). |
| `10` | The command is not in the wrapper's allow-list | Not a forbidden command — one the guard does not know. Do not retry it bare through `agent-browser`. Report to the user that this command is not in the allow-list; adding it is a one-line change to `scripts/guard.sh`. |
| `130`/`143` | Operation was interrupted | Re-run connect or cleanup for the same identity to inspect state safely. |

## Validation

The deterministic suite uses a mock daemon and high-concurrency races:

```bash
bash ~/.claude/skills/agent-browser-connect/tests/run.sh
```

It runs three layers: the allow-list policy (`tests/guard.sh`, no daemon), the structured
`lib.sh` readers (`tests/lib-interfaces.sh`, no daemon), and the mock-daemon integration
cases. Against a real browser, `AB_RUN_USER_CHROME=1 bash tests/real-chrome-guard.sh`
probes one session in the user's own Chrome and preserves the tab.

The gated integration suite launches the installed Google Chrome binary with a disposable profile. It never uses the user's profile:

```bash
AB_RUN_REAL_CHROME=1 bash ~/.claude/skills/agent-browser-connect/tests/real-chrome.sh
AB_RUN_REAL_CHROME=1 AB_REAL_CHROME_HEADLESS=0 bash ~/.claude/skills/agent-browser-connect/tests/real-chrome.sh  # visible disposable window
```

## Stale daemons

Browser-attached sessions do not receive the default one-hour idle shutdown. Past roughly 20 attached daemons, new sessions have been observed timing out even though Chrome remained healthy.

```bash
agent-browser session list
agent-browser --session <stale-name> close
```

Close stale sessions individually. `agent-browser close --all` can terminate sessions belonging to other agents or active conversations.

## Ephemeral-port exhaustion

A count near 16,000 established TCP connections is a strong signal:

```bash
netstat -an -p tcp | grep -c ESTABLISHED
lsof -nP -iTCP -sTCP:ESTABLISHED | awk '{print $1}' | sort | uniq -c | sort -rn
```

Report the culprit to the user. It is a machine-level connection leak, not a browser-target problem.
