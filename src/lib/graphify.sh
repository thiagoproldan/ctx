#!/usr/bin/env bash
# graphify index detection, so the hooks can suggest the graph before the worker.
#
# Why this exists: a structural question ("who calls X", "what does this module
# expose") is answered by graphify from the AST — deterministic, local, free per
# query. Delegating that to a cheap model pays for a worse answer. bulk-read is
# for what no graph indexes: logs, dumps, generated files, huge diffs.
#
# Cost: only called on the hooks' DENY path. An allowed read (the overwhelming
# majority) pays nothing for this.

# graphify_graph_path <start-dir>
# Echoes the project's graph.json path, or fails silently.
graphify_graph_path() {
  local dir="$1" out="${GRAPHIFY_OUT:-graphify-out}" i=0

  # GRAPHIFY_OUT takes a relative name ("graphify-out-feature") or an absolute
  # path ("/shared/graphify-out") — see graphify/paths.py.
  case "$out" in
  /*)
    [ -f "$out/graph.json" ] && {
      printf '%s' "$out/graph.json"
      return 0
    }
    return 1
    ;;
  esac

  # Bounded climb: the hook runs on every denied read, it cannot sweep the tree.
  while [ -n "$dir" ] && [ "$dir" != "/" ] && [ "$i" -lt 12 ]; do
    if [ -f "$dir/$out/graph.json" ]; then
      printf '%s' "$dir/$out/graph.json"
      return 0
    fi
    dir=$(dirname "$dir")
    i=$((i + 1))
  done
  return 1
}

# graphify_graphs_below <dir>
# Echoes one graph.json per line, found BELOW the directory.
#
# Exists for the folder-of-repos case: Claude opened in a directory holding three
# projects, each with its own graphify-out/. Climbing finds nothing (the graphs
# are one level down, not up), and the announcement would stay silent exactly
# where it helps most.
graphify_graphs_below() {
  local dir="$1" out="${GRAPHIFY_OUT:-graphify-out}"
  case "$out" in /*) return 1 ;; esac # an absolute path has no "below"
  # maxdepth 3 = exactly <repo>/<out>/graph.json. With 4 it reached two levels
  # down and announced half a dozen distant projects when opening a big folder.
  # No truncation here: whoever cuts the list must know the real total, or it
  # announces "8 projects" in a folder with 16. Cutting is the display's call.
  find "$dir" -maxdepth 3 \
    \( -name .git -o -name node_modules -o -name target -o -name .venv \) -prune -o \
    -path "*/$out/graph.json" -print 2>/dev/null | sort
}

# graphify_hint <file>
# Echoes the suggestion block, or nothing. Silence is the normal case.
graphify_hint() {
  local file="$1" dir graph stale=""

  # Suggesting a command that does not exist is worse than suggesting nothing.
  command -v graphify >/dev/null 2>&1 || return 0

  dir=$(cd "$(dirname "$file")" 2>/dev/null && pwd) || return 0
  graph=$(graphify_graph_path "$dir") || return 0

  # A stale index answers confidently about code that changed. Warn, don't hide
  # it, and don't block over it — stale is still useful for navigation.
  [ "$file" -nt "$graph" ] && stale='  (index is older than this file — `graphify .` refreshes it)'

  # Two leading blank lines: command substitution eats the trailing one, so
  # without them the block glues onto the text above.
  # Only `query` and `explain` — they answer "I was about to open this file to
  # understand it". `path` answers a different question; the skill documents it.
  printf '%s\n' \
    "" "" \
    "If the question is structural, this project's graph already answers it, free per query:" \
    "  graphify query \"<question>\" --graph ${graph}" \
    "  graphify explain \"<symbol>\" --graph ${graph}"
  # On its own line: hung off the end of the sentence above, it went unnoticed.
  [ -n "$stale" ] && printf '%s\n' "$stale"
  return 0
}
