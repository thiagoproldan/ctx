---
name: code-writer
description: Delegates boilerplate generation to a cheap non-Claude model (Gemini, via agy), writing straight to disk. Use for tests, config, docstrings, type stubs — any generation where more than ~80% is predictable from a reference file.
---

```bash
# Generate and write straight to the target file
ctx-code-write --spec "<what to generate>" --reference <model-file> --target <destination>

# Or print to stdout (omit --target)
ctx-code-write --spec "<what to generate>" --reference <model-file>
```

With `--target`, the generated code goes to disk without passing through your
context. `--reference` is required: without a file whose pattern to follow, the
output is plausible code that does not match the project. An existing target is
never overwritten without `--force`.

Each call is independent. To build on what was just generated, pass that file as
the next call's `--reference`.

After generating: review it and make the surgical edits for the ~5–20% that need
judgement. And **run the tests** — nobody has verified the worker's output.

Variables: `CTX_MODEL` (default `gemini-3.8-flash-medium`), `CTX_TIMEOUT_SECONDS` (300).
