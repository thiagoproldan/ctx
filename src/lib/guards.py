"""What ctx's PreToolUse guards share: git's answers, the ledger, the refusal."""

import datetime
import json
import os
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


def deny(reason):
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
