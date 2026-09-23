#!/usr/bin/env bash
# The hooks' test suite. Every case states the verdict it expects; a hook that
# never denies (or denies everything) fails here instead of in production.
#
# Usage: shunt-test            hermetic: hooks only (also runs at build time)
#        shunt-test --live     plus the worker: sandbox walls and one real call
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
REAL_WORKER_HOME="${SHUNT_WORKER_HOME:-${SHUNT_STATE:-${XDG_STATE_HOME:-$HOME/.local/state}/shunt}/worker-home}"
export SHUNT_STATE="$TMP/state"
export SHUNT_FUNNEL="$TMP/funnel-suite.jsonl"
export SHUNT_LEDGER="$TMP/usage-suite.jsonl"

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
  out=$(printf '%s' "$json" | env -u SHUNT_DISABLE SHUNT_MIN_LINES=500 "$HOOKS/$hook" 2>&1)
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
out=$(printf '%s' "$(read_json "$TMP/big.ts")" | env -u SHUNT_DISABLE -u SHUNT_MIN_LINES "$HOOKS/check-file-size")
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

echo "recursion guard (SHUNT_DISABLE=1):"
for h in check-file-size check-bash-read; do
  in=$(read_json "$TMP/big.ts")
  [ "$h" = check-bash-read ] && in=$(bash_json "cat $TMP/big.ts")
  out=$(printf '%s' "$in" | SHUNT_DISABLE=1 SHUNT_MIN_LINES=500 "$HOOKS/$h" 2>&1)
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
    env -u SHUNT_DISABLE PATH="$p" \
      SHUNT_MIN_LINES=500 "$HOOKS/check-file-size" 2>&1 |
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
has "bulk-read still offered alongside" present "shunt-bulk-read" "$(reason "$FAKEBIN" "$PROJ/src/deep/deeper/big.ts")"

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
  env -u SHUNT_DISABLE PATH="$FAKEBIN:$PATH" SHUNT_MIN_LINES=500 "$HOOKS/check-bash-read" |
  jq -r '.hookSpecificOutput.permissionDecisionReason // ""')
has "bash denial carries the graph hint too" present "$PROJ/graphify-out/graph.json" "$out"

# --- session announcement ---------------------------------------------------------
# This hook injects context into EVERY session. Each silence case below is a
# token it does not spend where it does not apply.
ann() {
  local p="${2:+$2:}$PATH"
  [ "${2:-}" = "PURE" ] && p="$PUREBIN"
  jq -nc --arg c "$1" '{hook_event_name:"SessionStart",cwd:$c,session_id:"t"}' |
    env -u SHUNT_DISABLE PATH="$p" "$HOOKS/announce-graph" 2>&1
}
echo "session announcement:"
has "with graph, announces" present "graphify query" "$(ann "$PROJ/src" "$FAKEBIN")"
has "with graph, points at the right file" present "$PROJ/graphify-out/graph.json" "$(ann "$PROJ/src" "$FAKEBIN")"
has "no graph, silence" absent "graphify" "$(ann "$TMP/no-index/src" "$FAKEBIN")"
has "no binary on PATH, silence" absent "graphify" "$(ann "$PROJ/src" "PURE")"
out=$(jq -nc --arg c "$PROJ/src" '{hook_event_name:"SessionStart",cwd:$c}' |
  SHUNT_DISABLE=1 PATH="$FAKEBIN:$PATH" "$HOOKS/announce-graph" 2>&1)
has "SHUNT_DISABLE disarms" absent "graphify" "$out"

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
trk() { printf '%s' "$1" | env -u SHUNT_DISABLE SHUNT_FUNNEL="$FUN" "$HOOKS/track-usage" >/dev/null 2>&1; }
evs() { jq -r '.ev' "$FUN" 2>/dev/null | tr '\n' ' '; }

trk "$(jq -nc '{session_id:"s",tool_name:"Bash",tool_input:{command:"graphify query \"x\" --graph /g.json"}}')"
has "graphify query becomes a graph event" present "graph" "$(evs)"
trk "$(jq -nc '{session_id:"s",tool_name:"Bash",tool_input:{command:"ls -la /tmp"}}')"
trk "$(jq -nc '{session_id:"s",tool_name:"Read",tool_input:{file_path:"/p/x.rs"}}')"
has "ls and whole Read record nothing" absent "graph graph" "$(evs)"
trk "$(jq -nc '{session_id:"s",tool_name:"Read",tool_input:{file_path:"/p/b.rs",offset:10,limit:5}}')"
has "targeted Read becomes reread" present "reread" "$(evs)"
has "reread keeps the right path" present '"path":"/p/b.rs"' "$(cat "$FUN")"
trk "$(jq -nc '{session_id:"s",tool_name:"Bash",tool_input:{command:"shunt-bulk-read --question q --paths /p/big.log"}}')"
has "bulk-read extracts --paths" present '"path":"/p/big.log"' "$(cat "$FUN")"

# A block must leave a trace, or the funnel only sees outcomes.
for h in check-file-size check-bash-read; do
  : >"$FUN"
  in=$(jq -nc --arg p "$TMP/big.ts" '{session_id:"sb",tool_name:"Read",tool_input:{file_path:$p}}')
  [ "$h" = check-bash-read ] && in=$(jq -nc --arg c "cat $TMP/big.ts" '{session_id:"sb",tool_name:"Bash",tool_input:{command:$c}}')
  printf '%s' "$in" | env -u SHUNT_DISABLE SHUNT_FUNNEL="$FUN" SHUNT_MIN_LINES=500 "$HOOKS/$h" >/dev/null
  has "$h logs the block" present '"ev":"block"' "$(cat "$FUN")"
  has "$h block keeps the session" present '"sid":"sb"' "$(cat "$FUN")"
done
# And an allowed read must not dirty the funnel.
: >"$FUN"
printf '%s' "$(jq -nc --arg p "$TMP/small.ts" '{session_id:"sb",tool_name:"Read",tool_input:{file_path:$p}}')" |
  env -u SHUNT_DISABLE SHUNT_FUNNEL="$FUN" SHUNT_MIN_LINES=500 "$HOOKS/check-file-size" >/dev/null
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
rep=$(HOME="$TMP" SHUNT_FUNNEL="$RFUN" SHUNT_LEDGER="$TMP/no-ledger.jsonl" \
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
has "199,999 tokens: still no handoff" absent "handoff" "$(sl "$(sl_json 199999 10 true 1830 0 "")")"
has "200k tokens: handoff" present "ctx 200k ⚑ handoff" "$(sl "$(sl_json 200000 10 true 1830 0 "")")"
has "handoff below 2x is yellow" present "${ESC}[33mctx 250k" "$(slc "$(sl_json 250000 10 true 1830 0 "")")"
has "handoff at 2x is red" present "${ESC}[31mctx 400k" "$(slc "$(sl_json 400000 10 true 1830 0 "")")"
has "millions formatted" present "ctx 1.2M" "$(sl "$(sl_json 1234567 10 true 1830 0 "")")"
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

# --- live: the worker ---------------------------------------------------------------
# Not hermetic (needs the worker signed in via shunt-login, and the network), so
# it is opt-in. The wall checks run commands inside the sandbox directly instead
# of asking the model to misbehave: they prove what the sandbox ALLOWS, which is
# the guarantee, independently of what a model feels like doing that day.
if [ "$LIVE" -eq 1 ]; then
  # The real worker home, not the suite's scratch state: the login lives there.
  export SHUNT_WORKER_HOME="$REAL_WORKER_HOME"
  # shellcheck source=lib/transport.sh
  . "$ROOT/lib/transport.sh"
  if ! shunt_preflight; then
    fail=$((fail + 1))
    echo "  FAIL  live checks need the worker signed in: run shunt-login"
  else
    echo "live — sandbox walls:"
    canary=".shunt-escape-canary-$$"
    # shellcheck disable=SC2016 # expanded inside the sandbox, on purpose
    view=$(shunt_sandbox bash -c '
      for p in /projects /run/secrets /run/user "$HOME/.ssh" "$HOME/.claude" "$HOME/.local/share/keyrings"; do
        [ -e "$p" ] && echo "VISIBLE $p"
      done
      [ -n "${DBUS_SESSION_BUS_ADDRESS:-}" ] && echo "VISIBLE session bus"
      touch "$HOME/'"$canary"'" "$HOME/.gemini/'"$canary"'" && echo wrote' 2>&1)
    has "no user dirs, keyring or bus inside" absent "VISIBLE" "$view"
    has "worker can write its home (sanity)" present "wrote" "$view"
    got=contained
    for p in "$HOME/$canary" "$SHUNT_WORKER_HOME/$canary" "$SHUNT_WORKER_HOME/.gemini/$canary"; do
      [ -e "$p" ] && {
        rm -f "$p"
        got=escaped
      }
    done
    has 'writes reach neither $HOME nor the worker home' absent "escaped" "$got"
    bus=$(
      shunt_sandbox "$(command -v busctl)" --user call org.freedesktop.systemd1 /org/freedesktop/systemd1 org.freedesktop.DBus.Peer Ping 2>&1
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
    has "ledger records agy usage" present '"worker":"agy"' "$(cat "$SHUNT_LEDGER" 2>/dev/null)"
  fi
fi

echo
echo "$pass ok, $fail failure(s)"
[ "$fail" -eq 0 ]
