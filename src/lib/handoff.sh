#!/usr/bin/env bash
# What the handoff hooks share: the context a session is at and when it last
# called, the one text that asks for a handoff, and where a written handoff is
# noted.
#
# The Stop hook (hooks/handoff) asks past the threshold, the user asks through
# /handoff (skills/handoff), hooks/handoff-written notes each handoff ekko
# writes, so that the status line can say how old it is, and hooks/cold-return
# points at it when a prompt would re-write an expired cache.

# ctx_context_tokens <transcript> -- the last main-thread call's input (input +
# cache writes + cache reads), read from the end of the transcript; 0 without
# one. A subagent's reply does not count, and neither does a line still being
# written, or any other line that is not JSON.
ctx_context_tokens() {
  local transcript="${1:-}" tokens=0
  if [ -n "$transcript" ] && [ -r "$transcript" ]; then
    tokens=$(tac -- "$transcript" 2>/dev/null | jq -nR '
      first(inputs | fromjson? | objects
            | select(.type == "assistant" and (.isSidechain | not)
                     and (.message.usage | type) == "object")
            | .message.usage
            | (.input_tokens // 0) + (.cache_creation_input_tokens // 0)
              + (.cache_read_input_tokens // 0)) // 0
    ' 2>/dev/null)
  fi
  case "$tokens" in '' | *[!0-9]*) tokens=0 ;; esac
  echo "$tokens"
}

# ctx_last_call <transcript> -- "<tokens> <epoch>": the last main-thread call's
# context, counted as ctx_context_tokens counts it, and when it was made, in
# seconds; "0 0" without one. A message Claude Code wrote itself (model
# <synthetic>: an API error, an interrupted turn) made no call and is passed
# over, like a subagent's reply.
ctx_last_call() {
  local transcript="${1:-}" out=""
  if [ -n "$transcript" ] && [ -r "$transcript" ]; then
    out=$(tac -- "$transcript" 2>/dev/null | jq -nrR '
      first(inputs | fromjson? | objects
            | select(.type == "assistant" and (.isSidechain | not)
                     and (.message.usage | type) == "object"
                     and .message.model != "<synthetic>")
            | [(.message.usage
                | (.input_tokens // 0) + (.cache_creation_input_tokens // 0)
                  + (.cache_read_input_tokens // 0)),
               (.timestamp // "" | tostring | sub("\\.[0-9]+"; "")
                | try fromdateiso8601 catch 0)]
            | map(floor | tostring) | join(" ")) // "0 0"
    ' 2>/dev/null)
  fi
  [[ "$out" =~ ^[0-9]+\ [0-9]+$ ]] || out="0 0"
  echo "$out"
}

# ctx_handoff_text <root> -- the ask, without the reason for it: the body of
# skills/handoff/SKILL.md, so the Stop hook and /handoff say the same thing.
ctx_handoff_text() {
  local text
  text=$(awk 'n >= 2 && (seen || NF) { seen = 1; print }
              n < 2 && /^---[[:space:]]*$/ { n++ }' "$1/skills/handoff/SKILL.md" 2>/dev/null)
  # Never an empty ask: without the skill file, the core of it.
  [ -n "$text" ] || text="Write a handoff (kind handoff) on the ekko task in progress, then tell the user in one line that /clear starts a fresh session from it."
  printf '%s\n' "$text"
}

# ctx_handoff_written <state> <session> -- the context at which this session
# last wrote a handoff, or nothing. The file is <state>/handoff/<session>.written,
# next to the Stop hook's book.
ctx_handoff_written() {
  local at=""
  [ -r "$1/handoff/$2.written" ] && read -r at <"$1/handoff/$2.written"
  case "$at" in '' | *[!0-9]*) ;; *) echo "$at" ;; esac
}
