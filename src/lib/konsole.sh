#!/usr/bin/env bash
# Typing into the Konsole tab a session runs in, for bin/auto-reset.
#
# Konsole exports the address of each tab's D-Bus object into the shell it
# starts (KONSOLE_DBUS_SERVICE, KONSOLE_DBUS_SESSION), so Claude Code and every
# hook it runs inherit the address of their own tab. Through it, sendText types
# into the tab as if from the keyboard, and getAllDisplayedText reads the
# screen. Konsole 26.08 answers sendText with "Access denied" unless
# EnableSecuritySensitiveDBusAPI is on in konsolerc ([KonsoleWindow]);
# reading needs nothing.
#
# What was measured on 2026-09-26 (Claude Code 2.1.283, Konsole 26.08.1; ekko
# notes 772 and 777):
#  - text and Enter in one sendText: a long text is taken as a paste, and its
#    Enter becomes a newline in the input box. Sent apart, 0.5 s later, the
#    Enter submits. Hence ctx_konsole_type.
#  - a permission dialog opens with "1. Yes" selected: an Enter typed then
#    approves the call. Hence ctx_screen_idle before every keystroke.
#  - a prompt typed this way is recorded as the user's own (origin.kind
#    "human", promptSource "typed").

# ctx_konsole <method> [signature args...] -- a call on this tab's session
# object; its reply on stdout.
ctx_konsole() {
  busctl --user call "${KONSOLE_DBUS_SERVICE:-}" "${KONSOLE_DBUS_SESSION:-}" \
    org.kde.konsole.Session "$@" 2>/dev/null
}

# ctx_konsole_screen -- the text on this tab's screen.
ctx_konsole_screen() {
  busctl --user --json=short call "${KONSOLE_DBUS_SERVICE:-}" "${KONSOLE_DBUS_SESSION:-}" \
    org.kde.konsole.Session getAllDisplayedText 2>/dev/null | jq -r '.data[0] // empty' 2>/dev/null
}

# ctx_konsole_writable -- Konsole takes typed input over D-Bus. An empty
# sendText types nothing (Vt102Emulation::sendText skips empty text) but is
# refused like any other while the setting is off.
ctx_konsole_writable() {
  ctx_konsole sendText s '' >/dev/null
}

# ctx_konsole_foreground -- the pid in the foreground of this tab.
ctx_konsole_foreground() {
  ctx_konsole foregroundProcessId | awk '$1 == "i" { print $2 }'
}

# ctx_konsole_type <text> -- the text, then Enter half a second later, apart.
ctx_konsole_type() {
  ctx_konsole sendText s "$1" >/dev/null || return 1
  sleep 0.5
  ctx_konsole sendText s $'\r' >/dev/null
}

# ctx_screen_idle [text] -- reads a Claude Code screen on stdin; succeeds only
# when the session is idle and its input box holds exactly <text> (empty by
# default): no dialog on screen, one line in the box, no spinner above it.
# Prints why not. The spinner is not always right above the box: a hint line
# ("◉ xhigh · /effort") or a tip can sit between them, so the three lines above
# are searched. Claude Code writes U+00A0 after the prompt's "❯", not a space.
# Byte for byte (LC_ALL=C), so that no locale changes what a character is: in
# the build sandbox's C locale, ─{20,} repeated the rule's last byte only.
ctx_screen_idle() {
  LC_ALL=C sed 's/\xc2\xa0/ /g' | LC_ALL=C awk -v want="${1:-}" '
    { sub(/[[:space:]]+$/, "") }
    NF == 0 { next }
    { line[++n] = $0 }
    /^(─){20,}$/ { sep[++s] = n }
    /Do you want to proceed\?|Esc to cancel|Enter to confirm/ { dialog = 1 }
    END {
      if (dialog) { print "a dialog is open"; exit 1 }
      if (s < 2) { print "no input box on screen"; exit 1 }
      top = sep[s - 1]; bottom = sep[s]
      if (bottom - top != 2) { print "the input box holds " bottom - top - 1 " lines"; exit 1 }
      box = line[top + 1]
      if (want == "") {
        if (box !~ /^❯ ?$/ && box !~ /^❯ Try "/) { print "text in the input box: " box; exit 1 }
      } else if (box != "❯ " want) { print "the input box holds: " box; exit 1 }
      for (i = top - 1; i > 0 && i >= top - 3; i--)
        if (line[i] ~ /^[^ ]+ [[:upper:]][[:alpha:]-]*…/) { print "busy: " line[i]; exit 1 }
    }'
}
