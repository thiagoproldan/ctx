#!/usr/bin/env bash
# The hooks' test suite. Every case states the verdict it expects; a hook that
# never denies (or denies everything) fails here instead of in production.
#
# Usage: ctx-test            hermetic: hooks only (also runs at build time)
#        ctx-test --live     plus the worker: sandbox walls and one real call
set -u
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOKS="$ROOT/hooks"
LIVE=0
[ "${1:-}" = "--live" ] && LIVE=1
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

# Ledger isolation. Without this the suite writes to the PRODUCTION funnel: the
# first real run dumped 32 fixture blocks into funnel.jsonl and the report began
# showing "32 ignored" — the instrument corrupting exactly what it measures.
# Exported, so it holds for every hook called here.
REAL_WORKER_HOME="${CTX_WORKER_HOME:-${CTX_STATE:-${XDG_STATE_HOME:-$HOME/.local/state}/ctx}/worker-home}"
export CTX_STATE="$TMP/state"
export CTX_FUNNEL="$TMP/funnel-suite.jsonl"
export CTX_LEDGER="$TMP/usage-suite.jsonl"

seq 1 900 | sed 's/^/line /' >"$TMP/big.ts"  # 900 lines
seq 1 40 | sed 's/^/line /' >"$TMP/small.ts" # 40 lines
cp "$TMP/big.ts" "$TMP/big.png"
mkdir -p "$TMP/dir" && cp "$TMP/big.ts" "$TMP/dir/inner.ts" && cp "$TMP/small.ts" "$TMP/dir/other.ts"

pass=0
fail=0

# An allowing hook writes nothing: empty stdout IS the allow. Normalising that is
# the one place the harness could lie, so it is explicit — empty becomes allow,
# broken JSON becomes PARSE-ERR (never allow by accident).
verdict() {
  local out="$1"
  [ -z "${out//[[:space:]]/}" ] && {
    echo allow
    return
  }
  printf '%s' "$out" | jq -er '.hookSpecificOutput.permissionDecision' 2>/dev/null || echo "PARSE-ERR"
}

# check <name> <expected: deny|allow> <hook> <input json>
check() {
  local name="$1" want="$2" hook="$3" json="$4" out got
  out=$(printf '%s' "$json" | env -u CTX_DISABLE CTX_MIN_LINES=500 "$HOOKS/$hook" 2>&1)
  got=$(verdict "$out")
  if [ "$got" = "$want" ]; then
    pass=$((pass + 1))
    printf '  ok    %-50s -> %s\n' "$name" "$got"
  else
    fail=$((fail + 1))
    printf '  FAIL  %-50s -> %s (expected %s)\n' "$name" "$got" "$want"
    [ -n "$out" ] && printf '        %s\n' "$(printf '%s' "$out" | head -3)"
  fi
}

read_json() { jq -nc --arg p "$1" '{tool_name:"Read",tool_input:{file_path:$p}}'; }
read_slice() { jq -nc --arg p "$1" '{tool_name:"Read",tool_input:{file_path:$p,offset:10,limit:20}}'; }
# The cwd field is what Claude Code sends; relative paths resolve against it.
bash_json() { jq -nc --arg c "$1" --arg d "$TMP" '{tool_name:"Bash",tool_input:{command:$c},cwd:$d}'; }

echo "check-file-size (threshold 500):"
check "900-line file" deny check-file-size "$(read_json "$TMP/big.ts")"
check "40-line file" allow check-file-size "$(read_json "$TMP/small.ts")"
check "900 lines with offset/limit" allow check-file-size "$(read_slice "$TMP/big.ts")"
check "missing file" allow check-file-size "$(read_json "$TMP/missing.ts")"
check "big binary (.png)" allow check-file-size "$(read_json "$TMP/big.png")"
check "tool_input without file_path" allow check-file-size '{"tool_name":"Read","tool_input":{}}'
out=$(printf '%s' "$(read_json "$TMP/big.ts")" | env -u CTX_DISABLE -u CTX_MIN_LINES "$HOOKS/check-file-size")
got=$(verdict "$out")
if [ "$got" = "deny" ]; then
  pass=$((pass + 1))
  printf '  ok    %-50s -> deny\n' "default threshold is 350, not 2000"
else
  fail=$((fail + 1))
  printf '  FAIL  %-50s -> %s (expected deny)\n' "default threshold is 350, not 2000" "$got"
fi

echo "check-bash-read (threshold 500) — bare commands:"
check "cat big" deny check-bash-read "$(bash_json "cat $TMP/big.ts")"
check "cat small" allow check-bash-read "$(bash_json "cat $TMP/small.ts")"
check "cat small big (2nd arg)" deny check-bash-read "$(bash_json "cat $TMP/small.ts $TMP/big.ts")"
check "cat big | grep x" allow check-bash-read "$(bash_json "cat $TMP/big.ts | grep line")"
check "cat big > file" allow check-bash-read "$(bash_json "cat $TMP/big.ts > $TMP/out.ts")"
check "cat big &> file" allow check-bash-read "$(bash_json "cat $TMP/big.ts &> $TMP/out.ts")"
check "head big (10 lines by default)" allow check-bash-read "$(bash_json "head $TMP/big.ts")"
check "head -50 big" allow check-bash-read "$(bash_json "head -50 $TMP/big.ts")"
check "head -n 800 big" deny check-bash-read "$(bash_json "head -n 800 $TMP/big.ts")"
check "tail -n 900 big" deny check-bash-read "$(bash_json "tail -n 900 $TMP/big.ts")"
check "tail -n +500 big (401 lines)" allow check-bash-read "$(bash_json "tail -n +500 $TMP/big.ts")"
check "tail -f big" allow check-bash-read "$(bash_json "tail -f $TMP/big.ts")"
check "less big" deny check-bash-read "$(bash_json "less $TMP/big.ts")"
check "cat of a missing file" allow check-bash-read "$(bash_json "cat $TMP/missing.ts")"
check "unrelated command (ls)" allow check-bash-read "$(bash_json "ls -la $TMP")"
check "wc -l big" allow check-bash-read "$(bash_json "wc -l $TMP/big.ts")"

echo "check-bash-read — what the first port let through:"
check "cd dir && cat relative" deny check-bash-read "$(bash_json "cd $TMP/dir && cat inner.ts")"
check "relative path against input cwd" deny check-bash-read "$(bash_json "cat big.ts")"
check "cat big 2>/dev/null" deny check-bash-read "$(bash_json "cat $TMP/big.ts 2>/dev/null")"
check 'for f in glob; do cat "$f"; done' deny check-bash-read "$(bash_json "for f in $TMP/dir/*.ts; do echo \"== \$f\"; cat \"\$f\"; done")"
check "for over small files only" allow check-bash-read "$(bash_json "for f in $TMP/small.ts $TMP/dir/other.ts; do cat \"\$f\"; done")"
check "13 small files add up (sum, not max)" deny check-bash-read "$(bash_json "cat $(printf "$TMP/small.ts %.0s" $(seq 13))")"
check "sed -n '1,900p' big" deny check-bash-read "$(bash_json "sed -n '1,900p' $TMP/big.ts")"
check "sed -n '1,20p' big" allow check-bash-read "$(bash_json "sed -n '1,20p' $TMP/big.ts")"
check "sed 's/a/b/' big (prints everything)" deny check-bash-read "$(bash_json "sed 's/a/b/' $TMP/big.ts")"
check "sed -i big (prints nothing)" allow check-bash-read "$(bash_json "sed -i 's/a/b/' $TMP/big.ts")"
check "cat big | head -n 800" deny check-bash-read "$(bash_json "cat $TMP/big.ts | head -n 800")"
check "cat big | head -50" allow check-bash-read "$(bash_json "cat $TMP/big.ts | head -50")"
check "sort big | uniq (passthrough)" deny check-bash-read "$(bash_json "sort $TMP/big.ts | uniq")"
check 'echo "$(cat big)" prints' deny check-bash-read "$(bash_json "echo \"\$(cat $TMP/big.ts)\"")"
check 'x=$(cat big) captures' allow check-bash-read "$(bash_json "x=\$(cat $TMP/big.ts)")"
check "sudo cat big" deny check-bash-read "$(bash_json "sudo cat $TMP/big.ts")"
check "(cd dir; cat relative) subshell" deny check-bash-read "$(bash_json "(cd $TMP/dir; cat inner.ts)")"
check "ls; tail -n 900 big (2nd statement)" deny check-bash-read "$(bash_json "ls; tail -n 900 $TMP/big.ts")"
check "heredoc cat" allow check-bash-read "$(bash_json "$(printf 'cat <<EOF\nhi\nEOF')")"
check "unparsable command" allow check-bash-read "$(bash_json "cat $TMP/big.ts ((( ")"

echo "recursion guard (CTX_DISABLE=1):"
for h in check-file-size check-bash-read; do
  in=$(read_json "$TMP/big.ts")
  [ "$h" = check-bash-read ] && in=$(bash_json "cat $TMP/big.ts")
  out=$(printf '%s' "$in" | CTX_DISABLE=1 CTX_MIN_LINES=500 "$HOOKS/$h" 2>&1)
  got=$(verdict "$out")
  if [ "$got" = "allow" ]; then
    pass=$((pass + 1))
    printf '  ok    %-50s -> allow\n' "$h disarmed"
  else
    fail=$((fail + 1))
    printf '  FAIL  %-50s -> %s (expected allow)\n' "$h disarmed" "$got"
  fi
done

# --- graphify hint --------------------------------------------------------------
# The detector is only worth having if it knows how to stay quiet. Each case
# below exists because the wrong silence (suggesting a missing command, pointing
# at another project's index) hurts more than no suggestion.

# reason <extra-PATH> <file> — the check-file-size denial text
reason() {
  local extra_path="$1" file="$2" p
  p="${extra_path:+$extra_path:}$PATH"
  [ "$extra_path" = "PURE" ] && p="$PUREBIN"
  printf '%s' "$(read_json "$file")" |
    env -u CTX_DISABLE PATH="$p" \
      CTX_MIN_LINES=500 "$HOOKS/check-file-size" 2>&1 |
    jq -r '.hookSpecificOutput.permissionDecisionReason // ""'
}
# has <name> <present|absent> <needle> <text>
has() {
  local name="$1" want="$2" needle="$3" text="$4" got
  case "$text" in *"$needle"*) got=present ;; *) got=absent ;; esac
  if [ "$got" = "$want" ]; then
    pass=$((pass + 1))
    printf '  ok    %-50s -> %s\n' "$name" "$got"
  else
    fail=$((fail + 1))
    printf '  FAIL  %-50s -> %s (expected %s)\n' "$name" "$got" "$want"
  fi
}

PROJ="$TMP/proj"
mkdir -p "$PROJ/graphify-out" "$PROJ/src/deep/deeper" "$TMP/no-index/src"
cp "$TMP/big.ts" "$PROJ/src/deep/deeper/big.ts"
cp "$TMP/big.ts" "$TMP/no-index/src/big.ts"
echo '{"nodes":[]}' >"$PROJ/graphify-out/graph.json"

# A fake `graphify`, for PATH only. Without it the detector must stay quiet even
# with an index present.
FAKEBIN="$TMP/bin"
mkdir -p "$FAKEBIN"
printf '#!/usr/bin/env bash\nexit 0\n' >"$FAKEBIN/graphify"
chmod +x "$FAKEBIN/graphify"

# Controlled PATH for the "no graphify" case: prepending an empty directory stops
# working once the real graphify is on the machine's PATH — the test would
# measure the machine, not the hook. PUREBIN has everything the hooks use except
# graphify.
PUREBIN="$TMP/purebin"
mkdir -p "$PUREBIN"
for c in jq find sed grep wc dirname basename sort head tr cat cut mktemp touch env bash python3 shfmt; do
  p=$(command -v "$c" 2>/dev/null) && ln -sf "$p" "$PUREBIN/$c"
done
command -v graphify >/dev/null 2>&1 && [ -e "$PUREBIN/graphify" ] && rm -f "$PUREBIN/graphify"

echo "graphify hint:"
has "no graphify on PATH, index present" absent "graphify query" "$(reason "PURE" "$PROJ/src/deep/deeper/big.ts")"
has "graphify present, no index" absent "graphify query" "$(reason "$FAKEBIN" "$TMP/no-index/src/big.ts")"
has "graphify and index (3 levels up)" present "graphify query" "$(reason "$FAKEBIN" "$PROJ/src/deep/deeper/big.ts")"
has "points at the right project's --graph" present "$PROJ/graphify-out/graph.json" "$(reason "$FAKEBIN" "$PROJ/src/deep/deeper/big.ts")"
has "bulk-read still offered alongside" present "ctx-bulk-read" "$(reason "$FAKEBIN" "$PROJ/src/deep/deeper/big.ts")"

# Freshness. Both ends are staged with touch: creation order above already made
# the index newer, and without forcing this the "stale" case would pass by never
# firing, not by working.
touch -d '2020-01-01' "$PROJ/graphify-out/graph.json"
has "stale index is flagged" present "index is older" "$(reason "$FAKEBIN" "$PROJ/src/deep/deeper/big.ts")"
touch "$PROJ/graphify-out/graph.json"
has "fresh index is not flagged" absent "index is older" "$(reason "$FAKEBIN" "$PROJ/src/deep/deeper/big.ts")"

# GRAPHIFY_OUT: relative name and absolute path.
mv "$PROJ/graphify-out" "$PROJ/graphify-out-feature"
has "no override, custom name not found" absent "graphify query" "$(reason "$FAKEBIN" "$PROJ/src/deep/deeper/big.ts")"
out=$(GRAPHIFY_OUT=graphify-out-feature reason "$FAKEBIN" "$PROJ/src/deep/deeper/big.ts")
has "relative GRAPHIFY_OUT honoured" present "graphify-out-feature/graph.json" "$out"
out=$(GRAPHIFY_OUT="$PROJ/graphify-out-feature" reason "$FAKEBIN" "$TMP/no-index/src/big.ts")
has "absolute GRAPHIFY_OUT honoured" present "graphify query" "$out"

# The Bash hook reuses the same hint on its denial path.
mv "$PROJ/graphify-out-feature" "$PROJ/graphify-out"
out=$(printf '%s' "$(bash_json "cd $PROJ/src/deep/deeper && cat big.ts")" |
  env -u CTX_DISABLE PATH="$FAKEBIN:$PATH" CTX_MIN_LINES=500 "$HOOKS/check-bash-read" |
  jq -r '.hookSpecificOutput.permissionDecisionReason // ""')
has "bash denial carries the graph hint too" present "$PROJ/graphify-out/graph.json" "$out"

# --- session announcement ---------------------------------------------------------
# This hook injects context into EVERY session. Each silence case below is a
# token it does not spend where it does not apply.
ann() {
  local p="${2:+$2:}$PATH"
  [ "${2:-}" = "PURE" ] && p="$PUREBIN"
  jq -nc --arg c "$1" '{hook_event_name:"SessionStart",cwd:$c,session_id:"t"}' |
    env -u CTX_DISABLE PATH="$p" "$HOOKS/announce-graph" 2>&1
}
echo "session announcement:"
has "with graph, announces" present "graphify query" "$(ann "$PROJ/src" "$FAKEBIN")"
has "with graph, points at the right file" present "$PROJ/graphify-out/graph.json" "$(ann "$PROJ/src" "$FAKEBIN")"
has "no graph, silence" absent "graphify" "$(ann "$TMP/no-index/src" "$FAKEBIN")"
has "no binary on PATH, silence" absent "graphify" "$(ann "$PROJ/src" "PURE")"
out=$(jq -nc --arg c "$PROJ/src" '{hook_event_name:"SessionStart",cwd:$c}' |
  CTX_DISABLE=1 PATH="$FAKEBIN:$PATH" "$HOOKS/announce-graph" 2>&1)
has "CTX_DISABLE disarms" absent "graphify" "$out"

# Folder of repos: Claude opened one level ABOVE the projects. Climbing finds
# nothing here, and without the downward search the announcement would be mute
# exactly when comparing repos.
REPOS="$TMP/repos"
for r in one two three; do
  mkdir -p "$REPOS/$r/graphify-out" "$REPOS/$r/src"
  echo '{}' >"$REPOS/$r/graphify-out/graph.json"
done
has "3 repos: counts all three" present "holds 3 indexed projects" "$(ann "$REPOS" "$FAKEBIN")"
has "3 repos: teaches merge-graphs" present "merge-graphs" "$(ann "$REPOS" "$FAKEBIN")"
has "3 repos: not the single-project text" absent "This project has a graph" "$(ann "$REPOS" "$FAKEBIN")"
mkdir -p "$TMP/empty"
has "empty folder: silence" absent "graphify" "$(ann "$TMP/empty" "$FAKEBIN")"
# One more nesting level must not be reached (noise at a distance). Its own tree:
# $TMP already has $PROJ as a DIRECT child, where announcing is right — the first
# version of this test measured the wrong tree, not the depth limit.
mkdir -p "$TMP/grand/mid/repo/graphify-out"
echo '{}' >"$TMP/grand/mid/repo/graphify-out/graph.json"
has "grandchild (2 levels) not reached" absent "graphify" "$(ann "$TMP/grand" "$FAKEBIN")"
has "child (1 level) reached" present "graphify" "$(ann "$TMP/grand/mid" "$FAKEBIN")"
# Inside a repo, the upward search wins, not the list.
has "inside a repo: upward path" present "This project has a graph" "$(ann "$REPOS/one/src" "$FAKEBIN")"

# --- funnel -----------------------------------------------------------------------
# track-usage runs on every Bash and Read. Half the cases here exist to prove it
# does NOT record — noise in the funnel corrupts the whole report.
echo "track-usage (PostToolUse) and block logging:"
FUN="$TMP/funnel.jsonl"
: >"$FUN"
trk() { printf '%s' "$1" | env -u CTX_DISABLE CTX_FUNNEL="$FUN" "$HOOKS/track-usage" >/dev/null 2>&1; }
evs() { jq -r '.ev' "$FUN" 2>/dev/null | tr '\n' ' '; }

trk "$(jq -nc '{session_id:"s",tool_name:"Bash",tool_input:{command:"graphify query \"x\" --graph /g.json"}}')"
has "graphify query becomes a graph event" present "graph" "$(evs)"
trk "$(jq -nc '{session_id:"s",tool_name:"Bash",tool_input:{command:"ls -la /tmp"}}')"
trk "$(jq -nc '{session_id:"s",tool_name:"Read",tool_input:{file_path:"/p/x.rs"}}')"
has "ls and whole Read record nothing" absent "graph graph" "$(evs)"
trk "$(jq -nc '{session_id:"s",tool_name:"Read",tool_input:{file_path:"/p/b.rs",offset:10,limit:5}}')"
has "targeted Read becomes reread" present "reread" "$(evs)"
has "reread keeps the right path" present '"path":"/p/b.rs"' "$(cat "$FUN")"
trk "$(jq -nc '{session_id:"s",tool_name:"Bash",tool_input:{command:"ctx-bulk-read --question q --paths /p/big.log"}}')"
has "bulk-read extracts --paths" present '"path":"/p/big.log"' "$(cat "$FUN")"

# A block must leave a trace, or the funnel only sees outcomes.
for h in check-file-size check-bash-read; do
  : >"$FUN"
  in=$(jq -nc --arg p "$TMP/big.ts" '{session_id:"sb",tool_name:"Read",tool_input:{file_path:$p}}')
  [ "$h" = check-bash-read ] && in=$(jq -nc --arg c "cat $TMP/big.ts" '{session_id:"sb",tool_name:"Bash",tool_input:{command:$c}}')
  printf '%s' "$in" | env -u CTX_DISABLE CTX_FUNNEL="$FUN" CTX_MIN_LINES=500 "$HOOKS/$h" >/dev/null
  has "$h logs the block" present '"ev":"block"' "$(cat "$FUN")"
  has "$h block keeps the session" present '"sid":"sb"' "$(cat "$FUN")"
done
# And an allowed read must not dirty the funnel.
: >"$FUN"
printf '%s' "$(jq -nc --arg p "$TMP/small.ts" '{session_id:"sb",tool_name:"Read",tool_input:{file_path:$p}}')" |
  env -u CTX_DISABLE CTX_FUNNEL="$FUN" CTX_MIN_LINES=500 "$HOOKS/check-file-size" >/dev/null
has "allowed read records nothing" absent "block" "$(cat "$FUN")"

# The report's correlation. Found in a real session: a denied Read, then a denied
# `cat` of the SAME file, then a delegation — the first block was reported as
# ignored, because any block closed its window. A block on a different file
# still must close it, or one delegation would absorb unrelated blocks.
echo "report correlation:"
RFUN="$TMP/report-funnel.jsonl"
{
  echo '{"ts":"2000-01-01T00:00:01Z","ev":"block","sid":"r","path":"/p/a.rs","lines":"900","tool":"Read"}'
  echo '{"ts":"2000-01-01T00:00:02Z","ev":"block","sid":"r","path":"/p/a.rs","lines":"900","tool":"Bash"}'
  echo '{"ts":"2000-01-01T00:00:03Z","ev":"bulk","sid":"r","path":"/p/a.rs"}'
  echo '{"ts":"2000-01-01T00:00:04Z","ev":"block","sid":"r","path":"/p/b.rs","lines":"800","tool":"Read"}'
  echo '{"ts":"2000-01-01T00:00:05Z","ev":"block","sid":"r","path":"/p/c.rs","lines":"700","tool":"Read"}'
  echo '{"ts":"2000-01-01T00:00:06Z","ev":"bulk","sid":"r","path":"/p/b.rs"}'
} >"$RFUN"
# HOME=$TMP: no transcripts to scan, so section 3 stays out of the way.
rep=$(HOME="$TMP" CTX_FUNNEL="$RFUN" CTX_LEDGER="$TMP/no-ledger.jsonl" \
  "$ROOT/report.sh" --since 2000-01-01 --until 2000-01-02 2>&1)
has "same-file retry shares the delegation" present "bulk-read         : 2" "$rep"
has "a different file still closes the window" present "NOTHING (ignored) : 2" "$rep"
has "the ignored ones are named" present "1x  /p/c.rs" "$rep"

# --- status line ------------------------------------------------------------------
# It runs after every assistant message and on a timer. Each warning has to
# appear exactly at its threshold, and a payload it cannot read must leave the
# footer empty instead of printing an error into it.
echo "status line:"
SL="$ROOT/bin/statusline"
now=$(date +%s)
# sl_json <context tokens> <5h percent> <warm: true|false> <cache expires in s> <misses> <miss cause>
sl_json() {
  jq -nc --argjson t "$1" --argjson p "$2" --argjson w "$3" --argjson e "$((now + $4))" \
    --argjson m "$5" --arg c "$6" --argjson r "$((now + 3600))" '
    {model: {display_name: "Opus 5"}, effort: {level: "max"},
     context_window: {total_input_tokens: $t, context_window_size: 1000000},
     rate_limits: {five_hour: {used_percentage: $p, resets_at: $r},
                   seven_day: {used_percentage: 41.2, resets_at: $r}},
     prompt_cache: ({warm: $w, caching_observed: true, ttl: "1h",
                     expires_at: (if $w then $e else null end),
                     misses: $m, recache_tokens_if_cold: $t}
                    + (if $c == "" then {} else {last_miss_cause: {causes: [$c]}} end))}'
}
sl() { printf '%s' "$1" | env NO_COLOR=1 COLUMNS="${2:-120}" "$SL"; }
slc() { printf '%s' "$1" | env -u NO_COLOR COLUMNS=120 "$SL"; }
ESC=$(printf '\033')

out=$(sl "$(sl_json 45000 23.5 true 1830 0 "")")
has "model and effort shown" present "Opus 5 max" "$out"
has "small context shows tokens" present "ctx 45k" "$out"
has "small context: no handoff" absent "handoff" "$out"
has "warm cache shows minutes left" present "cache ● 30m" "$out"
has "7d window on a wide terminal" present "7d 41%" "$out"
has "no miss, no miss segment" absent "miss" "$out"
has "NO_COLOR: no escape codes" absent "${ESC}[" "$out"
has "narrow terminal drops 7d" absent "7d" "$(sl "$(sl_json 45000 23.5 true 1830 0 "")" 80)"
has "249,999 tokens: still no handoff" absent "handoff" "$(sl "$(sl_json 249999 10 true 1830 0 "")")"
has "250k tokens: handoff" present "ctx 250k ⚑ handoff" "$(sl "$(sl_json 250000 10 true 1830 0 "")")"
has "handoff below 2x is yellow" present "${ESC}[33mctx 300k" "$(slc "$(sl_json 300000 10 true 1830 0 "")")"
has "handoff at 2x is red" present "${ESC}[31mctx 500k" "$(slc "$(sl_json 500000 10 true 1830 0 "")")"
has "millions formatted" present "ctx 1.2M" "$(sl "$(sl_json 1234567 10 true 1830 0 "")")"
has "CTX_HANDOFF_TOKENS=0: no flag at 900k" absent "handoff" \
  "$(sl_json 900000 10 true 1830 0 "" | env NO_COLOR=1 CTX_HANDOFF_TOKENS=0 "$SL")"
has "CTX_HANDOFF_5H=0: no flag at 99%" absent "handoff" \
  "$(sl_json 45000 99 true 1830 0 "" | env NO_COLOR=1 CTX_HANDOFF_5H=0 "$SL")"
has "5h at 84%: no handoff" absent "handoff" "$(sl "$(sl_json 45000 84.9 true 1830 0 "")")"
has "5h at 85%: handoff" present "5h 85%" "$(sl "$(sl_json 45000 85 true 1830 0 "")")"
has "5h at 85% says handoff" present "handoff" "$(sl "$(sl_json 45000 85 true 1830 0 "")")"
has "5h shows reset time" present "↺" "$(sl "$(sl_json 45000 85 true 1830 0 "")")"
has "cache about to go cold is yellow" present "${ESC}[33mcache ● 3m" "$(slc "$(sl_json 45000 10 true 230 0 "")")"
has "cold cache: tokens to re-cache" present "cache ○ cold, next call re-caches 612k" "$(sl "$(sl_json 612000 10 false 0 0 "")")"
has "misses with their cause" present "miss ×2 tools_changed" "$(sl "$(sl_json 45000 10 true 1830 2 tools_changed)")"
out=$(sl '{"model":{"display_name":"Opus 5"},"context_window":{"total_input_tokens":12000}}')
has "API user without limits or cache" present "Opus 5 · ctx 12k" "$out"
has "API user: nothing else invented" absent "5h" "$out"
out=$(
  printf 'not json' | "$SL"
  echo "rc=$?"
)
has "malformed input: exit 0" present "rc=0" "$out"
has "malformed input: nothing printed" absent "error" "$out"

# --- handoff (Stop) -----------------------------------------------------------------
# Past the threshold the turn stays open once, with the ask as context for
# Claude; below it, or once asked for that band, the hook says nothing. The
# defaults are what is tested, whatever the calling shell has set.
echo "handoff (Stop):"
HO="$HOOKS/handoff"
# transcript <file> <main-thread tokens> -- ends with a bigger subagent reply
# and a line still being written, both of which the hook must look past.
transcript() {
  jq -nc --argjson t "$2" '
    {type: "user", message: {content: "hi"}},
    {type: "assistant", message: {usage: {input_tokens: 2,
      cache_creation_input_tokens: 1000, cache_read_input_tokens: ($t - 1002)}}},
    {type: "assistant", isSidechain: true, message: {usage: {input_tokens: 900000}}}' >"$1"
  printf '{"type":"assis' >>"$1"
}
# stop_json <session> <transcript> [stop_hook_active] [background tasks]
stop_json() {
  jq -nc --arg s "$1" --arg t "$2" --argjson a "${3:-false}" --argjson n "${4:-0}" '
    {session_id: $s, transcript_path: $t, hook_event_name: "Stop",
     stop_hook_active: $a, session_crons: [],
     background_tasks: [range($n) | {id: "t\(.)", type: "shell", status: "running"}]}'
}
ho() { env -u CTX_DISABLE -u CTX_HANDOFF_TOKENS -u CTX_HANDOFF_5H "$@" "$HO" 2>&1; }
# stop <session> <tokens> [stop_hook_active] [background tasks]
stop() {
  transcript "$TMP/tr-$1.jsonl" "$2"
  stop_json "$1" "$TMP/tr-$1.jsonl" "${3:-false}" "${4:-0}" | ho
}
# is <name> <ask|quiet> <output> -- empty output is quiet, the Stop context an
# ask, anything else PARSE-ERR (never quiet by accident).
is() {
  local name="$1" want="$2" out="$3" got
  if [ -z "${out//[[:space:]]/}" ]; then
    got=quiet
  else
    got=$(printf '%s' "$out" | jq -er '.hookSpecificOutput | select(.hookEventName == "Stop")
      | .additionalContext | select(length > 0) | "ask"' 2>/dev/null) || got=PARSE-ERR
  fi
  if [ "$got" = "$want" ]; then
    pass=$((pass + 1))
    printf '  ok    %-50s -> %s\n' "$name" "$got"
  else
    fail=$((fail + 1))
    printf '  FAIL  %-50s -> %s (expected %s)\n' "$name" "$got" "$want"
    [ -n "$out" ] && printf '        %s\n' "$(printf '%s' "$out" | head -3)"
  fi
}

is "200k: quiet" quiet "$(stop a 200000)"
out=$(stop a 260000)
is "260k: asks" ask "$out"
has "names the context and the threshold" present "260k tokens, past the 250k" "$out"
has "asks for the ekko handoff" present "write a handoff (kind handoff)" "$out"
has "tells the user about /clear" present "/clear" "$out"
has "asks for typed notes first" present "decision, gotcha or procedure" "$out"
has "asks for the notes to read, by id" present "by id" "$out"
# One text for the Stop hook and /handoff: the skill's body, read here without
# the hook's code, must be in the ask as it is.
skill="$ROOT/skills/handoff/SKILL.md"
has "the ask is /handoff's own text" present "$(sed '/^---$/,/^---$/d' "$skill" | sed '/./,$!d')" \
  "$(printf '%s' "$out" | jq -r '.hookSpecificOutput.additionalContext' 2>/dev/null)"
has "/handoff is the user's alone" present "disable-model-invocation: true" "$(cat "$skill" 2>/dev/null)"
has "a subagent's 900k is not the context" absent "900k" "$out"
is "same band again (300k): quiet" quiet "$(stop a 300000)"
is "next band (510k): asks again" ask "$(stop a 510000)"
is "compacted to 120k: quiet" quiet "$(stop a 120000)"
is "past 250k again after compaction: asks" ask "$(stop a 270000)"
is "stop hook already continuing: quiet" quiet "$(stop b 300000 true)"
is "...and the ask is still owed" ask "$(stop b 300000)"
is "background task running: quiet" quiet "$(stop c 300000 false 1)"
has "...marked, for the cold-return hook" present "c.scheduled" "$(ls "$CTX_STATE/cold" 2>/dev/null)"
is "...asked at the next idle stop" ask "$(stop c 300000)"
has "...and the mark gone" absent "c.scheduled" "$(ls "$CTX_STATE/cold" 2>/dev/null)"
is "continued stop, task running: quiet" quiet "$(stop e 300000 true 1)"
has "...marked all the same" present "e.scheduled" "$(ls "$CTX_STATE/cold" 2>/dev/null)"
is "missing transcript: quiet" quiet "$(stop_json d "$TMP/none.jsonl" | ho)"
transcript "$TMP/tr-x.jsonl" 300000
is "session id with a slash: quiet" quiet "$(stop_json ../x "$TMP/tr-x.jsonl" | ho)"
is "CTX_DISABLE=1: quiet" quiet "$(stop_json x "$TMP/tr-x.jsonl" | CTX_DISABLE=1 "$HO" 2>&1)"
transcript "$TMP/tr-y.jsonl" 120000
is "CTX_HANDOFF_TOKENS=100000: 120k asks" ask "$(stop_json y "$TMP/tr-y.jsonl" | ho CTX_HANDOFF_TOKENS=100000)"
transcript "$TMP/tr-z.jsonl" 900000
is "CTX_HANDOFF_TOKENS=0: 900k quiet" quiet "$(stop_json z "$TMP/tr-z.jsonl" | ho CTX_HANDOFF_TOKENS=0)"
out=$(
  printf 'not json' | ho
  echo "rc=$?"
)
has "malformed input: exit 0" present "rc=0" "$out"
has "malformed input: nothing printed" absent "{" "$out"
has "each ask is logged" present '"ev":"handoff"' "$(cat "$CTX_STATE/handoff.jsonl" 2>/dev/null)"

# The 5-hour trigger reads what the status line left for the session.
# sl5 <session> <5h percent>
sl5() {
  jq -nc --arg s "$1" --argjson p "$2" '
    {session_id: $s, model: {display_name: "Opus 5"},
     context_window: {total_input_tokens: 45000},
     rate_limits: {five_hour: {used_percentage: $p}}}' |
    env NO_COLOR=1 "$SL" >/dev/null
}
sl5 f 90.6
has "status line leaves the 5h reading" present "90" "$(cat "$CTX_STATE/sessions/f" 2>/dev/null)"
out=$(stop f 50000)
is "5h at 90%, small context: asks" ask "$out"
has "names the 5-hour window" present "5-hour usage window is at 90%" "$out"
is "5h still at 90%: quiet" quiet "$(stop f 50000)"
sl5 f 40
stop f 50000 >/dev/null
sl5 f 88
is "window back under 85%, then over: asks" ask "$(stop f 50000)"
sl5 g 95
touch -d '20 minutes ago' "$CTX_STATE/sessions/g"
is "a 20-minute-old 5h reading is ignored" quiet "$(stop g 50000)"
sl5 h 90
has "both triggers in one ask" present ", and the 5-hour" "$(stop h 300000)"

# --- handoff written (PostToolUse) and its age ------------------------------------
# Each handoff ekko accepts leaves the context it was written at, and nothing
# else may: a mark left by a note or a refused write would make the status
# line call a stale handoff fresh, and the Stop hook skip an ask it owes.
echo "handoff written (PostToolUse):"
HW="$HOOKS/handoff-written"
# posted <session> <tokens> <tool> <tool_input json> <reply text> -- the hook's
# output, which is always empty
posted() {
  transcript "$TMP/tr-w-$1.jsonl" "$2"
  jq -nc --arg s "$1" --arg t "$TMP/tr-w-$1.jsonl" --arg n "$3" --argjson i "$4" --arg r "$5" '
    {session_id: $s, transcript_path: $t, hook_event_name: "PostToolUse",
     tool_name: $n, tool_input: $i, tool_response: [{type: "text", text: $r}]}' |
    env -u CTX_DISABLE "$HW" 2>&1
}
written() { cat "$CTX_STATE/handoff/$1.written" 2>/dev/null; }
OK='{"ok":true,"items":[{"id":415}]}'
EC=mcp__plugin_ekko_ekko__create
EB=mcp__plugin_ekko_ekko__batch
out=$(posted w1 332000 $EC '{"kind":"handoff","attached_to":337,"text":"WHERE IT STOPPED"}' "$OK")
has "a handoff ekko accepted is noted" present "332000" "$(written w1)"
has "...and the hook prints nothing" present "[]" "[$out]"
posted w2 332000 $EC '{"kind":"note","attached_to":337,"text":"about the handoff"}' "$OK" >/dev/null
has "a note that mentions one is not" absent "332000" "$(written w2)"
posted w3 332000 $EC '{"kind":"handoff","attached_to":337,"text":"h"}' "ATTACH_NOT_TASK: 337 is a note" >/dev/null
has "a refused handoff is not" absent "332000" "$(written w3)"
posted w4 332000 $EB '{"ops":[{"op":"create","kind":"decision","text":"d"},{"op":"create","kind":"handoff","attached_to":337,"text":"h"}]}' '{"ok":true,"results":[]}' >/dev/null
has "a handoff inside a batch is noted" present "332000" "$(written w4)"
posted w5 332000 $EB '{"ops":[{"op":"create","kind":"note","text":"the handoff was fine"}]}' '{"ok":true,"results":[]}' >/dev/null
has "a batch without one is not" absent "332000" "$(written w5)"
posted w6 332000 mcp__other__create '{"kind":"handoff","text":"h"}' "$OK" >/dev/null
has "another server's create is not ekko's" absent "332000" "$(written w6)"
posted w1 350000 $EC '{"kind":"handoff","attached_to":337,"text":"again"}' "$OK" >/dev/null
has "a later handoff moves the mark" present "350000" "$(written w1)"
jq -nc --arg t "$TMP/tr-w-w1.jsonl" --arg n "$EC" --arg r "$OK" '
  {session_id: "../w7", transcript_path: $t, tool_name: $n,
   tool_input: {kind: "handoff"}, tool_response: [{type: "text", text: $r}]}' |
  env -u CTX_DISABLE "$HW" >/dev/null 2>&1
has "session id with a slash: nothing written" absent "w7" "$(ls "$CTX_STATE" "$CTX_STATE/handoff")"
out=$(
  printf 'not json, but handoff' | env -u CTX_DISABLE "$HW"
  echo "rc=$?"
)
has "malformed input: exit 0" present "rc=0" "$out"

# A fresh handoff holds the session: the Stop hook stays quiet and the band
# counts as asked. A stale one, or one from before a compaction, does not.
mkdir -p "$CTX_STATE/handoff"
printf '245000\n' >"$CTX_STATE/handoff/k.written"
is "handoff at 245k, stop at 260k: quiet" quiet "$(stop k 260000)"
is "...at 300k, stale but asked: quiet" quiet "$(stop k 300000)"
has "a fresh handoff is logged" present '"ev":"handoff-fresh"' "$(cat "$CTX_STATE/handoff.jsonl" 2>/dev/null)"
printf '100000\n' >"$CTX_STATE/handoff/m.written"
is "handoff at 100k, stop at 260k: asks" ask "$(stop m 260000)"
printf '400000\n' >"$CTX_STATE/handoff/n.written"
is "handoff from before a compaction: asks" ask "$(stop n 260000)"
sl5 q 90
printf '45000\n' >"$CTX_STATE/handoff/q.written"
is "5h at 90% with a fresh handoff: quiet" quiet "$(stop q 50000)"

# The status line gives the handoff's age in context: fresh under a tenth of
# the threshold, stale past it.
# sls <session> <context tokens>
sls() {
  jq -nc --arg s "$1" --argjson t "$2" '
    {session_id: $s, model: {display_name: "Opus 5"},
     context_window: {total_input_tokens: $t}}' | env NO_COLOR=1 "$SL"
}
printf '330000\n' >"$CTX_STATE/handoff/v.written"
has "fresh handoff: ✓ and its age" present "ctx 335k ✓ handoff 5k ago" "$(sls v 335000)"
has "stale handoff: ⚑ and its age" present "ctx 410k ⚑ handoff 80k ago" "$(sls v 410000)"
printf '100000\n' >"$CTX_STATE/handoff/u.written"
has "under the threshold, stale: the age" present "ctx 180k · handoff 80k ago" "$(sls u 180000)"
has "under the threshold, fresh: ✓" present "ctx 102k ✓ handoff 2k ago" "$(sls u 102000)"
has "after a compaction: no age" absent "ago" "$(sls v 60000)"
has "no handoff written: no age" absent "ago" "$(sls nobody 300000)"
has "...and the flag as before" present "ctx 300k ⚑ handoff" "$(sls nobody 300000)"
has "fresh keeps the size colour" present "${ESC}[33mctx 335k ✓" \
  "$(jq -nc '{session_id: "v", context_window: {total_input_tokens: 335000}}' | env -u NO_COLOR "$SL")"
has "session id with a slash: no age" absent "ago" \
  "$(jq -nc '{session_id: "../v", context_window: {total_input_tokens: 335000}}' | env NO_COLOR=1 "$SL")"

# --- cold return (UserPromptSubmit) -------------------------------------------------
# A prompt that comes back to a big session past the cache's hour is stopped
# once, with the cost and the handoff's age; sent again it goes through, and so
# does a slash command. The defaults are what is tested.
echo "cold return (UserPromptSubmit):"
CR="$HOOKS/cold-return"
# ctr <file> <main-thread tokens> <minutes since that call> -- after the call
# come a message Claude Code wrote itself, a subagent's reply and a line still
# being written, the first two dated later: a hook that read them would see no
# pause at all.
ctr() {
  jq -nc --argjson t "$2" --arg at "$(date -u -d "@$(($(date +%s) - $3 * 60))" +%Y-%m-%dT%H:%M:%S.123Z)" '
    {type: "user", message: {content: "hi"}},
    {type: "assistant", timestamp: $at, message: {model: "claude-opus-5-5", usage: {input_tokens: 2,
      cache_creation_input_tokens: 1000, cache_read_input_tokens: ($t - 1002)}}},
    {type: "assistant", timestamp: "2099-01-01T00:00:00.000Z",
     message: {model: "<synthetic>", usage: {input_tokens: 0}}},
    {type: "assistant", isSidechain: true, timestamp: "2099-01-01T00:00:00.000Z",
     message: {usage: {input_tokens: 900000}}}' >"$1"
  printf '{"type":"assis' >>"$1"
}
# prompt_json <session> <transcript> [prompt]
prompt_json() {
  jq -nc --arg s "$1" --arg t "$2" --arg p "${3:-go on}" '
    {session_id: $s, transcript_path: $t, hook_event_name: "UserPromptSubmit", prompt: $p}'
}
cr() { env -u CTX_DISABLE -u CTX_COLD_TOKENS -u CTX_COLD_MINUTES -u CTX_HANDOFF_TOKENS "$@" "$CR" 2>&1; }
# back <session> <tokens> <minutes idle> [prompt] -- a new transcript each time
back() {
  ctr "$TMP/cr-$1.jsonl" "$2" "$3"
  prompt_json "$1" "$TMP/cr-$1.jsonl" "${4:-go on}" | cr
}
# guarded <name> <stop|pass> <output> -- empty output passes, a block with a
# reason stops, anything else PARSE-ERR (never a pass by accident).
guarded() {
  local name="$1" want="$2" out="$3" got
  if [ -z "${out//[[:space:]]/}" ]; then
    got=pass
  else
    got=$(printf '%s' "$out" | jq -er 'select(.decision == "block" and (.reason | length > 0)) | "stop"' 2>/dev/null) || got=PARSE-ERR
  fi
  if [ "$got" = "$want" ]; then
    pass=$((pass + 1))
    printf '  ok    %-50s -> %s\n' "$name" "$got"
  else
    fail=$((fail + 1))
    printf '  FAIL  %-50s -> %s (expected %s)\n' "$name" "$got" "$want"
    [ -n "$out" ] && printf '        %s\n' "$(printf '%s' "$out" | head -3)"
  fi
}
crwhy() { printf '%s' "$1" | jq -r '.reason // ""' 2>/dev/null; }

guarded "240k, idle 2h: passes" pass "$(back c1 240000 120)"
guarded "344k, idle 59m: passes" pass "$(back c2 344000 59)"
out=$(back c3 344000 72)
guarded "344k, idle 72m: stops" stop "$out"
has "says how long it sat idle" present "idle 1h12m" "$(crwhy "$out")"
has "names the context to re-write" present "all 344k tokens" "$(crwhy "$out")"
has "prices going on in the 5-hour window" present "Going on here costs ~4 points of the 5-hour window" "$(crwhy "$out")"
has "...and starting over" present "starting over, ~2 points" "$(crwhy "$out")"
has "no handoff: the board as it is" present "No handoff from this session" "$(crwhy "$out")"
has "offers /clear" present "/clear" "$(crwhy "$out")"
has "a subagent's 900k is not the context" absent "900k" "$(crwhy "$out")"
guarded "...sent again: passes" pass "$(prompt_json c3 "$TMP/cr-c3.jsonl" "go on, then" | cr)"
has "the stop is logged" present '"ev":"cold-stop"' "$(cat "$CTX_STATE/handoff.jsonl" 2>/dev/null)"
has "...and the prompt sent again" present '"ev":"cold-pass"' "$(cat "$CTX_STATE/handoff.jsonl" 2>/dev/null)"
guarded "more work, then a new pause: stops again" stop "$(back c3 350000 65)"
guarded "a slash command passes" pass "$(back c4 344000 90 "/handoff")"
guarded "...with a space before it too" pass "$(back c4 344000 90 " /handoff")"
mkdir -p "$CTX_STATE/cold" && : >"$CTX_STATE/cold/c10.scheduled"
guarded "a wakeup or background work pending: passes" pass "$(back c10 344000 90)"
has "...and is logged" present '"ev":"cold-scheduled"' "$(cat "$CTX_STATE/handoff.jsonl" 2>/dev/null)"
printf '340000\n' >"$CTX_STATE/handoff/c5.written"
has "fresh handoff: holds the session" present "handoff written 4k tokens ago holds this session" \
  "$(crwhy "$(back c5 344000 90)")"
printf '264000\n' >"$CTX_STATE/handoff/c6.written"
has "stale handoff: its age" present "last handoff is 80k tokens old" "$(crwhy "$(back c6 344000 90)")"
printf '400000\n' >"$CTX_STATE/handoff/c7.written"
has "handoff from before a compaction: says so" present "from before a compaction" \
  "$(crwhy "$(back c7 344000 90)")"
has "three days away: in days" present "idle 3 days" "$(crwhy "$(back c8 344000 4320)")"
has "530k: ~6 points" present "~6 points" "$(crwhy "$(back c9 530000 90)")"
guarded "missing transcript: passes" pass "$(prompt_json d1 "$TMP/none.jsonl" | cr)"
ctr "$TMP/cr-x.jsonl" 344000 90
guarded "session id with a slash: passes" pass "$(prompt_json ../x "$TMP/cr-x.jsonl" | cr)"
guarded "CTX_DISABLE=1: passes" pass "$(prompt_json x1 "$TMP/cr-x.jsonl" | CTX_DISABLE=1 "$CR" 2>&1)"
guarded "CTX_COLD_TOKENS=0: passes" pass "$(prompt_json x2 "$TMP/cr-x.jsonl" | cr CTX_COLD_TOKENS=0)"
guarded "CTX_COLD_MINUTES=0: passes" pass "$(prompt_json x3 "$TMP/cr-x.jsonl" | cr CTX_COLD_MINUTES=0)"
guarded "CTX_COLD_MINUTES=120: 90m passes" pass "$(prompt_json x4 "$TMP/cr-x.jsonl" | cr CTX_COLD_MINUTES=120)"
ctr "$TMP/cr-w.jsonl" 344000 17
has "CTX_COLD_MINUTES=10: 17m, in minutes" present "idle 17m, and the prompt cache has expired" \
  "$(crwhy "$(prompt_json w1 "$TMP/cr-w.jsonl" | cr CTX_COLD_MINUTES=10)")"
guarded "state that cannot be written: passes" pass \
  "$(prompt_json x5 "$TMP/cr-x.jsonl" | cr CTX_STATE="$TMP/big.ts/state")"
ctr "$TMP/cr-y.jsonl" 120000 90
guarded "CTX_COLD_TOKENS=100000: 120k stops" stop "$(prompt_json y1 "$TMP/cr-y.jsonl" | cr CTX_COLD_TOKENS=100000)"
jq -nc '{type: "assistant", message: {usage: {input_tokens: 344000}}}' >"$TMP/cr-z.jsonl"
guarded "a call with no time on it: passes" pass "$(prompt_json z1 "$TMP/cr-z.jsonl" | cr)"
out=$(
  printf 'not json' | cr
  echo "rc=$?"
)
has "malformed input: exit 0" present "rc=0" "$out"
has "malformed input: nothing printed" absent "{" "$out"

# --- live: the worker ---------------------------------------------------------------
# Not hermetic (needs the worker signed in via ctx-login, and the network), so
# it is opt-in. The wall checks run commands inside the sandbox directly instead
# of asking the model to misbehave: they prove what the sandbox ALLOWS, which is
# the guarantee, independently of what a model feels like doing that day.
if [ "$LIVE" -eq 1 ]; then
  # The real worker home, not the suite's scratch state: the login lives there.
  export CTX_WORKER_HOME="$REAL_WORKER_HOME"
  # shellcheck source=lib/transport.sh
  . "$ROOT/lib/transport.sh"
  if ! ctx_preflight; then
    fail=$((fail + 1))
    echo "  FAIL  live checks need the worker signed in: run ctx-login"
  else
    echo "live — sandbox walls:"
    canary=".ctx-escape-canary-$$"
    # shellcheck disable=SC2016 # expanded inside the sandbox, on purpose
    view=$(ctx_sandbox bash -c '
      for p in /projects /run/secrets /run/user "$HOME/.ssh" "$HOME/.claude" "$HOME/.local/share/keyrings"; do
        [ -e "$p" ] && echo "VISIBLE $p"
      done
      [ -n "${DBUS_SESSION_BUS_ADDRESS:-}" ] && echo "VISIBLE session bus"
      touch "$HOME/'"$canary"'" "$HOME/.gemini/'"$canary"'" && echo wrote' 2>&1)
    has "no user dirs, keyring or bus inside" absent "VISIBLE" "$view"
    has "worker can write its home (sanity)" present "wrote" "$view"
    got=contained
    for p in "$HOME/$canary" "$CTX_WORKER_HOME/$canary" "$CTX_WORKER_HOME/.gemini/$canary"; do
      [ -e "$p" ] && {
        rm -f "$p"
        got=escaped
      }
    done
    has 'writes reach neither $HOME nor the worker home' absent "escaped" "$got"
    bus=$(
      ctx_sandbox "$(command -v busctl)" --user call org.freedesktop.systemd1 /org/freedesktop/systemd1 org.freedesktop.DBus.Peer Ping 2>&1
      echo "rc=$?"
    )
    has "systemd --user unreachable" absent "rc=0" "$bus"

    echo "live — one real delegation each:"
    ans=$("$ROOT/bin/bulk-read" --question "What is the exact text on line 7? Reply with that text only." --paths "$TMP/small.ts" 2>"$TMP/err")
    has "bulk-read answers from the file" present "line 7" "$ans"
    [ -n "$ans" ] || sed 's/^/        /' "$TMP/err"
    "$ROOT/bin/code-write" --spec "Same format, lines 41 to 45 only." --reference "$TMP/small.ts" --target "$TMP/gen.ts" 2>"$TMP/err"
    has "code-write writes the target" present "line 4" "$(cat "$TMP/gen.ts" 2>/dev/null)"
    [ -s "$TMP/gen.ts" ] || sed 's/^/        /' "$TMP/err"
    has "ledger records agy usage" present '"worker":"agy"' "$(cat "$CTX_LEDGER" 2>/dev/null)"
  fi
fi

echo
echo "$pass ok, $fail failure(s)"
[ "$fail" -eq 0 ]
