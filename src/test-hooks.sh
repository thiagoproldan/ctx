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
# The account whose 5-hour reading the hooks share (lib/window.sh) is the
# profile's folder: one of the suite's own, and another for each group of cases
# that leaves a reading, so that no reading reaches cases it was not meant for.
export CLAUDE_CONFIG_DIR="$TMP/profile"

# Never the real tab. Run from a Claude Code session, the suite inherits the
# D-Bus address of the Konsole tab the user works in, and bin/auto-reset types
# into whatever these name. Here they name nothing; the auto-reset cases set
# their own, answered by a fake busctl.
export KONSOLE_DBUS_SERVICE=ctx.test.invalid KONSOLE_DBUS_SESSION=/Sessions/0
unset CLAUDE_CODE_ENTRYPOINT

# Never the real ekko. Before refusing, the guards ask ekko whether the user let
# the call through (ekko task 805), and the real one records every refusal it is
# asked about in the user's ~/.ekko. This one, first on PATH, answers what
# EKKO_FAKE says and appends its arguments and stdin to EKKO_FAKE_LOG; unset, it
# cannot tell (exit 2), and a refusal stands as it is.
EKKOBIN="$TMP/ekkobin"
mkdir -p "$EKKOBIN"
cat >"$EKKOBIN/ekko" <<EOF
#!$(command -v bash)
{ printf '%s\n' "\$*"; cat; echo; } >>"\${EKKO_FAKE_LOG:-/dev/null}"
case "\${EKKO_FAKE:-}" in
through) exit 0 ;;
refused)
  echo 'If the user wants this exact call made anyway, ask them with allow set to "abc123".'
  exit 1
  ;;
mute) exit 1 ;;
*) exit 2 ;;
esac
EOF
chmod +x "$EKKOBIN/ekko"
export PATH="$EKKOBIN:$PATH"

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

# eq <name> <expected> <got> -- defined before any case uses it: a helper
# called before its definition is "command not found", which counts as
# neither a pass nor a failure.
eq() {
  if [ "$3" = "$2" ]; then
    pass=$((pass + 1))
    printf '  ok    %-50s -> %s\n' "$1" "$3"
  else
    fail=$((fail + 1))
    printf '  FAIL  %-50s -> %s (expected %s)\n' "$1" "$3" "$2"
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
export CLAUDE_CONFIG_DIR="$TMP/profile-sl"
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
export CLAUDE_CONFIG_DIR="$TMP/profile"

# --- the account's 5-hour window (lib/window.sh) -------------------------------------
# Every session of an account leaves its reading in the same file, each with
# what its own process last heard from the API: the readings of one window keep
# the highest, a later window replaces them, an earlier one is dropped, and a
# window that ended reads as none (ekko task 808).
echo "5-hour window:"
# shellcheck source=lib/window.sh
. "$ROOT/lib/window.sh"
at1=$((now + 3600)) at2=$((now + 3600 + 18000))
w() { CLAUDE_CONFIG_DIR="$TMP/profile-w" "$@"; }
w ctx_window_merge 60 "$at1" 40
w ctx_window_merge 55 "$at1" 38
eq "an idle session's older number: the highest stays" "60 $at1 40" "$(w ctx_window)"
w ctx_window_merge 12 "$at2" 41
eq "a later window replaces it" "12 $at2 41" "$(w ctx_window)"
w ctx_window_merge 90 "$at1" 45
eq "an earlier window is dropped" "12 $at2 41" "$(w ctx_window)"
w ctx_window_merge 20 $((at2 + 120)) -
eq "the same window, its end rounded: the highest" "20 $((at2 + 120)) 41" "$(w ctx_window)"
echo "95 $((now - 60)) 50" >"$CTX_STATE/window/profile-w"
eq "a window that ended reads as none" "" "$(w ctx_window)"
eq "the account is the profile's folder" "claude-trabalho" "$(CLAUDE_CONFIG_DIR=/home/x/.claude-trabalho/ ctx_account)"
eq "...~/.claude without the variable" "claude" "$(env -u CLAUDE_CONFIG_DIR HOME=/home/x bash -c '. "$0"; ctx_account' "$ROOT/lib/window.sh")"
sl_json 45000 62.4 true 1830 0 "" | env NO_COLOR=1 CLAUDE_CONFIG_DIR="$TMP/profile-s" "$SL" >/dev/null
eq "the status line leaves the account's reading" "62 $at1 41" "$(CLAUDE_CONFIG_DIR="$TMP/profile-s" ctx_window)"
eq "one line for the model" "5h 62% until $(date -d "@$at1" +%H:%M), cap 85% · 7d 41%" "$(ctx_window_line 62 "$at1" 41)"

# --- window (SessionStart, UserPromptSubmit, PostToolUse) ------------------------------
# The model is told the reading as a session starts and with every prompt, and
# mid-turn once the window crosses 70% or the cap; past the cap a scheduled
# prompt is held, and the user's goes through with what the cap asks.
echo "window (SessionStart, UserPromptSubmit, PostToolUse):"
WH="$HOOKS/window"
PW="$TMP/profile-h"
# wh <event> [env...] -- the hook's output for the input on stdin
wh() {
  local ev="$1"
  shift
  env -u CTX_DISABLE -u CTX_HANDOFF_5H CLAUDE_CONFIG_DIR="$PW" "$@" "$WH" "$ev" 2>&1
}
told() { printf '%s' "$1" | jq -r '.hookSpecificOutput.additionalContext // .reason // ""' 2>/dev/null; }
held() { printf '%s' "$1" | jq -r '.decision // ""' 2>/dev/null; }
tool() { printf '{"session_id":"%s","tool_name":"Read"}' "$1" | wh tool; }
eq "no reading: nothing said" "" "$(printf '{"session_id":"w1","source":"startup"}' | wh start)"
CLAUDE_CONFIG_DIR="$PW" ctx_window_merge 62 "$at1" 48
out=$(printf '{"session_id":"w1","source":"startup"}' | wh start)
eq "start: the reading in one line" "ctx: 5h 62% until $(date -d "@$at1" +%H:%M), cap 85% · 7d 48%." "$(told "$out")"
eq "...as SessionStart's context" "SessionStart" "$(printf '%s' "$out" | jq -r '.hookSpecificOutput.hookEventName')"
has "prompt: the same line" present "ctx: 5h 62%" "$(told "$(printf '{"session_id":"w1","prompt":"oi","source":"user"}' | wh prompt)")"
eq "tool, the same band: nothing" "" "$(tool w1)"
CLAUDE_CONFIG_DIR="$PW" ctx_window_merge 74 "$at1" 48
has "tool: 70% crossed, told" present "Past 70%: pace the work" "$(told "$(tool w1)")"
eq "...once" "" "$(tool w1)"
CLAUDE_CONFIG_DIR="$PW" ctx_window_merge 86 "$at1" 48
has "tool: the cap crossed, told the rule" present "Past the cap the rest of the window is the user's reserve" "$(told "$(tool w1)")"
has "...logged" present '"ev":"window-crossed","sid":"w1"' "$(cat "$CTX_STATE/handoff.jsonl" 2>/dev/null)"
for source in loop_wakeup schedule_wakeup; do
  out=$(jq -nc --arg s "$source" '{session_id: "w1", prompt: "check", source: $s}' | wh prompt)
  eq "past the cap, source $source: held" "block" "$(held "$out")"
done
has "...fires again after the reset" present "fires again after the window resets" "$(told "$out")"
has "...logged" present '"ev":"window-held","sid":"w1"' "$(cat "$CTX_STATE/handoff.jsonl" 2>/dev/null)"
for source in user system sdk ""; do
  out=$(jq -nc --arg s "$source" '{session_id: "w1", prompt: "sigo?"} + (if $s == "" then {} else {source: $s} end)' | wh prompt)
  eq "past the cap, source ${source:-absent}: goes through" "" "$(held "$out")"
done
has "...with what the cap asks" present "A prompt the user sends goes through" "$(told "$out")"
eq "CTX_HANDOFF_5H=0: nothing held" "" \
  "$(held "$(jq -nc '{session_id: "w1", prompt: "check", source: "loop_wakeup"}' | wh prompt CTX_HANDOFF_5H=0)")"
CLAUDE_CONFIG_DIR="$PW" ctx_window_merge 10 "$at2" 50
eq "a new window: nothing" "" "$(tool w1)"
CLAUDE_CONFIG_DIR="$PW" ctx_window_merge 71 "$at2" 50
has "...and its 70% told again" present "Past 70%" "$(told "$(tool w1)")"
# A tool's input can be long: the hook reads its start and drains the rest.
out=$({
  printf '{"session_id":"w2","tool_name":"Read","tool_response":"'
  head -c 2000000 /dev/zero | tr '\0' a
  printf '"}'
} | wh tool)
has "a 2 MB tool input: read, and told" present "Past 70%" "$(told "$out")"

# --- window guard (PreToolUse) ------------------------------------------------------
# Past the cap, the work a session starts on its own is refused: a subagent, a
# new schedule, a headless claude. Everything else goes, and nothing is refused
# under the cap.
echo "window guard (PreToolUse):"
PG="$TMP/profile-g"
gw() { CLAUDE_CONFIG_DIR="$PG" check "$@"; }
tool_json() { jq -nc --arg t "$1" '{tool_name: $t, tool_input: {description: "x", prompt: "y"}, session_id: "suite", cwd: "/tmp"}'; }
gw "no reading: a subagent goes" allow guard-window "$(tool_json Agent)"
CLAUDE_CONFIG_DIR="$PG" ctx_window_merge 84 "$at1" 40
gw "84%: a subagent goes" allow guard-window "$(tool_json Agent)"
gw "84%: claude -p goes" allow guard-window "$(bash_json 'claude -p "resume o repo"')"
CLAUDE_CONFIG_DIR="$PG" ctx_window_merge 85 "$at1" 40
gw "85%: a subagent is refused" deny guard-window "$(tool_json Agent)"
gw "...Task, its old name" deny guard-window "$(tool_json Task)"
gw "...a new cron" deny guard-window "$(tool_json CronCreate)"
gw "...a wakeup" deny guard-window "$(tool_json ScheduleWakeup)"
gw "...claude -p" deny guard-window "$(bash_json 'claude -p "resume o repo"')"
gw "...claude --print, after cd, under timeout" deny guard-window "$(bash_json 'cd /tmp && timeout 600 claude --print x | tee o')"
gw "...inside bash -c" deny guard-window "$(bash_json 'bash -c "claude -p x"')"
gw "claude --version goes" allow guard-window "$(bash_json 'claude --version')"
gw "claude -p in a commit message goes" allow guard-window "$(bash_json 'git commit -m "claude -p is refused past the cap"')"
gw "another Bash call goes" allow guard-window "$(bash_json 'ls ~/.claude/projects')"
gw "a Read goes" allow guard-window "$(tool_json Read)"
CTX_HANDOFF_5H=0 gw "CTX_HANDOFF_5H=0: no cap" allow guard-window "$(tool_json Agent)"
EKKO_FAKE=through gw "the user let it through in ekko's menu" allow guard-window "$(tool_json Agent)"
out=$(tool_json Agent | env -u CTX_DISABLE CLAUDE_CONFIG_DIR="$PG" EKKO_FAKE=refused "$HOOKS/guard-window" |
  jq -r '.hookSpecificOutput.permissionDecisionReason // ""')
has "the reason names the window and the cap" present "the 5-hour window is at 85%, past the 85% cap, until $(date -d "@$at1" +%H:%M)" "$out"
has "...and how to ask the user" present 'allow set to "abc123"' "$out"
has "refusals are logged" present '"ev": "window-refuse"' "$(cat "$CTX_STATE/guard.jsonl" 2>/dev/null)"
has "...and the call let through" present '"ev": "window-excepted"' "$(cat "$CTX_STATE/guard.jsonl" 2>/dev/null)"

# --- handoff (Stop) -----------------------------------------------------------------
# With the user there, the hook asks nothing, past the threshold or the cap: the
# status line flags the handoff, and the user runs /handoff between tasks (ekko
# task 961). A session running alone -- the user away, in a Konsole tab of an
# interactive session -- is asked once a band, with the ask as context for
# Claude, and ctx then types the reset. Below the threshold, or once asked for
# that band, the hook says nothing. The defaults are what is tested, whatever
# the calling shell has set.
echo "handoff (Stop):"
HO="$HOOKS/handoff"
# transcript <file> <main-thread tokens> [minutes since the user typed] -- ends
# with a bigger subagent reply and a line still being written, both of which
# the hook must look past. Without the minutes no row carries an origin, and
# the session never reads as away.
transcript() {
  jq -nc --argjson t "$2" --arg ago "${3:-}" '
    (if $ago == "" then empty else
      {type: "user", uuid: "typed", origin: {kind: "human"},
       timestamp: (now - ($ago | tonumber) * 60 | todate), message: {content: "oi"}} end),
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
ho() { env -u CTX_DISABLE -u CTX_HANDOFF_TOKENS -u CTX_HANDOFF_5H "$HO" 2>&1; }
# stop <session> <tokens> [stop_hook_active] [background tasks] -- the user
# there: no origin in the transcript, and no Konsole tab.
stop() {
  transcript "$TMP/tr-$1.jsonl" "$2"
  stop_json "$1" "$TMP/tr-$1.jsonl" "${3:-false}" "${4:-0}" | ho
}
# A process named claude stands for Claude Code: the ancestor hooks/handoff
# looks for.
SOLO="$TMP/solo"
mkdir -p "$SOLO" && ln -sf "$(command -v bash)" "$SOLO/claude"
# solo <session> <tokens> [stop_hook_active] [background tasks] [VAR=value...]
# -- the hook in a Konsole tab of an interactive session, under a process named
# claude, the user's last prompt ${AWAY:-40} minutes old: alone, unless AWAY is
# under CTX_AUTO_RESET_IDLE (10).
solo() {
  local s="$1" t="$2" a="${3:-false}" n="${4:-0}"
  shift 2
  shift $(($# < 2 ? $# : 2))
  transcript "$TMP/tr-$s.jsonl" "$t" "${AWAY:-40}"
  # shellcheck disable=SC2016 # $0 is the hook, for the inner shell
  stop_json "$s" "$TMP/tr-$s.jsonl" "$a" "$n" |
    env -u CTX_DISABLE -u CTX_HANDOFF_TOKENS -u CTX_HANDOFF_5H -u CTX_AUTO_RESET_IDLE \
      PATH="$SOLO:$PATH" KONSOLE_DBUS_SERVICE=fake.konsole KONSOLE_DBUS_SESSION=/Sessions/7 \
      CLAUDE_CODE_ENTRYPOINT=cli "$@" "$SOLO/claude" -c '"$0"; true' "$HO" 2>&1
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
ledger() { cat "$CTX_STATE/handoff.jsonl" 2>/dev/null; }
# spared <session> -- the asks the user was spared, as the ledger counts them
spared() { grep -c "\"ev\":\"handoff-quiet\",\"sid\":\"$1\"" "$CTX_STATE/handoff.jsonl" 2>/dev/null; }

is "200k: quiet" quiet "$(stop a 200000)"
is "the user there, 260k: quiet" quiet "$(stop a 260000)"
eq "...counted as an ask spared" 1 "$(spared a)"
is "...300k, the same band: quiet" quiet "$(stop a 300000)"
eq "...counted once a band" 1 "$(spared a)"
is "...510k, the next band: quiet" quiet "$(stop a 510000)"
eq "...and counted" 2 "$(spared a)"
stop a 120000 >/dev/null
stop a 270000 >/dev/null
eq "...compacted and past 250k again: counted again" 3 "$(spared a)"
is "typed 1 minute ago, in Konsole: quiet" quiet "$(AWAY=1 solo b 260000)"
out=$(solo b 260000)
is "...40 minutes ago, the same band: asks" ask "$out"
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
is "alone, the same band again (300k): quiet" quiet "$(solo b 300000)"
is "alone, the next band (510k): asks again" ask "$(solo b 510000)"
is "alone, compacted to 120k: quiet" quiet "$(solo b 120000)"
is "alone, past 250k again after compaction: asks" ask "$(solo b 270000)"
is "stop hook already continuing: quiet" quiet "$(solo c 300000 true)"
is "...and the ask is still owed" ask "$(solo c 300000)"
is "the user there, a background task running: quiet" quiet "$(stop d 300000 false 1)"
has "...marked, for the cold-return hook" present "d.scheduled" "$(ls "$CTX_STATE/cold" 2>/dev/null)"
is "...and once it ended: quiet" quiet "$(stop d 300000)"
has "...and the mark gone" absent "d.scheduled" "$(ls "$CTX_STATE/cold" 2>/dev/null)"
is "continued stop, task running: quiet" quiet "$(stop e 300000 true 1)"
has "...marked all the same" present "e.scheduled" "$(ls "$CTX_STATE/cold" 2>/dev/null)"
is "missing transcript: quiet" quiet "$(stop_json m0 "$TMP/none.jsonl" | ho)"
transcript "$TMP/tr-x.jsonl" 300000
is "session id with a slash: quiet" quiet "$(stop_json ../x "$TMP/tr-x.jsonl" | ho)"
is "CTX_DISABLE=1, alone: quiet" quiet "$(solo x1 300000 false 0 CTX_DISABLE=1)"
is "CTX_HANDOFF_TOKENS=100000, alone: 120k asks" ask "$(solo y 120000 false 0 CTX_HANDOFF_TOKENS=100000)"
is "CTX_HANDOFF_TOKENS=0, alone: 900k quiet" quiet "$(solo z 900000 false 0 CTX_HANDOFF_TOKENS=0)"
out=$(
  printf 'not json' | ho
  echo "rc=$?"
)
has "malformed input: exit 0" present "rc=0" "$out"
has "malformed input: nothing printed" absent "{" "$out"
has "each ask is logged" present '"ev":"handoff"' "$(ledger)"

# The 5-hour trigger reads the account's reading, which the status line leaves
# (lib/window.sh); these sessions share an account of their own.
# sl5 <5h percent> [window: 1, or 2 for the next one]
sl5() {
  jq -nc --argjson p "$1" --argjson r "$((now + 3600 + (${2:-1} - 1) * 18000))" '
    {session_id: "any", model: {display_name: "Opus 5"},
     context_window: {total_input_tokens: 45000},
     rate_limits: {five_hour: {used_percentage: $p, resets_at: $r}}}' |
    env NO_COLOR=1 CLAUDE_CONFIG_DIR="$TMP/profile-5h" "$SL" >/dev/null
}
stop5() { CLAUDE_CONFIG_DIR="$TMP/profile-5h" stop "$@"; }
solo5() { CLAUDE_CONFIG_DIR="$TMP/profile-5h" solo "$@"; }
sl5 90.6
has "status line leaves the account's 5h reading" present "90 " "$(cat "$CTX_STATE/window/profile-5h" 2>/dev/null)"
is "the user there, 5h at 90%: quiet" quiet "$(stop5 f 300000)"
has "...counted, with the 5-hour reading" present '"ev":"handoff-quiet","sid":"f","tokens":"300000","five":"90"' "$(ledger)"
is "alone, small context, 5h at 90%: quiet" quiet "$(solo5 f2 50000)"
out=$(solo5 h 300000)
is "alone, 300k and 5h at 90%: asks" ask "$out"
has "both triggers in one ask" present ", and the 5-hour" "$out"
has "...names the 5-hour window" present "5-hour usage window is at 90%" "$out"
has "...and what the cap asks" present "Past the cap the rest of the window is the user's reserve" "$out"
is "alone, 5h still at 90%, the same band: quiet" quiet "$(solo5 h 300000)"
sl5 40 2
solo5 h 300000 >/dev/null
sl5 88 2
out=$(solo5 h 300000)
is "a new window under 85%, then over: asks" ask "$out"
has "...for the 5-hour window alone" absent "tokens, past the" "$out"
mkdir -p "$CTX_STATE/window" && echo "95 $((now - 60)) -" >"$CTX_STATE/window/profile-ended"
out=$(CLAUDE_CONFIG_DIR="$TMP/profile-ended" solo g 300000)
is "alone, a reading whose window ended: the band's ask" ask "$out"
has "...without the 5-hour window" absent "5-hour" "$out"

# The rule over the class (ekko task 961): with the user there, nothing ctx
# says past the threshold and the cap tells the model to write a handoff by
# itself. Every output such a session gets there is enumerated -- the Stop
# hook, the window hook at start, prompt and tool, the window guard's refusal
# -- and the ask a session alone gets, which must say it, is the check's no.
PK="$TMP/profile-k"
CLAUDE_CONFIG_DIR="$PK" ctx_window_merge 95 "$at1" 40
present_said=$(
  CLAUDE_CONFIG_DIR="$PK" AWAY=1 solo k1 300000
  for ev in start prompt tool; do
    jq -nc --arg s "k-$ev" '{session_id: $s, source: "startup", prompt: "oi", tool_name: "Read"}' |
      env -u CTX_DISABLE -u CTX_HANDOFF_5H CLAUDE_CONFIG_DIR="$PK" "$WH" "$ev" 2>&1
  done
  tool_json Agent | env -u CTX_DISABLE CLAUDE_CONFIG_DIR="$PK" EKKO_FAKE=refused "$HOOKS/guard-window" 2>&1
)
eq "the user there, past both: what is said" 4 "$(grep -o 'Past the cap' <<<"$present_said" | wc -l)"
has "...the subagent refused among it" present "ctx refused a subagent" "$present_said"
has "...and none of it asks for a handoff" absent "handoff" "$(tr '[:upper:]' '[:lower:]' <<<"$present_said")"
has "alone, the ask does (the check's no)" present "handoff" \
  "$(CLAUDE_CONFIG_DIR="$PK" solo k2 300000 | tr '[:upper:]' '[:lower:]')"

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

# Alone, a fresh handoff starts the reset instead of a second ask (see the auto
# reset below); a stale one, or one from before a compaction, is asked again.
mkdir -p "$CTX_STATE/handoff"
printf '100000\n' >"$CTX_STATE/handoff/hm.written"
is "alone, handoff at 100k, stop at 260k: asks" ask "$(solo hm 260000)"
printf '400000\n' >"$CTX_STATE/handoff/hn.written"
is "alone, handoff from before a compaction: asks" ask "$(solo hn 260000)"

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

# --- auto reset: the session alone ---------------------------------------------------
# Away from the keyboard, past the threshold, with a fresh handoff, the Stop hook
# starts bin/auto-reset, which types /clear and 'continuando' into the session's
# Konsole tab. Here the tab is a fake busctl playing Konsole with Claude Code in
# it: it keeps the input box, an Enter on /clear starts a fresh transcript, an
# Enter on anything else appends it as a typed row.
echo "auto reset (Stop, bin/auto-reset):"
# eq <name> <expected> <got>
# shellcheck source=lib/konsole.sh
. "$ROOT/lib/konsole.sh"
# shellcheck source=lib/handoff.sh
. "$ROOT/lib/handoff.sh"
SCREENS="$ROOT/test-data/screens"

# The guard, on six screens captured live on 2026-09-26. busy2 has a hint line
# between the spinner and the box, busy3 a tip: the first guard read those as
# idle. With --any, text in the box is no reason to wait: a prompt suggestion
# looks the same as the user's own words (ekko gotcha 784), and only typing
# tells them apart.
guard() { ctx_screen_idle "${2:-}" <"$SCREENS/$1.txt" >/dev/null && echo types || echo waits; }
eq "idle, empty box" types "$(guard idle)"
eq "busy" waits "$(guard busy)"
eq "busy, a hint line under the spinner" waits "$(guard busy2)"
eq "busy, a tip under the spinner" waits "$(guard busy3)"
eq "the user's half-typed text" waits "$(guard text)"
eq "permission dialog (Enter would approve)" waits "$(guard dialog)"
eq "idle, but /clear expected in the box" waits "$(guard idle /clear)"
RULE="────────────────────────────────────────"
typed_screen() { printf '✻ Crunched for 1s · done\n%s\n❯\xc2\xa0%s\n%s\n  ctx 15k\n' "$RULE" "$1" "$RULE"; }
eq "/clear typed, /clear expected" types "$(typed_screen /clear | ctx_screen_idle /clear >/dev/null && echo types || echo waits)"
eq "/clear typed after the user's text" waits "$(typed_screen 'abc/clear' | ctx_screen_idle /clear >/dev/null && echo types || echo waits)"
eq "--any, idle: an empty box" "" "$(ctx_screen_idle --any <"$SCREENS/idle.txt")"
eq "--any, text in the box: the text" "meio digitado" "$(ctx_screen_idle --any <"$SCREENS/text.txt")"
for s in busy busy2 busy3 dialog; do
  eq "--any, $s" waits "$(ctx_screen_idle --any <"$SCREENS/$s.txt" >/dev/null && echo types || echo waits)"
done
eq "--any, a box not at the ❯ prompt" waits \
  "$(printf '✻ Crunched for 1s · done\n%s\n! ls\n%s\n  ctx 15k\n' "$RULE" "$RULE" | ctx_screen_idle --any >/dev/null && echo types || echo waits)"

# rows <file> <tokens> <row>... -- a transcript: each row human:<minutes ago>[:uuid]
# or note:<minutes ago> (a background task's notification), then a
# main-thread call of <tokens>.
rows() {
  local f="$1" t="$2" r kind ago uuid
  shift 2
  : >"$f"
  for r in "$@"; do
    IFS=: read -r kind ago uuid <<<"$r"
    jq -nc --arg k "$kind" --argjson a "$ago" --arg u "${uuid:-u$RANDOM}" '
      {type: "user", uuid: $u,
       origin: {kind: (if $k == "human" then "human" else "task-notification" end)},
       timestamp: (now - $a * 60 | todate), message: {content: "x"}}' >>"$f"
  done
  jq -nc --argjson t "$t" '{type: "assistant", message: {usage: {input_tokens: 2,
    cache_creation_input_tokens: 1000, cache_read_input_tokens: ($t - 1002)}}}' >>"$f"
}
ago() { read -r at _ known <<<"$(ctx_last_human "$@")"; [ "$known" = 1 ] && echo $((($(date +%s) - at) / 60)) || echo unknown; }
rows "$TMP/p1.jsonl" 1000 human:30 note:5 note:1
eq "the user typed 30m ago; notifications since" 30 "$(ago "$TMP/p1.jsonl")"
rows "$TMP/p2.jsonl" 1000 human:30 human:2:mine note:1
echo mine >"$TMP/p2.typed"
eq "ctx's own typing is passed over" 30 "$(ago "$TMP/p2.jsonl" "$TMP/p2.typed")"
transcript "$TMP/p3.jsonl" 1000
eq "no origin on any row: unknown, never away" unknown "$(ago "$TMP/p3.jsonl")"

# The fake tab. State in $FK: box (the input box), sent (each sendText, %q),
# current (the transcript an Enter appends to), suggest (a prompt suggestion,
# shown while the box is empty, as Claude Code does), and flags deny, busy,
# dialog, meddle (the user types a 'u' after each text ctx types) and restless
# (the box changes at every reading).
FAKEBIN="$TMP/fakebin"
mkdir -p "$FAKEBIN"
cat >"$FAKEBIN/busctl" <<EOF
#!$(command -v bash)
set -u
F="\$FK" json=0
args=()
for a in "\$@"; do
  case "\$a" in --user) ;; --json=short) json=1 ;; *) args+=("\$a") ;; esac
done
# call <service> <path> <interface> <method> [signature argument]
[ "\${args[0]}" = call ] && [ "\${args[1]}" = fake.konsole ] && [ "\${args[2]}" = /Sessions/7 ] || exit 1
render() {
  if [ -e "\$F/dialog" ]; then cat "$SCREENS/dialog.txt"
  elif [ -e "\$F/busy" ]; then cat "$SCREENS/busy.txt"
  else printf '✻ Crunched for 1s · done\n%s\n❯\xc2\xa0%s\n%s\n  ctx 15k\n' "$RULE" "\$(shown)" "$RULE"
  fi
}
shown() {
  if [ -s "\$F/box" ]; then cat "\$F/box"
  elif [ -e "\$F/suggest" ]; then cat "\$F/suggest"
  fi
}
case "\${args[4]}" in
  foregroundProcessId) echo "i \$(cat "\$F/fg")" ;;
  getAllDisplayedText)
    [ -e "\$F/restless" ] && printf . >>"\$F/box"
    render | jq -Rsc '{type: "s", data: [.]}' ;;
  sendText)
    [ -e "\$F/deny" ] && { echo "Call failed: Access denied" >&2; exit 1; }
    # Another session of the same project, busy all along.
    [ -s "\$F/other" ] && echo '{"type":"assistant"}' >>"\$(cat "\$F/other")"
    t="\${args[6]:-}"
    printf '%q\n' "\$t" >>"\$F/sent"
    case "\$t" in
      '') ;;
      \$'\x15') : >"\$F/box" ;;
      \$'\x7f') b=\$(cat "\$F/box"); printf '%s' "\${b%?}" >"\$F/box" ;;
      \$'\r')
        b=\$(cat "\$F/box"); : >"\$F/box"
        if [ "\$b" = /clear ]; then
          n="\$(dirname "\$(cat "\$F/current")")/fresh-\$\$.jsonl"
          cat "$ROOT/test-data/cleared.jsonl" >"\$n"
          echo "\$n" >"\$F/current"
        elif [ -n "\$b" ]; then
          jq -nc --arg c "\$b" '{type: "user", uuid: "typed-row", origin: {kind: "human"},
            timestamp: (now | todate), message: {content: \$c}}' >>"\$(cat "\$F/current")"
        fi ;;
      *) printf '%s' "\$t" >>"\$F/box"
        if [ -e "\$F/meddle" ]; then printf u >>"\$F/box"; fi ;;
    esac ;;
  *) exit 1 ;;
esac
EOF
chmod +x "$FAKEBIN/busctl"
# A process named claude stands for Claude Code: the tab's foreground, and the
# ancestor hooks/handoff looks for.
ln -sf "$(command -v bash)" "$FAKEBIN/claude"

# tab <name> [flags...] -- a fresh fake tab around the transcript $TMP/ar-<name>/s-<name>.jsonl,
# with Claude Code (this shell, standing in) in the foreground.
tab() {
  FK="$TMP/fk-$1"
  rm -rf "$FK" "$TMP/ar-$1"
  mkdir -p "$FK" "$TMP/ar-$1"
  : >"$FK/box"
  echo "$TMP/ar-$1/s-$1.jsonl" >"$FK/current"
  echo "${FG:-$$}" >"$FK/fg"
  shift
  for f in "$@"; do : >"$FK/$f"; done
  export FK
}
AR="$ROOT/bin/auto-reset"
reset_env() { env -u CTX_DISABLE PATH="$FAKEBIN:$PATH" KONSOLE_DBUS_SERVICE=fake.konsole \
  KONSOLE_DBUS_SESSION=/Sessions/7 CTX_AUTO_RESET_WAIT="${WAIT:-4}" "$@"; }
sent() { tr '\n' ' ' <"$FK/sent" 2>/dev/null; }
said() { grep "\"sid\":\"$1\"" "$CTX_STATE/handoff.jsonl" 2>/dev/null | tail -1; }

tab a1
rows "$TMP/ar-a1/s-a1.jsonl" 300000 human:40
# Another session here began with a /clear of its own, and keeps writing.
cp "$ROOT/test-data/cleared.jsonl" "$TMP/ar-a1/other.jsonl"
echo "$TMP/ar-a1/other.jsonl" >"$FK/other"
reset_env "$AR" s-a1 "$TMP/ar-a1/s-a1.jsonl" $$
eq "types /clear, Enter, the prompt, Enter" "'' /clear \$'\\r' continuando \$'\\r' " "$(sent)"
has "...and logs the reset to the fresh session" present '"ev":"auto-reset","sid":"s-a1","to":"fresh-' "$(said s-a1)"
has "...noting the prompt's row as ctx's own" present "typed-row" "$(cat "$CTX_STATE"/auto/fresh-*.typed 2>/dev/null)"
has "...and its lock is gone" absent "s-a1.lock" "$(ls "$CTX_STATE/auto")"

tab a2 deny
rows "$TMP/ar-a2/s-a2.jsonl" 300000 human:40
reset_env "$AR" s-a2 "$TMP/ar-a2/s-a2.jsonl" $$
eq "Konsole refuses input: nothing typed" "" "$(sent)"
has "...logged" present "refuses typed input" "$(said s-a2)"

FG=1 tab a3
rows "$TMP/ar-a3/s-a3.jsonl" 300000 human:40
reset_env "$AR" s-a3 "$TMP/ar-a3/s-a3.jsonl" $$
eq "another process in the tab: nothing typed" "'' " "$(sent)"
has "...logged" present "not this session" "$(said s-a3)"

for state in dialog busy; do
  tab "a-$state" "$state"
  rows "$TMP/ar-a-$state/s-a-$state.jsonl" 300000 human:40
  WAIT=3 reset_env "$AR" "s-a-$state" "$TMP/ar-a-$state/s-a-$state.jsonl" $$
  eq "$state for the whole wait: nothing typed" "'' " "$(sent)"
done
has "...the dialog is why" present "a dialog is open" "$(said s-a-dialog)"

# Text in the box may be a prompt suggestion, which typing replaces, or the
# user's own, which typing adds to: /clear is typed, and taken back when the
# box then holds more.
bs6=$(for _ in 1 2 3 4 5 6; do printf '%q ' $'\x7f'; done)
tab a4
printf 'meio digitado' >"$FK/box"
rows "$TMP/ar-a4/s-a4.jsonl" 300000 human:40
WAIT=3 reset_env "$AR" s-a4 "$TMP/ar-a4/s-a4.jsonl" $$
eq "the user's half-typed text: /clear, taken back" "'' /clear $bs6" "$(sent)"
eq "...the box as it was" "meio digitado" "$(cat "$FK/box")"
has "...logged" present "taken back" "$(said s-a4)"

tab a6
printf 'roda em segundo plano' >"$FK/suggest"
rows "$TMP/ar-a6/s-a6.jsonl" 300000 human:40
reset_env "$AR" s-a6 "$TMP/ar-a6/s-a6.jsonl" $$
eq "a prompt suggestion in the box: typed over" "'' /clear \$'\\r' continuando \$'\\r' " "$(sent)"
has "...and the reset logged" present '"ev":"auto-reset","sid":"s-a6"' "$(said s-a6)"

tab a7 meddle
printf 'meio digitado' >"$FK/box"
rows "$TMP/ar-a7/s-a7.jsonl" 300000 human:40
WAIT=3 reset_env "$AR" s-a7 "$TMP/ar-a7/s-a7.jsonl" $$
eq "the user types as ctx types: nothing taken back" "'' /clear " "$(sent)"
has "...logged" present "left as it was" "$(said s-a7)"

tab a8 restless
rows "$TMP/ar-a8/s-a8.jsonl" 300000 human:40
WAIT=3 reset_env "$AR" s-a8 "$TMP/ar-a8/s-a8.jsonl" $$
eq "the box changes at every reading: nothing typed" "'' " "$(sent)"
has "...logged" present "changed between readings" "$(said s-a8)"

# Past the cap on the 5-hour window, the /clear and not the prompt: the fresh
# session waits for the user (ekko task 808).
CLAUDE_CONFIG_DIR="$TMP/profile-c" ctx_window_merge 90 "$at1" 40
tab a9
rows "$TMP/ar-a9/s-a9.jsonl" 300000 human:40
reset_env CLAUDE_CONFIG_DIR="$TMP/profile-c" "$AR" s-a9 "$TMP/ar-a9/s-a9.jsonl" $$
eq "past the cap: /clear, and not the prompt" "'' /clear \$'\\r' " "$(sent)"
has "...logged as held" present '"held":"cap"' "$(said s-a9)"

tab a5 busy
rows "$TMP/ar-a5/s-a5.jsonl" 300000 human:40
WAIT=8 reset_env "$AR" s-a5 "$TMP/ar-a5/s-a5.jsonl" $$ &
sleep 1.5
rows "$TMP/ar-a5/new.jsonl" 300000 human:0
cat "$TMP/ar-a5/new.jsonl" >>"$TMP/ar-a5/s-a5.jsonl"
rm -f "$FK/busy"
wait
eq "the user types while it waits: nothing typed" "'' " "$(sent)"
has "...logged" present "the user typed" "$(said s-a5)"

# The Stop hook decides; run under a process named claude, as Claude Code runs it.
# stop_auto <session> <stop json> [env...] -- the hook's output, in a Konsole tab
# of an interactive session unless the env says otherwise.
stop_auto() {
  local j="$2"
  shift 2
  # shellcheck disable=SC2016 # $0 is the hook, for the inner shell
  printf '%s' "$j" | env -u CTX_DISABLE -u CTX_HANDOFF_TOKENS -u CTX_HANDOFF_5H -u CTX_AUTO_RESET_IDLE \
    PATH="$FAKEBIN:$PATH" KONSOLE_DBUS_SERVICE=fake.konsole KONSOLE_DBUS_SESSION=/Sessions/7 \
    CTX_AUTO_RESET_WAIT=4 CLAUDE_CODE_ENTRYPOINT=cli "$@" "$FAKEBIN/claude" -c '"$0"; true' "$HO" 2>&1
}
# fresh_handoff <session> <tokens> -- as hooks/handoff-written leaves it
fresh_handoff() { mkdir -p "$CTX_STATE/handoff" && echo "$2" >"$CTX_STATE/handoff/$1.written"; }
# settled <session> -- the detached reset's last word, waited for
settled() {
  for _ in $(seq 1 40); do
    said "$1" | grep -q -E '"ev":"auto-reset(-stop)?"' && break
    sleep 0.25
  done
  said "$1"
}

FG=$$ tab h1
rows "$TMP/ar-h1/s-h1.jsonl" 262000 human:40 note:1
fresh_handoff s-h1 258000
out=$(stop_auto s-h1 "$(stop_json s-h1 "$TMP/ar-h1/s-h1.jsonl" true 1)")
is "alone, handoff fresh: quiet" quiet "$out"
has "...the reset starts" present '"ev":"auto-reset-start","sid":"s-h1"' "$(cat "$CTX_STATE/handoff.jsonl")"
last=$(settled s-h1)
has "...a hook of ours reaches the fake tab" present '"ev":"auto-reset-stop"' "$last"
has "...and stops there: this shell is no Claude Code" present "not this session" "$last"

tab h2
rows "$TMP/ar-h2/s-h2.jsonl" 262000 human:2
fresh_handoff s-h2 258000
stop_auto s-h2 "$(stop_json s-h2 "$TMP/ar-h2/s-h2.jsonl")" >/dev/null
has "user typed 2m ago: no reset" absent '"sid":"s-h2","tokens"' \
  "$(grep auto-reset-start "$CTX_STATE/handoff.jsonl")"

tab h3
rows "$TMP/ar-h3/s-h3.jsonl" 262000 human:40 note:1
out=$(stop_auto s-h3 "$(stop_json s-h3 "$TMP/ar-h3/s-h3.jsonl" false 1)")
is "alone, a shell running, no handoff: asks" ask "$out"
has "...saying ctx types the /clear" present "ctx types /clear and 'continuando'" "$out"
has "...and to name the running tasks" present "name each in the handoff" "$out"
is "present, a shell running: quiet, as before" quiet \
  "$(rows "$TMP/ar-h3/p.jsonl" 262000 human:1 && stop_auto s-h3p "$(stop_json s-h3p "$TMP/ar-h3/p.jsonl" false 1)")"
cron_json=$(stop_json s-h4 "$TMP/ar-h3/s-h3.jsonl" | jq -c '.session_crons = [{id: "c1", schedule: "*/5 * * * *", recurring: true, prompt: "check"}]')
is "alone, a wakeup scheduled: quiet" quiet "$(stop_auto s-h4 "$cron_json")"
out=$(stop_auto s-h5 "$(stop_json s-h5 "$TMP/ar-h3/s-h3.jsonl")" CLAUDE_CODE_ENTRYPOINT=sdk-cli)
is "claude -p: never alone, nothing asked" quiet "$out"
out=$(stop_auto s-h6 "$(stop_json s-h6 "$TMP/ar-h3/s-h3.jsonl")" KONSOLE_DBUS_SESSION=)
is "outside Konsole: never alone, nothing asked" quiet "$out"
out=$(stop_auto s-h7 "$(stop_json s-h7 "$TMP/ar-h3/s-h3.jsonl")" CTX_AUTO_RESET_IDLE=0)
is "CTX_AUTO_RESET_IDLE=0: never alone, nothing asked" quiet "$out"
transcript "$TMP/ar-h3/old.jsonl" 262000
out=$(stop_auto s-h8 "$(stop_json s-h8 "$TMP/ar-h3/old.jsonl")")
is "no origin in the transcript: never alone, nothing asked" quiet "$out"
out=$(stop_auto s-h9 "$(stop_json s-h9 "$TMP/ar-h3/s-h3.jsonl")" CLAUDE_CONFIG_DIR="$TMP/profile-c")
has "alone past the cap: the /clear, not 'continuando'" present "ctx types /clear into this session's tab, and not 'continuando'" "$out"
has "...and what the cap asks" present "Past the cap the rest of the window is the user's reserve" "$out"

# --- cold return (UserPromptSubmit) -------------------------------------------------
# A prompt that comes back to a big session past the cache's hour is stopped
# once, with the cost and the handoff's age; sent again it goes through, and so
# does a slash command. The hook is off by default (ekko task 929): `cr` runs it
# with the defaults, `on` at 250k, the value the README gives to turn it on.
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
on() { cr CTX_COLD_TOKENS=250000 "$@"; }
# back <session> <tokens> <minutes idle> [prompt] -- a new transcript each time
back() {
  ctr "$TMP/cr-$1.jsonl" "$2" "$3"
  prompt_json "$1" "$TMP/cr-$1.jsonl" "${4:-go on}" | on
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

ctr "$TMP/cr-off.jsonl" 530000 90
guarded "off by default: 530k, idle 90m, passes" pass "$(prompt_json off1 "$TMP/cr-off.jsonl" | cr)"
has "...and logs nothing" absent '"sid":"off1"' "$(cat "$CTX_STATE/handoff.jsonl" 2>/dev/null)"
guarded "240k, idle 2h: passes" pass "$(back c1 240000 120)"
guarded "344k, idle 59m: passes" pass "$(back c2 344000 59)"
out=$(back c3 344000 72)
guarded "344k, idle 72m: stops" stop "$out"
has "says how long it sat idle" present "idle 1h12m" "$(crwhy "$out")"
has "names the context to re-write" present "all 344k tokens" "$(crwhy "$out")"
has "prices going on as a multiple of starting over" present "going on here costs ~1.6 times what starting over does" "$(crwhy "$out")"
has "...in no points: their price in units moves" absent "point" "$(crwhy "$out")"
has "no handoff: the board as it is" present "No handoff from this session" "$(crwhy "$out")"
has "offers /clear" present "/clear" "$(crwhy "$out")"
has "a subagent's 900k is not the context" absent "900k" "$(crwhy "$out")"
guarded "...sent again: passes" pass "$(prompt_json c3 "$TMP/cr-c3.jsonl" "go on, then" | on)"
has "the stop is logged" present '"ev":"cold-stop"' "$(cat "$CTX_STATE/handoff.jsonl" 2>/dev/null)"
has "...and the prompt sent again" present '"ev":"cold-pass"' "$(cat "$CTX_STATE/handoff.jsonl" 2>/dev/null)"
guarded "more work, then a new pause: stops again" stop "$(back c3 350000 65)"
guarded "a slash command passes" pass "$(back c4 344000 90 "/handoff")"
guarded "...with a space before it too" pass "$(back c4 344000 90 " /handoff")"
mkdir -p "$CTX_STATE/cold" && : >"$CTX_STATE/cold/c10.scheduled"
guarded "a wakeup or background work pending: passes" pass "$(back c10 344000 90)"
has "...and is logged" present '"ev":"cold-scheduled"' "$(cat "$CTX_STATE/handoff.jsonl" 2>/dev/null)"
printf '340000\n' >"$CTX_STATE/handoff/c5.written"
out=$(crwhy "$(back c5 344000 90)")
has "fresh handoff: holds the session" present "handoff written 4k tokens ago holds this session" "$out"
has "...and says /handoff is not needed: it pays the rewrite" present "no /handoff needed (it costs this same rewrite)" "$out"
printf '264000\n' >"$CTX_STATE/handoff/c6.written"
has "stale handoff: its age" present "last handoff is 80k tokens old" "$(crwhy "$(back c6 344000 90)")"
printf '400000\n' >"$CTX_STATE/handoff/c7.written"
has "handoff from before a compaction: says so" present "from before a compaction" \
  "$(crwhy "$(back c7 344000 90)")"
has "three days away: in days" present "idle 3 days" "$(crwhy "$(back c8 344000 4320)")"
has "530k: ~2.5 times" present "costs ~2.5 times what" "$(crwhy "$(back c9 530000 90)")"
has "under 1, with a lower threshold: ~0.7 times" present "costs ~0.7 times what" \
  "$(crwhy "$(ctr "$TMP/cr-c11.jsonl" 150000 90 && prompt_json c11 "$TMP/cr-c11.jsonl" | env -u CTX_DISABLE -u CTX_COLD_MINUTES -u CTX_HANDOFF_TOKENS CTX_COLD_TOKENS=100000 "$CR" 2>&1)")"
guarded "missing transcript: passes" pass "$(prompt_json d1 "$TMP/none.jsonl" | on)"
ctr "$TMP/cr-x.jsonl" 344000 90
guarded "session id with a slash: passes" pass "$(prompt_json ../x "$TMP/cr-x.jsonl" | on)"
guarded "CTX_DISABLE=1: passes" pass "$(prompt_json x1 "$TMP/cr-x.jsonl" | on CTX_DISABLE=1)"
guarded "CTX_COLD_TOKENS=0: passes" pass "$(prompt_json x2 "$TMP/cr-x.jsonl" | cr CTX_COLD_TOKENS=0)"
guarded "CTX_COLD_MINUTES=0: passes" pass "$(prompt_json x3 "$TMP/cr-x.jsonl" | on CTX_COLD_MINUTES=0)"
guarded "CTX_COLD_MINUTES=120: 90m passes" pass "$(prompt_json x4 "$TMP/cr-x.jsonl" | on CTX_COLD_MINUTES=120)"
ctr "$TMP/cr-w.jsonl" 344000 17
has "CTX_COLD_MINUTES=10: 17m, in minutes" present "idle 17m, and the prompt cache has expired" \
  "$(crwhy "$(prompt_json w1 "$TMP/cr-w.jsonl" | on CTX_COLD_MINUTES=10)")"
guarded "state that cannot be written: passes" pass \
  "$(prompt_json x5 "$TMP/cr-x.jsonl" | on CTX_STATE="$TMP/big.ts/state")"
ctr "$TMP/cr-y.jsonl" 120000 90
guarded "CTX_COLD_TOKENS=100000: 120k stops" stop "$(prompt_json y1 "$TMP/cr-y.jsonl" | cr CTX_COLD_TOKENS=100000)"
jq -nc '{type: "assistant", message: {usage: {input_tokens: 344000}}}' >"$TMP/cr-z.jsonl"
guarded "a call with no time on it: passes" pass "$(prompt_json z1 "$TMP/cr-z.jsonl" | on)"
out=$(
  printf 'not json' | on
  echo "rc=$?"
)
has "malformed input: exit 0" present "rc=0" "$out"
has "malformed input: nothing printed" absent "{" "$out"

# --- work-loss guard (PreToolUse on Bash) -------------------------------------------
# Each rule runs against a repository state that would lose work and one that
# would not: a guard that refuses on the command's name alone fails here. $TMP
# is under /tmp, a scratch root, so the scratch roots move elsewhere for these.
echo "work-loss guard (PreToolUse on Bash):"
WL="$TMP/wl"
export CTX_GUARD_SCRATCH="$TMP/scratch"
wl_json() { jq -nc --arg c "$1" --arg d "${2:-$WL/repo}" '{tool_name:"Bash",tool_input:{command:$c},cwd:$d,session_id:"suite"}'; }
g() { git -C "${GD:-$WL/repo}" -c user.name=suite -c user.email=suite@ctx "$@" >/dev/null 2>&1; }
wl() { check "$1" "$2" guard-work-loss "$(wl_json "$3" "${4:-}")"; }
mkdir -p "$WL" "$TMP/scratch" "$TMP/plain" && echo x >"$TMP/plain/x"
git init -q --bare -b main "$WL/remote.git"
git init -q -b main "$WL/repo"
printf 'one\n' >"$WL/repo/a.txt" && printf 'two\n' >"$WL/repo/b.txt" && printf 'build/\n' >"$WL/repo/.gitignore"
g add -A && g commit -q -m first && g remote add origin "$WL/remote.git" && g push -q -u origin main && g remote set-head origin main

wl "reset --hard, clean tree" allow 'git reset --hard'
printf 'changed\n' >"$WL/repo/a.txt"
wl "reset --hard, a.txt changed" deny 'git reset --hard'
wl "a stray = before it, which broke the lexer" deny '= y; git reset --hard'
wl "checkout -- a.txt, changed" deny 'git checkout -- a.txt'
wl "checkout -- b.txt, unchanged" allow 'git checkout -- b.txt'
wl "checkout HEAD a.txt, no --" deny 'git checkout HEAD a.txt'
wl "checkout ." deny 'git checkout .'
wl "checkout main, a switch" allow 'git checkout main'
wl "restore a.txt" deny 'git restore a.txt'
wl "restore --staged a.txt" allow 'git restore --staged a.txt'
wl "switch --discard-changes" deny 'git switch --discard-changes main'
wl "git rm -f a.txt" deny 'git rm -f a.txt'
wl "git stash push -u, then reset: one command" allow 'git stash push -u && git reset --hard'
wl "echo names it" allow 'echo "git reset --hard"'
wl "a here-document names it" allow "$(printf 'cat <<EOF\ngit reset --hard\nEOF')"
wl "bash -c" deny "bash -c 'git reset --hard'"
wl "cd into the repository first" deny "cd $WL/repo && git reset --hard" "$TMP"
wl "git -C the repository" deny "git -C $WL/repo reset --hard" "$TMP"
CTX_GUARD_SCRATCH="$WL" wl "the repository under a scratch root" allow 'git reset --hard'
g checkout -- a.txt

printf 'x\n' >"$WL/repo/new.txt"
wl "clean -fd, an untracked file" deny 'git clean -fd'
wl "clean -nd, a dry run" allow 'git clean -nd'
rm "$WL/repo/new.txt" && mkdir -p "$WL/repo/build" && echo o >"$WL/repo/build/out"
wl "clean -fd, only ignored files" allow 'git clean -fd'
wl "clean -fdx, ignored files" deny 'git clean -fdx'

printf 'stashed\n' >"$WL/repo/b.txt" && g stash push -q -m keepme
wl "stash drop, changes nowhere else" deny 'git stash drop'
wl "stash clear, changes nowhere else" deny 'git stash clear'
g stash apply -q
wl "stash drop, changes in the work tree" allow 'git stash drop'
g stash drop -q && g checkout -- b.txt

g checkout -q -b feat && echo f >"$WL/repo/f.txt" && g add f.txt && g commit -q -m feat && g checkout -q main
wl "branch -D, a commit only it has" deny 'git branch -D feat'
wl "branch -d, git refuses itself" allow 'git branch -d feat'
g push -q origin feat
wl "branch -D, pushed" allow 'git branch -D feat'
# wlwhy <command> -- the reason the guard gives, for a refusal.
wlwhy() { printf '%s' "$(wl_json "$1")" | env -u CTX_DISABLE "$HOOKS/guard-work-loss" 2>&1; }
# A commit whose patch another branch holds, rebased or cherry-picked there, is
# not lost with its branch (ekko task 891); one changed after the copy is, and
# so is a merge, which has no patch of its own to match. main moves first: a
# pick onto the commit's own parent within the same second is that very commit.
g checkout -q -b copied && echo c >"$WL/repo/c.txt" && g add c.txt && g commit -q -m copied &&
  g checkout -q main && echo m >"$WL/repo/m.txt" && g add m.txt && g commit -q -m "main moves" &&
  g cherry-pick copied && g push -q origin main
wl "branch -D, its commit copied to main" allow 'git branch -D copied'
g checkout -q copied && echo more >>"$WL/repo/c.txt" && g commit -q -am "changed after the copy" && g checkout -q main
wl "branch -D, a commit changed after the copy" deny 'git branch -D copied'
has "...counts only that one, the newest" present "copied (1 commit(s), newest: changed after the copy)" \
  "$(wlwhy 'git branch -D copied')"
g checkout -q -b merged copied~1 && g merge -q --no-ff -m "merge main" main && g checkout -q main
wl "branch -D, a merge only it has" deny 'git branch -D merged'
g branch -D copied merged

g worktree add -q "$WL/wt" -b wtb && echo w >"$WL/wt/w.txt"
wl "worktree remove --force, an untracked file" deny "git worktree remove --force $WL/wt"
rm "$WL/wt/w.txt"
wl "worktree remove --force, clean" allow "git worktree remove --force $WL/wt"
g worktree remove --force "$WL/wt"

git clone -q "$WL/remote.git" "$WL/other" && GD="$WL/other" g commit -q --allow-empty -m theirs && GD="$WL/other" g push -q origin main && g fetch -q origin
wl "push --force origin main, drops a remote commit" deny 'git push --force origin main'
wl "push +main, the same" deny 'git push origin +main'
wl "push --delete origin main" deny 'git push --delete origin main'
wl "push --force-with-lease origin feat" allow 'git push --force-with-lease origin feat'
wl "push origin main, no force" allow 'git push origin main'
g merge -q --ff-only origin/main
wl "push --force origin main, a fast-forward" allow 'git push --force origin main'

mkdir -p "$WL/repo/sub" && echo u >"$WL/repo/sub/u.txt"
wl "rm -rf a folder with an untracked file" deny 'rm -rf sub'
wl "rm -rf an ignored build folder" allow 'rm -rf build'
wl "rm -f a file: not recursive" allow 'rm -f sub/u.txt'
rm -rf "$WL/repo/sub"
g commit -q --allow-empty -m local
wl "rm -rf a repository with an unpushed commit" deny "rm -rf $WL/repo" "$TMP"
wl "rm -rf .git, an unpushed commit" deny 'rm -rf .git'
wl "rm -rf through a variable" deny "S=$WL; rm -rf \"\$S/repo\"" "$TMP"
wl "rm -rf a folder holding that repository" deny "rm -rf $WL" "$TMP"
wl "rm -rf outside any repository" allow 'rm -rf plain' "$TMP"
g push -q origin main
wl "rm -rf a pushed, clean repository" allow "rm -rf $WL/repo" "$TMP"
wl "rm -rf .git, pushed and clean" allow 'rm -rf .git'
# The same rule for a whole repository: a local commit whose patch a remote
# holds is kept there; one changed after the copy is not.
g checkout -q -b local-copy && echo l >"$WL/repo/l.txt" && g add l.txt && g commit -q -m "local copy" &&
  g checkout -q main && echo n >"$WL/repo/n.txt" && g add n.txt && g commit -q -m "main moves again" &&
  g cherry-pick local-copy && g push -q origin main
wl "rm -rf a repository, its local commit pushed as a copy" allow "rm -rf $WL/repo" "$TMP"
wl "rm -rf .git, the same" allow 'rm -rf .git'
g checkout -q local-copy && echo more >>"$WL/repo/l.txt" && g commit -q -am "changed after the copy" && g checkout -q main
wl "rm -rf a repository, a commit changed after the copy" deny "rm -rf $WL/repo" "$TMP"
has "...counts only that one" present "1 commit(s) on local branches" "$(wlwhy 'rm -rf .git')"
g branch -D local-copy
has "a refusal goes to guard.jsonl" present '"ev": "guard-refuse"' "$(cat "$CTX_STATE/guard.jsonl" 2>/dev/null)"
has "a pass goes to guard.jsonl" present '"ev": "guard-pass"' "$(cat "$CTX_STATE/guard.jsonl" 2>/dev/null)"
unset CTX_GUARD_SCRATCH GD

# --- secrets guard (PreToolUse on Read, Grep and Bash) ------------------------------
# Each rule against a file that is secret and one that is not, and each command
# that prints a secret with its output shown and sent elsewhere. HOME and the
# secret roots move into $TMP, so nothing real is read.
echo "secrets guard (PreToolUse on Read, Grep and Bash):"
SEC="$TMP/sec"
SH="$SEC/home"
mkdir -p "$SH/.ssh" "$SH/.claude-x" "$SH/.config/gh" "$SEC/persist" "$SEC/plain" "$SEC/repo/src" "$SEC/repo/keys"
printf -- '-----BEGIN OPENSSH PRIVATE KEY-----\nfake\n-----END OPENSSH PRIVATE KEY-----\n' >"$SH/.ssh/id_ed25519"
echo 'ssh-ed25519 AAAA fake' >"$SH/.ssh/id_ed25519.pub" && echo 'Host x' >"$SH/.ssh/config"
echo '{"claudeAiOauth":{}}' >"$SH/.claude-x/.credentials.json" && echo '{}' >"$SH/.claude-x/settings.json"
echo 'github.com: {oauth_token: fake}' >"$SH/.config/gh/hosts.yml"
echo 'machine x login y password z' >"$SH/.netrc"
echo 'fake' >"$SEC/persist/github-token"
echo 'KEY=1' >"$SEC/plain/.env.local"
git init -q -b main "$SEC/repo"
printf '.env\n' >"$SEC/repo/.gitignore" && echo 'TEMPLATE=1' >"$SEC/repo/.env.development"
echo 'const x = 1' >"$SEC/repo/src/app.ts"
GD="$SEC/repo" g add -A && GD="$SEC/repo" g commit -q -m first
echo 'API_KEY=fake' >"$SEC/repo/.env" && echo 'API_KEY=' >"$SEC/repo/.env.example"
echo 'AGE-SECRET-KEY-1FAKE' >"$SEC/repo/keys/age-combined-identity.txt"

sec_read() { jq -nc --arg p "$1" --arg d "$SEC/repo" '{tool_name:"Read",tool_input:{file_path:$p},cwd:$d,session_id:"suite"}'; }
sec_grep() {
  jq -nc --arg p "$1" --arg m "$2" --arg g "${3:-}" --arg d "$SEC/repo" \
    '{tool_name:"Grep",tool_input:({pattern:"KEY",path:$p,output_mode:$m} + if $g == "" then {} else {glob:$g} end),cwd:$d,session_id:"suite"}'
}
sec_bash() { jq -nc --arg c "$1" --arg d "${2:-$SEC/repo}" '{tool_name:"Bash",tool_input:{command:$c},cwd:$d,session_id:"suite"}'; }
sg() { HOME="$SH" CTX_SECRET_ROOTS="$SEC/persist" check "$1" "$2" guard-secrets "$3"; }
sb() { sg "$1" "$2" "$(sec_bash "$3" "${4:-}")"; }

sg "Read an SSH private key" deny "$(sec_read "$SH/.ssh/id_ed25519")"
sg "Read its public half" allow "$(sec_read "$SH/.ssh/id_ed25519.pub")"
sg "Read ~/.ssh/config" allow "$(sec_read "$SH/.ssh/config")"
sg "Read a file under a secret root" deny "$(sec_read "$SEC/persist/github-token")"
sg "Read Claude Code's .credentials.json" deny "$(sec_read "$SH/.claude-x/.credentials.json")"
sg "Read Claude Code's settings.json" allow "$(sec_read "$SH/.claude-x/settings.json")"
sg "Read gh's hosts.yml" deny "$(sec_read "$SH/.config/gh/hosts.yml")"
sg "Read ~/.netrc" deny "$(sec_read "$SH/.netrc")"
sg "Read an age identity" deny "$(sec_read "$SEC/repo/keys/age-combined-identity.txt")"
sg "Read an untracked, ignored .env" deny "$(sec_read "$SEC/repo/.env")"
sg "Read a tracked .env.development" allow "$(sec_read "$SEC/repo/.env.development")"
sg "Read an untracked .env.example" allow "$(sec_read "$SEC/repo/.env.example")"
sg "Read a .env.local outside any repository" deny "$(sec_read "$SEC/plain/.env.local")"
sg "Read a source file" allow "$(sec_read "$SEC/repo/src/app.ts")"

sg "Grep content over a folder holding a .env" deny "$(sec_grep "$SEC/repo" content)"
sg "Grep files_with_matches over it" allow "$(sec_grep "$SEC/repo" files_with_matches)"
sg "Grep content, glob *.ts" allow "$(sec_grep "$SEC/repo" content '*.ts')"
sg "Grep content of the .env itself" deny "$(sec_grep "$SEC/repo/.env" content)"

sb "cat .env" deny 'cat .env'
sb "cat .env.development, tracked" allow 'cat .env.development'
sb "cat .env > file" allow 'cat .env > /dev/null'
sb "ls, stat, test -e, wc -l on it" allow 'ls -la .env* && stat .env && test -e .env && wc -l .env'
sb "grep -c KEY .env" allow 'grep -c KEY .env'
sb "grep KEY .env" deny 'grep KEY .env'
sb "grep -rn KEY ." deny 'grep -rn KEY .'
sb "grep -rn KEY, no path" deny 'grep -rn KEY'
sb "grep -rn --include=*.ts KEY ." allow "grep -rn --include='*.ts' KEY ."
sb "grep -rn KEY src" allow 'grep -rn KEY src'
sb "grep -rn over it, matching nothing in .env" allow 'grep -rn "const x" .'
sb "grep -oE names only from .env" allow "grep -oE '^[A-Z_]+=' .env"
sb "grep -E a name and its value from .env" deny "grep -E '^API_KEY=' .env"
sb "grep -v, every other line of .env" deny "grep -v '^#' .env"
sb "grep -E matching nothing in .env" allow "grep -E '^MISSING=' .env"
sb "rg KEY: hidden files skipped" allow 'rg KEY'
sb "rg --hidden KEY" deny 'rg --hidden KEY'
sb "rg KEY .env, named" deny 'rg KEY .env'
sb "grep for the words /persist/secrets" allow "grep -rn $SEC/persist src"
sb "sed -n 1p .env" deny 'sed -n 1p .env'
sb "sed -i on .env" allow "sed -i 's/1/2/' .env"
sb "jq on .credentials.json" deny 'jq . ~/.claude-x/.credentials.json'
sb "jq's .env filter on settings.json" allow "jq '.env.X' ~/.claude-x/settings.json"
sb "cat < ~/.netrc" deny 'cat < ~/.netrc'
sb "cat .env | wc -l: a pipe counts as shown" deny 'cat .env | wc -l'
sb "cat .env | wc -l > file" allow 'cat .env | wc -l > /dev/null'
sb "bash -c 'cat .env'" deny "bash -c 'cat .env'"
sb "bash -c 'cat .env' > file" allow "bash -c 'cat .env' > /dev/null"
sb "echo names it" allow 'echo "cat .env"'
sb "a stray = before it" deny '= y; cat .env'
sb "an escaped backtick inside quotes" allow 'grep -rnoE "a[\`]b" src'
sb "a here-document names it" allow "$(printf 'cat <<EOF\ncat .env\nEOF')"
sb "sourcing .env" allow '. ./.env && true'
sb "diff <(cat .env) .env.example" deny 'diff <(cat .env) .env.example'
sb "diff -q .env .env.example" allow 'diff -q .env .env.example'
sb "cd ~/.ssh && cat id_ed25519" deny 'cd ~/.ssh && cat id_ed25519'
sb "cat ~/.ssh/*.pub" allow 'cat ~/.ssh/*.pub'
sb "cat ~/.ssh/*" deny 'cat ~/.ssh/*'
sb "grep -r over the home folder" deny 'grep -r token ~'
sb "rg over the home folder: hidden skipped" allow 'rg token ~'
sb "openssl pkey -in a private key" deny 'openssl pkey -in ~/.ssh/id_ed25519'
sb "dd if=.env" deny 'dd if=.env'
sb "cat under a secret root" deny "cat $SEC/persist/github-token"
sb "ls a secret root" allow "ls -la $SEC/persist"
sb "bwrap --tmpfs over a secret root" allow "bwrap --tmpfs $SEC/persist --ro-bind / / true"

# Every reader in READERS, on the untracked .env; API is the pattern, script or
# filter for the ones that take one first, and a missing file for the rest.
readers=$(python3 -c "import sys; sys.path.insert(0, '$HOOKS/../lib'); import guard_secrets as g; print(' '.join(sorted(g.READERS - {'dd', 'openssl'})))")
missed=""
for r in $readers; do
  out=$(sec_bash "$r API .env" | HOME="$SH" CTX_SECRET_ROOTS="$SEC/persist" env -u CTX_DISABLE "$HOOKS/guard-secrets")
  [ "$(verdict "$out")" = deny ] || missed+=" $r"
done
has "every reader in READERS refuses .env ($(wc -w <<<"$readers"))" absent " " "$missed"

sb "gh auth token" deny 'gh auth token'
sb "gh auth token inside \$(...)" allow 'NIX_CONFIG="access-tokens = github.com=$(gh auth token)" nix flake update x'
sb "gh auth token > file" allow 'gh auth token > /dev/null'
sb "gh auth status" allow 'gh auth status'
sb "gh auth status --show-token" deny 'gh auth status --show-token'
sb "sops -d" deny 'sops -d secrets.yaml'
sb "sops -d --output" allow 'sops -d --output out.yaml secrets.yaml'
sb "sops -e" allow 'sops -e plain.yaml'
sb "age -d" deny 'age -d -i key.txt f.age'
sb "age -d -o" allow 'age -d -i key.txt -o out f.age'
sb "gpg -d" deny 'gpg -d f.gpg'
sb "gpg --export-secret-keys -o" allow 'gpg --export-secret-keys -o out.asc'
sb "secret-tool lookup" deny 'secret-tool lookup service x'
sb "secret-tool store" allow 'secret-tool store --label=x service x'
sb "kwallet-query -r" deny 'kwallet-query -r x kdewallet'
sb "kwallet-query -l" allow 'kwallet-query -l kdewallet'
sb "pass show" deny 'pass show email/x'
sb "pass, a bare name" deny 'pass email/x'
sb "pass show -c" allow 'pass show -c email/x'
sb "pass ls" allow 'pass ls'
sb "git credential fill" deny "printf 'host=github.com\\n' | git credential fill"
sb "a commit message names gh auth token" allow 'git commit -q --allow-empty -m "gh auth token"'
has "a refusal goes to guard.jsonl" present '"ev": "secret-refuse"' "$(cat "$CTX_STATE/guard.jsonl" 2>/dev/null)"
has "a secret sent to a file goes to guard.jsonl" present '"ev": "secret-pass"' "$(cat "$CTX_STATE/guard.jsonl" 2>/dev/null)"

# --- ekko's answer, before a guard refuses (ekko task 805) ---------------------------
# A call either guard would refuse, asked of the fake ekko: it goes through only
# when ekko says the user let it, the refusal gains the sentence ekko gives, and
# without ekko, or when it cannot tell, the refusal stands as it was.
echo "ekko's answer, before a guard refuses:"
# ek <EKKO_FAKE> <hook> <input json>: the hook's output under that answer
ek() {
  printf '%s' "$3" | env -u CTX_DISABLE EKKO_FAKE="$1" EKKO_FAKE_LOG="$TMP/ekko.log" \
    CTX_GUARD_SCRATCH="$TMP/scratch" HOME="$SH" CTX_SECRET_ROOTS="$SEC/persist" "$HOOKS/$2" 2>&1
}
why() { printf '%s' "$1" | jq -r '.hookSpecificOutput.permissionDecisionReason // ""'; }
NOEKKO="$TMP/noekko"
mkdir -p "$NOEKKO"
for c in bash env cat dirname readlink python3 git; do
  p=$(command -v "$c" 2>/dev/null) && ln -sf "$p" "$NOEKKO/$c"
done
printf 'changed\n' >"$WL/repo/a.txt"
reset=$(wl_json 'git reset --hard')
: >"$TMP/ekko.log"
out=$(ek "" guard-work-loss "$reset")
eq "ekko cannot tell: refused as before" deny "$(verdict "$out")"
has "  and the reason gains nothing" absent "allow set to" "$(why "$out")"
has "ekko is asked with the guard's reason" present "--guard --refuse ctx's work-loss guard refused \`git reset --hard\`" "$(cat "$TMP/ekko.log")"
has "  and the call's event on stdin" present '"command": "git reset --hard"' "$(cat "$TMP/ekko.log")"
out=$(ek refused guard-work-loss "$reset")
eq "ekko keeps it refused: refused" deny "$(verdict "$out")"
has "  the reason still says what would be lost" present "it would destroy" "$(why "$out")"
eq "  and ends with ekko's sentence" 'If the user wants this exact call made anyway, ask them with allow set to "abc123".' \
  "$(why "$out" | tail -1)"
out=$(ek through guard-work-loss "$reset")
eq "ekko says the user let it through: passes" allow "$(verdict "$out")"
has "  logged as guard-excepted" present '"ev": "guard-excepted"' "$(cat "$CTX_STATE/guard.jsonl" 2>/dev/null)"
out=$(ek mute guard-work-loss "$reset")
eq "ekko fails without a word: refused as before" deny "$(verdict "$out")"
out=$(printf '%s' "$reset" | env -u CTX_DISABLE PATH="$NOEKKO" CTX_GUARD_SCRATCH="$TMP/scratch" "$HOOKS/guard-work-loss" 2>&1)
eq "no ekko on PATH: refused as before" deny "$(verdict "$out")"
has "  and the reason gains nothing" absent "allow set to" "$(why "$out")"
g checkout -q -- a.txt

: >"$TMP/ekko.log"
out=$(ek through guard-secrets "$(sec_read "$SH/.ssh/id_ed25519")")
eq "a secret's Read the user let through: passes" allow "$(verdict "$out")"
has "  logged as secret-excepted" present '"ev": "secret-excepted"' "$(cat "$CTX_STATE/guard.jsonl" 2>/dev/null)"
has "  ekko is asked about the Read itself" present '"file_path": "'"$SH/.ssh/id_ed25519"'"' "$(cat "$TMP/ekko.log")"
out=$(ek through guard-secrets "$(sec_grep "$SEC/repo" content)")
eq "a secret's Grep the user let through: passes" allow "$(verdict "$out")"
out=$(ek refused guard-secrets "$(sec_bash 'cat .env')")
eq "cat .env, kept refused: refused" deny "$(verdict "$out")"
has "  the reason ends with ekko's sentence" present 'allow set to "abc123"' "$(why "$out")"
out=$(ek "" guard-secrets "$(sec_bash 'cat .env')")
has "cat .env, ekko cannot tell: no sentence" absent "allow set to" "$(why "$out")"

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
