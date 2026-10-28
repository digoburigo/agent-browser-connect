# agent-browser-connect

An [agent skill](https://code.claude.com/docs/en/skills) that lets a coding agent drive **the Chrome you already have open** — your profile, your logins, your extensions — instead of launching a headless browser you cannot see.

It wraps [`agent-browser`](https://github.com/vercel-labs/agent-browser) so that every command the agent issues is bound to one tab it owns. The rest of your browser is left alone, and several agents can share the same Chrome without stealing each other's tabs.

## Why

Since 0.39.2, agent-browser retains a live external CDP attachment across follow-up commands, and tab pinning is sticky. This skill adds conversation ownership, exact-target verification, serialized commands, controlled recovery and an allow-list. Its per-session wrapper still passes the exact browser WebSocket, `--pin-tab` and `--session` on every call; upstream attachment persistence is not an ownership or cleanup boundary.

## Prerequisites

- **bash**, **node** (for the small JSON helpers), and standard Unix tools
- **`agent-browser`** on your `PATH`: `npm install -g agent-browser` (tested against 0.40.0)
- **Google Chrome** (or Chromium / Brave / Chrome Canary) with remote debugging on: open `chrome://inspect/#remote-debugging`, tick **Enable**, wait for `Server running at: 127.0.0.1:9222`. Chrome remembers this across restarts.

macOS and Linux. Windows is not supported (WSL should work; untested).

## Install

The repository root _is_ the skill, so clone it straight into your agent's skills directory:

```bash
# Claude Code
git clone https://github.com/digoburigo/agent-browser-connect \
  ~/.claude/skills/agent-browser-connect
```

Update later with `git -C ~/.claude/skills/agent-browser-connect pull`.

Other agents read skills from their own directory — clone to whichever applies:

| Agent                     | Directory                     |
| ------------------------- | ----------------------------- |
| Claude Code               | `~/.claude/skills/`           |
| Codex / opencode / pi     | `~/.agents/skills/`           |
| Project-local (any agent) | `.claude/skills/` in the repo |

To share **one** copy across several agents, clone once to a canonical location and symlink it into each skills directory:

```bash
git clone https://github.com/digoburigo/agent-browser-connect ~/.agents/skills/agent-browser-connect
ln -s ~/.agents/skills/agent-browser-connect ~/.claude/skills/agent-browser-connect
```

The scripts resolve their own location, so any install path works. `SKILL.md` does not hardcode an install path either: it tells the agent to start `connect.sh` from the directory its harness loaded the skill from, and `connect.sh` then prints absolute paths for everything that follows, so the directory is needed exactly once.

If you run several agents against one clone, symlinking (above) is what keeps them in sync. A machine with Claude Code, Codex, opencode and pi installed ends up with the skill visible at seven or more paths; one real clone plus symlinks means one `git pull` updates all of them.

## Usage

The agent invokes it; you normally do not. In short:

```bash
# 1. Connect — opens one pinned tab and prints a wrapper path + session name.
#    Substitute wherever you installed the skill; this example assumes Claude Code.
bash ~/.claude/skills/agent-browser-connect/scripts/connect.sh myapp --url http://localhost:3000

# 2. Every browser command goes through the printed wrapper
bash <wrapper> snapshot -i
bash <wrapper> click @e3

# 3. Finish this task, keeping the approved connection for conversation follow-ups.
bash <skill-dir>/scripts/cleanup.sh --keep-alive <session>

# 4. Release only on explicit disconnect or at conversation end (keeps the tab).
bash <skill-dir>/scripts/cleanup.sh <session>
```

Add `--react` to `connect.sh` when the task needs React introspection — the DevTools hook is an init script registered once per session, not per page, so it cannot be added later.

Browser access is conversation-scoped: use the same wrapper for follow-ups. Re-running connect with the same owner/slot reuses the connection and preserves settings. Omitted flags no longer reset them; use `--no-persistent`, `--no-auto-approve` or `--no-react` to opt out explicitly.

Add `--persistent` for bounded recovery after connection loss. Add `--auto-approve` on macOS only after an explicit opt-in to pressing Chrome's security dialog (terminal Accessibility permission required). Reusing a live connection starts no approval clicker. Browser-access permission alone never enables auto-approval. See [`references/design.md`](references/design.md#auto-approve-pressing-chromes-dialog).

New owners default to **20-minute idle disconnection**, using agent-browser's native timer. Chrome, the owned tab, wrapper, binding and settings remain for resume. Existing saved timeouts are unchanged; reconnect with `--idle-timeout 1200` to switch an existing owner. Changing a live timeout replaces the daemon and may require approval; unchanged settings keep the socket. `--idle-timeout 0` disables shutdown. Idle resume needs a new Chrome connection but remembers a granted auto-approval opt-in. See [session options](references/session-options.md#idle-policy) for environment overrides.

Cleanup uses fixed existing-only daemon control, not a separate CLI browser command. It never bootstraps a daemon or replays an uncertain action. Native route and tab operations can still redial Chrome if backend health changes after preflight. The bridge depends on the native protocol of the tested version above, with a 30-second active-I/O deadline and a 256 KiB aggregate response cap. Unsupported responses fail closed. See [cleanup limits](references/design.md#cleanup).

Full agent-facing instructions: [`SKILL.md`](SKILL.md).

## Documentation

- [`SKILL.md`](SKILL.md) — the steps the agent follows. Short by design.
- [`references/session-options.md`](references/session-options.md) — optional recovery, auto-approval, React, idle policy and batch commands.
- [`references/design.md`](references/design.md) — why the wrapper exists, what the guard rejects, the containment boundary, and the Chrome/CDP behaviour behind each decision.
- [`references/troubleshooting.md`](references/troubleshooting.md) — recovery for repeated approval dialogs, a closed port, Chrome restarts, `tab_gone`, drift, wrong-page commands, stale daemons, and the exit-status table.

## Tests

```bash
bash tests/run.sh                                  # deterministic mock daemon + lifecycle regressions
AB_RUN_REAL_CHROME=1 bash tests/real-chrome.sh     # gated; disposable Chrome profile
AB_RUN_USER_CHROME=1 bash tests/real-chrome-guard.sh    # gated; one tab in YOUR Chrome, gentle
AB_RUN_USER_CHROME=1 bash tests/stress-user-chrome.sh   # gated; opens N tabs in YOUR Chrome
```

`real-chrome-guard.sh` is the safe one: a single session, no concurrency, no tab creation, and it releases with plain `cleanup.sh` so your tab survives. It checks what the mock suite structurally cannot — that the guard really sits in front of a live CLI, that a real daemon accepts the batch form the dispatcher sends, and that the bound tab is unchanged after every refusal.

**The stress test can crash the browser it is testing.** At its default 10 tabs x 6 rounds it segfaulted Chrome 153 during round 6 (2026-09-18), taking every open tab with it. Chrome relaunched itself and the helper released all ten sessions cleanly, but do not point this at a browser you are relying on — pass a smaller count (`... stress-user-chrome.sh 3 3`) or run it against a Chrome you are happy to lose.

`tests/run.sh` runs in CI on every push. Its lifecycle regressions cover sticky settings, concurrent opt-outs and timeout handoffs, task cleanup, scoped approval, native timeout propagation, migration and transactional replacement. The disposable suite observes daemon process exit, stable follow-up TCP sockets, long commands, same-target resume, zero disable, maximum conversion, failed replacements, malformed-policy release and pre-administration expiry. It inspects actual CDP targets. It does not exercise real approval dialogs or establish compatibility with historical daemon protocols. Set `AB_LEGACY_IDLE_SOURCE` to an archived pre-migration `scripts/idle.mjs` to also observe an already-running old watcher exit after migration.

## Contributing

Keep `SKILL.md` short — it is loaded into an agent's context on every browser task. Rationale belongs in `references/design.md`, recovery steps in `references/troubleshooting.md`. Run `tests/run.sh` before opening a PR.

If you installed via symlink, edit through the symlink freely; **replacing a symlink with a real directory** silently stops that agent from receiving updates.

## License

MIT — see [LICENSE](LICENSE). `agent-browser` itself is a separate project (vercel-labs, Apache-2.0); this skill uses its CLI and fixed native administrative protocol.
