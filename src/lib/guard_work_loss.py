"""ctx's work-loss guard (ekko task 803, decision 801): refuse a git or rm call
only when it would destroy work that exists nowhere else, and say what.

Reads Claude Code's PreToolUse JSON for a Bash call on stdin. It walks the
calls the command runs in order, following cd, pushd, git -C and NAME=value,
reads each repository's state, and prints a deny naming what would be lost on
the first call that would lose it. Everything else passes, and so does any
error: a broken guard must not break the shell.

Keyed on state, not on the command's name: git reset --hard in a clean tree
loses nothing its reflog cannot give back, and passes. A git stash or git
commit earlier in the same command counts as keeping the work, so the fix the
reason suggests, run as one command, is not refused again.

Not guarded: paths under the scratch roots (CTX_GUARD_SCRATCH, colon-separated;
/tmp, /var/tmp, $XDG_RUNTIME_DIR and ~/.cache by default), rm -r outside any
repository, where no state says whether a copy exists, and a script the
command runs, whose calls the hook never sees.

Each call it examines goes to $CTX_STATE/guard.jsonl, refused or not.
"""

import datetime
import glob
import json
import os
import re
import subprocess
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from shell_calls import calls  # noqa: E402

HOME = os.path.expanduser("~")
SAVING_STASH = {None, "push", "save"}
SHOWN = 5  # paths named in a reason; the rest are counted
# What a rule returns for a call whose form cannot lose work: not examined.
SKIP = object()


def scratch_roots():
    value = os.environ.get("CTX_GUARD_SCRATCH")
    if value is None:
        value = ":".join(
            ["/tmp", "/var/tmp", os.environ.get("XDG_RUNTIME_DIR", ""), HOME + "/.cache"]
        )
    return [os.path.realpath(root) for root in value.split(":") if root]


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


def toplevel(where):
    out = git(where, "rev-parse", "--show-toplevel") if os.path.isdir(where) else None
    return out.strip() if out else None


def listed(paths):
    shown = ", ".join(paths[:SHOWN])
    more = len(paths) - SHOWN
    return shown + (f" and {more} more" if more > 0 else "")


def porcelain(where, *args):
    """The paths git status names, from `git -C where status --porcelain ...`."""
    out = git(where, "status", "--porcelain", *args)
    if not out:
        return []
    return [line[3:].split(" -> ")[-1] for line in out.splitlines() if len(line) > 3]


def letters(args):
    """The short options' letters, up to --."""
    found = set()
    for arg in args:
        if arg == "--":
            break
        if arg.startswith("-") and not arg.startswith("--"):
            found |= set(arg[1:])
    return found


def operands(args, valued=()):
    """The arguments that are not options, skipping the values `valued` take."""
    found, skip, dashes = [], False, False
    for arg in args:
        if skip:
            skip = False
        elif dashes or not arg.startswith("-") or arg == "-":
            found.append(arg)
        elif arg == "--":
            dashes = True
        elif arg in valued:
            skip = True
    return found


def after_dashes(args):
    return args[args.index("--") + 1 :] if "--" in args else None


# --- what each call would lose -------------------------------------------------


def tracked_changes(where, paths=None):
    changed = porcelain(where, "-uno", *(["--", *paths] if paths else []))
    if not changed:
        return None
    return (
        f"uncommitted changes to {len(changed)} tracked file(s): {listed(changed)}",
        "Commit them, or keep them with git stash push, then run it again.",
    )


def checkout(where, args):
    paths = after_dashes(args)
    if paths is not None:
        return tracked_changes(where, paths) if paths else SKIP
    flags = letters(args)
    if "f" in flags or "--force" in args:
        return tracked_changes(where)
    names = operands(args, valued=("-b", "-B", "--orphan", "--conflict"))
    if not names or {"-b", "-B", "--orphan", "-p", "--patch"} & set(args):
        return SKIP
    first = names[0]
    if git(where, "rev-parse", "-q", "--verify", first + "^{commit}") is not None:
        names = names[1:]  # a commit, then the paths to take from it
    return tracked_changes(where, names) if names else SKIP  # a switch: git keeps changes


def restore(where, args):
    staged = "--staged" in args or "S" in letters(args)
    worktree = "--worktree" in args or "W" in letters(args)
    if staged and not worktree:
        return SKIP  # the index only: the work tree keeps the changes
    paths = operands(args, valued=("-s", "--source"))
    return tracked_changes(where, paths) if paths else SKIP


def git_rm(where, args):
    if not ("f" in letters(args) or "--force" in args) or "--cached" in args:
        return SKIP  # without -f git refuses to drop local changes itself
    paths = operands(args)
    return tracked_changes(where, paths) if paths else SKIP


def clean(where, args):
    flags = letters(args)
    if "n" in flags or "--dry-run" in args or not ("f" in flags or "--force" in args):
        return SKIP  # a dry run, or git refuses without -f
    dry = ["clean", "-n"]
    dry += ["-d"] if "d" in flags else []
    dry += ["-x"] if "x" in flags else []
    dry += ["-X"] if "X" in flags else []
    for i, arg in enumerate(args):
        if arg in ("-e", "--exclude") and i + 1 < len(args):
            dry += ["-e", args[i + 1]]
        elif arg.startswith("--exclude="):
            dry.append(arg)
    dry += ["--", *operands(args, valued=("-e", "--exclude"))]
    out = git(where, *dry) or ""
    doomed = [line.removeprefix("Would remove ") for line in out.splitlines()]
    if not doomed:
        return None
    return (
        f"{len(doomed)} untracked path(s) git cannot bring back: {listed(doomed)}",
        "git stash push -u keeps them; or remove only the ones meant to go, by name.",
    )


def stash_kept_here(top, ref):
    """Whether the stash's changes are already in the work tree."""
    patch = git(top, "diff", "--binary", ref + "^1", ref)
    if patch and git(top, "apply", "-R", "--check", stdin=patch) is None:
        return False
    if git(top, "rev-parse", "-q", "--verify", ref + "^3") is not None:
        for line in (git(top, "ls-tree", "-r", ref + "^3") or "").splitlines():
            meta, path = line.split("\t", 1)
            blob = meta.split()[2]
            here = os.path.join(top, path)
            if not os.path.isfile(here):
                return False
            if (git(top, "hash-object", here) or "").strip() != blob:
                return False
    return True


def stash(where, args):
    names = operands(args)
    verb = names[0] if names else None
    if verb not in ("drop", "clear"):
        return SKIP
    top = toplevel(where)
    if not top:
        return SKIP
    if verb == "clear":
        refs = [line.split(":")[0] for line in (git(top, "stash", "list") or "").splitlines()]
    else:
        ref = names[1] if len(names) > 1 else "stash@{0}"
        refs = [f"stash@{{{ref}}}" if ref.isdigit() else ref]
    lost = []
    for ref in refs:
        if git(top, "rev-parse", "-q", "--verify", ref) is None:
            continue
        if not stash_kept_here(top, ref):
            subject = (git(top, "log", "-1", "--format=%s", ref) or "").strip()
            lost.append(f"{ref} ({subject})")
    if not lost:
        return None
    return (
        f"{len(lost)} stash(es) whose changes are nowhere else: {listed(lost)}",
        "Leave it: a stash costs nothing, and the user can drop it. "
        "To use it, git stash apply or git stash branch <name>.",
    )


def branch(where, args):
    flags = letters(args)
    deleting = "D" in flags or (
        ("d" in flags or "--delete" in args) and ("f" in flags or "--force" in args)
    )
    if not deleting or "r" in flags or "--remotes" in args:
        return SKIP
    lost = []
    for name in operands(args):
        if git(where, "rev-parse", "-q", "--verify", "refs/heads/" + name) is None:
            continue
        only = git(
            where, "rev-list", "--count", "refs/heads/" + name,
            "--not", "--exclude=" + name, "--branches", "--remotes", "--tags", "HEAD",
        )
        if only and int(only) > 0:
            tip = (git(where, "log", "-1", "--format=%s", "refs/heads/" + name) or "").strip()
            lost.append(f"{name} ({only.strip()} commit(s), newest: {tip})")
    if not lost:
        return None
    return (
        f"branch(es) holding commits no other branch, tag or remote has: {listed(lost)}",
        "Push it or tag it first (git tag keep/<name> <name>), then delete it.",
    )


def worktree(where, args, scratch):
    names = operands(args)
    if not names or names[0] != "remove" or not ("f" in letters(args) or "--force" in args):
        return SKIP
    lost = []
    for name in names[1:]:
        path = os.path.realpath(os.path.join(where, os.path.expanduser(name)))
        if under(path, scratch) or not os.path.isdir(path):
            continue
        changed = porcelain(path)
        if changed:
            lost.append(f"{name}: {listed(changed)}")
    if not lost:
        return None
    return (
        f"a worktree with uncommitted or untracked files: {listed(lost)}",
        "Commit or stash inside that worktree first, then remove it.",
    )


def push(where, args):
    flags = letters(args)
    forced = "f" in flags or any(arg.startswith("--force") and arg != "--force-if-includes" for arg in args)
    deleting = "d" in flags or "--delete" in args
    names = operands(args, valued=("--repo", "-o", "--push-option", "--receive-pack", "--exec"))
    if "--mirror" in args or not (forced or deleting or any(n.startswith("+") or n.startswith(":") for n in names[1:])):
        return SKIP
    current = (git(where, "symbolic-ref", "-q", "--short", "HEAD") or "").strip()
    remote = names[0] if names else (git(where, "config", f"branch.{current}.remote") or "origin").strip()
    specs = names[1:] or [current]
    head = (git(where, "symbolic-ref", "-q", "--short", f"refs/remotes/{remote}/HEAD") or "").strip()
    default = head.split("/", 1)[1] if "/" in head else None
    for name in ("main", "master"):
        if default is None and git(where, "rev-parse", "-q", "--verify", f"refs/remotes/{remote}/{name}") is not None:
            default = name
    if not default:
        return None
    for spec in specs:
        plus = spec.startswith("+")
        source, colon, dest = spec.lstrip("+").partition(":")
        if not colon:
            dest = source
        if dest == "HEAD":
            dest = current
        dest = dest.removeprefix("refs/heads/")
        if dest != default:
            continue
        if deleting or (colon and not source):
            return (f"{remote}/{default}, the remote's default branch, by deleting it", "Do not delete it.")
        if not (forced or plus):
            continue
        theirs = f"refs/remotes/{remote}/{default}"
        gone = git(where, "rev-list", "--count", f"{source or 'HEAD'}..{theirs}")
        if gone and int(gone) > 0:
            return (
                f"{gone.strip()} commit(s) on {remote}/{default}, the remote's default branch, "
                "that the forced push would drop",
                "Push to another branch, or rebase on it and push without force.",
            )
    return None


def repo_loss(root):
    """What a repository holds that exists nowhere else, or None."""
    parts = []
    changed = porcelain(root)
    if changed:
        parts.append(f"{len(changed)} uncommitted or untracked file(s) ({listed(changed)})")
    stashes = (git(root, "stash", "list") or "").splitlines()
    if stashes:
        parts.append(f"{len(stashes)} stash(es)")
    remotes = (git(root, "remote") or "").split()
    commits = git(root, "rev-list", "--count", "--all")
    if commits and int(commits) > 0:
        if not remotes:
            parts.append(f"{commits.strip()} commit(s) and no remote to hold them")
        else:
            local = git(root, "rev-list", "--count", "--branches", "--not", "--remotes")
            if local and int(local) > 0:
                parts.append(f"{local.strip()} commit(s) on local branches that no remote has")
    return "; ".join(parts) or None


def nested_repos(path, limit=4000):
    """The repositories under path, and whether the walk was cut short."""
    found, seen = [], 0
    for top, dirs, files in os.walk(path):
        seen += 1
        if seen > limit:
            return found, True
        if ".git" in dirs or ".git" in files:
            found.append(top)
            dirs[:] = []
            continue
        dirs[:] = [d for d in dirs if d not in ("node_modules", "target", ".direnv", "__pycache__")]
    return found, False


def remove(where, args, variables, scratch):
    if not ("r" in letters(args) or "R" in letters(args) or "--recursive" in args):
        return None
    lost = []
    for word in operands(args):
        for path in expand(word, variables, where):
            path = os.path.realpath(path)
            if under(path, scratch) or not os.path.exists(path):
                continue
            if os.path.basename(path) == ".git" and os.path.isdir(path):
                # git rev-parse cannot run inside .git, and the history goes with it
                held = repo_loss(os.path.dirname(path))
                if held:
                    lost.append(f"{word}, the history of {os.path.dirname(path)}: {held}")
                continue
            base = path if os.path.isdir(path) else os.path.dirname(path)
            top = toplevel(base)
            if top and os.path.realpath(top) != path:
                changed = porcelain(top, "-uall", "--", path)
                if changed:
                    lost.append(f"{word}: {len(changed)} untracked or modified file(s) ({listed(changed)})")
                continue
            repos, _ = ([path], False) if top else nested_repos(path)
            for root in repos:
                held = repo_loss(root)
                if held:
                    lost.append(f"the repository {root}: {held}")
    if not lost:
        return None
    return (
        "; ".join(lost),
        "Commit, push or stash (git stash push -u) what should stay, "
        "or remove only the ignored or disposable paths.",
    )


# --- walking the command -------------------------------------------------------


def expand(word, variables, where):
    """The paths a word names, or [] when it names one the hook cannot know."""
    if word.startswith("~"):
        word = HOME + word[1:]

    def value(match):
        name = match.group(1) or match.group(2)
        found = variables.get(name, os.environ.get(name))
        if found is None:
            raise KeyError(name)
        return found

    try:
        word = re.sub(r"\$\{(\w+)\}|\$(\w+)", value, word)
    except KeyError:
        return []
    if "$" in word or "`" in word:
        return []
    path = os.path.join(where, word)
    if any(char in word for char in "*?["):
        return glob.glob(path)
    return [path]


def git_call(args, where):
    """git's own options, then the subcommand and its args, and the folder
    the subcommand runs in."""
    i = 0
    while i < len(args):
        arg = args[i]
        if arg == "-C" and i + 1 < len(args):
            where = os.path.join(where, os.path.expanduser(args[i + 1]))
            i += 2
        elif arg in ("-c", "--git-dir", "--work-tree", "--namespace") and i + 1 < len(args):
            i += 2
        elif arg.startswith("-"):
            i += 1
        else:
            return arg, args[i + 1 :], where
    return None, [], where


def verdict(command, cwd, scratch):
    """(rule, call, loss, keep) for the first call that would lose work, and
    the list of calls examined."""
    where, variables, saved, examined = cwd, {}, set(), []
    for name, args in calls(command):
        if name == "=":
            variables[args[0]] = args[1]
        elif name in ("export", "local", "declare", "readonly"):
            for arg in args:
                if "=" in arg and not arg.startswith("-"):
                    key, val = arg.split("=", 1)
                    variables[key] = val
        elif name in ("cd", "pushd"):
            target = operands(args)
            paths = expand(target[0], variables, where) if target else [HOME]
            if len(paths) == 1 and os.path.isdir(paths[0]):
                where = os.path.realpath(paths[0])
        elif name == "git":
            sub, rest, here = git_call(args, where)
            if sub is None or not os.path.isdir(here):
                continue
            top = toplevel(here)
            if not top or under(os.path.realpath(top), scratch):
                continue
            stash_verb = (operands(rest) or [None])[0]
            if sub == "commit" or (sub == "stash" and stash_verb in SAVING_STASH):
                saved.add(top)
                continue
            rule = {
                "reset": lambda: tracked_changes(here) if "--hard" in rest else SKIP,
                "checkout": lambda: checkout(here, rest),
                "switch": lambda: tracked_changes(here)
                if "--discard-changes" in rest or "--force" in rest or "f" in letters(rest)
                else SKIP,
                "restore": lambda: restore(here, rest),
                "rm": lambda: git_rm(here, rest),
                "clean": lambda: clean(here, rest),
                "stash": lambda: stash(here, rest),
                "branch": lambda: branch(here, rest),
                "worktree": lambda: worktree(here, rest, scratch),
                "push": lambda: push(here, rest),
            }.get(sub)
            if rule is None:
                continue
            if top in saved and sub != "push":
                continue  # an earlier git stash or git commit kept the work
            loss = rule()
            if loss is SKIP:
                continue
            call = " ".join(["git", *args])
            examined.append((f"git {sub}", call, here))
            if loss:
                return (f"git {sub}", call, here, *loss), examined
        elif name == "rm":
            call = " ".join(["rm", *args])
            if not ("r" in letters(args) or "R" in letters(args) or "--recursive" in args):
                continue
            examined.append(("rm -r", call, where))
            loss = remove(where, args, variables, scratch)
            if loss:
                return ("rm -r", call, where, *loss), examined
    return None, examined


def log(event, sid, rule, call, where, loss=""):
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


def main():
    event = json.load(sys.stdin)
    command = (event.get("tool_input") or {}).get("command") or ""
    cwd = event.get("cwd") or os.getcwd()
    sid = event.get("session_id") or ""
    found, examined = verdict(command, cwd, scratch_roots())
    for rule, call, where in examined:
        if not found or call != found[1]:
            log("guard-pass", sid, rule, call, where)
    if not found:
        return
    rule, call, where, loss, keep = found
    log("guard-refuse", sid, rule, call, where, loss)
    reason = (
        f"ctx's work-loss guard refused `{call[:200]}` in {where}: it would destroy {loss}. "
        f"That work exists nowhere else. {keep}"
    )
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


if __name__ == "__main__":
    try:
        main()
    except Exception:  # noqa: BLE001 -- see the docstring: errors let the call through
        pass
