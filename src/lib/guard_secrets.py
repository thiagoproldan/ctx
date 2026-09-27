"""ctx's secrets guard (ekko task 804, decision 801): refuse a call that would
bring secret material into the context, and say what.

Reads Claude Code's PreToolUse JSON for Read, Grep or Bash on stdin. A file is
secret by where it is and what it holds, not by the command that names it:
- anything under the secret roots (CTX_SECRET_ROOTS, colon-separated;
  /persist/secrets, /run/secrets and /run/secrets.d by default);
- an age key: age-combined-identity.txt, sops/age/keys.txt, $SOPS_AGE_KEY_FILE;
- a private key under ~/.ssh, told by its first line;
- Claude Code's ~/.claude*/.credentials.json, gh's hosts.yml, git's stored
  credentials and ~/.netrc;
- a .env or .env.* file git does not track, bar the templates (.env.example,
  .sample, .template, .dist).

Refused: a Read of one; a Grep that shows lines of one; a Bash call that prints
what it reads (READERS) naming one, fed one by <, or searching a folder that
holds one; and a command that prints a secret of its own (printed_secret: gh
auth token, sops -d, ...). Unless what it prints goes to a file, or into a
$(...) or backticks: a pipe counts as shown, unless the pipeline ends in a
file. Metadata passes: ls, stat, test, wc and file are no readers, and grep -c,
-l and -q print no lines.

Not guarded: what a sourced .env puts in the environment and a later call
prints, a script the command runs, and a copy made in one call and read in
another. Any error lets the call through. Each refusal, and each call that
named a secret and passed because its output went elsewhere, goes to
$CTX_STATE/guard.jsonl.
"""

import fnmatch
import glob
import json
import os
import re
import subprocess
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from guards import HOME, deny, git, log, under  # noqa: E402
from shell_calls import expand, letters, located, operands  # noqa: E402

TEMPLATES = {"example", "sample", "template", "dist"}
# Commands that print what they read from the files they are given.
READERS = {
    "ack", "ag", "awk", "base32", "base64", "basenc", "bat", "batcat", "cat",
    "colordiff", "column", "comm", "cut", "dd", "diff", "egrep", "expand",
    "fgrep", "fmt", "fold", "gawk", "gojq", "grep", "hd", "head", "hexdump",
    "jq", "join", "less", "mawk", "more", "nl", "od", "openssl", "paste", "pr",
    "rev", "rg", "sdiff", "sed", "sort", "strings", "tac", "tail", "ug",
    "ugrep", "unexpand", "uniq", "xxd", "yq",
}
GREPS = {"grep", "egrep", "fgrep", "rg", "ag", "ack", "ugrep", "ug"}
# Searchers that recurse into a folder without being asked, and skip hidden
# files (.env, ~/.ssh, ~/.claude*) unless told otherwise.
RECURSING = {"rg", "ag", "ack", "ugrep", "ug"}
SKIPS_HIDDEN = {"rg", "ag", "ug"}
# The options whose value is no file to read, where it could look like one.
VALUED = {
    "grep": ("-e", "-f", "-m", "-A", "-B", "-C", "-d", "-D", "--include", "--exclude", "--exclude-dir"),
    "rg": ("-e", "-f", "-g", "--glob", "--iglob", "-t", "--type", "-T", "--type-not", "-m", "-A", "-B",
           "-C", "-r", "--replace", "-j", "-M", "-E", "--pre", "--sort", "--type-add", "-d", "--max-depth"),
    "awk": ("-f", "-v", "-F", "-i"),
    "jq": ("--arg", "--argjson", "--indent", "-f", "--from-file"),
    "sed": ("-e", "-f", "--expression", "--file", "-l"),
}
# The searches whose output can be told by running them on one file: the
# options that change what they match or print, and what a .env line shows
# when it holds a name and no value.
SEARCHES = {"grep", "egrep", "fgrep", "rg", "ugrep", "ug"}
MATCHING_LETTERS = "iyEFGPwxvzoUsS"
MATCHING = {
    "--ignore-case", "--extended-regexp", "--fixed-strings", "--basic-regexp", "--perl-regexp",
    "--word-regexp", "--line-regexp", "--invert-match", "--only-matching", "--null-data",
    "--multiline", "--pcre2", "--case-sensitive", "--smart-case",
}
NAME_ONLY = re.compile(r"\s*(export\s+)?[A-Za-z_][\w.]*\s*=?\s*")
PASS_COMMANDS = {
    "init", "ls", "list", "find", "search", "insert", "add", "edit", "generate",
    "rm", "remove", "delete", "mv", "rename", "cp", "copy", "git", "help", "version",
}
WALK_LIMIT = 4000  # folders a recursive search is followed into, looking for a .env
SKIPPED = {".git", "node_modules", "target", ".direnv", "__pycache__"}


# --- what is secret --------------------------------------------------------------


def secret_roots():
    value = os.environ.get("CTX_SECRET_ROOTS")
    if value is None:
        value = "/persist/secrets:/run/secrets:/run/secrets.d"
    return [root.rstrip("/") for root in value.split(":") if root]


def config_home():
    return os.environ.get("XDG_CONFIG_HOME") or os.path.join(HOME, ".config")


def credential_files():
    """The fixed files that hold a login, and what each holds."""
    gh = os.environ.get("GH_CONFIG_DIR") or os.path.join(config_home(), "gh")
    files = {
        os.path.join(gh, "hosts.yml"): "gh's GitHub token",
        os.path.join(HOME, ".git-credentials"): "git's stored credentials",
        os.path.join(config_home(), "git", "credentials"): "git's stored credentials",
        os.path.join(HOME, ".netrc"): "the logins in ~/.netrc",
        os.path.join(config_home(), "sops", "age", "keys.txt"): "an age key",
    }
    if os.environ.get("SOPS_AGE_KEY_FILE"):
        files[os.environ["SOPS_AGE_KEY_FILE"]] = "an age key"
    for path in glob.glob(os.path.join(HOME, ".claude*", ".credentials.json")):
        files[path] = "Claude Code's login token"
    return {os.path.realpath(path): what for path, what in files.items()}


def private_key(path):
    try:
        with open(path, "rb") as key:
            return b"PRIVATE KEY-----" in key.read(4096)
    except OSError:
        name = os.path.basename(path)
        return name.startswith("id_") and not name.endswith(".pub")


def dotenv(name):
    return name == ".env" or (name.startswith(".env.") and name.rsplit(".", 1)[-1] not in TEMPLATES)


def tracked(path):
    folder, name = os.path.split(path)
    return git(folder, "ls-files", "--error-unmatch", "--", name) is not None


def secret(path):
    """What the file at path holds, when that is secret; None otherwise."""
    if not os.path.isfile(path):
        return None
    real = os.path.realpath(path)
    for root in secret_roots():
        if under(os.path.abspath(path), [root]) or under(real, [os.path.realpath(root)]):
            return f"a file under {root}"
    name = os.path.basename(real)
    if name == "age-combined-identity.txt" or real.endswith("/sops/age/keys.txt"):
        return "an age key"
    known = credential_files().get(real)
    if known:
        return known
    if under(real, [os.path.realpath(os.path.join(HOME, ".ssh"))]) and private_key(real):
        return "an SSH private key"
    if dotenv(name) and not tracked(real):
        return "a .env file git does not track"
    return None


def fixed_secrets():
    """The secret files that do not depend on the folder: under the roots, the
    logins in the home folder, and the private keys under ~/.ssh."""
    for root in secret_roots():
        for top, _, files in os.walk(root):
            yield from (os.path.join(top, name) for name in files)
    yield from credential_files()
    for path in glob.glob(os.path.join(HOME, ".ssh", "*")):
        if os.path.isfile(path) and private_key(path):
            yield path


def held_under(folder, hidden, include=(), exclude=(), exclude_dirs=(), shows=lambda path: True):
    """The first secret a recursive search of folder would print, as 'path
    (what)', or None. hidden: whether the search enters hidden files and
    folders; the globs filter as grep's --include, --exclude and --exclude-dir;
    shows(path) tells whether the search prints anything secret from path."""
    folder = os.path.realpath(folder)

    def reached(path):
        parts = os.path.relpath(path, folder).split(os.sep)
        if parts[0] == ".." or (not hidden and any(part.startswith(".") for part in parts)):
            return False
        if any(fnmatch.fnmatch(part, glob_) for part in parts[:-1] for glob_ in exclude_dirs):
            return False
        if include and not any(fnmatch.fnmatch(parts[-1], glob_) for glob_ in include):
            return False
        return not any(fnmatch.fnmatch(parts[-1], glob_) for glob_ in exclude)

    for path in fixed_secrets():
        if os.path.isfile(path) and reached(path) and secret(path) and shows(path):
            return f"{path} ({secret(path)})"
    if not hidden:
        return None  # every .env is a hidden file
    seen = 0
    for top, dirs, files in os.walk(folder):
        seen += 1
        if seen > WALK_LIMIT:
            return None  # too big to tell; the fixed secrets were checked above
        dirs[:] = [d for d in dirs if d not in SKIPPED]
        for name in files:
            path = os.path.join(top, name)
            if dotenv(name) and reached(path):
                what = secret(path)
                if what and shows(path):
                    return f"{path} ({what})"
    return None


# --- what a call would show ------------------------------------------------------


def git_subcommand(args):
    i = 0
    while i < len(args):
        if args[i] in ("-C", "-c", "--git-dir", "--work-tree", "--namespace"):
            i += 2
        elif args[i].startswith("-"):
            i += 1
        else:
            return args[i], args[i + 1 :]
    return None, []


def printed_secret(name, args):
    """What secret the command prints of its own, or None."""
    words, flags = operands(args), letters(args)
    to_file = "o" in flags or any(arg == "--output" or arg.startswith("--output=") for arg in args)
    if name == "gh":
        if words[:2] == ["auth", "token"]:
            return "gh's GitHub token"
        if words[:2] == ["auth", "status"] and ("t" in flags or "--show-token" in args):
            return "gh's GitHub token"
    elif name == "sops":
        decrypting = "d" in flags or "--decrypt" in args or words[:1] == ["decrypt"]
        if decrypting and not any(arg == "--output" or arg.startswith("--output=") for arg in args):
            return "what sops decrypts"
    elif name == "age":
        if ("d" in flags or "--decrypt" in args) and not to_file:
            return "what age decrypts"
    elif name in ("gpg", "gpg2"):
        exporting = any(arg.startswith("--export-secret") for arg in args)
        if (exporting or "d" in flags or "--decrypt" in args) and not to_file:
            return "a secret gpg decrypts or exports"
    elif name == "secret-tool":
        if words[:1] == ["lookup"]:
            return "a secret from the desktop keyring"
    elif name == "kwallet-query":
        if "r" in flags or "--read-password" in args:
            return "a password from KWallet"
    elif name == "pass":
        if flags & {"c", "q"} or {"--clip", "--qrcode"} & set(args):
            return None
        if words and (words[0] in ("show", "otp", "grep") or words[0] not in PASS_COMMANDS):
            return "a password from pass"
    elif name == "git":
        sub, rest = git_subcommand(args)
        if sub == "credential" and operands(rest)[:1] == ["fill"]:
            return "git's stored credentials"
    return None


def quiet(name, args):
    """Whether this reader prints no content: names, counts, or nothing."""
    flags = letters(args)
    if name in GREPS:
        short = set("qlc") | (set() if name == "rg" else {"L"})
        long_ = {"--quiet", "--silent", "--files-with-matches", "--files-without-match", "--count",
                 "--count-matches", "--files"}
        return bool(flags & short or long_ & set(args))
    if name == "sed":
        return "i" in flags or any(arg.startswith("--in-place") for arg in args)
    if name in ("awk", "gawk"):
        return "inplace" in args
    if name in ("diff", "colordiff"):
        return "q" in flags or "--brief" in args
    if name == "sort":
        return "o" in flags or any(arg.startswith("--output") for arg in args)
    return False


def read_files(name, args):
    """The words a reader reads as files."""
    if name == "dd":
        return [arg[3:] for arg in args if arg.startswith("if=")]
    if name == "openssl":
        return [args[i + 1] for i, arg in enumerate(args[:-1]) if arg in ("-in", "-inkey", "-key")]
    family = {"gawk": "awk", "mawk": "awk", "gojq": "jq", "yq": "jq"}.get(name, name)
    family = "grep" if name in GREPS - {"rg"} else family
    words = operands(args, VALUED.get(family, ()))
    if family in ("grep", "rg", "sed", "awk", "jq"):
        # The first operand is the pattern, script or filter, unless an option gave it.
        given = {"-e", "-f", "--regexp", "--file", "--expression", "--from-file"}
        if not (given & set(args) or any(arg.startswith(tuple(g + "=" for g in given)) for arg in args)):
            words = words[1:]
    return [word for word in words if word != "-"]


def recursive(name, args):
    if name in RECURSING:
        return True
    return name in GREPS and (
        bool(letters(args) & {"r", "R"})
        or bool({"--recursive", "--dereference-recursive", "--directories=recurse"} & set(args))
    )


def sees_hidden(name, args):
    if name not in SKIPS_HIDDEN:
        return True
    unrestricted = any(re.fullmatch(r"-u{2,}", arg) for arg in args)
    return unrestricted or "--hidden" in args or "." in letters(args) or "--unrestricted" in args


def globs(args, *options):
    found = []
    for i, arg in enumerate(args):
        for option in options:
            if arg == option and i + 1 < len(args):
                found.append(args[i + 1])
            elif arg.startswith(option + "="):
                found.append(arg[len(option) + 1 :])
    return found


def search_output(name, args, path):
    """What this grep-like call would print from path alone, found by running
    its own pattern and matching options on that file here, with the output
    kept out of the context; None when that cannot be told."""
    keep, patterns, words, dashes, i = [], [], [], False, 0
    valued = VALUED["rg" if name == "rg" else "grep"]
    while i < len(args):
        arg, value = args[i], args[i + 1] if i + 1 < len(args) else None
        if dashes or not arg.startswith("-") or arg == "-":
            words.append(arg)
        elif arg == "--":
            dashes = True
        elif arg in ("-e", "--regexp", "-f", "--file", "-A", "-B", "-C") and value is not None:
            (keep if arg in ("-A", "-B", "-C") else patterns).extend([arg, value])
            i += 1
        elif arg.startswith(("--regexp=", "--file=")):
            patterns.append(arg)
        elif re.fullmatch(r"-[ABC]?\d+|--(after-|before-)?context=\d+", arg) or arg in MATCHING:
            keep.append(arg)
        elif arg in valued and value is not None:
            i += 1  # its value is no pattern
        elif not arg.startswith("--") and set(arg[1:]) & set(MATCHING_LETTERS):
            keep.append("-" + "".join(c for c in arg[1:] if c in MATCHING_LETTERS))
        i += 1
    if not patterns:
        if not words:
            return None
        patterns = ["-e", words[0]]
    plain = ["--no-filename", "--no-line-number"] if name == "rg" else ["-h"]
    try:
        done = subprocess.run(
            [name, *keep, *plain, *patterns, "--", path], capture_output=True, text=True, timeout=5
        )
    except (OSError, subprocess.SubprocessError):
        return None
    return {0: done.stdout, 1: ""}.get(done.returncode)


def prints_secret_from(name, args, path):
    """Whether this reader prints anything secret from the secret file at path.
    A grep-like search prints only what it matches: nothing, or from a .env
    only the names (grep -o '^[A-Z_]*='), shows no secret. Anything else does."""
    if name not in SEARCHES:
        return True
    out = search_output(name, args, path)
    if out is None:
        return True  # cannot tell: the file is secret, and the call reads it
    lines = [line for line in out.splitlines() if line.strip() and line != "--"]
    if not dotenv(os.path.basename(path)):
        return bool(lines)
    return not all(NAME_ONLY.fullmatch(line) for line in lines)


def shown_by_reader(name, args, stdin, variables, where):
    """What secret this reader call would print, as 'word (what)', or None."""
    if quiet(name, args):
        return None
    shows = lambda path: prints_secret_from(name, args, path)  # noqa: E731
    words = read_files(name, args)
    deep = recursive(name, args)
    if deep and not words:
        words = ["."]
    for word in words + ([stdin] if stdin else []):
        for path in expand(word, variables, where):
            if os.path.isdir(path) and deep:
                include = globs(args, "--include") + [g for g in globs(args, "-g", "--glob") if not g.startswith("!")]
                exclude = globs(args, "--exclude") + [g[1:] for g in globs(args, "-g", "--glob") if g.startswith("!")]
                held = held_under(
                    path, sees_hidden(name, args), include, exclude, globs(args, "--exclude-dir"), shows
                )
                if held:
                    return f"{word}, which holds {held}"
            else:
                what = secret(path)
                if what and (word == stdin or shows(path)):
                    return f"{word} ({what})"
    return None


def bash(command, cwd):
    """(rule, call, where, what) for the first call that would show a secret,
    and the calls that named one but sent it elsewhere, as (rule, call, where)."""
    passed = []
    for call, where, variables in located(command, cwd):
        name, args = call
        text = " ".join([name, *args])
        what = printed_secret(name, args)
        rule = "prints a secret" if what else "reads a secret"
        if not what and name in READERS:
            what = shown_by_reader(name, args, call.stdin, variables, where)
        if not what:
            continue
        if call.output() != "shown":
            passed.append((rule, text, where))
            continue
        return (rule, text, where, what), passed
    return None, passed


def main():
    event = json.load(sys.stdin)
    tool = event.get("tool_name") or ""
    given = event.get("tool_input") or {}
    cwd = event.get("cwd") or os.getcwd()
    sid = event.get("session_id") or ""
    keep = "Use it without showing it: inside $(...), or with the output sent to a file."
    if tool == "Read":
        path = os.path.join(cwd, given.get("file_path") or "")
        what = secret(path)
        if what:
            log("secret-refuse", sid, "Read", path, cwd, what)
            deny(
                f"ctx's secrets guard refused reading {path}: it is {what}, and would land in the "
                "context. Its metadata passes: ls -l, stat, test -e, wc -l."
            )
        return
    if tool == "Grep":
        if (given.get("output_mode") or "files_with_matches") != "content":
            return
        path = os.path.join(cwd, given.get("path") or ".")
        glob_ = [given["glob"]] if given.get("glob") else []
        what = held_under(path, True, glob_) if os.path.isdir(path) else secret(path)
        if what:
            log("secret-refuse", sid, "Grep", path, cwd, what)
            deny(
                f"ctx's secrets guard refused a Grep of {path} showing content: it would print "
                f"lines of {what}. files_with_matches or count pass, and so does a narrower path or glob."
            )
        return
    found, passed = bash(given.get("command") or "", cwd)
    for rule, call, where in passed:
        log("secret-pass", sid, rule, call, where)
    if not found:
        return
    rule, call, where, what = found
    log("secret-refuse", sid, rule, call, where, what)
    deny(
        f"ctx's secrets guard refused `{call[:200]}` in {where}: it would print {what} into the "
        f"context. {keep} A file's metadata passes: ls, stat, test -e, wc, grep -c."
    )


if __name__ == "__main__":
    try:
        main()
    except Exception:  # noqa: BLE001 -- see the docstring: errors let the call through
        pass
