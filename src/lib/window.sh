#!/usr/bin/env bash
# The account's 5-hour and 7-day windows, as the status line last saw them,
# and the caps on them (ekko task 808; the 7-day one, task 2 on ctx's board).
#
# The user's words, 2026-09-26: tell the model where the 5-hour limit stands,
# and put a cap at 85%, leaving 15% for emergencies or anything else. The cap
# is CTX_HANDOFF_5H (default 85; 0 turns it off), the same number past which a
# session running alone is asked for its handoff (hooks/handoff): past it a
# session starts nothing new, and the rest of the window is the user's. With
# the user there, nothing tells the model to write a handoff by itself (ekko
# task 961): that is the user's /handoff.
#
# The week has a cap of its own, CTX_HANDOFF_7D (default 95; 0 off), which
# does all the 5-hour cap does. At 100% of the week Claude Code stops
# answering until it resets, days later; one point of it cost 6-8 points of
# the 5-hour window, as measured on 2026-10-02, so 95%, floored, leaves 4-5
# points: some 24-40 points of a 5-hour window, the user's reserve.
#
# Only the status line is handed the rate limits: no hook's input carries
# them (Claude Code 2.1.283). So bin/statusline leaves a reading where every
# hook of every session on the account finds it, $CTX_STATE/window/<account>:
# one line, "<five> <resets> <seven> <seven_resets>" -- the 5-hour percentage,
# when that window ends (epoch seconds), the 7-day percentage and when that
# window ends, each "-" when unknown.
#
# A Claude Code profile is an account, named by its folder (CLAUDE_CONFIG_DIR,
# ~/.claude by default). Every session of the profile writes the same file,
# each with the numbers its own process last heard from the API, and an idle
# session's status line, refreshed every 30 seconds, repeats an old one.
# Usage never falls within a window, so the readings of one window keep the
# highest; a reading of a later window replaces the file, and one of an
# earlier window is dropped -- the week by its own end, since it can reset
# within a 5-hour window. A reading at the cap therefore stands until its
# window ends, however old it is, and a window that has ended reads as none.

# ctx_account -- the name of this profile's account: its folder's, without
# the leading dot, and only characters a file name can hold.
ctx_account() {
  local dir="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
  dir="${dir%/}"
  dir="${dir##*/}"
  dir="${dir#.}"
  dir="${dir//[^A-Za-z0-9._-]/_}"
  echo "${dir:-claude}"
}

# ctx_window_file -- where this account's reading is kept.
ctx_window_file() {
  echo "${CTX_STATE:-${XDG_STATE_HOME:-$HOME/.local/state}/ctx}/window/$(ctx_account)"
}

# ctx_window_cap [7d] -- the cap, in percent of the 5-hour window, or with 7d
# of the 7-day one; 0 when off.
ctx_window_cap() {
  if [ "${1:-}" = 7d ]; then
    case "${CTX_HANDOFF_7D:-}" in
    '' | *[!0-9]*) echo 95 ;;
    *) echo "$CTX_HANDOFF_7D" ;;
    esac
    return 0
  fi
  case "${CTX_HANDOFF_5H:-}" in
  '' | *[!0-9]*) echo 85 ;;
  *) echo "$CTX_HANDOFF_5H" ;;
  esac
}

# ctx_window -- "<five> <resets> <seven> <seven_resets>" while the 5-hour
# window read last has not ended; nothing otherwise. A week that has ended
# reads as unknown: "-" for both.
ctx_window() {
  local five="" resets="" seven="" seven_resets="" file now
  file=$(ctx_window_file)
  [ -r "$file" ] && read -r five resets seven seven_resets _ <"$file" 2>/dev/null
  case "$five$resets" in '' | *[!0-9]*) return 0 ;; esac
  now=${EPOCHSECONDS:-$(date +%s)}
  [ "$resets" -gt "$now" ] || return 0
  case "$seven" in '' | *[!0-9]*) seven=- ;; esac
  case "$seven_resets" in
  '' | *[!0-9]*) seven_resets=- ;;
  *) [ "$seven_resets" -gt "$now" ] || seven=- seven_resets=- ;;
  esac
  echo "$five $resets $seven $seven_resets"
}

# ctx_window_merge <five> <resets> [<seven> [<seven_resets>]] -- adds a status
# line's reading to the account's, as the top of this file says. Under a lock,
# so that two sessions' status lines never write a lower number over a higher
# one; a lock not had within a second skips the write, which the next refresh
# makes.
ctx_window_merge() {
  local five="$1" resets="$2" seven="${3:--}" seven_resets="${4:--}" file
  local old_five="" old_resets="" old_seven="" old_seven_resets=""
  case "$five$resets" in '' | *[!0-9]*) return 0 ;; esac
  case "$seven" in '' | *[!0-9]*) seven=- ;; esac
  case "$seven_resets" in '' | *[!0-9]*) seven_resets=- ;; esac
  file=$(ctx_window_file)
  mkdir -p "${file%/*}" 2>/dev/null || return 0
  (
    flock -w 1 9 || exit 0
    [ -r "$file" ] && read -r old_five old_resets old_seven old_seven_resets _ <"$file"
    case "$old_five$old_resets" in '' | *[!0-9]*) old_five="" old_resets="" ;; esac
    case "$old_seven" in '' | *[!0-9]*) old_seven=- ;; esac
    case "$old_seven_resets" in '' | *[!0-9]*) old_seven_resets=- ;; esac
    if [ -n "$old_resets" ]; then
      # The same window, give or take the rounding of its end: the highest.
      if [ "$resets" -lt $((old_resets - 300)) ]; then
        exit 0
      elif [ "$resets" -le $((old_resets + 300)) ]; then
        [ "$old_five" -gt "$five" ] && five=$old_five
        [ "$resets" -lt "$old_resets" ] && resets=$old_resets
        # The week by the same rule, by its own end: a reading without one
        # keeps what it adds to, and with both, a later week replaces it.
        if [ "$old_seven" != - ]; then
          if [ "$seven" = - ]; then
            seven=$old_seven seven_resets=$old_seven_resets
          elif [ "$seven_resets" = - ] || [ "$old_seven_resets" = - ]; then
            [ "$old_seven" -gt "$seven" ] && seven=$old_seven
            [ "$seven_resets" = - ] && seven_resets=$old_seven_resets
          elif [ "$seven_resets" -lt $((old_seven_resets - 300)) ]; then
            seven=$old_seven seven_resets=$old_seven_resets
          elif [ "$seven_resets" -le $((old_seven_resets + 300)) ]; then
            [ "$old_seven" -gt "$seven" ] && seven=$old_seven
            [ "$seven_resets" -lt "$old_seven_resets" ] && seven_resets=$old_seven_resets
          fi
        fi
      fi
    fi
    [ "$five $resets $seven $seven_resets" = "$old_five $old_resets $old_seven $old_seven_resets" ] && exit 0
    printf '%s %s %s %s\n' "$five" "$resets" "$seven" "$seven_resets" >"$file.$$" && mv -f -- "$file.$$" "$file"
  ) 9>>"$file.lock" 2>/dev/null
  return 0
}

# ctx_window_hot <five> <resets> <seven> <seven_resets> -- the window at or
# past its cap, as "<5h|7d> <percent> <resets> <cap>": the week first, whose
# stop is the longer; nothing when neither is.
ctx_window_hot() {
  local cap
  cap=$(ctx_window_cap 7d)
  case "${3:--}" in
  '' | *[!0-9]*) ;;
  *) if [ "$cap" -gt 0 ] && [ "$3" -ge "$cap" ]; then
    echo "7d $3 ${4:--} $cap"
    return 0
  fi ;;
  esac
  cap=$(ctx_window_cap)
  case "${1:-}" in '' | *[!0-9]*) return 0 ;; esac
  [ "$cap" -gt 0 ] && [ "$1" -ge "$cap" ] && echo "5h $1 $2 $cap"
  return 0
}

# ctx_window_band <five> [<seven>] -- 3 at or past the week's cap, 2 at or
# past the 5-hour cap, 1 from 70% of it, else 0: the bands the model is told
# of when the reading crosses them.
ctx_window_band() {
  local hot
  hot=$(ctx_window_hot "$1" - "${2:--}" -)
  case "$hot" in
  7d*) echo 3 ;;
  5h*) echo 2 ;;
  *) if [ "$1" -ge 70 ]; then echo 1; else echo 0; fi ;;
  esac
}

# ctx_window_until <5h|7d> <epoch> -- when a window ends: "21:40" for the
# 5-hour one, "Sat 21:40" for the week; "it resets" when unknown.
ctx_window_until() {
  case "${2:-}" in '' | *[!0-9]*)
    echo "it resets"
    return 0
    ;;
  esac
  if [ "$1" = 7d ]; then
    LC_ALL=C date -d "@$2" '+%a %H:%M' 2>/dev/null
  else
    date -d "@$2" +%H:%M 2>/dev/null
  fi
}

# ctx_window_line <five> <resets> [<seven> [<seven_resets>]] -- the reading in
# one line: "5h 62% until 21:40, cap 85% · 7d 48% until Sat 21:00, cap 95%".
ctx_window_line() {
  local cap cap7 line seven=""
  cap=$(ctx_window_cap)
  cap7=$(ctx_window_cap 7d)
  line="5h $1% until $(ctx_window_until 5h "$2")"
  [ "$cap" -gt 0 ] && line="$line, cap $cap%"
  case "${3:--}" in
  '' | *[!0-9]*) ;;
  *)
    seven=" · 7d $3%"
    [ "${4:--}" != - ] && seven="$seven until $(ctx_window_until 7d "$4")"
    [ "$cap7" -gt 0 ] && seven="$seven, cap $cap7%"
    ;;
  esac
  echo "$line$seven"
}

# ctx_window_rule [7d <seven_resets>] -- what the cap asks of a session past
# it: the 5-hour one, or the week's.
ctx_window_rule() {
  if [ "${1:-}" = 7d ]; then
    echo "Past the cap on the 7-day window the rest of the week is the user's reserve, and at 100% Claude Code stops answering until $(ctx_window_until 7d "${2:-}"): finish the step at hand and start nothing new -- no subagent, no headless claude, no new schedule, which ctx refuses. A prompt the user sends goes through: do what it asks, and nothing more."
    return 0
  fi
  echo "Past the cap the rest of the window is the user's reserve: finish the step at hand and start nothing new -- no subagent, no headless claude, no new schedule, which ctx refuses. A prompt the user sends goes through: do what it asks, and nothing more."
}
