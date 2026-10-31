# agent-browser-connect design notes

Read this when a guard message surprises you or when changing the scripts. The steps an
agent follows live in `SKILL.md`; this file holds the reasoning behind them.

## Why the user's Chrome, and why a wrapper

The user watches browser work in their own window: their profile, logins, extensions
and session state. A headless browser cannot see what they are logged into and they
cannot see what it does. So the only target is their running Chrome over CDP.

Since 0.39.2, agent-browser keeps a live external attachment when follow-up commands omit
connection flags (upstream #2155), and native tab pinning is sticky. Earlier versions
could drop the attachment and launch a local browser. The wrapper still passes the
exact browser WebSocket, `--pin-tab` and `--session` on every call: native persistence
is not conversation ownership, an allow-list or a cleanup boundary. It remains the
only supported way to issue browser commands.

## Exact WebSocket, one attach

Chrome's remote-debugging toggle asks approval per incoming WebSocket connection, and it
answers `/json/version` and `/json/list` with 404, so they are not health checks.
Passing only a port makes agent-browser's discovery path open a probe WebSocket and then
a real one, which is two approval dialogs. The same is true of any invocation whose
launch-affecting flags differ from the previous one's: the daemon dials a new socket, and
approval mode prompts again. Since 0.38 the replaced socket is closed rather than
stranded (upstream #1739), so the cost is the dialog, not an accumulating pile. `connect.sh` checks raw TCP, reads the
matching `DevToolsActivePort` file without opening a WebSocket, and hands agent-browser
the exact URL. It attaches once and does not retry blindly. Repeated dialogs mean new
connections: check task cleanup, setting changes and daemon loss before blaming another
process. `--persistent` adds bounded recovery (see below). Measured on agent-browser 0.39.1 (2026-10-15): the disposable-profile suite
and the user-Chrome guard probe each attached once (`attach=1`, no other foreground events).

## Conversation lifetime, task cleanup, and native idle shutdown

A stable session name is not an approved WebSocket. Previously the skill ordered a full
release after each task, deleting state and stopping the daemon. The next task used the
same name but made a fresh connection, so Chrome quite correctly asked again. Local
history showed four fresh attaches for one owner in a single day. Repeated connect also
reset `persistent`, `react` and `auto_approve` to zero whenever flags were omitted.

The lifecycle now separates three operations:

- **Task cleanup** (`cleanup.sh --keep-alive`) removes network routes on the proven live
  connection, retaining the daemon, wrapper, target and policy.
  It fails without disconnecting if route removal fails or would require reconnecting.
  The agent stops its own traces/profilers before this step.
- **Native idle shutdown** stops only this session's daemon after the saved idle interval
  (20 minutes for new owners by default).
  It preserves the tab sidecar and owner metadata, including explicit auto-approval
  policy, so a resume can rebind the same tab without renegotiating the user's opt-in.
  Chrome still needs a new transport approval after idle shutdown unless auto-approval
  was explicitly enabled.
- **Full release** (plain cleanup, or `--close-tab`) forgets the connection and settings.
  It is for explicit disconnect or conversation termination, not each final response.
  A skill cannot detect every harness's conversation end; native idle shutdown bounds daemon lifetime.

Settings are tri-state at the CLI: omitted = inherit from verified owner metadata,
positive flag = enable, negative flag = disable. `ab_configure_policy` in `lib.sh`
owns defaults, inheritance and validation after ownership is proven. Missing booleans
default to disabled; malformed booleans fail before daemon inspection and matching
negative flags can repair them. Consent is never
inferred from an existing tab or another owner. `--no-react` affects future attachments;
an installed init script cannot be uninstalled from a live daemon by changing metadata.

`--idle-timeout` is inherited. `AB_IDLE_TIMEOUT_SECONDS` defaults a new session to
1200 seconds (20 minutes). Existing saved timeouts are unchanged. An existing owner
missing the timeout uses a fixed legacy 3600 seconds regardless of the current environment.
Zero disables native idle shutdown. `ab_configure_policy` derives and exports `AGENT_BROWSER_IDLE_TIMEOUT_MS` from normalized saved or requested
seconds for every CLI invocation. Ambient native timeout values cannot override owner
policy. Milliseconds are never persisted. The maximum accepted seconds value is
2147483647, which converts to 2147483647000 milliseconds.

Agent-browser owns the timer. Attached browsers are exempt from its default idle timeout,
not from an explicitly configured timeout. A running command can outlast the configured
idle interval. Native expiration is independent of the shell lock, so transport can
disconnect between preflight and forwarding. The dispatcher never replays a sent action.
The disposable regression delays a mutation beyond expiry, then verifies one mutation,
the same owned target and no additional tabs. Daemon diagnostics and dashboard input
also refresh native activity; polling can postpone shutdown. Closing an owned tab enters
`tab_gone` without stopping the daemon. There is no tab-close watcher or automatic tab
closure: native idle shutdown disconnects from external Chrome and preserves its tabs.

Changing a live timeout is a connect transaction. Connect validates desired policy first,
then inspects and stops the old daemon using its saved native configuration. It requires
verified inactivity before applying the desired timeout and attaching the replacement.
The old target and sidecar remain. Metadata is staged and atomically committed only after
target proof. Unchanged settings retain the daemon and socket. A timeout change never
receives the version-swap-only retry.

On failure, connect stops an uncommitted replacement before restoring old metadata and
the wrapper. If replacement shutdown cannot be verified, connect disables the wrapper and
quarantines the old metadata in the session directory. Backups and target sidecars remain
for manual recovery. It does not authorize commands against a daemon with a different
policy from restored metadata.

Older watcher-managed records require one explicit connect before a cached wrapper can
run browser commands. Records with legacy lease or activity keys, or no saved timeout,
do not prove native configuration. Migration uses a fixed zero setting for non-connecting
diagnostics and verified daemon stop, then applies the resolved policy. Missing timeout
uses the fixed legacy default. Explicit positive and negative choices still take
precedence, including repair of malformed saved consent. Successful publication removes
the legacy keys. Existing watchers lose metadata authority and exit on their next read,
within a minute. No unverified watcher PID is killed and no upgrade supervisor exists.

Agent-browser 0.39.1 can acknowledge `close` before its daemon exits. Explicit release,
timeout replacement and version swaps use `ab_stop_daemon` to poll non-connecting
`session info` under the owner lock until inactivity is verified. A positive close
reply alone is not success. Unproven-metadata release uses a fixed zero timeout only for
non-connecting diagnostics and daemon stop. It performs no browser commands.

Since 0.39.4 (upstream #2135) an explicit `close` also releases the session's tab pin
before replying and rewrites the `<session>.target` sidecar with `"pinned": false`.
Every path through `ab_stop_daemon` (timeout replacement, version swap, release) therefore
leaves the sidecar unpinned. The binding the skill relies on is the sidecar's target id and
URL, which survive. The pin comes back with the next attach, because the wrapper passes
`--pin-tab` on every call. A failed replacement restores metadata and the wrapper, not that
flag; a pin left by a dead daemon does not lock the tab anyway.

## Version mismatch after an upgrade

The daemon keeps running the agent-browser it was started with. Upgrading the CLI leaves
the session held by the old one, and the first BROWSER command prints
`⚠ Daemon version mismatch detected, restarting...` and restarts it. A restarted daemon
has no external CDP attachment, so without the connection flags it launches its own
Chrome: measured 2026-09-16 going 0.37.1 → 0.38.0, a bare `tab list` on a leftover
session started a full Chrome for Testing tree instead of using the user's browser.
The 0.39.2 attachment-persistence fix stores its target in daemon memory, so it does not
replace this deliberate restart-and-reattach safeguard.

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
  attaches once on purpose (blind retries could stack approval dialogs), but
  here it stopped a working daemon, and a freshly started daemon's first command
  sometimes times out; failing would leave the user with no session at all.

An empty version on either side disables the check; it never guesses a mismatch.

## Persistent mode: bounded self-healing

Without `--persistent`, every lost connection stops at exit 8 and the agent re-runs
connect. That stays the default because a reconnect can cost an approval dialog, and an
implicit loop of them is worse than a visible failure. `--persistent` makes the dispatcher
run that same re-run itself, under three bounds:

- **Once per command.** `dispatch.sh` turns its pre-command checks into `preflight`, which
  records a `HEAL_REASON` instead of exiting. Only these heal: `daemon-inactive`,
  `session-info-failed`, `version-mismatch`, `tab-list-failed` (what a Chrome restart looks
  like: the recorded WebSocket is gone), `target-gone` and `no-owned-target`. A guard refusal,
  unsafe metadata, a lock timeout and every post-command check never heal. The command ran,
  and running it twice is not safe.
- **A cooldown after failure.** `heal.state` holds the last attempt. For
  `AB_HEAL_COOLDOWN_SECONDS` (60) after a failed heal, no heal is tried, so an unanswered
  dialog cannot turn into a stack of them.
- **A timeout.** agent-browser's CLI waits about five minutes for an unanswered approval
  before giving up ("Failed to read ... after 5 retries", measured 2026-09-25 on 0.38.1), far
  longer than an agent's command timeout. The heal runs connect in its own process group and
  a watchdog stops it after `AB_HEAL_TIMEOUT_SECONDS` (90). The order matters: while the
  daemon waits on the dialog, connect's rollback `close` blocks on the daemon too. So the
  watchdog kills that session's daemon first (proven by its pid file and process name), then
  TERMs connect, whose rollback finishes and restores `session.meta`. Upstream #2059 (0.39.0)
  does not retire the kill: the daemon now accepts new connections while a command holds its
  state lock, but a SIGTERM still waits for that command to finish, and an attach blocked on
  an unanswered dialog does not finish. (Read from the PR, not re-measured: that means
  deliberately leaving a dialog unanswered in the user's Chrome.)

The heal hands the session lock to connect and takes it back. It passes the recorded owner
(`AB_CONNECT_ID`, or `--session` for `explicit:` owners), slot, port and an internal
`--recover` context. It passes no policy flags. Under its lock, connect requires current
metadata proving that owner and currently enabled persistence before inspecting the daemon.
A newer opt-out therefore survives recovery, and full release cannot be undone by a
pending heal. The dispatcher reloads identity and all policy after healing. An incomplete
target is healable only after identity and policy validation. For a closed tab it also passes
`--replace-url`: the URL from agent-browser's `<session>.target` sidecar, which the CLI
rewrites after every command but sanitizes (the query string is dropped). `json.mjs
target-url` accepts only http(s) or `about:blank`.

What was measured live on 2026-09-25 (agent-browser 0.38.1):

| Loss | Recovery |
|---|---|
| Socket dropped, daemon alive | The daemon redials by itself on the next call: one dialog, same tab. The skill does nothing. |
| Daemon killed | A new daemon rebinds the same tab through the sidecar; no new tab. `attach mode=rebound` in `events.log`. |
| Owned tab closed | `tab new` on the live connection: no dialog, one foreground tab. |
| Heal with nobody approving | Timed out, daemon stopped, meta and sidecar intact. |

Two rollback rules exist for heals, and they also protect a hand re-run after a dead daemon.
A failed re-attach never closes the tab the session already owned, and it keeps the
`.target` sidecar, so the next attempt rebinds instead of opening a tab.

Chrome quitting is the one loss nothing heals. A heal waits connect's usual 30 s for the
port, fails and cools down.

## Auto-approve: pressing Chrome's dialog

Chrome has no way to remember an approval. The upstream request (chrome-devtools-mcp #825)
was closed as not planned, and the `RemoteDebuggingAllowed` policy only switches remote
debugging on or off. Since Chrome 136 the default profile also ignores
`--remote-debugging-port`, which is the approval-free path. So `--auto-approve` presses the
button through the macOS Accessibility API (`scripts/approve.js`, JXA via `osascript`;
`AXPress` acts without focusing Chrome). Recorded 2026-09-25: the prompt is an `AXSheet`
titled "Allow remote debugging?" on a browser window, holding the buttons "Turn off in
settings", "Cancel" and "Allow". Titles are overridable (`AB_APPROVE_APP`,
`AB_APPROVE_TITLE`, `AB_APPROVE_BUTTON`) for other Chromium browsers or locales.

**The sheet names no client**, so any process that dials 9222 while the approver runs gets
approved too. The time window is the only scope there is, and it is kept small:

- It runs only around a connection this session opens: a fresh attach, or the one call
  after `lsof` proves an existing daemon has no established socket (the redial case).
  Re-running connect on a proven live socket starts no approver. Unknown socket state
  does not authorize a click. It is never a background clicker.
- It presses at most once, then exits; the caller kills it when the command returns.
- A sheet already open before it starts belongs to someone else, so auto-approve stands
  down (`auto-approve-skipped`) and the user answers by hand.
- It is opt-in per owner session, because it trades a security prompt for convenience
  and that trade is the user's to make. The explicit opt-in survives follow-ups, heals
  and native idle shutdown; `--no-auto-approve` or full release revokes it. Ordinary permission
  to use the browser does not imply permission to press this security button.

Measured: connect with a dead daemon approved and attached in 1.7 s; a killed daemon healed
inside one command in 2.1 s; a dropped socket in 1.6 s; a closed tab in 1.5 s.

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

### Lost replies: `outcome_unknown`

Through 0.39.0 the CLI re-sent a command up to five times when the daemon's reply was
lost, even after the request had been written, so a `click` or `fill` could run twice
(upstream #2032). Since 0.39.1 (#2085) only read-only commands are retried; a mutating one
fails with `code: "outcome_unknown"` (kept in `--json` and batch output). The dispatcher
passes that through unchanged, and its post-command `tab list` usually fails next (exit 9),
because the reply was lost to a dying daemon. That is where an agent is tempted to
reconnect and repeat the action, so `SKILL.md` tells it to read the page state first.

A persistent heal never replays a command: it runs only from `preflight`, before the
command is sent.

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

A dash word is a flag unless the verb is in `AB_VERB_NEGATIVE_NUMBERS` and the word is a
plain negative number, so `set geo -23.5 -46.6` and `fill @e1 -5` work. The list is per
verb because the native parsers differ: `scroll down -5` drops the amount and scrolls the
default distance, so it stays refused. Other dash words stay refused on every verb because
the CLI strips global flags such as `-q` even from a `fill` value.

`tests/mcp-catalog.tsv` classifies every tool in `agent-browser mcp --tools all`.
`node tests/mcp-catalog.mjs --live` reports new tools and input properties after a version
bump, so most gaps surface before a task hits exit 10. It covers what MCP exposes, not
every CLI flag, and a new input can still need a guard row of its own.

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
  stays with attached callers, which pass `--cdp --pin-tab --session`. Cleanup uses
  the separate fixed native bridge, not an ordinary CLI invocation.

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

Batch has one external shape, JSON `string[][]` on stdin. Each member is a nonempty
array of strings. Empty argument strings, spaces, tabs, quotes, backslashes and Unicode
survive unchanged. An empty outer array remains accepted by the native CLI.

```bash
printf '%s\n' '[["fill","#name",""],["snapshot","-i"]]' | bash <wrapper> batch --bail --json
```

Migrate quoted command operands to arrays. For example, replace `batch 'get url'`
with `printf '%s\n' '[["get","url"]]' | bash <wrapper> batch`. Quoted operands now
fail with a JSON-stdin migration message. Only `--bail`, `--json` and `--omit-command`
(0.40.0+; with `--json` it replaces each echoed command array with its index) are batch
flags outside the arrays. Ordinary single commands keep their existing interface.

`json.mjs batch-check <bash-path> <guard-path>` reads raw stdin directly. Bash must
not capture raw input first because command substitution erases literal NUL. The helper
validates the complete JSON schema before starting guard children. NUL, CR, LF and unit
separator inside words remain prohibited.

Each member is sent through exact argv to the authoritative Bash guard with nested
batch disabled. Child calls use `spawnSync`, argument arrays and `shell: false`.
Guard stdout is discarded and diagnostics remain on stderr. Deliberate refusals retain
status 2 and unknown commands or flags retain status 10. Child execution errors and
signals fail closed with status 2 before daemon access. Canonical JSON is emitted only
after every member passes. Preflight and native execution follow validation.

The shell-word tokenizer, quoted-program accumulation and separator transport are gone.
There is no compatibility parser or second word grammar. The operating system imposes
an argv size limit on each guard child. Oversized members fail closed, even if native
stdin alone could carry them. One Bash guard child per member is an accepted tradeoff;
no performance improvement is claimed.

## Containment boundary

The page count from `tab list` covers every page in Chrome, including the user's own
tabs, so growth is information rather than an error, and it is never persisted or
counted against cleanup. agent-browser does not expose opener data, so a page-created
popup cannot be told apart from a tab the user opened at the same moment; the wrapper
reports and preserves both. Command pinning is not a one-window guarantee.

## Cleanup

Cleanup uses `scripts/admin.mjs` on the validated existing native socket. Omitting
`--cdp` from an ordinary CLI browser command is not safe teardown. The CLI can bootstrap
a daemon or apply ambient launch settings. The bridge has fixed operations, sends no
separate CLI launch and never bootstraps a daemon or replays an uncertain action.

`--keep-alive` clears task routes and retains the live connection. Plain release only
stops the daemon, which disables interception. Malformed policy denies route and tab
operations but does not prevent independently verified release. `--close-tab` requires
valid policy and exact target ownership. Unverified closure returns partial status 6
after verified shutdown. Unknown shutdown retains recovery artifacts with status 5.
If native expiry wins after keep-alive preflight, cleanup refuses rather than silently
releasing; plain release can reconcile explicitly reported inactivity.

The bridge depends on the native protocol of the agent-browser version the README names
as tested. It uses a 30-second active-I/O deadline and a 256 KiB aggregate response cap.
Unsupported frames, responses or confirmation requests fail closed. No historical
protocol compatibility is promised. Diagnostics require an explicit boolean `active`; a
missing or malformed field cannot prove inactivity.

Existing-only transport does not make browser actions atomic with CDP preflight.
Native route and tab handlers can redial their backend if health changes afterward.
Target resolution also retains a native list-to-close race. Native completion and
listing establish manager state, not independent proof that Chrome removed a target.
The disposable suite separately inspects actual target absence, daemon PIDs and
established CDP sockets. It does not exercise real approval dialogs.

Attached browsers are exempt only from agent-browser's default timeout. The explicit
owner timeout enables native shutdown without destroying policy or target bindings.

## Metadata

Each session directory holds a `session.meta` key-value file: version, owner id and key,
session, label, slot, port, CDP URL, socket dir, owned target id, created time, and the
`persistent`, `react` and `auto_approve` policy, plus normalized `idle_timeout_seconds`.
New records contain no idle lease or activity fields. Existing version-4 records remain
readable for deliberate migration through connect. The root is a cache directory, not
`$TMPDIR`, which macOS purges out from under a live wrapper. The
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
