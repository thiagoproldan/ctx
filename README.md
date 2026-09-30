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

What the plugin adds to both is _enforcement_: hooks block the big read,
instead of trusting someone to remember. The handoff is the user's to time,
between tasks, and the status line flags when it is due; a session left alone
is held for it, and cleared into a fresh one.

Installed from this flake into every Claude Code profile, as a skills-directory
plugin, the same way ekko is.

## Layers

1. **Hooks** (`src/hooks/`, wired by `plugin.json`)
   - `check-file-size` — `PreToolUse` on `Read`: a whole-file read above
     `CTX_MIN_LINES` (350) is denied with a message that teaches the right path.
     `offset`/`limit` reads pass.
   - `check-bash-read` — `PreToolUse` on `Bash`: parses the command with `shfmt`
     and denies it if the whole command line would print more than the threshold.
   - `guard-work-loss` — `PreToolUse` on `Bash`: denies a git or `rm -r` call
     only when it would destroy work that exists nowhere else, and says what
     (see _The work-loss guard_).
   - `guard-secrets` — `PreToolUse` on `Read`, `Grep` and `Bash`: denies a call
     that would bring secret material into the context, and says what (see
     _The secrets guard_).
   - `guard-window` — `PreToolUse` on `Agent`, `Task`, `CronCreate`,
     `ScheduleWakeup` and `Bash`: past the cap on the 5-hour window, denies the
     work a session starts on its own (see _The 5-hour cap_).
   - `window` — `SessionStart`, `UserPromptSubmit` and `PostToolUse` on every
     tool: tells the model where the account's 5-hour window stands, and holds
     a scheduled prompt past the cap (see _The 5-hour cap_).
   - `announce-graph` — `SessionStart`: if the project has a graphify index, say
     so on turn zero.
   - `track-usage` — `PostToolUse` on `Bash|Read`: records what happened after a
     block, for the funnel.
   - `handoff` — `Stop`: with the user away, past `CTX_HANDOFF_TOKENS` of
     context (250k), keeps the turn open once and asks for the ekko handoff,
     then has `bin/auto-reset` type the `/clear` and `continuando` into the
     session's Konsole tab (see _A session left alone_). With the user there it
     asks nothing: the status line flags the handoff, and the user runs
     `/handoff` (see _The handoff_).
   - `handoff-written` — `PostToolUse` on ekko's `create` and `batch`: notes the
     context at which the session wrote a handoff, so its age can be shown.
   - `cold-return` — `UserPromptSubmit`, off by default: with `CTX_COLD_TOKENS`
     set (250000, the Stop hook's threshold), a prompt that comes back to a
     context that big after `CTX_COLD_MINUTES` (60) idle, when the prompt cache
     has expired, is stopped once with what going on and starting over would
     cost and how old the handoff is; sent again, it goes through.
2. **Scripts** — `ctx-bulk-read` and `ctx-code-write` do the delegation;
   `ctx-report` and `ctx-test` measure and verify; `ctx-statusline` draws the
   status line.
3. **Skills** — `bulk-reader` and `code-writer` say when and how to call them.
   `handoff` is for the user only (`/handoff`): the handoff at a moment the
   user picks, in the text the Stop hook asks a session left alone with.

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

Until 0.10.0 the hook asked whoever was there, at whatever point the work had
reached. Of its 30 asks over 2026-09-23..29 with the user there, 18 were
followed by a prompt that went on with the work, and 12 ended the session
(ekko task 961). Claude Code's own advice is a `/clear` between unrelated
tasks, and only the user can tell where one ends. So with the user there the
hook asks nothing: the status line flags the handoff from the threshold on,
and the user runs `/handoff` and `/clear` between tasks. Claude Code's
compaction (`autoCompactWindow`, ~417k here) stays the net under a session
that is never cleared.

At the end of each turn, the `handoff` hook reads the context from the end of
the transcript: the last main-thread call's input, cache writes and cache
reads. A subagent's replies do not count, and neither does a line still being
written. With the user there, it asks nothing, and logs each ask it spared,
once, to `$CTX_STATE/handoff.jsonl` as `handoff-quiet`. With the user away
(see _A session left alone_), it:

- past the threshold, keeps the turn open once — as `additionalContext`,
  which Claude Code shows as _Stop hook feedback_, not as an error — asking
  first for typed ekko notes (decision, gotcha, procedure) for whatever later
  sessions must keep, then for the handoff on the task in progress: where it
  stopped, what was decided and why, the files, the notes the next session
  must read in full, by id, and the next step as an action the next session
  takes at once, without exploring first. Then one line telling the user to
  `/clear`, which ctx types itself;
- asks once per band: at T, again at 2T, 3T…; a compaction re-arms the bands
  it came back under. A band crossed with the user there is still owed, and
  asked once the user is away;
- past the threshold, asks again when the 5-hour window passes its cap,
  `CTX_HANDOFF_5H`, once, re-armed when a later window comes in under it. It
  reads the account's reading (see _The 5-hour cap_), and past the cap the
  ask adds what the cap asks: start nothing new. The cap by itself asks
  nothing;
- stays quiet while a stop hook is already continuing the turn;
- once a handoff this session wrote is fresh — less than a tenth of the
  threshold of context since it — starts the reset instead of a second ask;
- logs each ask to `$CTX_STATE/handoff.jsonl`.

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

### Coming back to a cold cache

Claude Code keeps the context cached for an hour. After a longer pause, the
next call writes all of it back to the cache, at twice the input price, before
any work: in the 30 days to 2026-09-24 that happened 65 times, 7.5% of the
bill, at a median context of 525k, and 58 of them came with the user's next
prompt. One of 530k cost 7 points of the 5-hour window on 2026-09-23.
Starting over costs too: the new session writes its ~45k prefix and spends
~331k units finding its way (the mean over those 30 days), ~421k units in all,
input being 1 and a cache write 2. Under ~210k of context, going on is the
cheaper of the two. A point of the window is no fixed number of units — 175k
that day, 63-77k since — so the hook gives going on as a multiple of starting
over, not in points.

So the `cold-return` hook reads when the last main-thread call was made (the
transcript's timestamp; a message Claude Code wrote itself, such as an API
error, made no call) and stops, once, a prompt that arrives `CTX_COLD_MINUTES`
(60) or more after it on a context of `CTX_COLD_TOKENS` or more (250000, the
Stop hook's threshold, is the value to turn it on with). No call is made;
Claude Code shows the reason, with what going on costs against starting over,
and the prompt under it:

```text
ctx: idle 1h12m, and the prompt cache has expired: this prompt would first write all 344k tokens of context back to the cache, at twice the input price.
Before any work, going on here costs ~1.6 times what starting over does (the new session's prime and first reads).
The handoff written 4k tokens ago holds this session: /clear starts the next one from it, no /handoff needed (it costs this same rewrite).
Sent again, the prompt goes through.
```

With a stale handoff, or none, the third line says so, and that `/handoff`
first costs this same rewrite. Each stop is keyed to the last call it followed
(`$CTX_STATE/cold/<session>`), so the prompt sent again goes through and the
next pause after more work can stop again. A slash command always goes
through, and so does any prompt while background work or a scheduled wakeup
would resume the session: the hook's input does not say who sent the prompt,
and one a cron or a `/loop` sent has nobody to send it again. The Stop hook,
whose input lists them, keeps the mark (`$CTX_STATE/cold/<session>.scheduled`).
Each stop, each prompt sent again after one, and each let through for a
schedule is logged to `$CTX_STATE/handoff.jsonl` (`cold-stop`, `cold-pass`,
`cold-scheduled`): how often a stop ends in a `/clear` is the count that says
whether the hook pays. The log alone does not give it: a `/handoff` after the
stop pays the rewrite, and the prompt sent after that passes as any other,
with no `cold-pass`. Both stops of the first four days ended that way, which
only the transcripts showed (ekko task 540).

It is off by default since 0.9.0 (`CTX_COLD_TOKENS` 0, ekko task 929). The
Stop hook and auto-reset (_A session left alone_) now take the same gain
before the cache goes cold: in the 1.5 days after 0.8.0 there were 0 rewrites
of 100k or more after an hour idle, against 7 in the 3.1 days before, while
the returns after an hour kept coming, to sessions of 34-81k. Where the guard
did stop a prompt, it saved nothing. What would bring it back is those
rewrites coming back, from a session auto-reset cannot reach, such as one in
the background: `CTX_COLD_TOKENS=250000` turns it on. Since 0.10.0 the Stop
hook no longer asks a user who is there for the handoff (_The handoff_), which
may bring some back; ekko task 941's recount keeps the two periods apart.

In a folder without an ekko board, the ask only tells the user. ekko needs
nothing new for this: the handoff is an ekko note of kind `handoff`, which the
next session's prime shows first.

### A session left alone

A session left to run on its own — watching a long job overnight, say — used
to stall at the handoff, or go on paying for an ever larger context, until
someone typed `/clear` and `continuando`. Now the same ritual runs without
them, with no switch to remember: the session tells by itself whether the user
is there.

- **Away** means nothing typed for `CTX_AUTO_RESET_IDLE` minutes (10) since
  the first turn after the user's last prompt ended, read off the transcript:
  a prompt the user typed carries `origin.kind` `human`, while a background
  task's notification and a resume after a usage limit do not, though both
  fire `UserPromptSubmit` like a typed prompt. A transcript that carries no
  `origin` at all never reads as away.
- A turn the user watches is no time away, however long it runs. Counted from
  the prompt, a 10-minute turn once made the user away at its end, while they
  were writing the next prompt, and `/clear` was typed into it (ekko task
  967). A turn's end is the `turn_duration` row Claude Code writes once the
  turn is over; a stop a hook continues writes none. On 2026-09-29, over 171
  transcripts of Claude Code 2.1.280–2.1.284, 531 of the 594 stops ctx did not
  continue were followed by one; 61 ended a headless session, 2 ran straight
  into a queued prompt, and none of the 35 stops ctx continued was. A Claude
  Code that writes none never reads as away.
- Away, past the threshold, the Stop hook asks for the handoff even with
  background shells running, and has Claude name each in it with its output
  file: a `/clear` does not stop them, and their notifications reach the fresh
  session.
- Once a fresh handoff is written, the Stop hook starts `bin/auto-reset`,
  detached. It waits for the turn to end, types `/clear`, waits for the fresh
  session's transcript, then types `CTX_AUTO_RESET_PROMPT` (`continuando`),
  logging `auto-reset` or `auto-reset-stop` with the reason to
  `$CTX_STATE/handoff.jsonl`.

It types only into Konsole, through the D-Bus object Konsole exports into each
tab's shell (`KONSOLE_DBUS_SERVICE`, `KONSOLE_DBUS_SESSION`), which Claude Code
and its hooks inherit. Konsole 26.08 refuses typed input over D-Bus unless
**Configure Konsole › General › Enable the security sensitive parts of the
DBus API** is on (`[KonsoleWindow] EnableSecuritySensitiveDBusAPI=true` in
`konsolerc`), and with it on, any process of the user can type into any tab.
An empty `sendText` tells which, typing nothing. Elsewhere — another
terminal, tmux, `claude -p` (`CLAUDE_CODE_ENTRYPOINT` other than `cli`) — a
session is never alone: nothing is asked and nothing is typed, as with the
user there. So it is while a scheduled wakeup, a monitor or a subagent is
pending: none was tried across a `/clear`.

Before each keystroke, `bin/auto-reset` checks that the tab's foreground
process is this session's Claude Code, that the user has typed nothing since
it started, and that the screen (`getAllDisplayedText`) shows the session
idle, with no dialog: a permission dialog opens with `1. Yes` selected, so an
Enter typed into one would approve the call. What was measured on 2026-09-26
(Claude Code 2.1.283) shaped the rest:

- At a turn's end, Claude Code may show a prompt suggestion in the input box,
  on by default (`promptSuggestionEnabled`), and on screen it reads exactly
  like text the user typed. Typing tells them apart: it replaces a
  suggestion, and adds to the user's text. So the box may hold any text that
  stays the same for two readings in a row; once typed into, it must hold
  exactly what was typed, or what was typed is taken back, a backspace a
  character, when nothing else changed there, and the reset stops. The box is
  read again before each backspace, so a key or an Enter of the user's ends
  the take-back where it stands, and the log says so. On 2026-09-29 the user
  pressed Enter one backspace in: the prompt went out ending in `/clea`, five
  more backspaces followed, and the log said `taken back`. A draft the user
  leaves in the box for 10 minutes after a turn has ended still looks like a
  suggestion, and is still typed into.
- A long text sent with its Enter in one `sendText` is taken as a paste, and
  the Enter becomes a newline, so each Enter goes alone, half a second later.

A prompt typed this way is recorded as the user's own, so the rows ctx
typed are listed in `$CTX_STATE/auto/<session>.typed` and passed over when
presence is read. The 5-hour trigger never resets: a reset spends the window,
it does not spare it. And past the cap on the window, the reset types the
`/clear` and not `continuando`: the fresh session costs nothing while it
waits for the user, whose reserve the rest of the window is.

## The 5-hour cap

The user, 2026-09-26: tell the model where the 5-hour limit stands, cap it at
85%, and keep the last 15% for emergencies or anything else. The cap is
`CTX_HANDOFF_5H` (85; 0 turns it off), also where the status line flags the
handoff (`5h 87% ⚑ handoff`): past it, a session starts nothing new, and the
rest of the window is the user's. Nothing tells the model to write a handoff
by itself: that is the user's `/handoff`, and the Stop hook's ask to a session
left alone (_The handoff_).

**The reading.** Only the status line is handed the rate limits; no hook's
input carries them (Claude Code 2.1.283). So `ctx-statusline` leaves one
reading per account in `$CTX_STATE/window/<account>`, named after the
profile's folder (`CLAUDE_CONFIG_DIR`, `~/.claude` by default): the 5-hour
percentage, when that window ends, and the 7-day percentage. Every session of
the account writes the same file, each with the numbers its own process last
heard from the API, and an idle session's status line, refreshed every 30
seconds, repeats an old one. Usage never falls within a window, so the readings
of one window keep the highest, a later window replaces them, and one of an
earlier window is dropped. A reading at the cap stands until its window ends,
however old it is, and a window that has ended reads as none.

**What the model is told.** One line as a session starts and with every
prompt — `ctx: 5h 62% until 21:40, cap 85% · 7d 48%.` — and, mid-turn, once,
when the window crosses 70% (pace the work; start nothing long) or the cap. A
turn left alone can run for hours between two prompts.

**What the cap holds back.** Past the cap:

- `guard-window` refuses a subagent (`Agent`, or `Task` as it was named
  before), a new schedule (`CronCreate`, `ScheduleWakeup`) and a Bash call that
  runs `claude -p` or `--print`, wherever the command runs it. Each refusal can
  be lifted for one call through ekko (see _An exception, through ekko_). A
  script that starts `claude` by itself is not seen.
- `window` holds a scheduled prompt: a `/loop` wakeup or a cron's fire, told
  apart by the `source` of `UserPromptSubmit`'s input (`loop_wakeup`,
  `schedule_wakeup`). A recurring schedule fires again after the window
  resets. A prompt without a `source` counts as the user's, since Claude Code
  says payloads may omit it while the field rolls out.
- `bin/auto-reset` types the `/clear` and not `continuando`.

The user's own prompt goes through, with the reading and what the cap asks:
the reserve is theirs to spend. The week has no cap; its percentage is in the
line.

## The work-loss guard

With `bypassPermissions` on, no classifier stands between Claude and a
`git reset --hard`. A replay of this machine's 30,334 tool calls from
2026-08-04 to 2026-09-26 found 93 git calls of the kinds that can lose work
(`reset --hard`, `checkout --`, `branch -D`, `worktree remove --force`,
`stash drop`) and 247 `rm -r`: most of them routine, on scratch repositories or
on work already committed. A rule keyed on the command's name would stop all of
them. `guard-work-loss` is keyed on state instead: it follows `cd`, `pushd`,
`git -C` and variables through the command, reads each repository, and denies
a call only when it would destroy something with no other copy, naming it and
how to keep it.

| Call                                                                | Refused when it would destroy                          |
| ------------------------------------------------------------------- | ------------------------------------------------------ |
| `reset --hard`, `checkout -f`, `switch --discard-changes`           | uncommitted changes to tracked files                   |
| `checkout [<rev>] -- <paths>`, `checkout .`, `restore`, `git rm -f` | changes under those paths (`restore --staged` passes)  |
| `clean -f`                                                          | what `git clean -n` with the same flags lists          |
| `stash drop`, `stash clear`                                         | a stash whose changes are not already in the work tree |
| `branch -D`                                                         | commits with no copy on another branch, tag or remote  |
| `worktree remove --force`                                           | that worktree's changes, untracked files included      |
| a forced push, or a delete, to the remote's default branch          | commits on the remote the push would drop              |
| `rm -r` inside a repository                                         | untracked or modified files under the path             |
| `rm -r` of a repository, its `.git`, or a folder holding one        | changes, stashes, and commits with no copy on a remote |

A copy counts: a commit rebased or cherry-picked onto another branch has a new
id but the same patch, and `git cherry` finds it (ekko task 891). So `branch -D`
and `rm -r` of a repository pass when every commit they would take has its
patch on a ref that stays; a merge, which has no patch of its own, never does.
A forced push to the default branch is refused all the same: it rewrites the
history others fetch.

A `git stash` or `git commit` earlier in the same command counts as keeping
the work, so the fix the reason suggests, run as one command, passes. Not
guarded: the scratch roots (`CTX_GUARD_SCRATCH`), `rm -r` outside any
repository, where no state says whether a copy exists, and whatever a script
the command runs does, which the hook never sees. The threat is an accident,
not a hijacked agent: a hook sees only the literal call. Any error in the guard
lets the call through. Every call it examines, refused or not, goes to
`$CTX_STATE/guard.jsonl`.

## The secrets guard

`guard-secrets` refuses a call that would print a secret into the context.
A file is secret by where it is and what it holds, not by the command that
names it:

- anything under the secret roots (`CTX_SECRET_ROOTS`: `/persist/secrets`,
  `/run/secrets` and `/run/secrets.d`);
- an age key (`age-combined-identity.txt`, `sops/age/keys.txt`,
  `$SOPS_AGE_KEY_FILE`), and a private key under `~/.ssh`, told by its first
  line;
- Claude Code's `~/.claude*/.credentials.json`, gh's `hosts.yml`, git's stored
  credentials and `~/.netrc`;
- a `.env` or `.env.*` git does not track, bar the templates (`.example`,
  `.sample`, `.template`, `.dist`).

It refuses a `Read` of one, a `Grep` that shows its lines, and a Bash call that
prints what it reads (`cat`, `grep`, `jq`, `sed`, `head` and 45 more) naming
one, fed one by `<`, or searching a folder that holds one. It also refuses the
commands that print a secret of their own: `gh auth token`,
`gh auth status --show-token`, `sops -d`, `age -d`, `gpg -d`,
`secret-tool lookup`, `kwallet-query -r`, `pass show` and
`git credential fill`. Unless the output goes to a file or into `$(...)`, so
`NIX_CONFIG="access-tokens = github.com=$(gh auth token)" nix flake update`
passes. A pipe counts as shown unless the pipeline ends in a file. Metadata
passes: `ls`, `stat`, `test -e`, `wc`, and `grep -c`, `-l` or `-q`.

A grep-like search prints only what it matches, so the guard runs the call's
own pattern on the secret file, with the output kept out of the context, and
refuses only if it would print something: from a `.env`, a value, not just
names (`grep -oE '^[A-Z_]+='` passes). Replayed over this machine's 21,842
Bash and 1,633 Read calls from 2026-08-04 to 2026-09-27 (UTC), against the
disk as it is now, it refuses 6: three would have printed a database URI or a
password from a `.env`, three a flag's value from a `.env.local`. The first
draft refused 20: five were a lexer defect that lost a search's path, and nine
searches that match no value in those files.

Not guarded: what a sourced `.env` puts in the environment and a later call
prints, a script the command runs, and a copy made in one call and read in
another. Any error in the guard lets the call through. Each refusal, and each
call that named a secret but sent it elsewhere, goes to
`$CTX_STATE/guard.jsonl`.

## An exception, through ekko

A refusal stands unless the user lifts it, for one call. Before any of the
three guards refuses, it runs `ekko --guard --refuse <reason>` with the call's `PreToolUse`
event on stdin, when [ekko](https://github.com/thiagoproldan/ekko) 0.25 or
later is on `PATH`:

- ekko exits 0 when the user's answer in ekko's menu let this exact call
  through: from the same folder and session, once, within 24 hours. The call
  passes, logged as `guard-excepted`, `secret-excepted` or `window-excepted`.
- ekko exits 1 after recording the refusal under a short code, and prints the
  sentence the reason ends with: how the session asks the user, through ekko's
  `ask` with that code. The menu shows the call as ekko recorded it, not as the
  session describes it.
- Anything else, or no ekko, and the refusal stands as it was.

Only the user's answer in ekko's menu counts; one a session records does not.
ekko's own guard, a gotcha whose command cue the user turned on, refuses the
same way, and one answer lets a call through both.

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
| `CTX_STATE`             | `~/.local/state/ctx`      | Where the ledgers, window readings and worker home live            |
| `CTX_WORKER_HOME`       | `$CTX_STATE/worker-home`  | The worker's own home, holding its `agy` login                     |
| `GRAPHIFY_OUT`          | `graphify-out`            | Read, never set here — honours graphify's own                      |
| `CTX_HANDOFF_TOKENS`    | `250000`                  | Status line and Stop hook: context that warrants a handoff (0 off) |
| `CTX_HANDOFF_5H`        | `85`                      | The cap on the 5-hour window: no new work past it (0 off)          |
| `CTX_CACHE_WARN_MIN`    | `5`                       | Status line: minutes left before cache is cold                     |
| `CTX_COLD_TOKENS`       | `0`                       | Cold-return hook: context worth stopping a prompt for (0 off)      |
| `CTX_COLD_MINUTES`      | `60`                      | Cold-return hook: idle minutes that make the cache cold (0 off)    |
| `CTX_AUTO_RESET_IDLE`   | `10`                      | Stop hook: idle minutes that make the user away (0 off)            |
| `CTX_AUTO_RESET_PROMPT` | `continuando`             | Auto reset: what it types into the fresh session                   |
| `CTX_AUTO_RESET_WAIT`   | `300`                     | Auto reset: seconds each wait lasts before it gives up             |
| `CTX_GUARD_SCRATCH`     | `/tmp:/var/tmp:…`         | Work-loss guard: colon-separated roots it never guards             |
| `CTX_SECRET_ROOTS`      | `/persist/secrets:…`      | Secrets guard: colon-separated roots whose every file is secret    |

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
