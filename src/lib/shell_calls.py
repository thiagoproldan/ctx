"""Split a Bash tool command into the calls it runs, in order.

Generalized from the pgrep guard in ~/NixOS (scripts/claude-code-pgrep-guard.py),
whose lexer was replayed on the 304 commands of 30 days that name pgrep or
pkill: quotes, comments, $(...) and backticks, bash -c strings, and
here-documents, whose bodies are text and not commands. A word that only names
a command, in an echo, a commit message or a here-document, is not a call.

calls(command) gives each call as (name, args), with the name's directory cut
off; an assignment such as S=/tmp/x gives ("=", [name, value]), so a caller can
follow the variables a later call names. A redirection and its target are left
out of the args.
"""

import re
import shlex

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


def uncommented(command):
    """The command with its comments cut and each unquoted newline made a ';'.
    shlex alone would end a comment only at a newline, and a newline between
    two commands would be mere whitespace to it."""
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
        out.append(char)
        i += 1
    return "".join(out)


def words(command):
    """The command's words, with backticks split off."""
    lexer = shlex.shlex(uncommented(command), posix=True, punctuation_chars=True)
    lexer.whitespace_split = True
    lexer.commenters = ""
    for word in lexer:
        parts = word.split("`")
        for i, part in enumerate(parts):
            if i:
                yield "`"
            if part:
                yield part


def substitutions(text):
    """The inside of every $(...) and `...`, quoted or not: a double-quoted
    "$(git stash drop)" is one word to shlex, and still runs."""
    for start in (m.end() for m in re.finditer(r"\$\(", text)):
        depth, end = 0, start
        while end < len(text) and depth >= 0:
            depth += {"(": 1, ")": -1}.get(text[end], 0)
            end += 1
        yield text[start : end - 1]
    ticks = [m.start() for m in re.finditer(r"(?<!\\)`", text)]
    for opening, closing in zip(ticks[::2], ticks[1::2]):
        yield text[opening + 1 : closing]


def calls(command):
    """Each call the command runs, as (name, args), in the order written; the
    calls inside $(...) and backticks come after the rest."""
    command = HEREDOC.sub(r"\1", command)
    found = []
    for text in [command, *substitutions(command)]:
        try:
            found += simple_calls(text)
        except ValueError:  # quotes shlex cannot pair: split on blanks instead
            found += loose_calls(text)
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
    found, current, prev, target = [], None, None, False
    for word in words(text):
        if target:  # a redirection's target is no argument
            target = False
        elif REDIRECTION.fullmatch(word):
            target = True
            if current and current[1] and current[1][-1].isdigit():
                current[1].pop()  # the 2 of 2>&1
        elif current is not None:
            if word in SEPARATORS:
                current = None
            else:
                if current[0] in SHELLS and re.fullmatch(r"-\w*c", prev or ""):
                    found += calls(word)
                current[1].append(word)
        elif word in SEPARATORS:
            pass
        elif at_command_position(prev):
            if ASSIGNMENT.fullmatch(word):
                found.append(("=", word.split("=", 1)))
            elif not (word.startswith("-") or DURATION.fullmatch(word)):
                name = word.rsplit("/", 1)[-1]
                if name in WRAPPERS:
                    found.append((name, []))  # the next word is still a command
                else:
                    current = (name, [])
                    found.append(current)
        prev = word
    return found


def loose_calls(text):
    found = []
    for part in re.split(r"&&|\|\||[;&|\n]", uncommented(text)):
        pieces = part.split()
        while pieces and ASSIGNMENT.fullmatch(pieces[0]):
            found.append(("=", pieces.pop(0).split("=", 1)))
        while pieces and pieces[0].rsplit("/", 1)[-1] in WRAPPERS:
            pieces.pop(0)
        if pieces:
            found.append((pieces[0].rsplit("/", 1)[-1], pieces[1:]))
    return found
