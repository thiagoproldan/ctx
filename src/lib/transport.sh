#!/usr/bin/env bash
# ctx transport: hand one chat turn to a cheap model that is not Claude.
#
# Spotify's plugin talks to AiKA through portal-cli (Gemini Flash). Here the
# worker is Google's Antigravity CLI (`agy`) on the user's Gemini subscription,
# so a delegated read spends Gemini quota instead of Claude quota — which is
# where the article's saving actually comes from. (The first port used
# `claude -p --model haiku`: cheaper per token, but the same Claude quota, plus
# ~15k tokens of Claude Code system prompt on every call.)
#
# Two properties of agy shape everything below:
#
#   1. The payload cannot go through argv. MAX_ARG_STRLEN caps one argument at
#      128 KB and `-p` does not read stdin, so the turn is sent as one NDJSON
#      event with `--input-format stream-json`, which does.
#
#   2. agy is an AGENT. In print mode it runs with permission_mode
#      "always-proceed": run_command, write_to_file and web tools, all
#      auto-approved, and there is no flag to turn tools off. `--mode plan`
#      does not stop them (measured: a plain request made it `touch` a file and
#      write another one). The worker reads untrusted content — logs, dumps,
#      someone else's code — so a prompt injection in a file would be a shell on
#      this machine. The worker therefore runs inside bubblewrap:
#        - no $HOME, no /projects, no /run/secrets: only /nix, /etc and the
#          few /run entries DNS needs are visible;
#        - no D-Bus at all, so no keyring and no systemd --user (the session bus
#          would let it start a process OUTSIDE the sandbox);
#        - its home is the worker's OWN home, $CTX_WORKER_HOME, mounted as an
#          ephemeral overlay: nothing it writes survives the call — conversation
#          history, config, an MCP server an injection might try to add.
#
#      The worker home exists because agy keeps the user's login in the
#      keyring, and exposing the Secret Service to the sandbox would hand an
#      injected worker every other secret in it too. agy falls back to a token
#      file when there is no session bus (its changelog: "bypasses the keyring
#      when no D-Bus session bus is present"), so `ctx-login` runs agy once,
#      interactively, inside the same walls but with that home writable. The
#      only secret the worker can then reach is its own Gemini token.
#      What remains reachable: that token and the network the model API needs.

CTX_STATE="${CTX_STATE:-${XDG_STATE_HOME:-$HOME/.local/state}/ctx}"
CTX_MODEL="${CTX_MODEL:-gemini-3.8-flash-medium}"
CTX_TIMEOUT_SECONDS="${CTX_TIMEOUT_SECONDS:-300}"
# The model has a 1M-token window, but agy cuts a message at 192,000 bytes,
# whatever they hold: measured 2026-10-09 on agy 1.2.16 with numbered lines of
# code (~2.1 bytes a token), of hex (~1) and of accented text (148,279
# characters), each cut within a line of byte 192,000 -- 48,000 tokens at the
# 4 bytes a token agy's ByteApproximationTokenCounter counts. Past it the end
# of the message never arrives, and the end is where bulk-read's question is:
# 5 of 5 calls past ~190 KB on 2026-10-07 answered without it. So the cap is
# on what agy is sent, instructions included, under that edge.
CTX_MAX_PAYLOAD_BYTES="${CTX_MAX_PAYLOAD_BYTES:-190000}"
CTX_LEDGER="${CTX_LEDGER:-$CTX_STATE/usage.jsonl}"
CTX_WORKER_HOME="${CTX_WORKER_HOME:-$CTX_STATE/worker-home}"

CTX_TMPFILES=()
trap 'rm -rf "${CTX_TMPFILES[@]}"' EXIT

ctx_tmpfile() {
  local f
  f=$(mktemp) || return 1
  CTX_TMPFILES+=("$f")
  printf -v "$1" '%s' "$f"
}

ctx_preflight() {
  local missing="" c
  for c in jq agy bwrap; do
    command -v "$c" >/dev/null 2>&1 || missing="$missing $c"
  done
  if [ -n "$missing" ]; then
    echo "Error: missing command(s):$missing" >&2
    return 1
  fi
  if [ ! -d "$CTX_WORKER_HOME/.gemini" ]; then
    echo "Error: the worker has no login yet ($CTX_WORKER_HOME)." >&2
    echo 'Run `ctx-login` once, in a terminal, to sign agy in for the sandboxed worker.' >&2
    return 1
  fi
}

# ctx_sandbox [--login] <cmd> [args]... — run a command with the worker's view
# of the system. --login mounts the worker home writable and keeps the terminal
# (no new session, no timeout), for the one interactive sign-in.
ctx_sandbox() {
  local login=0
  if [ "${1:-}" = "--login" ]; then
    login=1
    shift
  fi
  local home="$HOME"
  local args=(
    --die-with-parent
    --unshare-pid --unshare-ipc --unshare-uts
    --ro-bind /nix /nix
    --ro-bind /etc /etc
    --ro-bind-try /bin /bin
    --ro-bind-try /usr /usr
    --proc /proc --dev /dev
    --tmpfs /tmp --tmpfs /run
    --ro-bind /run/current-system /run/current-system
    --ro-bind-try /run/systemd/resolve /run/systemd/resolve
    --ro-bind-try /run/nscd /run/nscd
    --tmpfs /home --tmpfs /root
    --setenv HOME "$home"
    --dir /tmp/run --setenv XDG_RUNTIME_DIR /tmp/run
    --unsetenv DBUS_SESSION_BUS_ADDRESS
    --dir /tmp/work --chdir /tmp/work
  )

  if [ "$login" -eq 1 ]; then
    args+=(--bind "$CTX_WORKER_HOME" "$home")
    bwrap "${args[@]}" "$@"
    return
  fi

  # --new-session: the worker cannot push keystrokes into the caller's
  # terminal (TIOCSTI). Interactive login needs that terminal, so only here.
  args+=(--new-session --overlay-src "$CTX_WORKER_HOME" --tmp-overlay "$home")
  # CTX_DISABLE is inherited by anything the worker spawns that might load
  # these hooks; cheap insurance against recursion.
  CTX_DISABLE=1 timeout "$CTX_TIMEOUT_SECONDS" bwrap "${args[@]}" "$@"
}

# ctx_invoke <label> <instructions> <message-file>
# Writes the answer to stdout; accounting goes to stderr and the ledger.
#
# agy has no system-prompt flag, so the instructions travel at the top of the
# user turn. That also carries the "no tools" rule — a request, not a
# guarantee; the guarantee is the sandbox.
#
# The message ends with a mark the worker cannot guess, and the reply must
# start with it: a worker that never saw the end -- cut by agy, wherever its
# edge moves -- cannot. On 2026-10-09 the reply started with the mark in 9 of
# 9 whole messages (5-108 KB: seven probes, a bulk-read, a code-write), and
# not in a bulk-read of 290 KB, cut; three probes cut at 192 KB said they saw
# no end. Counting the worker's input tokens could not tell: a cut that drops
# only the last line, the question, moves them by less than the content does.
ctx_invoke() {
  local label="$1" instructions="$2" message_file="$3"
  local bytes sent content_file event_file out_file err_file result rc text started mark seen

  ctx_tmpfile content_file || return 1
  ctx_tmpfile event_file || return 1
  ctx_tmpfile out_file || return 1
  ctx_tmpfile err_file || return 1

  mark="ctx-end-$(od -An -N4 -tx1 /dev/urandom | tr -d ' \n')"
  {
    printf '<instructions>\n%s\n%s\n</instructions>\n\n' "$instructions" \
      'The message ends with a line "END-OF-MESSAGE <mark>". Start your reply with that mark alone on its first line, then the rest; if the message has no such line, start with MISSING alone on the first line.'
    cat "$message_file"
    printf '\nEND-OF-MESSAGE %s\n' "$mark"
  } >"$content_file"

  bytes=$(wc -c <"$message_file" | tr -d ' ')
  sent=$(wc -c <"$content_file" | tr -d ' ')
  if [ "$sent" -gt "$CTX_MAX_PAYLOAD_BYTES" ]; then
    echo "Error: $label would send the worker $sent bytes, past the $CTX_MAX_PAYLOAD_BYTES cap: agy cuts a message at 192,000 bytes, and its end, where the question is, would never arrive." >&2
    echo "Split it: fewer or smaller files per call, then put the answers together." >&2
    return 1
  fi

  jq -Rsc '{event: "user", message: {role: "user", content: .}}' <"$content_file" >"$event_file"

  started=$(date +%s%3N)
  ctx_sandbox "$(command -v agy)" \
    --input-format stream-json \
    --output-format stream-json \
    --model "$CTX_MODEL" \
    --disable-slash-commands \
    <"$event_file" >"$out_file" 2>"$err_file"
  rc=$?

  if [ "$rc" -eq 124 ]; then
    echo "Error: $label exceeded ${CTX_TIMEOUT_SECONDS}s. Raise CTX_TIMEOUT_SECONDS or split the call." >&2
    return 1
  fi

  result=$(jq -c 'select(.event == "result") | .result' "$out_file" 2>/dev/null | tail -n 1)
  if [ -z "$result" ]; then
    echo "Error: $label returned no result event (rc=$rc)." >&2
    sed 's/^/  /' "$err_file" | head -20 >&2
    return 1
  fi
  if [ "$(printf '%s' "$result" | jq -r '.status')" != "SUCCESS" ]; then
    local error
    error=$(printf '%s' "$result" | jq -r '.error // "no detail"')
    echo "Error: $label: $error" >&2
    case "$error" in
    *auth*) echo "The worker's login is missing or expired: run \`ctx-login --force\` in a terminal." >&2 ;;
    esac
    return 1
  fi

  text=$(printf '%s' "$result" | jq -r '.response // empty')
  if [ -z "$text" ]; then
    echo "Error: $label returned no text." >&2
    return 1
  fi
  # The mark, on the reply's first line that holds anything, is taken off.
  seen=false
  text=${text#"${text%%[![:space:]]*}"}
  if [[ ${text%%$'\n'*} == *"$mark"* ]]; then
    seen=true
    case "$text" in
    *$'\n'*) text=${text#*$'\n'} ;;
    *) text="" ;;
    esac
  fi

  # Ledger: the saving is only verifiable if every delegation records its cost.
  mkdir -p "$(dirname "$CTX_LEDGER")" 2>/dev/null
  printf '%s' "$result" | jq -c \
    --arg label "$label" --arg model "$CTX_MODEL" \
    --argjson payload_bytes "$bytes" --argjson sent_bytes "$sent" --argjson end_seen "$seen" \
    --argjson answer_bytes "${#text}" --argjson ms "$(($(date +%s%3N) - started))" \
    '{ts: now|todate, label: $label, worker: "agy", model: $model,
      payload_bytes: $payload_bytes, sent_bytes: $sent_bytes, end_seen: $end_seen,
      answer_bytes: $answer_bytes,
      worker_input: (.usage.input_tokens // 0),
      worker_cache_read: (.usage.cache_read_tokens // 0),
      worker_thinking: (.usage.thinking_tokens // 0),
      worker_output: (.usage.output_tokens // 0),
      ms: $ms}' >>"$CTX_LEDGER" 2>/dev/null || true

  if [ "$seen" != true ]; then
    echo "Error: $label: the worker's reply does not start with the mark that ends its message, so it did not see the end, where the question is. agy cut it, or the worker broke the rule: split the call, or retry it once." >&2
    return 1
  fi
  if [ -z "$text" ]; then
    echo "Error: $label returned no text." >&2
    return 1
  fi
  printf '%s\n' "$text"
}
