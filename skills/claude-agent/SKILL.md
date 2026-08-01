---
name: claude-agent
description: Run Claude Code CLI headless as an independent coding agent for implementation, investigation, planning, or review in a local workspace. Use when asked to delegate work to a separate Claude session, get an independent Claude pass, capture a Claude session ID, or resume and continue an earlier headless Claude run.
---

# Claude Agent

Run `claude -p` from the intended workspace, give it a bounded outcome,
monitor it at the task's time scale, and preserve its session ID when
follow-up work is likely.

Read `/cross-provider-agent` first and apply its doctrine to the whole
dispatch; this skill is only the Claude transport.

## Check the CLI and authentication

Treat installed help as authoritative because Claude Code evolves:

```bash
claude --version
claude --help
```

If a run fails with an authentication error, ask the user to run `claude`
interactively and `/login`. Never display, copy, or embed authentication
files or tokens.

## Start a worker

Run from the intended workspace directory — the working directory is the
workspace.

```bash
cd /absolute/path/to/workspace && claude -p --output-format json \
  --permission-mode plan \
  "Act as an independent worker for the current task. Complete TASK without making changes and return a concise evidence-backed result."
```

For authorized implementation, drop `--permission-mode plan` and grant the
task's specific needs with `--allowedTools`.

## Capture the session ID

Allocate the ID before starting when it must be known even if the first turn
is interrupted:

```bash
claude_session_id="$(uuidgen)"
claude -p --output-format json --session-id "$claude_session_id" \
  "Inspect the repository and complete TASK. Verify the result."
```

With `--output-format json`, the terminal result object
carries `session_id`, `result`, and `is_error`.

## Resume a session

With the flag:

```bash
--resume "$claude_session_id"
```

Use `--continue` only when continuing the most recent conversation is
unambiguous. Add `--fork-session` when the follow-up must not extend the
original session's history.

## Profiled dispatch: github-pr-reviewer

`profiles/github-pr-reviewer/settings.json` encodes the profile from
`/cross-provider-agent` as pure permission rules: `dontAsk` default mode
(auto-denies anything not pre-approved, so a headless run never stalls on a
prompt), narrow allows for workspace reads and the profile's `gh` surface,
and explicit denies for the nearby writes.

```bash
cd /absolute/path/to/workspace && claude -p --output-format json \
  --settings /absolute/path/to/claude-agent/profiles/github-pr-reviewer/settings.json \
  --setting-sources "" \
  "REVIEW_TASK"
```

`--setting-sources ""` loads no user, project, or local settings layer, so
pre-existing configuration cannot widen the child's effective authority.

## Monitor and verify

Run a long invocation in the background and inspect its output at intervals
appropriate to the task. On completion require a zero exit status and
`"is_error": false` in the result object; treat a nonzero exit or an error
result as failure. The `result` field contains the worker's response.
