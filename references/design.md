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

### What the guard permits

The policy lives in `scripts/guard.sh` and is an **allow-list**: a fixed set of verb
phrases, a fixed set of flags for each, and a refusal for everything else. It was a
deny-list until 2026-09-18, and the reason for the inversion is that a deny-list defaults
to *permit* for anything it has not heard of. Measured against agent-browser 0.38.1, that
default was letting `plugin add`, `upgrade`, `install`, `stream enable --port`,
`removeinitscript`, `clipboard read`, `webmcp invoke`, `auth login`, `state save` and the
launch-affecting `--proxy`, `--extension`, `--init-script`, `--args`, `--ca-cert`,
`--allow-file-access` and `--confirm-actions` through untouched — while still spending
entries on `window` and `bringtofront`, which stopped being agent-browser commands
somewhere before 0.38.1 and whose absence nothing detected.

Permitted, in outline: page navigation and interaction, `frame` and `dialog`, observation
(`snapshot`, `screenshot`, `get …`, `is …`, `find …`, `console`, `errors`, `diff
snapshot|screenshot`), `eval`, `react …`, `vitals`, `a11y`, `pushstate`, `trace` and
`profiler`, `network …`, `cookies`, `storage`, the emulation members of `set`, `tab list`,
`batch` and `skills`. The table itself is the authoritative list.

Refused, and worth knowing why:

- Anything that creates, switches or closes a target: the `tab` family except `tab list`,
  `click --new-tab`, `inspect`, and the key chords that open or restore a window.
- `record`, which creates a browser context that Chrome shows as a separate window and
  that `record stop` never disposes.
- Every connection, profile and launch-affecting flag, because one whose value differs
  from the previous invocation's makes the daemon dial another WebSocket and costs the
  user another approval dialog. `connect.sh --react` and per-action `--human` are the
  ways in.
- `keydown` and `keyup`, which hold a modifier across commands and so split a chord into
  pieces the chord check cannot see (`keydown Meta` then `press t`).
- Commands that reach outside the browser session altogether: `plugin`, `upgrade`,
  `install`, `doctor`, `stream`, `mcp`, `dashboard`, `chat`, `clipboard`, `webmcp`,
  `auth`, `state`, `removeinitscript`, `confirm`, `deny`.
- Nested `batch`, which would carry a whole unguarded program inside a guarded command.

**It fails closed, and that is the trade.** A command agent-browser ships tomorrow will be
refused until someone adds it to the table — exit 10, distinct from the exit 2 that means
"deliberately forbidden", precisely so the two can be told apart. There is deliberately no
environment override: an escape hatch named in an error message is one the agent will
take, and a bare `agent-browser` call is the single outcome this skill exists to prevent.
The recovery for exit 10 is to report it and add a line to `scripts/guard.sh`.

`AB_DENY_EXPLAIN` in that file supplies the specific reason for a refusal. It is advisory
only — it grants nothing, so an entry that goes stale degrades a message and never opens a
hole. Presence in it is also what selects exit 2 over exit 10.

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

## Structured reads: json.mjs, and session.meta

`json.mjs` prints `key=value` lines and the shell reads them by name through
`ab__field`. It used to print bare lines whose meaning was their position, and 22
call sites across `connect.sh`, `dispatch.sh` and `cleanup.sh` decoded them with
`sed -n '5p'`. Adding a field was safe only at the end, reordering one corrupted
three scripts at once, and nothing failed when it happened. Two readers in
`lib.sh` own the shapes now:

- `ab_session_info` runs `session info` and publishes `AB_SESSION_*`. It never
  passes `--cdp`, and that is the point: asking whether a session is alive must
  not be able to open a connection or launch a bundled browser, and `session
  info` is also the one call that does not restart a version-mismatched daemon.
  That rule used to be a comment repeated at three call sites; it is now a
  property of the function, and a test asserts the flag never appears.
- `ab_tab_state` publishes `AB_TAB_*` from `tab list --json`. The command itself
  stays with the caller because the invocation legitimately differs — attached
  callers pass `--cdp --pin-tab --session`, teardown must not — so only the shape
  moved.

`session.meta` gained an interface for the same reason. The ownership invariant
is the one safety property this repo has, and it was transcribed three times:
`dispatch.sh` hard-failed on a malformed CDP URL, `cleanup.sh` quietly downgraded
the identical condition to "not proven", and `connect.sh` checked only the owner
key. `ab_load_meta` is the single implementation. It validates version, session,
owner key against `H(owner_id|slot|port)`, the CDP endpoint and the owned target,
publishes `AB_META_*`, and on failure sets `AB_META_ERROR` to something the
caller can print. Callers still decide what a failure *means* — dispatch refuses
the command, cleanup preserves every Chrome target — but they no longer disagree
about what a valid record is. `AB_META_VERSION` replaces the bare `4` that used
to appear in all three files.

## Batch: what is guarded is what runs

`batch` in argument mode used to be checked and then forwarded differently. Each
argument was split by `json.mjs`, the resulting words were guarded, and then the
**original string** was handed to agent-browser to parse again. Two parsers
deciding one policy only holds while they agree, and they did not: `json.mjs`
splits on spaces and treats a tab as an ordinary character, so
`batch $'tab\tnew http://x'` guarded as the single unknown verb `tab<TAB>new`
while a whitespace-splitting parser downstream could read it as `tab new`.

The dispatcher now re-encodes the guarded words with `json.mjs batch-encode` and
sends them as the JSON array-of-arrays that the stdin path already used. There is
one parse, and the words the guard approved are the words that run. `--bail` and
`--json` stay CLI flags and are not folded into the command array.

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

## Rejected: collapsing the scripts

A review on 2026-09-04 sketched reducing these scripts to roughly 150 lines by dropping
the per-session lock, the transactional rollback in `connect.sh`, and the symlink and
ownership hardening on every path. That was considered and **rejected**, and the reasoning
still holds:

- The lock is what makes two wrapped commands on one session serialize. Without it two
  agents sharing a browser interleave a `tab list` / command / `tab list` bracket and each
  sees the other's binding as drift.
- The rollback is what stops a failed attach from leaving a tab, a daemon and a half
  written wrapper behind. A failed attach is not rare — it is what an unapproved Chrome
  dialog produces.
- The symlink and `-O` ownership checks guard a wrapper root that lives in a shared
  temp directory.

Line count is not the constraint here; a wrong tab in the user's browser is. Anything
proposing to remove one of these three should say what it does about the failure that
motivated it. This note exists so the same simplification is not re-proposed on the
strength of the line count alone — it is the one decision worth carrying forward from
`docs/spec-2026-09-04-harness-portability-and-noise.md`, which was removed once it had
been implemented and had gone stale.
