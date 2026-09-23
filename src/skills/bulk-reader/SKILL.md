---
name: bulk-reader
description: Delegates file reading to a cheap non-Claude model (Gemini, via agy) instead of pulling the content into context. Use when reading files over ~350 lines, answering a question that spans 3+ files, or summarising big diffs and logs. If the project has a graphify index, query the graph first.
---

**Before delegating, check whether it is a graph question.** If the project has
`graphify-out/graph.json` (and `graphify` on PATH), a structural question — _who
calls X, what this module exposes, how A and B connect_ — is answered from the
AST, free per query and with no risk of an invented summary:

```bash
graphify query "<question>"  --graph <root>/graphify-out/graph.json
graphify explain "<symbol>"  --graph <root>/graphify-out/graph.json
graphify path "<A>" "<B>"    --graph <root>/graphify-out/graph.json
```

The blocking hooks already detect the index and build these commands with the
right path when it exists. `shunt-bulk-read` is for what no graph indexes — logs,
dumps, generated files, huge diffs — and for when there is no index:

```bash
shunt-bulk-read --question "<question>" --paths <file1> [<file2> ...]
```

The files go to the worker (Gemini Flash through `agy`, on the Gemini
subscription) and **never enter your context** — only the answer does. It also
does not spend Claude quota. Each call is independent: for a follow-up, call
again with the same `--paths`; resending the files costs you nothing.

Lines are numbered before they reach the worker, so line citations in the answer
are copied from the file, not counted. Still, **verify on disk** (`sed -n 'N,Mp'`)
any exact line or value before using it in an edit — the answer is a summary,
not the file.

When **not** to use it: a file you will edit as a whole, a small file, or when
you already know the slice you want (then use `Read` with `offset`/`limit`, or
`grep`/`sed -n` with a narrow range, which pass the hooks).

The hooks count what a whole command line would print — `cd`, loops, several
files and pipes included — so splitting a dump into ten small `cat`s does not
get around them; delegating does.

Variables: `SHUNT_MODEL` (default `gemini-3.8-flash-medium`), `SHUNT_TIMEOUT_SECONDS`
(300), `SHUNT_MAX_PAYLOAD_BYTES` (2000000 ≈ 500k tokens).
