# Spec: make agent-browser-connect work in every harness and stop crying wolf

Status: implemented 2026-09-04 (see "Implementation notes" at the end)
Date: 2026-09-04
Source: code review of the skill on 2026-09-04 (Claude Code session, Fable 5.1)

## Problem Statement

An agent working in the user's Chrome follows the skill's documented protocol and is
stopped before it touches the browser. In Claude Code, the connect step refuses to run
because it only recognizes the pi harness's session variable, even though Claude Code
exports its own stable session id. The repo's CLAUDE.md and AGENTS.md both tell agents
to run exactly the command that fails.

When the connect step does succeed, every wrapped command is run through a path that
the skill's own permission allow-list does not cover, so a non-bypass session gets a
permission prompt on every click. Each command also costs four agent-browser round trips
and two node startups, and the batch command that would amortize that is blocked.

Finally, the guard reports problems that are not problems. If the user opens a tab in
their own browser while the agent works, the dispatcher records an "unattributed
target event" and cleanup exits nonzero, and the skill text tells the agent never to
call that a success. When the pinned target drifts, the dispatcher fixes it and then
makes the agent re-run the command anyway.

## Solution

The skill connects on the first try in Claude Code, pi, Codex and opencode, using
whichever stable session id the harness provides. Wrapped commands are allowed by the
skill's own permission list without prompting. Growth in the user's tab count is
reported as information, never as a cleanup failure. Drift is corrected and the
command proceeds. One JSON parser, one test runtime, no version numbers in prose, and
exit codes the agent can look up.

## User Stories

1. As an agent in Claude Code, I want connect.sh to derive my owner identity from the harness session id that is actually exported, so that I can connect without inventing a `--session` value.
2. As an agent in pi, I want the existing identity source to keep working unchanged, so that nothing that works today breaks.
3. As an agent in Codex or opencode, I want a documented environment variable I can set once, so that the same skill works there too.
4. As an agent, I want the error for a missing identity to name every accepted variable, so that I can fix the environment instead of guessing.
5. As a user running Claude Code in default permission mode, I want wrapped browser commands to be covered by the skill's allow-list, so that I am not prompted on every snapshot and click.
6. As an agent, I want the connect output to print the wrapper invocation in the exact form the allow-list covers, so that I copy something that works.
7. As a user who opens a tab in my own browser while an agent works, I want that not to turn the agent's cleanup into a failure, so that the agent does not report a broken run over my normal browsing.
8. As an agent, I want the dispatcher to still tell me when Chrome's page count grew during my command, so that I can mention a popup if one appeared.
9. As an agent, I want cleanup to exit zero when it closed the exact target it owned and detached its daemon, regardless of what the user's other tabs did, so that my success report is honest and simple.
10. As an agent whose pinned target drifted before a command, I want the dispatcher to restore the target and run my command, so that I do not spend a round trip re-issuing it.
11. As an agent, I want to know when drift was corrected, so that I can suspect a bare agent-browser call somewhere and stop it.
12. As an agent running a snapshot, click, snapshot loop, I want each wrapped command to cost as few daemon round trips as the guarantee allows, so that UI testing stays fast.
13. As an agent, I want to send several safe commands in one `batch` through the wrapper, so that I can amortize the guard's overhead when the guarantee still holds.
14. As an agent, I want `batch` to reject the same tab, window and connection commands the single-command path rejects, so that batching is not a way around the guard.
15. As a maintainer, I want one JSON parsing mechanism across connect, dispatch and cleanup, so that a change in agent-browser's output shape breaks in one place, not two.
16. As a maintainer, I want the unit tests to need only the runtimes the scripts themselves need, so that node alone runs everything.
17. As a maintainer, I want the skill text to describe agent-browser behavior without pinning a version number in prose, so that the text does not silently rot after an upgrade.
18. As an agent reading an error, I want every exit code the scripts can return listed in the troubleshooting reference with its meaning and the recovery step, so that I act on the code instead of the wording.
19. As an agent waiting for the CDP port, I want a progress line during the bounded wait, so that thirty seconds of silence does not look like a hang.
20. As a user, I want none of these changes to weaken the guarantees that already work: exact WebSocket resolution, one attach with no blind retries, cleanup without `--cdp`, exact-target close, and refusal of tab and window creation.

## Implementation Decisions

**Identity resolution.** Connect accepts, in order, an explicit `--session`, `AB_CONNECT_ID`,
`PI_SESSION_ID`, and `CLAUDE_CODE_SESSION_ID`. The order puts the skill's own override
first, then the harness variables. The owner key derivation does not change, so existing
pi sessions keep the same session names and wrapper paths. The missing-identity error
lists all four sources. Codex and opencode are served by `AB_CONNECT_ID`, documented in
SKILL.md as a one-line export for harnesses without a session variable.

**Permission coverage.** The skill's `allowed-tools` frontmatter gains a pattern covering
the wrapper root under both `/tmp` and the macOS per-user temp directory. The connect
output and SKILL.md examples show the wrapper invoked the way the pattern matches. The
wrapper path format itself does not change.

**Target growth is informational.** The dispatcher keeps the before and after page count
and still prints the notice when the count grew, because a page-created popup is worth
knowing about. It no longer persists an event counter into the session metadata, and
cleanup no longer reads one or exits nonzero because of it. The metadata schema drops
the counter field and bumps its version so old wrappers are rejected with the existing
"outdated, re-run connect" message. SKILL.md's cleanup section drops the sentence about
extra targets making cleanup nonzero.

**Drift correction proceeds.** When the pre-command check finds the owned target present
but not active, the dispatcher restores it, prints a one-line notice to stderr, and runs
the command. The post-command check is unchanged. The dedicated exit code for
"restored, re-run" is retired from the pre-command path and remains only for the
post-command case, where the command already ran against the wrong binding.

**Fewer round trips per command.** The pre-command `session info` call is folded into
the pre-command `tab list` call: if `tab list` succeeds the daemon is active, and the
tab-state parser already reports whether the owned target is present. This removes one
agent-browser invocation and one node startup per command without weakening the check.
The lock and the post-command check stay.

**Batch is allowed with scanning.** `batch` is permitted when every line of its input
passes the same argument and action filter the single-command path applies. Batch input
from stdin is read into memory, scanned, then forwarded. Any rejected line rejects the
whole batch before anything is sent. Nested `batch` remains rejected.

**One JSON parser.** The sed-based JSON helpers in the shared library are removed.
Connect uses the existing node helper for session info, as dispatch and cleanup already
do. The node helper gains nothing new.

**One test runtime.** The unit suite's TCP fixture is rewritten in node using the
standard net module. The bun requirement and the bun check are removed. The real-Chrome
suite is unchanged.

**No version pins in prose.** SKILL.md and the troubleshooting reference describe the
probe-then-reconnect discovery behavior and the containment boundary as properties of
the current agent-browser without naming a version. A single line notes which version
the skill was last verified against, and nothing else references it.

**Exit codes documented.** The troubleshooting reference gains a table of every exit code
across connect, dispatch and cleanup with meaning and next step. Codes keep their
current values except the retired pre-drift one.

**Port wait feedback.** The bounded wait prints one stderr line per attempt with the
attempt number and the remaining count.

## Testing Decisions

A good test drives a script the way an agent does, through its command line and
environment, and asserts on exit status, stdout, stderr and the files and mock calls
left behind. It does not read internal shell variables or call library functions
directly, except where the existing suite already computes the expected session name
from the owner key.

The seam is the existing one: the unit suite in the tests directory, which runs
connect, the generated wrapper and cleanup against a mock agent-browser that logs
every invocation and simulates drift, extra targets, attach failure and disconnects.
Every change in this spec is observable there. No new seam is introduced.

Cases to add or change, each as a new `new_case` block in the pattern the suite already
uses:

- Connect succeeds with only `CLAUDE_CODE_SESSION_ID` set and yields the same session
  name that `AB_CONNECT_ID` with the same value would. Connect with none of the four
  sources fails with exit 2 and an error naming all four.
- The extra-target case asserts the dispatcher exits zero, prints the notice, writes
  no counter into metadata, and that cleanup afterwards exits zero with the normal
  success line.
- The drift-before case asserts exit zero, the restore call in the mock log, the
  requested command in the mock log after the restore, and the notice on stderr.
- The exact case's expected count of agent-browser invocations per wrapped command
  drops by one, and the mock log shows no `session info` call from the dispatcher.
- A batch case: a batch of two safe commands is forwarded once; a batch containing
  `tab new` is rejected with exit 2 and reaches the mock zero times.
- A metadata-version case: a version-2 wrapper is rejected by the new dispatcher with
  the outdated message.
- The suite runs with node on PATH and no bun.

The gated real-Chrome suite keeps its existing assertions, with the two cleanup
expectations of exit 6 changed to exit 0, since the popup and drift targets are still
preserved but no longer fail cleanup. The popup case keeps asserting that the popup
target survives cleanup.

Prior art: every case above mirrors an existing block in the unit suite, and the
real-Chrome suite already has the popup and drift scenarios.

## Out of Scope

- The deeper simplification the review sketched, collapsing the scripts to roughly 150
  lines by dropping the lock, the transactional rollback and the symlink hardening.
  This spec keeps every existing safety mechanism and only removes noise and dead code.
- Testing under Chrome's connection-approval mode. The real-Chrome suite still uses a
  headless profile without approval.
- Closing the two leaked pre-rewrite daemons on the user's machine. They can be closed
  by name with the current cleanup script; that is an operator action, not a code change.
- Changing the wrapper path format, the session naming scheme, or the owner key.
- Any change to agent-browser itself, including opener-aware popup containment.

## Further Notes

The repo's CLAUDE.md and AGENTS.md examples stay valid once identity resolution accepts
the Claude Code variable, so they need no edit. The session memory file that describes
the skill should be re-read after the change lands, since it states that cleanup exits
nonzero on extra targets.

No issue tracker or triage label vocabulary was configured for this session, so this
spec is stored alongside the skill instead of being published. Run
`/setup-matt-pocock-skills` to configure one, then publish with the `ready-for-agent`
label.

## Implementation notes (2026-09-04)

Implemented by two agents in sequence on the same tree. Deviations from the decisions above:

- **The dispatcher keeps its `session info` call.** Folding it into `tab list` would have
  let a wrapper on a dead session pass `--cdp` to a fresh daemon, which opens a new Chrome
  connection and approval dialog, or launch a bundled browser. Story 20 forbids that
  trade, so per-command cost stays at four agent-browser invocations. `batch` is the
  sanctioned way to amortize it.
- **Metadata is version 4, not 3.** The second agent added `owner_id` and an
  owner-consistency check, and moved the lock key from owner to session so two explicit
  callers on one daemon serialize. Both kept; both covered by tests.
- **Extra hardening kept from the second agent:** `inspect` (opens a DevTools window),
  tab-management key chords via `press`, `--flag=value` variants, and flags before the
  action are all rejected.
- **The version pin survives in one place** in each document as a "last verified against"
  line, as decided.
