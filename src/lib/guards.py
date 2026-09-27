"""What ctx's PreToolUse guards share: git's answers, the ledger, the refusal."""

import datetime
import json
import os
import shutil
import subprocess

HOME = os.path.expanduser("~")


def under(path, roots):
    return any(path == root or path.startswith(root.rstrip("/") + "/") for root in roots)


def git(where, *args, stdin=None):
    """git's stdout, or None when it fails or cannot run."""
    try:
        done = subprocess.run(
            ["git", "-C", where, *args],
            input=stdin,
            capture_output=True,
            text=True,
            timeout=5,
        )
    except (OSError, subprocess.SubprocessError):
        return None
    return done.stdout if done.returncode == 0 else None


def log(event, sid, rule, call, where, loss=""):
    """A line in $CTX_STATE/guard.jsonl, the guards' ledger."""
    state = os.environ.get("CTX_STATE") or os.path.join(
        os.environ.get("XDG_STATE_HOME") or os.path.join(HOME, ".local", "state"), "ctx"
    )
    line = {
        "ts": datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "ev": event,
        "sid": sid,
        "rule": rule,
        "cwd": where,
        "call": call[:300],
    }
    if loss:
        line["loss"] = loss[:500]
    try:
        os.makedirs(state, exist_ok=True)
        with open(os.path.join(state, "guard.jsonl"), "a") as ledger:
            ledger.write(json.dumps(line) + "\n")
    except OSError:
        pass  # a lost measurement, never a stuck session


def excepted(reason, event):
    """What ekko says of a call a guard is about to refuse (ekko task 805):
    True when the user's answer in ekko's menu let this exact call through,
    else the sentence the refusal ends with, on how to ask for it; None when
    ekko is not installed or cannot tell, and the refusal stands as it is."""
    ekko = shutil.which("ekko")
    if not ekko or event is None:
        return None
    try:
        done = subprocess.run(
            [ekko, "--guard", "--refuse", reason],
            input=json.dumps(event),
            capture_output=True,
            text=True,
            timeout=5,
        )
    except (OSError, ValueError, subprocess.SubprocessError):
        return None
    if done.returncode == 0:
        return True
    if done.returncode == 1 and done.stdout.strip():
        return done.stdout.strip()
    return None


def deny(reason, event=None):
    """Refuses the call `event` describes, with `reason`, and returns True;
    returns False, printing nothing, when ekko says the user let it through."""
    said = excepted(reason, event)
    if said is True:
        return False
    if said:
        reason = f"{reason}\n\n{said}"
    print(
        json.dumps(
            {
                "hookSpecificOutput": {
                    "hookEventName": "PreToolUse",
                    "permissionDecision": "deny",
                    "permissionDecisionReason": reason,
                }
            }
        )
    )
    return True
