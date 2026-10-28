# Session options

Read before using optional connection settings or batch commands. The basic workflow
is in [SKILL.md](../SKILL.md).

## Settings and recovery

Omitted flags inherit saved settings. Disable explicitly with `--no-persistent`,
`--no-auto-approve` or `--no-react`. Recovery inherits the latest committed policy;
a pending heal cannot undo a concurrent opt-out or full release.

`--persistent` enables one pre-command recovery attempt after daemon loss, a closed tab,
a Chrome restart or an upgrade. It never replays a command already sent. The
`! ... persistent mode is reconnecting` message explains recovery. A closed tab is
replaced only on the next command, at its last URL without the query string.
Re-navigate if the query mattered.

## Automatic approval

Use `--auto-approve` only after a separate, explicit user opt-in. It presses Chrome's
remote-debugging approval button for connections this owner opens; it requires macOS
and terminal Accessibility permission. Browser-task permission alone is not consent.
Remember the opt-in for this conversation instead of asking again per task.
Live connection reuse starts no approval clicker. Idle shutdown preserves the opt-in;
`--no-auto-approve` or full release revokes it.

## Idle policy

New owners default to 1200 seconds (20 minutes), overridden by `AB_IDLE_TIMEOUT_SECONDS`.
Existing saved policies are inherited.

To deliberately change an owner's policy, run connect for the same owner/slot with
`--idle-timeout 1200`. Changing a live timeout replaces the daemon and may require a
new Chrome approval; unchanged settings reuse the socket. `--idle-timeout 0` disables
native shutdown even when ambient native settings conflict.

The timer stops the daemon, not Chrome or its tabs. It preserves the wrapper, owner
settings and target binding for resume. Long commands can finish before shutdown.
Daemon commands (including diagnostics) and dashboard input count as activity;
avoid polling solely to keep a connection alive. Closing the owned tab does not itself
stop the daemon or reopen the tab.

## React introspection

Connect with `--react` before the daemon starts. The hook is installed once and survives
navigation. Use `react tree`, `react inspect <id>` and `react renders start|stop` through
the wrapper. `✓ React:` confirms a response; `! React:` may mean React has not booted.
Retry the React command first.

Adding the hook to a running unhooked daemon requires full release and a new connection;
explain that cost instead of repeatedly reconnecting. Later `--enable` flags are refused.
`--no-react` changes future attachments; it cannot uninstall a hook already running.

## Batch and long loops

Send JSON arrays of command argument arrays on stdin:

```bash
printf '%s\n' '[["snapshot","-i"],["click","@e3"]]' | bash <wrapper> batch --bail --json --omit-command
```

Each command is a nonempty array of strings. Empty arguments, spaces, tabs and Unicode
are preserved; `[["fill","#name",""]]` clears an input. Only `--bail`, `--json` and
`--omit-command` belong outside the arrays. `--omit-command` (with `--json`) replaces each
echoed command array with its index, which keeps output short and stops echoing `fill`
values; typed text and `get value`/`eval` results can still contain them. Quoted command
operands are retired. Every member is guarded before browser access; NUL, CR, LF and unit separator are rejected inside words.

For long observation loops, `snapshot --delta` prints changes and
`screenshot --if-changed <path>` skips identical captures.
