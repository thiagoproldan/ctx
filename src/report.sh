#!/usr/bin/env bash
# Report on three different questions:
#
#   1. Is Claude using this correctly?          -> funnel.jsonl
#   2. What did the delegations save and cost?  -> usage.jsonl
#   3. Where does session context actually go?  -> Claude Code transcripts
#
# The first needs correlation. Counting usage alone answers "it was used", never
# "it was used when it should have been" — the number that matters is the block
# that turned into nothing, and it only shows up by tying each block to what
# came after it, in the same session, before the next block.
#
# The third exists because (2) only sees what was delegated. "98% saved" over
# ten delegations says nothing about a week where 90% of the context came from
# small Bash outputs no hook can catch. Measuring the sessions is what tells you
# whether the shunt matters for how you work, and --since/--until let you
# compare a week before a change with a week after it.
#
# Usage: shunt-report [--since YYYY-MM-DD] [--until YYYY-MM-DD]
set -u
SHUNT_STATE="${SHUNT_STATE:-${XDG_STATE_HOME:-$HOME/.local/state}/shunt}"
FUNNEL="${SHUNT_FUNNEL:-$SHUNT_STATE/funnel.jsonl}"
LEDGER="${SHUNT_LEDGER:-$SHUNT_STATE/usage.jsonl}"
MIN_LINES="${SHUNT_MIN_LINES:-350}"

since=$(date -d '7 days ago' +%F)
until=$(date -d tomorrow +%F)
while [ $# -gt 0 ]; do
  case "$1" in
  --since)
    since="$2"
    shift 2
    ;;
  --until)
    until="$2"
    shift 2
    ;;
  *)
    echo "usage: shunt-report [--since YYYY-MM-DD] [--until YYYY-MM-DD]" >&2
    exit 1
    ;;
  esac
done

in_window() { jq -c --arg s "$since" --arg u "$until" 'select((.ts // "") >= $s and (.ts // "") < $u)' "$1" 2>/dev/null; }

echo "== window: $since .. $until"
echo

# One correlation rule, used by both funnel reports below: a block's outcome is
# the first relevant event of the SAME session between it and that session's
# next block on a DIFFERENT file. Without the window, one graph query would
# "resolve" every earlier block at once. Blocks on the same file do not close it:
# Claude denied a Read and then denied a `cat` of that same file is one attempt
# retried with another tool, and the delegation that follows answers both —
# closing at any block counted the first as ignored.
JQ_OUTCOMES='
  def outcomes:
    . as $ev
    | ($ev | to_entries) as $t
    | [ $t[] | select(.value.ev == "block") ]
    | map(
        .key as $i | .value as $b
        | ([ $t[] | select(.key > $i and .value.sid == $b.sid and .value.ev == "block"
                           and .value.path != $b.path) | .key ] | first) as $nb
        | (if $nb == null then ($ev | length) else $nb end) as $lim
        | ([ $t[]
             | select(.key > $i and .key < $lim and .value.sid == $b.sid)
             | select(.value.ev == "graph"
                      or ((.value.ev == "reread" or .value.ev == "bulk")
                          and .value.path == $b.path))
             | .value.ev ] | first) as $r
        | { path: $b.path, lines: $b.lines, tool: ($b.tool // "Read"), outcome: ($r // "nothing") }
      );
'

echo "== 1. funnel: what Claude did after each block"
funnel=$([ -s "$FUNNEL" ] && in_window "$FUNNEL")
if [ -n "$funnel" ]; then
  printf '%s\n' "$funnel" | jq -rs "$JQ_OUTCOMES"'
    . as $ev
    | (outcomes) as $o
    | ($o | group_by(.outcome) | map({(.[0].outcome): length}) | add // {}) as $c
    | ($o | group_by(.tool) | map("\(.[0].tool) \(length)") | join(", ")) as $bytool
    | ([ $ev[] | select(.ev == "graph") ] | length) as $nq
    | ([ $o[] | (.lines | tonumber? // 0) ]) as $l
    | ($c.nothing // 0) as $nothing
    | "blocks: \($o | length)  (\($bytool))",
      "  -> graph queried     : \($c.graph  // 0)",
      "  -> targeted re-read  : \($c.reread // 0)",
      "  -> bulk-read         : \($c.bulk   // 0)",
      "  -> NOTHING (ignored) : \($nothing)\(if $nothing > 0 then "   <- look here" else "" end)",
      "",
      "graph queries: \($nq)  (deterministic, free)",
      (if ($l | length) > 0 and ($l | add) > 0
       then "lines kept out: \($l | add) in total, largest \($l | max)"
       else empty end)
  '
  # Naming the file is what makes the number actionable: if it is always the
  # same one, the threshold is wrong, not Claude.
  printf '%s\n' "$funnel" | jq -rs "$JQ_OUTCOMES"'
    outcomes | map(select(.outcome == "nothing") | .path)
    | if length > 0 then
        "", "ignored blocks, by file:",
        (group_by(.) | sort_by(-length) | .[0:5][] | "  \(length)x  \(.[0])")
      else empty end
  '
else
  echo "no funnel events in this window ($FUNNEL)"
fi

echo
echo "== 2. delegations"
ledger=$([ -s "$LEDGER" ] && in_window "$LEDGER")
if [ -n "$ledger" ]; then
  printf '%s\n' "$ledger" | jq -rs '
    def fmt: tostring | [splits("(?=(?:.{3})+$)")] | join(".") | sub("^\\.";"");
    map(select(.label == "bulk-read")) as $r
    | ($r | map(.payload_bytes) | add // 0 | . / 4 | floor) as $in
    | ($r | map(.answer_bytes)  | add // 0 | . / 4 | floor) as $out
    | "delegations: \(length)  (bulk-read \($r | length), code-write \(map(select(.label == "code-write")) | length))",
      "  input kept out of your context : ~\($in | fmt) tokens",
      "  answer that came in            : ~\($out | fmt) tokens",
      (if $in > 0 then "  reduction                      : \((100 - ($out * 100 / $in)) | floor)%" else empty end),
      "",
      "  by worker (what the delegations cost, on whose quota):",
      (group_by((.worker // "claude") + "/" + .model)[]
       | . as $g
       | ($g | map((.worker_input // 0) + (.worker_cache_create // 0) + (.worker_cache_read // 0)
                   + (.worker_output // 0) + (.worker_thinking // 0)) | add) as $tok
       | ($g[0].worker // "claude") as $w
       | "    \($w)/\($g[0].model): \($g | length) calls, ~\($tok | fmt) worker tokens"
         + (if $w == "claude" then " — CLAUDE quota" else " — Gemini quota, not Claude" end)
         + (if ($g | map(.cost_usd // 0) | add) > 0
            then ", US$ \($g | map(.cost_usd // 0) | add * 1000 | round / 1000)" else "" end))
  '
else
  echo "no delegations in this window ($LEDGER)"
fi

echo
echo "== 3. sessions: where the context came from"
# Every Claude Code profile (see usr.claude-code): ~/.claude, ~/.claude-*.
mapfile -t transcripts < <(find "$HOME"/.claude "$HOME"/.claude-* -path '*/projects/*' -name '*.jsonl' \
  -newermt "$since" 2>/dev/null)
if [ "${#transcripts[@]}" -eq 0 ]; then
  echo "no transcripts modified since $since"
  exit 0
fi
# Per file, emit {u: tool_use id, n: name} and {r: tool_use id, b: bytes, l: lines};
# then join them. Content counts as what reached the model: a persisted-output
# preview counts as its preview, which is right — the rest never came in.
cat "${transcripts[@]}" 2>/dev/null | jq -c --arg s "$since" --arg u "$until" '
  select((.timestamp // "") >= $s and (.timestamp // "") < $u)
  | .sessionId as $sid
  | .message.content? | arrays | .[]
  | if .type == "tool_use" then {u: .id, n: .name, sid: $sid}
    elif .type == "tool_result" then
      ((.content | if type == "string" then . else (map(.text? // "") | join("")) end) as $t
       | {r: .tool_use_id, b: ($t | length), l: ($t | split("\n") | length), sid: $sid})
    else empty end' 2>/dev/null |
  jq -rs --argjson min "$MIN_LINES" '
    def fmt: tostring | [splits("(?=(?:.{3})+$)")] | join(".") | sub("^\\.";"");
    (map(select(.u)) | map({(.u): .n}) | add // {}) as $names
    | map(select(.r) | . + {n: ($names[.r] // "?")}) as $res
    | ($res | map(.b) | add // 0) as $all
    | ($res | map(select(.l > $min))) as $big
    | "\($res | map(.sid) | unique | length) sessions, \($res | length) tool results, ~\($all / 4 | floor | fmt) tokens of tool output",
      "",
      "  tool                               calls     ~tokens   share",
      ($res | group_by(.n) | map({n: .[0].n, c: length, b: (map(.b) | add)})
       | sort_by(-.b) | .[0:10][]
       | "  \(.n | .[0:32] | . + (" " * (33 - length)))\(.c | tostring | (" " * (7 - length)) + .)  \(.b / 4 | floor | fmt | (" " * (10 - length)) + .)   \(if $all > 0 then (.b * 100 / $all | floor) else 0 end)%"),
      "",
      "  results over \($min) lines (what a hook could still catch): \($big | length) calls, ~\($big | map(.b) | add // 0 | . / 4 | floor | fmt) tokens = \(if $all > 0 then (($big | map(.b) | add // 0) * 100 / $all | floor) else 0 end)% of tool output",
      ($big | group_by(.n) | map("    \(.[0].n): \(length) calls, ~\(map(.b) | add / 4 | floor | fmt) tokens") | .[])
  '
