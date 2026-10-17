# graff detection, so the hooks can point at graff's map before graphify's.
#
# graff (github.com/thiagoproldan/graff) maps a git worktree's Rust, Nix, Bash,
# Python, C and Markdown: where a name is defined, what reaches it, what a file
# defines, each answer with file:line ranges. Its plugin brings its own MCP
# server and SessionStart announcement; what ctx adds is the outline on a denied
# read, so the next call reads one slice with offset and limit instead of the
# whole file. graphify (lib/graphify.sh) stays the fallback wherever graff is
# absent or reads no code, until graff's verdict decides between them (graff's
# task 26).
#
# Cost: graff_outline runs only on the hooks' DENY path, graff_announces only
# at SessionStart. An allowed read pays nothing for this.

# graff_outline <file>
# Echoes the denial's block with the file's outline: its symbols and their line
# ranges. Fails silently when graff is not on PATH, the file is outside a git
# worktree or in no language graff reads, it defines no symbol, or graff does
# not answer within CTX_GRAFF_TIMEOUT seconds.
graff_outline() {
  local file="$1" dir out timeout="${CTX_GRAFF_TIMEOUT:-10}"
  case "$timeout" in '' | *[!0-9]*) timeout=10 ;; esac

  # Suggesting a command that does not exist is worse than suggesting nothing.
  command -v graff >/dev/null 2>&1 || return 1

  dir=$(cd "$(dirname "$file")" 2>/dev/null && pwd) || return 1
  # A worktree's first question indexes it: 0.5-2.6 s cold on ~/NixOS, graff
  # and ekko, about 0.1 s warm (2026-10-17, load average ~20). The budget is
  # graff's own: past 1,000 tokens it leaves out nested symbols and says so.
  out=$(timeout "$timeout" graff outline -C "$dir" --budget 1000 "$file" 2>/dev/null) || return 1
  # "N lines, 0 symbols": nothing to slice by.
  case "$out" in *", 0 symbols"*) return 1 ;; esac

  # Two leading blank lines: command substitution eats the trailing one, so
  # without them the block glues onto the text above (as graphify_hint).
  printf '%s\n' "" "" \
    "graff's outline of this file, its symbols and their lines: read the slice you need with offset and limit." \
    "$out"
}

# graff_announces
# Succeeds when graff's own SessionStart hook speaks for the session whose hook
# input is on stdin: graff on PATH, and code it reads in the worktree. It asks
# graff's hook itself, with the same input and CLAUDE_PROJECT_DIR, so the two
# never disagree on what graff maps: 15-41 ms on ekko, graff, ctx and ~/NixOS.
graff_announces() {
  command -v graff >/dev/null 2>&1 || return 1
  [ -n "$(timeout 5 graff --hook 2>/dev/null)" ]
}
