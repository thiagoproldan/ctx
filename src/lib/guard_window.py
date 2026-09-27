"""ctx's cap on the 5-hour window (ekko task 808, decision 863): past the cap,
refuse the work a session starts on its own, and say why.

Reads Claude Code's PreToolUse JSON on stdin; hooks/guard-window runs this only
once the account's window is at or past the cap (lib/window.sh), and passes the
reading as its arguments: <five> <resets> <cap>. Refused, each with ekko's
allow-once, as the other guards are (ekko task 805):
  - a subagent: Agent, or Task as it was named before;
  - a new schedule: CronCreate, ScheduleWakeup;
  - a Bash call that runs claude headless (-p, --print), wherever the command
    runs it: after cd or env, under timeout, inside bash -c.
Everything else passes, and so does any error: a broken guard must not break
the session. A script that starts claude by itself is not seen.
"""

import datetime
import json
import os
import re
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from guards import deny, log  # noqa: E402
from shell_calls import calls  # noqa: E402

SUBAGENTS = {"Agent", "Task"}
SCHEDULES = {"CronCreate", "ScheduleWakeup"}
PRINT_SHORT = re.compile(r"^-[A-Za-z]*p[A-Za-z]*$")


def headless(command):
    """The first call in the command that runs claude headless, or None."""
    for call in calls(command):
        name, args = call
        if name == "claude" and any(arg == "--print" or PRINT_SHORT.match(arg) for arg in args):
            return " ".join(["claude", *args])
    return None


def main():
    five, resets, cap = (int(word) for word in sys.argv[1:4])
    event = json.load(sys.stdin)
    tool = event.get("tool_name") or ""
    sid = event.get("session_id") or ""
    cwd = event.get("cwd") or os.getcwd()
    if tool in SUBAGENTS:
        what, rule, call = "a subagent", "subagent", json.dumps(event.get("tool_input") or {})[:300]
    elif tool in SCHEDULES:
        what, rule, call = "a new schedule", "schedule", json.dumps(event.get("tool_input") or {})[:300]
    elif tool == "Bash":
        call = headless((event.get("tool_input") or {}).get("command") or "")
        if call is None:
            return
        what, rule = "a headless claude run", "headless"
    else:
        return
    until = datetime.datetime.fromtimestamp(resets).strftime("%H:%M")
    reason = (
        f"ctx refused {what}: the 5-hour window is at {five}%, past the {cap}% cap, until {until}. "
        "Past the cap the rest of the window is the user's reserve: finish the step at hand, write "
        "the handoff, and start nothing new."
    )
    refused = deny(reason, event)
    log("window-refuse" if refused else "window-excepted", sid, rule, call, cwd)


if __name__ == "__main__":
    try:
        main()
    except Exception:  # noqa: BLE001 -- see the docstring: errors let the call through
        pass
