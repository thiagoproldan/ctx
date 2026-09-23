# shunt

A local port of Spotify's [`shunt`](https://github.com/spotify/portal-ai-plugins/tree/main/plugins/shunt)
Claude Code plugin, described in _[Portal by Spotify cut my Claude Code token
usage by 90%](https://engineering.atspotify.com/2026/9/portal-by-spotify-cut-my-claude-code-token-usage-by-90)_.

One idea: **I/O work does not need the expensive model.** Reading 6,000 lines to
answer "what does this module do?" and generating predictable boilerplate are
jobs a cheap model handles — and what comes back into the expensive context is
the answer, not the file. What the plugin adds to the idea is _enforcement_:
hooks block the big read instead of trusting someone to remember.

Installed by `usr.shunt` (`modules/usr/shunt.nix`) into every Claude Code
profile, as a skills-directory plugin, the same way `usr.ekko` is.

## Layers

1. **Hooks** (`src/hooks/`, wired by `plugin.json`)
   - `check-file-size` — `PreToolUse` on `Read`: a whole-file read above
     `SHUNT_MIN_LINES` (350) is denied with a message that teaches the right path.
     `offset`/`limit` reads pass.
   - `check-bash-read` — `PreToolUse` on `Bash`: parses the command with `shfmt`
     and denies it if the whole command line would print more than the threshold.
   - `announce-graph` — `SessionStart`: if the project has a graphify index, say
     so on turn zero.
   - `track-usage` — `PostToolUse` on `Bash|Read`: records what happened after a
     block, for the funnel.
2. **Scripts** — `shunt-bulk-read` and `shunt-code-write` do the delegation;
   `shunt-report` and `shunt-test` measure and verify.
3. **Skills** — `bulk-reader` and `code-writer` say when and how to call them.

## The worker: Gemini through `agy`, sandboxed

Upstream talks to AiKA Modes via `portal-cli` (Gemini 2.5 Flash), Spotify-internal
infrastructure. Here the worker is the Antigravity CLI (`agy`) on the Gemini
subscription, default model `gemini-3.8-flash-medium`.

The worker being **outside Claude's quota** is the point. The first version of
this port used `claude -p --model haiku`: cheaper per token, but it drew from the
same subscription, and every call also paid ~15k tokens of Claude Code system
prompt.

Two things about `agy` had to be dealt with:

- **No stdin for `-p`, and argv caps one argument at 128 KB.** The turn goes in
  as one NDJSON event through `--input-format stream-json`, which does read stdin.
  The cap becomes the worker's context (`SHUNT_MAX_PAYLOAD_BYTES`, 2 MB).
- **`agy` is an agent with every tool auto-approved in print mode** —
  `run_command`, `write_to_file`, web access — and no flag turns that off
  (`--mode plan` does not; measured). The worker reads untrusted text, so a prompt
  injection in a log would be a shell on this machine. It therefore runs under
  `bwrap`:
  - only `/nix`, `/etc` and the `/run` entries DNS needs are mounted; no `$HOME`,
    no `/projects`, no `/run/secrets`;
  - no D-Bus at all: no keyring, and no `systemd --user` — the session bus would
    let the worker start a process outside the sandbox;
  - its home is its **own**, `~/.local/state/shunt/worker-home`, mounted as an
    ephemeral overlay: nothing the worker writes survives the call — its
    conversation history, its config, an MCP server an injection tries to add.

  `shunt-test --live` checks these walls directly (writes reach neither `$HOME`
  nor the worker home, no user directories, keyring or bus are visible, systemd
  is unreachable) and makes one real call of each kind.

### The worker's login

`agy` keeps your login in the system keyring, and exposing the Secret Service to
the sandbox would hand an injected worker every other secret in it. But `agy`
falls back to a token file when there is no D-Bus session (its changelog:
"bypasses the keyring when no D-Bus session bus is present"). So the worker has
its own home, signed in once:

```bash
shunt-login          # interactive: open the URL it shows in your browser
shunt-login --force  # sign in again (expired or revoked token)
```

It runs `agy` inside the same walls with the worker home writable, then checks
the login from inside the call sandbox. **Residual exposure:** the worker's own
Gemini token, and the network the model API needs.

## Where this port diverges from upstream (and why)

| Change                                                                                       | Reason                                                                                                                                                                                                                                                                                                                           |
| -------------------------------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Hook schema `hookSpecificOutput.permissionDecision: "deny"`                                  | Upstream emits `{"decision":"block"}`, a legacy form current docs no longer describe.                                                                                                                                                                                                                                            |
| **Numbered lines** sent to the worker                                                        | Unnumbered, the worker _counts_ lines to cite a position and gets it wrong: on a 6,101-line file it placed `importlib.import_module` at 1779; it is at 2879. Numbered, it hit 2869 and 2879 exactly.                                                                                                                             |
| `check-bash-read` parses the command (shfmt) instead of matching its start                   | Upstream only looks at a command that _starts_ with `cat`/`head`/…. Claude writes compound commands: one week of real sessions had 586 reads mid-command (`cd x && cat y`, `2>/dev/null`, `for … cat`). This version follows `cd`, expands `for` loops and globs, carries line counts through pipes, and sums the whole command. |
| `head`/`tail` only count as a dump when N exceeds the threshold                              | `head file` shows 10 lines. Upstream blocks it anyway — punishing the targeted read the plugin wants to encourage.                                                                                                                                                                                                               |
| `code-write --target` refuses to overwrite without `--force`, and checks the directory first | The output passes through nobody's context: a wrong target erases a file silently. An unwritable target only surfaced _after_ paying for the generation.                                                                                                                                                                         |
| Worker sandbox                                                                               | See above.                                                                                                                                                                                                                                                                                                                       |
| Ledger + funnel + session metrics (`shunt-report`)                                           | The article's 90% is theirs. This measures yours.                                                                                                                                                                                                                                                                                |

## Integration with graphify

The two cut tokens in different halves: graphify cuts the cost of **finding**
(querying an AST graph instead of opening five files), shunt cuts the cost of
**ingesting** a big file you already know. A structural question delegated to a
cheap model pays for a worse answer than the graph gives for free.

So the block message suggests the graph first — but only when it really exists.
`lib/graphify.sh` speaks only when **both** hold:

- `graphify` is on `PATH` (suggesting a missing command is worse than nothing);
- `<root>/graphify-out/graph.json` exists, searched climbing at most 12 levels
  from the file (honours `GRAPHIFY_OUT`, relative name or absolute path, as
  `graphify/paths.py` does).

If `graph.json` is older than the file being read, the message says so — it does
not block: a stale index still serves for navigation, as long as you know.

## The funnel: is it being used right?

Counting usage answers _"it was used"_, never _"it was used when it should have
been"_. The funnel does: each block has exactly four outcomes, and only one is bad.

| Outcome                     | Reading                                           |
| --------------------------- | ------------------------------------------------- |
| queried the graph           | great                                             |
| re-read with `offset/limit` | great — it was an edit                            |
| called `shunt-bulk-read`    | fine                                              |
| **nothing**                 | the hook was ignored and the information was lost |

A block's outcome is the first relevant event **of the same session** between it
and that session's next block — without that window, one graph query would
"resolve" every earlier block.

## Is it worth it for how you work?

`shunt-report` section 3 reads the Claude Code transcripts of every profile and
splits tool output by tool, plus how much of it came in results over the
threshold — the share a hook could still catch. When this port was rebuilt
(2026-09-15), that share was 11% over the previous week: most context came from many small Bash
outputs, not from big files. The article's 90% was measured on reading big files
in a monorepo; it is a ceiling for that workload, not a promise for every one.
Compare windows with `--since`/`--until` to see what a change actually did.

## Usage

```bash
shunt-bulk-read  --question "what does this do?" --paths a.py b.py
shunt-code-write --spec "tests for X" --reference ref_test.py --target new_test.py
shunt-report [--since 2026-09-08] [--until 2026-09-15]
shunt-login [--force]
shunt-statusline   # Claude Code runs it; reads the status-line JSON on stdin
shunt-test [--live]
```

## Status line

`shunt-statusline` shows the terms that decide what a session costs. Per call,
with Opus 5 weights, cost = 0.1·C + 2·(d + ρ·C) + 5·o: the context re-read on
every call (70% of the measured bill), the full rewrite when the cache is
invalidated or cold (10%), and the output. So it shows:

| Segment                                                  | Meaning                                                               |
| -------------------------------------------------------- | --------------------------------------------------------------------- |
| `Opus 5 max`                                             | model and effort — changing either mid-session invalidates the cache  |
| `ctx 212k ⚑ handoff`                                     | context tokens; yellow from `SHUNT_HANDOFF_TOKENS`, red at twice that |
| `5h 87% ↺14:30 ⚑ handoff`                                | 5-hour window and its reset; handoff from `SHUNT_HANDOFF_5H`          |
| `7d 41%`                                                 | 7-day window, on terminals at least 100 columns wide                  |
| `cache ● 38m` / `cache ○ cold, next call re-caches 612k` | minutes until the cache goes cold, or what the next call will rewrite |
| `miss ×2 tools_changed`                                  | cache misses this session and the last cause Claude Code diagnosed    |

`usr.shunt` wires it through a `claude` wrapper that adds `--settings` with the
status line: command-line settings rank above user settings, so every profile
gets it while `settings.json` stays mutable, and a plugin cannot carry a status
line. The wrapper leaves subcommands alone — on 2.1.272, `attach`, `kill`, `logs`,
`respawn`, `rm` and `stop` reject `--settings`, and `remote-control` errors — using
the list from the binary's own `--help`, plus the hidden `rc`/`remote-control`.

## Variables

| Var                       | Default                    | What                                           |
| ------------------------- | -------------------------- | ---------------------------------------------- |
| `SHUNT_MIN_LINES`         | `350`                      | Block threshold                                |
| `SHUNT_MODEL`             | `gemini-3.8-flash-medium`  | Worker model (`agy models` lists them)         |
| `SHUNT_TIMEOUT_SECONDS`   | `300`                      | Cap per call                                   |
| `SHUNT_MAX_PAYLOAD_BYTES` | `2000000`                  | Payload cap                                    |
| `SHUNT_DISABLE`           | —                          | `1` disarms **every** hook                     |
| `SHUNT_STATE`             | `~/.local/state/shunt`     | Where the ledger, funnel and worker home live  |
| `SHUNT_WORKER_HOME`       | `$SHUNT_STATE/worker-home` | The worker's own home, holding its `agy` login |
| `GRAPHIFY_OUT`            | `graphify-out`             | Read, never set here — honours graphify's own  |
| `SHUNT_HANDOFF_TOKENS`    | `200000`                   | Status line: context that warrants a handoff   |
| `SHUNT_HANDOFF_5H`        | `85`                       | Status line: 5-hour percentage for a handoff   |
| `SHUNT_CACHE_WARN_MIN`    | `5`                        | Status line: minutes left before cache is cold |

## What it does not solve

The worker is cheap, not good. Its answer is an **unverified** summary: check on
disk (`sed -n 'N,Mp'`) any exact line or value before using it in an edit, and
run the tests of whatever `shunt-code-write` generates. The gain is in not
loading 80k tokens of file for a 900-token question — not in trusting the answer.

## graphify on NixOS

`usr.shunt` also installs graphify from nixpkgs and its Claude skill from the
package (`skill.md` plus `skills/claude/references`), in place of
`graphify install`, and ignores `graphify-out/` globally in git. Two details
found by measuring:

- **`--code-only` is the default you want.** Without it, `graphify .` aborts when
  the corpus has docs/PDFs/images: those need an LLM API key, and a subscription
  login is not one. The **code** graph is local and free anyway:
  `graphify . --code-only --no-viz`.
- **`.glsl` is not indexed** — GLSL shaders are invisible to the graph and need
  reading. `.swift`, `.metal`, `.m` and `.mm` are (the last three through the C
  parser).
