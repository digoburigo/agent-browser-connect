# agent-browser-connect troubleshooting

Read this reference when connection approval repeats, port 9222 is unavailable, Chrome restarts, a pin disappears, commands reach the wrong page, or stale daemons accumulate.

## Connection approval and port diagnostics

Chrome's remote-debugging toggle and connection approval are separate:

- `chrome://inspect/#remote-debugging` remembers that the server is enabled.
- Approval mode still asks once for each incoming WebSocket connection.
- Another connected agent does not authorize a new connection.

First distinguish an agent asking in chat, a harness tool-permission prompt, and Chrome's
**Allow remote debugging?** dialog. They are different permission layers; a CLI tool
allow-list cannot suppress Chrome's security dialog. Once browser access is authorized
for this conversation, the agent should continue through the same wrapper without
asking for that access again. Automatic clicking of Chrome's dialog is a separate,
explicit opt-in.

A fresh connection should show at most one Chrome approval. Reusing the live connection
should show none. When dialogs repeat:

1. Check whether the agent ran plain `cleanup.sh` after the previous task. It stops the
   approved daemon. Use `cleanup.sh --keep-alive` between tasks; reserve full release
   for explicit disconnect or conversation termination.
2. Check the session's `events.log` for `attach mode=fresh`, `timeout-change`, `heal-start`
   or `version-mismatch`. The same session name does not imply the same connection.
3. Re-run connect for the same owner/slot, without inventing a new identity or dropping
   back to bare agent-browser. Omitted flags now preserve settings; only explicit
   `--no-auto-approve` revokes an existing opt-in (full release also forgets it).
4. If a live session still reconnects, check flag changes, socket loss and other clients.
   Repeated dialogs do not by themselves prove another process is at fault.

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
| Browser task finished, but the conversation will continue | Retain the already-approved connection | Stop your trace/profiler, then run `cleanup.sh --keep-alive <session>`. Continue with the same wrapper on follow-ups. |
| Daemon becomes inactive after idle time | The native timer stopped the daemon, preserving Chrome, the owned tab, wrapper, binding and owner policy | Re-run connect for the same owner and slot, or let a persistent wrapper heal. Chrome needs one new transport approval; a granted `--auto-approve` opt-in is remembered. Change the inherited timeout with `--idle-timeout <seconds>`; `0` disables native shutdown. |
| `Task routes could not be cleared without reconnecting` | Route cleanup failed, the socket is down, or the daemon version changed | The session was retained rather than disconnected. Recover with the same connect, then retry task cleanup, or explicitly release if finished. |
| `Invalid saved session setting ...` | A saved boolean is malformed | Connect and keep-alive deny browser operations. Explicit release can still stop the proven existing daemon; optional closure preserves the target and reports status 6. Explicitly disable the named setting (`--no-auto-approve`, `--no-persistent`, `--no-react`) or inspect the private metadata; do not infer consent from a malformed value. |
| Wrapper reports corrected drift | The persisted binding changed while the owned target still existed | The dispatcher restores the target before running the requested command. Continue through the same wrapper and stop using any bare browser command. |
| Commands reach the wrong page | A bare agent-browser command bypassed the guard | Return to the wrapper. `tab list` is the only public tab-management operation it permits. |
| Chrome keeps switching between two agents' tabs | Something brought a tab to the front: a fresh connect (new tabs open in the foreground), a `tab_gone` recovery, a drift restore (`tab <id>` always sends `Page.bringToFront`), or a bare `bringtofront` | Read `events.log` in each agent's wrapper directory (the path `connect.sh` printed, minus `/ab`). Zero `drift-restored` lines means the wrapper is not the cause; look for bare `agent-browser` calls or repeated reconnects. `cleanup.sh` prints the same counts and archives the log under `<wrapper root>/.history/`. |
| A second Chrome window appeared and stayed after the task | `record start` ran on the session (through a wrapper older than 2026-09-04, or bare). It creates a new browser context, which Chrome shows as its own window, and `record stop` does not close it | Close that window by hand. The wrapper now rejects `record`; use `screenshot` for stills, or `trace start|stop` / `profiler start|stop` to capture what happened. A fresh attach can also land in a new window when Chrome has no normal window open for the default profile; that one is Chrome's placement rule, not the skill |
| `! ... persistent mode is reconnecting` followed by the command's output | A `--persistent` session healed: its daemon died, its tab closed, Chrome restarted or agent-browser was upgraded | Nothing to do. `events.log` records `heal-start` / `heal-ok`. A closed tab came back in the foreground at its last URL minus the query string. |
| `persistent mode did not reconnect: the last attempt failed Ns ago` | A heal failed less than `AB_HEAL_COOLDOWN_SECONDS` (60) ago, and retrying now could stack another approval dialog | Look at Chrome for an unanswered dialog, then re-run connect by hand or wait out the cooldown; the next command after it tries again. |
| `No connection within 90s: Chrome is most likely still showing its approval dialog` | A heal waited `AB_HEAL_TIMEOUT_SECONDS` for approval. The waiting daemon was stopped (its rollback would otherwise block too), so that dialog is stale | Ask the user to cancel the stale dialog. The next command after the cooldown reconnects; with `--auto-approve` it needs no click. |
| `--auto-approve could not read Google Chrome's windows` | The terminal running the agent lacks the macOS Accessibility permission, so `approve.js` cannot see the sheet | Ask the user to allow the terminal app (Ghostty, iTerm, …) under System Settings › Privacy & Security › Accessibility. Until then the dialog is approved by hand; nothing else changes. |
| `A remote-debugging dialog was already open before this connection` | Another client's approval was pending when this connect started. The sheet does not say whose it is, so auto-approve leaves it alone | The user answers it by hand. This session's own dialog may be stacked behind it. |
| `outcome_unknown` from a `click`, `fill`, `press`, `open` or other mutating command | The command reached the daemon but the reply was lost (agent-browser 0.39.1+ no longer re-sends it). It may or may not have run | Re-run connect if the wrapper asks for it, then `snapshot -i` or `get url` before repeating the action. Read-only commands are safe to repeat. |
| `Ref not found: @eN` | The page changed after a snapshot | Run `bash <wrapper> snapshot -i` again and use fresh refs. |
| Chrome restarted | The exact browser WebSocket changed | Re-run connect for the same owner/slot or explicit session (a `--persistent` session does this by itself). |
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
bash tests/run.sh
```

It runs three layers: the allow-list policy (`tests/guard.sh`, no daemon), the structured
`lib.sh` readers (`tests/lib-interfaces.sh`, no daemon), and the mock-daemon integration
cases, including `tests/lifecycle-cases.sh` for conversation reuse, explicit opt-outs,
route-only cleanup, native timeout propagation, concurrent handoffs and transactional replacement. Against a real browser, `AB_RUN_USER_CHROME=1 bash tests/real-chrome-guard.sh`
probes one session in the user's own Chrome and preserves the tab.

Run these from the skill directory. The gated integration suite launches the installed Google Chrome binary with a disposable profile. It never uses the user's profile:

```bash
AB_RUN_REAL_CHROME=1 bash tests/real-chrome.sh
AB_RUN_REAL_CHROME=1 AB_REAL_CHROME_HEADLESS=0 bash tests/real-chrome.sh  # visible disposable window
```

## Where session state lives

Wrappers, `session.meta` and `events.log` live under `~/Library/Caches/agent-browser-connect`
on macOS and `${XDG_STATE_HOME:-~/.local/state}/agent-browser-connect` elsewhere
(`AB_CONNECT_ROOT` overrides). Until 2026-09-25 they lived in `$TMPDIR`, which macOS purges;
a purged root deleted the wrapper an agent was still calling. Sessions connected before that
date still use their `$TMPDIR` wrapper until they are cleaned up and connected again.

## Cleanup transport limits

Cleanup sends fixed requests to the validated existing native socket, not bare CLI
browser commands. Omitting `--cdp` alone does not prevent CLI bootstrap or ambient
launch changes. The bridge never launches a daemon or replays an uncertain action.
Native route and tab operations can still redial after CDP preflight if backend health
changes. Protocol support is tested with 0.39.1, not all historical versions. Active
I/O has a 30-second deadline and a 256 KiB aggregate response cap; unsupported replies
fail closed. Keep recovery artifacts after status 5. Status 6 means shutdown completed
but optional target closure was not verified. Disposable checks inspect actual PIDs,
sockets and targets, not real approval dialogs.

## Stale daemons

Attached browsers are exempt from agent-browser's default one-hour idle timeout, not an
explicit native timeout. The skill derives `AGENT_BROWSER_IDLE_TIMEOUT_MS` from saved
owner policy on each invocation. Native shutdown preserves Chrome, owner policy and the
target sidecar. `--idle-timeout 0` explicitly disables it despite ambient native settings.
Old watcher-managed owners need one explicit connect to migrate. Successful publication
removes the old watcher's authority; it exits on its next read. Cached old wrappers refuse
browser commands until migration. There is no idle log or replacement watcher.

Past roughly 20 attached daemons, new sessions have been observed timing out even though
Chrome remained healthy. Inspect the daemon's process and the owner's saved timeout.
Do not reap another active conversation. A failed timeout replacement stops its new daemon
before restoring policy. If shutdown is unverified, the wrapper is disabled and recovery
artifacts remain in its session directory. Report that failure rather than treating the
old policy as safely restored.

```bash
agent-browser session list
bash <skill-dir>/scripts/cleanup.sh <owned-stale-session>
```

Release only your own stale sessions individually. Do not use bare CLI close as a
cleanup workaround. `agent-browser close --all` can terminate other conversations.

## Ephemeral-port exhaustion

A count near 16,000 established TCP connections is a strong signal:

```bash
netstat -an -p tcp | grep -c ESTABLISHED
lsof -nP -iTCP -sTCP:ESTABLISHED | awk '{print $1}' | sort | uniq -c | sort -rn
```

Report the culprit to the user. It is a machine-level connection leak, not a browser-target problem.
