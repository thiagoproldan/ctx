#!/usr/bin/env bash
# The account's 5-hour window, as the status line last saw it, and the cap
# on it (ekko task 808).
#
# The user's words, 2026-09-26: tell the model where the 5-hour limit stands,
# and put a cap at 85%, leaving 15% for emergencies or anything else. The cap
# is CTX_HANDOFF_5H (default 85; 0 turns it off), the same number past which a
# session running alone is asked for its handoff (hooks/handoff): past it a
# session starts nothing new, and the rest of the window is the user's. With
# the user there, nothing tells the model to write a handoff by itself (ekko
# task 961): that is the user's /handoff.
#
# Only the status line is handed the rate limits: no hook's input carries
# them (Claude Code 2.1.283). So bin/statusline leaves a reading where every
# hook of every session on the account finds it, $CTX_STATE/window/<account>:
# one line, "<five> <resets> <seven>" -- the 5-hour percentage, when that
# window ends (epoch seconds), and the 7-day percentage, "-" when unknown.
#
# A Claude Code profile is an account, named by its folder (CLAUDE_CONFIG_DIR,
# ~/.claude by default). Every session of the profile writes the same file,
# each with the numbers its own process last heard from the API, and an idle
# session's status line, refreshed every 30 seconds, repeats an old one.
# Usage never falls within a window, so the readings of one window keep the
# highest; a reading of a later window replaces the file, and one of an
# earlier window is dropped. A reading at the cap therefore stands until its
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

# ctx_window_cap -- the cap, in percent of the 5-hour window; 0 when off.
ctx_window_cap() {
  case "${CTX_HANDOFF_5H:-}" in
    '' | *[!0-9]*) echo 85 ;;
    *) echo "$CTX_HANDOFF_5H" ;;
  esac
}

# ctx_window -- "<five> <resets> <seven>" while the window read last has not
# ended; nothing otherwise.
ctx_window() {
  local five="" resets="" seven="" file
  file=$(ctx_window_file)
  [ -r "$file" ] && read -r five resets seven <"$file" 2>/dev/null
  case "$five$resets" in '' | *[!0-9]*) return 0 ;; esac
  [ "$resets" -gt "${EPOCHSECONDS:-$(date +%s)}" ] || return 0
  echo "$five $resets ${seven:--}"
}

# ctx_window_merge <five> <resets> <seven> -- adds a status line's reading to
# the account's, as the top of this file says. Under a lock, so that two
# sessions' status lines never write a lower number over a higher one; a lock
# not had within a second skips the write, which the next refresh makes.
ctx_window_merge() {
  local five="$1" resets="$2" seven="${3:--}" file old_five="" old_resets="" old_seven=""
  case "$five$resets" in '' | *[!0-9]*) return 0 ;; esac
  case "$seven" in '' | *[!0-9]*) seven=- ;; esac
  file=$(ctx_window_file)
  mkdir -p "${file%/*}" 2>/dev/null || return 0
  (
    flock -w 1 9 || exit 0
    [ -r "$file" ] && read -r old_five old_resets old_seven <"$file"
    case "$old_five$old_resets" in '' | *[!0-9]*) old_five="" old_resets="" ;; esac
    if [ -n "$old_resets" ]; then
      # The same window, give or take the rounding of its end: the highest.
      if [ "$resets" -lt $((old_resets - 300)) ]; then
        exit 0
      elif [ "$resets" -le $((old_resets + 300)) ]; then
        [ "$old_five" -gt "$five" ] && five=$old_five
        [ "$resets" -lt "$old_resets" ] && resets=$old_resets
        case "$old_seven" in '' | *[!0-9]*) ;; *) { [ "$seven" = - ] || [ "$old_seven" -gt "$seven" ]; } && seven=$old_seven ;; esac
      fi
    fi
    [ "$five $resets $seven" = "$old_five $old_resets ${old_seven:--}" ] && exit 0
    printf '%s %s %s\n' "$five" "$resets" "$seven" >"$file.$$" && mv -f -- "$file.$$" "$file"
  ) 9>>"$file.lock" 2>/dev/null
  return 0
}

# ctx_window_band <five> -- 2 at or past the cap, 1 from 70%, else 0: the
# bands the model is told of when the window crosses them.
ctx_window_band() {
  local cap
  cap=$(ctx_window_cap)
  if [ "$cap" -gt 0 ] && [ "$1" -ge "$cap" ]; then
    echo 2
  elif [ "$1" -ge 70 ]; then
    echo 1
  else
    echo 0
  fi
}

# ctx_window_line <five> <resets> <seven> -- the reading in one line:
# "5h 62% until 21:40, cap 85% · 7d 48%".
ctx_window_line() {
  local cap until seven=""
  cap=$(ctx_window_cap)
  until=$(date -d "@$2" +%H:%M 2>/dev/null)
  [ "${3:--}" != - ] && seven=" · 7d $3%"
  if [ "$cap" -gt 0 ]; then
    echo "5h $1% until $until, cap $cap%$seven"
  else
    echo "5h $1% until $until$seven"
  fi
}

# ctx_window_rule -- what the cap asks of a session past it.
ctx_window_rule() {
  echo "Past the cap the rest of the window is the user's reserve: finish the step at hand and start nothing new -- no subagent, no headless claude, no new schedule, which ctx refuses. A prompt the user sends goes through: do what it asks, and nothing more."
}
