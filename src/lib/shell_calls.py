"""Split a Bash tool command into the calls it runs, in order.

Generalized from the pgrep guard in ~/NixOS (scripts/claude-code-pgrep-guard.py),
whose lexer was replayed on the 304 commands of 30 days that name pgrep or
pkill: quotes, comments, $(...) and backticks, bash -c strings, and
here-documents, whose bodies are text and not commands. A word that only names
a command, in an echo, a commit message or a here-document, is not a call.

calls(command) gives each call as a Call, a (name, args) pair with the name's
directory cut off; an assignment such as S=/tmp/x gives ("=", [name, value]),
so a caller can follow the variables a later call names. A redirection and its
target are left out of the args, and kept on the Call: where its output goes
(Call.output) and the file a < feeds it (Call.stdin). located(command, cwd)
also follows cd, pushd and the assignments, and gives each other call with the
folder it runs in.
"""

import glob
import os
import re
import shlex

HOME = os.path.expanduser("~")
# Words after which the next word is a command: shell syntax and the wrappers
# that run their arguments (timeout 5 git, xargs -r rm, sudo rm).
SEPARATORS = {
    ";",
    ";;",
    "&",
    "&&",
    "|",
    "||",
    "|&",
    "(",
    ")",
    "`",
    "!",
    "{",
    "}",
    "if",
    "then",
    "elif",
    "else",
    "do",
    "while",
    "until",
    "time",
}
WRAPPERS = {
    "timeout",
    "nohup",
    "nice",
    "stdbuf",
    "xargs",
    "sudo",
    "doas",
    "env",
    "exec",
    "command",
    "builtin",
    "watch",
    "setsid",
}
# Shells whose -c string is a command of its own (timeout 60 bash -c '...').
SHELLS = {"bash", "sh", "zsh", "dash"}
# A here-document's body is text, not commands: keep only its first line.
HEREDOC = re.compile(
    r"(<<-?\s*(['\"]?)(\w+)\2[^\n]*)\n.*?\n[ \t]*\3[ \t]*(?=\n|$)", re.S
)
ASSIGNMENT = re.compile(r"[A-Za-z_]\w*=.*", re.S)
# shlex splits 2>&1 into 2, >& and 1, and >/dev/null into > and /dev/null.
REDIRECTION = re.compile(r"[<>&|]*[<>][<>&|]*")
DURATION = re.compile(r"[\d.]+[smhd]?")
# The file descriptor written against a redirection, as in 2>&1, marked by
# uncommented(): shlex alone gives the same 5 for head -n 5 > out.
FD = re.compile(r"__fd(\d)__")
# What a $(...) or a backtick span leaves in the text around it: a word no
# expansion can resolve. A <(...) or >(...) leaves the path bash passes.
CAPTURED = "$__ctx_substitution"
PROCESS = "/dev/fd/63"
# Where a redirection to one of these still ends up in the tool's output.
SHOWN = {"/dev/stdout", "/dev/stderr", "/dev/tty", "/dev/fd/1", "/dev/fd/2"}


class Call(tuple):
    """A call as (name, args). sink is where its own output goes: "shown"
    (the tool's result), "file", or "captured" by a $(...) or backticks;
    piped_to is the call its output feeds, parent the bash -c that runs it,
    and stdin the file a < redirection feeds it."""

    def __new__(cls, name, args):
        call = super().__new__(cls, (name, args))
        call.sink, call.piped_to, call.parent, call.stdin = "shown", None, None, None
        return call

    def redirect(self, operator, fd, target):
        if operator == "<" and fd in (None, "0"):
            self.stdin = target
        elif operator.startswith("&>"):
            self.sink = "shown" if target in SHOWN else "file"
        elif ">" in operator and not operator.startswith("<") and fd in (None, "1"):
            if operator == ">&" and target.isdigit():
                return  # >&2 and >&1 leave it in the tool's output
            self.sink = "shown" if target in SHOWN else "file"

    def output(self):
        """Where what this call prints ends up, through its pipes and the bash
        -c that runs it: the end of a pipeline decides."""
        call = self
        while call.piped_to is not None:
            call = call.piped_to
        if call.sink == "shown" and call.parent is not None:
            return call.parent.output()
        return call.sink


def uncommented(command):
    """The command with its comments cut, each unquoted newline made a ';', and
    the file descriptor before a redirection marked. shlex alone would end a
    comment only at a newline, and a newline between two commands would be
    mere whitespace to it."""
    out, quote, i = [], None, 0
    while i < len(command):
        char = command[i]
        if char == "\\" and quote != "'":
            out.append(command[i : i + 2])
            i += 2
            continue
        if quote:
            quote = None if char == quote else quote
        elif char in "'\"":
            quote = char
        elif char == "#" and (not out or out[-1][-1] in " \t\n;&|("):
            while i < len(command) and command[i] != "\n":
                i += 1
            continue
        elif char == "\n":
            char = " ; "
        elif (
            char.isdigit()
            and command[i + 1 : i + 2] in ("<", ">")
            and (not out or out[-1][-1] in " \t\n;&|(")
        ):
            char = f" __fd{char}__"
        out.append(char)
        i += 1
    return "".join(out)


def words(command):
    """The command's words. A backtick left here is a literal one: blanked()
    has already taken the pairs that run a command."""
    lexer = shlex.shlex(uncommented(command), posix=True, punctuation_chars=True)
    lexer.whitespace_split = True
    lexer.commenters = ""
    yield from lexer


def blanked(text):
    """The text with each outermost $(...), <(...), >(...) and `...` put back
    as one word, and what each held: [(inside, captured)]. Quoted or not: a
    double-quoted "$(git stash drop)" is one word to shlex, and still runs."""
    out, inner, i = [], [], 0
    while i < len(text):
        pair = text[i : i + 2]
        if pair in ("$(", "<(", ">(") and text[i - 1 : i] != "\\":
            depth, end = 0, i + 2
            while end < len(text) and depth >= 0:
                depth += {"(": 1, ")": -1}.get(text[end], 0)
                end += 1
            inner.append((text[i + 2 : end - 1], pair == "$("))
            out.append(CAPTURED if pair == "$(" else PROCESS)
            i = end
        elif text[i] == "`" and text[i - 1 : i] != "\\":
            end = text.find("`", i + 1)
            while end > 0 and text[end - 1] == "\\":
                end = text.find("`", end + 1)
            if end < 0:
                out.append(text[i:])
                break
            inner.append((text[i + 1 : end], True))
            out.append(CAPTURED)
            i = end + 1
        else:
            out.append(text[i])
            i += 1
    return "".join(out), inner


def calls(command, sink="shown"):
    """Each call the command runs, in the order written; the calls inside
    $(...), <(...) and backticks come after the rest. A $(...) or backticks
    capture what their calls print; a <(...) hands it to the call around it,
    so it counts as shown."""
    top, inner = blanked(HEREDOC.sub(r"\1", command))
    try:
        found = simple_calls(top)
    except ValueError:  # quotes shlex cannot pair: split on blanks instead
        found = loose_calls(top)
    for call in found:
        if call.sink == "shown":
            call.sink = sink
    for text, captured in inner:
        found += calls(text, "captured" if captured else sink)
    return found


def at_command_position(prev):
    return (
        prev is None
        or prev in SEPARATORS
        or prev in WRAPPERS
        or prev.startswith("-")
        or DURATION.fullmatch(prev)
        or ASSIGNMENT.fullmatch(prev)
    )


def simple_calls(text):
    found, current, prev = [], None, None
    fd = redirection = piping = None
    for word in words(text):
        # A redirection, its descriptor and its target are no arguments, and
        # leave prev as it was: 2>/dev/null git ... still starts a call.
        if redirection is not None:
            if current is not None:
                current.redirect(*redirection, word)
            redirection = None
            continue
        if FD.fullmatch(word):
            fd = FD.fullmatch(word).group(1)
            continue
        if REDIRECTION.fullmatch(word):
            redirection, fd = (word, fd), None
            continue
        if current is not None:
            if word in SEPARATORS:
                piping = current if word in ("|", "|&") else None
                current = None
            else:
                if current[0] in SHELLS and re.fullmatch(r"-\w*c", prev or ""):
                    for call in calls(word):
                        call.parent = call.parent or current
                        found.append(call)
                current[1].append(word)
        elif word in SEPARATORS:
            pass
        elif at_command_position(prev):
            if ASSIGNMENT.fullmatch(word):
                found.append(Call("=", word.split("=", 1)))
            elif not (word.startswith("-") or DURATION.fullmatch(word)):
                name = word.rsplit("/", 1)[-1]
                if name in WRAPPERS:
                    found.append(Call(name, []))  # the next word is still a command
                else:
                    current = Call(name, [])
                    if piping is not None:
                        piping.piped_to, piping = current, None
                    found.append(current)
        prev = word
    return found


def loose_calls(text):
    found = []
    for part in re.split(r"&&|\|\||[;&|\n]", uncommented(text)):
        pieces = [piece for piece in part.split() if not FD.fullmatch(piece)]
        while pieces and ASSIGNMENT.fullmatch(pieces[0]):
            found.append(Call("=", pieces.pop(0).split("=", 1)))
        while pieces and pieces[0].rsplit("/", 1)[-1] in WRAPPERS:
            pieces.pop(0)
        if pieces:
            found.append(Call(pieces[0].rsplit("/", 1)[-1], pieces[1:]))
    return found


# --- the words of a call ---------------------------------------------------------


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


def located(command, cwd):
    """Each call but cd, pushd and the assignments, as (call, folder, variables):
    the folder it runs in and the variables set before it, as far as the
    command's own text says."""
    where, variables = cwd, {}
    for call in calls(command):
        name, args = call
        if name == "=":
            if len(args) == 2:  # a word = at a command's place is no assignment
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
        else:
            yield call, where, variables
