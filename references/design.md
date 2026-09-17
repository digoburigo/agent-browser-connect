# agent-browser-connect design notes

Read this when a guard message surprises you or when changing the scripts. The steps an
agent follows live in `SKILL.md`; this file holds the reasoning behind them.

## Why the user's Chrome, and why a wrapper

The user watches browser work in their own window: their profile, logins, extensions
and session state. A headless browser cannot see what they are logged into and they
cannot see what it does. So the only target is their running Chrome over CDP.

`--pin-tab` in agent-browser is not sticky in practice: one command without the
connection flags rebinds the session to another tab. The wrapper therefore passes the
exact browser WebSocket, `--pin-tab` and `--session` on every call, and it is the only
supported way to issue browser commands.

## Exact WebSocket, one attach

Chrome's remote-debugging toggle asks approval per incoming WebSocket connection, and it
answers `/json/version` and `/json/list` with 404, so they are not health checks.
Passing only a port makes agent-browser's discovery path open a probe WebSocket and then
a real one, which is two approval dialogs. The same is true of any invocation whose
launch-affecting flags differ from the previous one's: the daemon dials a new socket, and
approval mode prompts again. Since 0.38 the replaced socket is closed rather than
stranded (upstream #1739), so the cost is the dialog, not an accumulating pile. `connect.sh` checks raw TCP, reads the
matching `DevToolsActivePort` file without opening a WebSocket, and hands agent-browser
the exact URL. It attaches once and does not retry blindly; a repeated dialog means
another process is reconnecting. Last verified against agent-browser 0.38.0 (2026-09-16).

## Version mismatch after an upgrade

The daemon keeps running the agent-browser it was started with. Upgrading the CLI leaves
the session held by the old one, and the first BROWSER command prints
`⚠ Daemon version mismatch detected, restarting...` and restarts it. A restarted daemon
has no external CDP attachment, so without the connection flags it launches its own
Chrome: measured 2026-09-16 going 0.37.1 → 0.38.0, a bare `tab list` on a leftover
session started a full Chrome for Testing tree instead of using the user's browser.

`session info` is the one call that does **not** restart it, and it reports the daemon's
version, so both scripts compare that against the CLI on `PATH` (`ab_cli_version`) right
where they already inspect the session:

- `dispatch.sh` refuses the command with exit 8 rather than being the thing that trips
  the restart mid-command.
- `connect.sh` stops the stale daemon itself and attaches once with the current version.
  It leaves the `<session>.target` sidecar in place, so the replacement usually rebinds
  to the same tab. When it opens a fresh one instead, connect switches back to the owned
  target and closes that tab — but only when it is the tab this attach bound to and it
  never left `about:blank`.
- This is also the only path allowed a second attach attempt. Everywhere else the script
  attaches once on purpose (a repeated dialog means another process is reconnecting), but
  here it stopped a working daemon, and a freshly started daemon's first command
  sometimes times out; failing would leave the user with no session at all.

An empty version on either side disables the check; it never guesses a mismatch.

## Identity and session naming

The session name is derived from a hash of owner id, slot and port. The label is
excluded on purpose, so renaming a task cannot allocate another browser session. Owner
id is the first of `AB_CONNECT_ID`, `PI_SESSION_ID`, `CLAUDE_CODE_SESSION_ID`. Without
one, connect refuses rather than inventing a random identity that would leak a tab.
`--slot` exists for the rare task that needs two owned targets.

## What the dispatcher does per command

1. Takes a per-session lock so concurrent wrapped commands serialize.
2. Confirms the daemon is active through `session info` without `--cdp`, so a dead
   session never spawns a new connection or a bundled browser from inside a command.
   The same call reports the daemon's agent-browser version; a mismatch with the CLI
   stops here with exit 8 (see above) instead of restarting the daemon mid-command.
3. Reads `tab list`; if the owned target exists but is not active, restores it and
   continues.
4. Runs the command. `batch` is forwarded only after every contained command passes the
   same guard as a single command.
5. Reads `tab list` again. If the binding moved, restores it and exits 9. If Chrome's
   page count grew, prints a one-line note and leaves the new page alone.

The guard rejects: tab creation, switching and closing (`tab list` is allowed), window
commands, `inspect` (opens a DevTools window), `record` (see below), `click --new-tab`,
key chords that open or close tabs, nested `batch`, every connection or profile override
flag, and the launch-affecting `--enable` and `--input-mode` (they differ from the
previous invocation's flags, so the daemon dials another WebSocket and Chrome asks for
another approval; `connect.sh --react` and per-action `--human` are the ways in).

## Visible tab versus bound tab

The pin controls which tab receives commands. It does not control which tab Chrome
shows, and only one tab per window is visible. Verified against agent-browser 0.36.0
source and re-checked on 0.38.0: ordinary page commands (`open`, `click`, `snapshot`, `screenshot`, `get`,
`eval`) never send `Page.bringToFront`. The paths that do move the visible tab are:

- `Target.createTarget`, which Chrome opens in the foreground. A pinned session never
  adopts an existing tab, so every fresh attach creates one, and so does the
  `tab new` in `connect.sh`'s `tab_gone` recovery. agent-browser does not pass CDP's
  `background: true`, so this cannot be avoided from the wrapper.
- `tab <id>` (agent-browser's `tab_switch`), which sends `Page.bringToFront`
  unconditionally, after a 3 s renderer probe that falls back to
  `Target.activateTarget`. The dispatcher's drift restore uses it, and so does
  `connect.sh` when it is re-run while the binding has drifted.
- The `bringtofront` command, which the guard now rejects.
- `record start` and `record restart`, which the guard rejects since 2026-09-04. The
  daemon calls `Target.createBrowserContext` and creates the recording page inside that
  context. Chrome shows a fresh context as a **separate window**, the page is added
  with activation (so the session rebinds to it and the dispatcher's post-check reports
  drift), and `record stop` never disposes the context, so the window outlives the
  recording. This was the source of the "agent opened another window" reports.
- `state save` and `auth save`, which create a temporary tab in the default context to
  read storage and close it again. A foreground flicker in the existing window, not a
  new window; allowed and not logged.

Every one of these is appended to `events.log` in the session directory
(`attach mode=fresh`, `tab-new`, `drift-restored`), and cleanup prints the counts and
archives the file under `<root>/.history/`. Two agents sharing one window will still
hide each other's tab at connect time; that is a property of Chrome, not of the pin.

`connect.sh` re-run on a live session checks that the daemon is still bound to the
target recorded in `session.meta`. If that target exists but is not active, it switches
back to it before navigating. Without this, a drifted daemon would have the re-run
navigate whatever tab was active (the user's, or another agent's) and record it as
owned.

## Containment boundary

The page count from `tab list` covers every page in Chrome, including the user's own
tabs, so growth is information rather than an error, and it is never persisted or
counted against cleanup. agent-browser does not expose opener data, so a page-created
popup cannot be told apart from a tab the user opened at the same moment; the wrapper
reports and preserves both. Command pinning is not a one-window guarantee.

## Cleanup

Cleanup talks to the existing daemon without `--cdp`. By default it clears network
routes, stops the daemon, removes session state, and leaves the Chrome tab open as a
normal user tab. Passing `--close-tab` opts into closing the exact target id recorded at
connect time, and only when the metadata proves ownership. If that target cannot be
closed without reconnecting, cleanup detaches, reports that it may remain, and exits 6
rather than causing another approval dialog. Routes are cleared first because an abort
route on a live session once left the user's own devtools scripts blocked and looked
like a broken app.

Sessions attached to a user's browser are exempt from agent-browser's idle shutdown, so
every session left behind is a daemon that lives until reboot. One machine accumulated
twenty, and past that point new sessions time out even with a healthy Chrome.

## Metadata

Each session directory holds a `session.meta` key-value file: version, owner id and key,
session, label, slot, port, CDP URL, socket dir, owned target id, created time. The
dispatcher rejects any version other than the current one, and any file whose owner key
does not match its owner id, slot and port.
