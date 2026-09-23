#!/usr/bin/env bash
# shunt transport: hand one chat turn to a cheap model that is not Claude.
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
#        - its home is the worker's OWN home, $SHUNT_WORKER_HOME, mounted as an
#          ephemeral overlay: nothing it writes survives the call — conversation
#          history, config, an MCP server an injection might try to add.
#
#      The worker home exists because agy keeps the user's login in the
#      keyring, and exposing the Secret Service to the sandbox would hand an
#      injected worker every other secret in it too. agy falls back to a token
#      file when there is no session bus (its changelog: "bypasses the keyring
#      when no D-Bus session bus is present"), so `shunt-login` runs agy once,
#      interactively, inside the same walls but with that home writable. The
#      only secret the worker can then reach is its own Gemini token.
#      What remains reachable: that token and the network the model API needs.

SHUNT_STATE="${SHUNT_STATE:-${XDG_STATE_HOME:-$HOME/.local/state}/shunt}"
SHUNT_MODEL="${SHUNT_MODEL:-gemini-3.8-flash-medium}"
SHUNT_TIMEOUT_SECONDS="${SHUNT_TIMEOUT_SECONDS:-300}"
# Gemini Flash has a 1M-token window; ~4 bytes/token leaves ample headroom.
SHUNT_MAX_PAYLOAD_BYTES="${SHUNT_MAX_PAYLOAD_BYTES:-2000000}"
SHUNT_LEDGER="${SHUNT_LEDGER:-$SHUNT_STATE/usage.jsonl}"
SHUNT_WORKER_HOME="${SHUNT_WORKER_HOME:-$SHUNT_STATE/worker-home}"

SHUNT_TMPFILES=()
trap 'rm -rf "${SHUNT_TMPFILES[@]}"' EXIT

shunt_tmpfile() {
  local f
  f=$(mktemp) || return 1
  SHUNT_TMPFILES+=("$f")
  printf -v "$1" '%s' "$f"
}

shunt_preflight() {
  local missing="" c
  for c in jq agy bwrap; do
    command -v "$c" >/dev/null 2>&1 || missing="$missing $c"
  done
  if [ -n "$missing" ]; then
    echo "Error: missing command(s):$missing" >&2
    return 1
  fi
  if [ ! -d "$SHUNT_WORKER_HOME/.gemini" ]; then
    echo "Error: the worker has no login yet ($SHUNT_WORKER_HOME)." >&2
    echo 'Run `shunt-login` once, in a terminal, to sign agy in for the sandboxed worker.' >&2
    return 1
  fi
}

# shunt_sandbox [--login] <cmd> [args]... — run a command with the worker's view
# of the system. --login mounts the worker home writable and keeps the terminal
# (no new session, no timeout), for the one interactive sign-in.
shunt_sandbox() {
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
    args+=(--bind "$SHUNT_WORKER_HOME" "$home")
    bwrap "${args[@]}" "$@"
    return
  fi

  # --new-session: the worker cannot push keystrokes into the caller's
  # terminal (TIOCSTI). Interactive login needs that terminal, so only here.
  args+=(--new-session --overlay-src "$SHUNT_WORKER_HOME" --tmp-overlay "$home")
  # SHUNT_DISABLE is inherited by anything the worker spawns that might load
  # these hooks; cheap insurance against recursion.
  SHUNT_DISABLE=1 timeout "$SHUNT_TIMEOUT_SECONDS" bwrap "${args[@]}" "$@"
}

# shunt_invoke <label> <instructions> <message-file>
# Writes the answer to stdout; accounting goes to stderr and the ledger.
#
# agy has no system-prompt flag, so the instructions travel at the top of the
# user turn. That also carries the "no tools" rule — a request, not a
# guarantee; the guarantee is the sandbox.
shunt_invoke() {
  local label="$1" instructions="$2" message_file="$3"
  local bytes event_file out_file err_file result rc text started

  bytes=$(wc -c <"$message_file" | tr -d ' ')
  if [ "$bytes" -gt "$SHUNT_MAX_PAYLOAD_BYTES" ]; then
    echo "Error: payload of $bytes bytes exceeds the $SHUNT_MAX_PAYLOAD_BYTES cap." >&2
    echo "Send fewer files, or raise SHUNT_MAX_PAYLOAD_BYTES if it fits the worker's context." >&2
    return 1
  fi

  shunt_tmpfile event_file || return 1
  shunt_tmpfile out_file || return 1
  shunt_tmpfile err_file || return 1

  {
    printf '<instructions>\n%s\n</instructions>\n\n' "$instructions"
    cat "$message_file"
  } |
    jq -Rsc '{event: "user", message: {role: "user", content: .}}' >"$event_file"

  started=$(date +%s%3N)
  shunt_sandbox "$(command -v agy)" \
    --input-format stream-json \
    --output-format stream-json \
    --model "$SHUNT_MODEL" \
    --disable-slash-commands \
    <"$event_file" >"$out_file" 2>"$err_file"
  rc=$?

  if [ "$rc" -eq 124 ]; then
    echo "Error: $label exceeded ${SHUNT_TIMEOUT_SECONDS}s. Raise SHUNT_TIMEOUT_SECONDS or split the call." >&2
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
    *auth*) echo "The worker's login is missing or expired: run \`shunt-login --force\` in a terminal." >&2 ;;
    esac
    return 1
  fi

  text=$(printf '%s' "$result" | jq -r '.response // empty')
  if [ -z "$text" ]; then
    echo "Error: $label returned no text." >&2
    return 1
  fi

  # Ledger: the saving is only verifiable if every delegation records its cost.
  mkdir -p "$(dirname "$SHUNT_LEDGER")" 2>/dev/null
  printf '%s' "$result" | jq -c \
    --arg label "$label" --arg model "$SHUNT_MODEL" \
    --argjson payload_bytes "$bytes" --argjson answer_bytes "${#text}" \
    --argjson ms "$(($(date +%s%3N) - started))" \
    '{ts: now|todate, label: $label, worker: "agy", model: $model,
      payload_bytes: $payload_bytes, answer_bytes: $answer_bytes,
      worker_input: (.usage.input_tokens // 0),
      worker_cache_read: (.usage.cache_read_tokens // 0),
      worker_thinking: (.usage.thinking_tokens // 0),
      worker_output: (.usage.output_tokens // 0),
      ms: $ms}' >>"$SHUNT_LEDGER" 2>/dev/null || true

  printf '%s\n' "$text"
}
