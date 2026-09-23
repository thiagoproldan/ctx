# ctx

Keeps Claude Code's context small, and hands off to
[ekko](https://github.com/thiagoproldan/ekko) before it grows.

ctx is a fork of shunt, this machine's port of Spotify's
[`shunt`](https://github.com/spotify/portal-ai-plugins/tree/main/plugins/shunt)
Claude Code plugin, described in _[Portal by Spotify cut my Claude Code token
usage by 90%](https://engineering.atspotify.com/2026/9/portal-by-spotify-cut-my-claude-code-token-usage-by-90)_,
which lived in the NixOS configuration until this repository took it over.

Two ideas:

- **I/O work does not need the expensive model.** Reading 6,000 lines to answer
  "what does this module do?" and generating predictable boilerplate are jobs a
  cheap model handles — and what comes back into the expensive context is the
  answer, not the file.
- **A long session pays for its whole context on every call.** Re-reading the
  context is most of the bill; a handoff to the board and a `/clear` drop it.

What the plugin adds to both is _enforcement_: hooks block the big read, and
hold the turn for the handoff, instead of trusting someone to remember.

Installed from this flake into every Claude Code profile, as a skills-directory
plugin, the same way ekko is.

## Layers

1. **Hooks** (`src/hooks/`, wired by `plugin.json`)
   - `check-file-size` — `PreToolUse` on `Read`: a whole-file read above
     `CTX_MIN_LINES` (350) is denied with a message that teaches the right path.
     `offset`/`limit` reads pass.
   - `check-bash-read` — `PreToolUse` on `Bash`: parses the command with `shfmt`
     and denies it if the whole command line would print more than the threshold.
   - `announce-graph` — `SessionStart`: if the project has a graphify index, say
     so on turn zero.
   - `track-usage` — `PostToolUse` on `Bash|Read`: records what happened after a
     block, for the funnel.
   - `handoff` — `Stop`: past `CTX_HANDOFF_TOKENS` of context (250k), or the
     5-hour window past `CTX_HANDOFF_5H` (85%), keeps the turn open once and
     asks for the ekko handoff and a `/clear` — unless a handoff the session
     wrote moments before already holds it.
   - `handoff-written` — `PostToolUse` on ekko's `create` and `batch`: notes the
     context at which the session wrote a handoff, so its age can be shown.
2. **Scripts** — `ctx-bulk-read` and `ctx-code-write` do the delegation;
   `ctx-report` and `ctx-test` measure and verify; `ctx-statusline` draws the
   status line.
3. **Skills** — `bulk-reader` and `code-writer` say when and how to call them.
   `handoff` is the user's alone (`/handoff`): the Stop hook's ask, at a moment
   the user picks.

## The handoff

The status line has said `ctx Nk ⚑ handoff` since 2026-09-15, and the clears
still came late and by eye: on 2026-09-21 at 199k, 349k, 356k, 506k and 719k
of context. Every call re-reads the whole context, so each of those segments
paid for tokens a handoff would have dropped.

A replay of 30 days of this machine's transcripts (344 sessions) priced the
policy "reset at the end of any turn that closes above T" against what was
actually done. T = 250k saves 22–25% of the bill net (the range is how much
nuance a reset loses: none, or ten extra calls each), about 90% of what 200k
saves with about 30% fewer resets — and each reset costs the user a `/clear`
and the next session a few minutes of orientation. Hence the default.

At the end of each turn, the `handoff` hook:

- reads the context from the end of the transcript: the last main-thread
  call's input, cache writes and cache reads. A subagent's replies do not
  count, and neither does a line still being written;
- past the threshold, keeps the turn open once — as `additionalContext`, which
  Claude Code shows as _Stop hook feedback_, not as an error — asking first for
  typed ekko notes (decision, gotcha, procedure) for whatever later sessions
  must keep, then for the handoff on the task in progress: where it stopped,
  what was decided and why, the files, the notes the next session must read in
  full, by id, and the next step as an action the next session takes at once,
  without exploring first. Then one line telling the user to `/clear`;
- asks once per band: at T, again at 2T, 3T…; a compaction re-arms the bands
  it came back under;
- asks when the 5-hour window passes `CTX_HANDOFF_5H`, once, re-armed when the
  window comes back under it. A Stop hook's input carries no rate limits, so
  the status line leaves each session's reading in `$CTX_STATE/sessions/`, and
  the hook trusts it for 10 minutes;
- stays quiet while a stop hook is already continuing the turn, and while
  background work or a scheduled wakeup would resume the session — a `/clear`
  then would drop it. It asks at the next stop instead;
- stays quiet, and counts the band as asked, while a handoff this session wrote
  is fresh: less than a tenth of the threshold of context since it;
- logs each ask, and each one a fresh handoff spared, to
  `$CTX_STATE/handoff.jsonl`.

The ask is the body of `skills/handoff/SKILL.md`, which is also what `/handoff`
sends: one text, so the hook and the command cannot drift apart.

A handoff goes stale as the session goes on. The first live ask came at 330k
on 2026-09-23; a user who keeps working after it, because the session matters,
would `/clear` later from a handoff that no longer says where the session
stopped — and the next session is told to act on it at once. Asking again
every so often would hold a turn each time, in exactly those sessions. So the
`handoff-written` hook notes the context each accepted handoff was written at
(`$CTX_STATE/handoff/<session>.written`), and the status line shows the age:
`✓ handoff 5k ago` while it is fresh, `⚑ handoff 80k ago` once the session has
gone on, which is the cue to run `/handoff` before the `/clear`.

In a folder without an ekko board, the ask only tells the user. ekko needs
nothing new for this: the handoff is an ekko note of kind `handoff`, which the
next session's prime shows first.

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
  The cap becomes the worker's context (`CTX_MAX_PAYLOAD_BYTES`, 2 MB).
- **`agy` is an agent with every tool auto-approved in print mode** —
  `run_command`, `write_to_file`, web access — and no flag turns that off
  (`--mode plan` does not; measured). The worker reads untrusted text, so a prompt
  injection in a log would be a shell on this machine. It therefore runs under
  `bwrap`:
  - only `/nix`, `/etc` and the `/run` entries DNS needs are mounted; no `$HOME`,
    no `/projects`, no `/run/secrets`;
  - no D-Bus at all: no keyring, and no `systemd --user` — the session bus would
    let the worker start a process outside the sandbox;
  - its home is its **own**, `~/.local/state/ctx/worker-home`, mounted as an
    ephemeral overlay: nothing the worker writes survives the call — its
    conversation history, its config, an MCP server an injection tries to add.

  `ctx-test --live` checks these walls directly (writes reach neither `$HOME`
  nor the worker home, no user directories, keyring or bus are visible, systemd
  is unreachable) and makes one real call of each kind.

### The worker's login

`agy` keeps your login in the system keyring, and exposing the Secret Service to
the sandbox would hand an injected worker every other secret in it. But `agy`
falls back to a token file when there is no D-Bus session (its changelog:
"bypasses the keyring when no D-Bus session bus is present"). So the worker has
its own home, signed in once:

```bash
ctx-login          # interactive: open the URL it shows in your browser
ctx-login --force  # sign in again (expired or revoked token)
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
| Ledger + funnel + session metrics (`ctx-report`)                                           | The article's 90% is theirs. This measures yours.                                                                                                                                                                                                                                                                                |

## Integration with graphify

The two cut tokens in different halves: graphify cuts the cost of **finding**
(querying an AST graph instead of opening five files), ctx cuts the cost of
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
| called `ctx-bulk-read`    | fine                                              |
| **nothing**                 | the hook was ignored and the information was lost |

A block's outcome is the first relevant event **of the same session** between it
and that session's next block — without that window, one graph query would
"resolve" every earlier block.

## Is it worth it for how you work?

`ctx-report` section 3 reads the Claude Code transcripts of every profile and
splits tool output by tool, plus how much of it came in results over the
threshold — the share a hook could still catch. When this port was rebuilt
(2026-09-15), that share was 11% over the previous week: most context came from many small Bash
outputs, not from big files. The article's 90% was measured on reading big files
in a monorepo; it is a ceiling for that workload, not a promise for every one.
Compare windows with `--since`/`--until` to see what a change actually did.

## Usage

```bash
ctx-bulk-read  --question "what does this do?" --paths a.py b.py
ctx-code-write --spec "tests for X" --reference ref_test.py --target new_test.py
ctx-report [--since 2026-09-08] [--until 2026-09-15]
ctx-login [--force]
ctx-statusline   # Claude Code runs it; reads the status-line JSON on stdin
ctx-test [--live]
```

## Status line

`ctx-statusline` shows the terms that decide what a session costs. Per call,
with Opus 5 weights, cost = 0.1·C + 2·(d + ρ·C) + 5·o: the context re-read on
every call (70% of the measured bill), the full rewrite when the cache is
invalidated or cold (10%), and the output. So it shows:

| Segment                                                  | Meaning                                                               |
| -------------------------------------------------------- | --------------------------------------------------------------------- |
| `Opus 5 max`                                             | model and effort — changing either mid-session invalidates the cache  |
| `ctx 212k ⚑ handoff`                                     | context tokens; yellow from `CTX_HANDOFF_TOKENS`, red at twice that |
| `ctx 335k ✓ handoff 5k ago`                              | a handoff this session wrote, fresh: a `/clear` loses nothing         |
| `ctx 410k ⚑ handoff 80k ago`                             | the session went on past it: `/handoff` again before the `/clear`     |
| `5h 87% ↺14:30 ⚑ handoff`                                | 5-hour window and its reset; handoff from `CTX_HANDOFF_5H`          |
| `7d 41%`                                                 | 7-day window, on terminals at least 100 columns wide                  |
| `cache ● 38m` / `cache ○ cold, next call re-caches 612k` | minutes until the cache goes cold, or what the next call will rewrite |
| `miss ×2 tools_changed`                                  | cache misses this session and the last cause Claude Code diagnosed    |

The NixOS module wires it through a `claude` wrapper that adds `--settings` with the
status line: command-line settings rank above user settings, so every profile
gets it while `settings.json` stays mutable, and a plugin cannot carry a status
line. The wrapper leaves subcommands alone — on 2.1.272, `attach`, `kill`, `logs`,
`respawn`, `rm` and `stop` reject `--settings`, and `remote-control` errors — using
the list from the binary's own `--help`, plus the hidden `rc`/`remote-control`.

## Variables

| Var                     | Default                   | What                                                               |
| ----------------------- | ------------------------- | ------------------------------------------------------------------ |
| `CTX_MIN_LINES`         | `350`                     | Block threshold                                                    |
| `CTX_MODEL`             | `gemini-3.8-flash-medium` | Worker model (`agy models` lists them)                             |
| `CTX_TIMEOUT_SECONDS`   | `300`                     | Cap per call                                                       |
| `CTX_MAX_PAYLOAD_BYTES` | `2000000`                 | Payload cap                                                        |
| `CTX_DISABLE`           | —                         | `1` disarms **every** hook                                         |
| `CTX_STATE`             | `~/.local/state/ctx`      | Where the ledgers, session readings and worker home live           |
| `CTX_WORKER_HOME`       | `$CTX_STATE/worker-home`  | The worker's own home, holding its `agy` login                     |
| `GRAPHIFY_OUT`          | `graphify-out`            | Read, never set here — honours graphify's own                      |
| `CTX_HANDOFF_TOKENS`    | `250000`                  | Status line and Stop hook: context that warrants a handoff (0 off) |
| `CTX_HANDOFF_5H`        | `85`                      | Status line and Stop hook: 5-hour percentage for a handoff         |
| `CTX_CACHE_WARN_MIN`    | `5`                       | Status line: minutes left before cache is cold                     |

## Moving from shunt

Every `SHUNT_` variable is now `CTX_`, and every `shunt-` command `ctx-`. The
state moved from `~/.local/state/shunt` to `~/.local/state/ctx`: move the
directory to keep the worker's login and the ledgers, or run `ctx-login` once.

## What it does not solve

The worker is cheap, not good. Its answer is an **unverified** summary: check on
disk (`sed -n 'N,Mp'`) any exact line or value before using it in an edit, and
run the tests of whatever `ctx-code-write` generates. The gain is in not
loading 80k tokens of file for a 900-token question — not in trusting the answer.

## graphify on NixOS

The NixOS module also installs graphify from nixpkgs and its Claude skill from the
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

## License

Apache License 2.0, the license of upstream shunt: see `LICENSE`, and `NOTICE`
for what this repository took from it.
