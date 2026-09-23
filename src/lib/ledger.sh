#!/usr/bin/env bash
# Funnel ledger. One JSON line per event, append-only.
#
# Two separate books on purpose:
#   usage.jsonl  — what each delegation cost, written by transport.sh
#   funnel.jsonl — what Claude DID, written by the hooks
#
# Only the funnel answers "of N blocks, how many turned into a graph query, a
# targeted re-read, a delegation, or nothing". "Nothing" is the one number that
# exposes a hook being ignored, and no usage counter on its own can see it.

CTX_STATE="${CTX_STATE:-${XDG_STATE_HOME:-$HOME/.local/state}/ctx}"
CTX_FUNNEL="${CTX_FUNNEL:-$CTX_STATE/funnel.jsonl}"

# ctx_log <ev> <sid> [key value]...
ctx_log() {
  local ev="$1" sid="$2"
  shift 2
  local args=(-c -n --arg ev "$ev" --arg sid "$sid")
  local filter='{ts: (now|todate), ev: $ev, sid: $sid'
  while [ $# -ge 2 ]; do
    args+=(--arg "k_$1" "$2")
    filter="$filter, $1: \$k_$1"
    shift 2
  done
  filter="$filter}"
  # A failed write must never take a hook down: the worst case is a lost
  # measurement, not a stuck session.
  mkdir -p "$(dirname "$CTX_FUNNEL")" 2>/dev/null
  jq "${args[@]}" "$filter" >>"$CTX_FUNNEL" 2>/dev/null || true
}
