---
name: claude-agent
description: Run Claude Code CLI headless as an independent coding agent for implementation, investigation, planning, or review in a local workspace. Use when asked to delegate work to a separate Claude session, get an independent Claude pass, capture a Claude session ID, or resume and continue an earlier headless Claude run.
---

# Claude Agent

Run `claude -p` from the intended workspace, give it a bounded outcome,
monitor it at the task's time scale, and preserve its session ID when
follow-up work is likely.

Doctrine — authorization scope, least authority, prompt discipline, session
and verification rules — lives in `/cross-provider-agent`. This skill is the
Claude transport.

## Check the CLI and authentication

Treat installed help as authoritative because Claude Code evolves:

```bash
claude --version
claude --help
```

If a run fails with an authentication error, ask the user to run `claude`
interactively and `/login`. Never display, copy, or embed authentication
files or tokens.

Omit `--model` unless the user requests a particular model; use the
configured default rather than hard-coding one.

## Start a worker

Run from the intended workspace directory — the working directory is the
workspace. Default analysis, planning, and review to plan mode:

```bash
cd /absolute/path/to/workspace && claude -p --output-format json \
  --permission-mode plan \
  "Act as an independent worker for the current task. Complete TASK without making changes and return a concise evidence-backed result."
```

For authorized implementation, drop `--permission-mode plan` and grant the
task's specific needs with `--allowedTools` entries rather than a broader
permission mode.

## Capture the session ID

Allocate the ID before starting when it must be known even if the first turn
is interrupted:

```bash
claude_session_id="$(uuidgen)"
claude -p --output-format json --session-id "$claude_session_id" \
  "Inspect the repository and complete TASK. Verify the result."
```

Otherwise parse it from the run: with `--output-format json`, the terminal
result object carries `session_id`, `result`, and `is_error`. Parse it only
after a clean process exit. Treat the output as potentially sensitive
because it can contain prompts, paths, and file content.

## Resume a session

Resume a specific session from the same workspace, sequentially:

```bash
claude -p --output-format json --resume "$claude_session_id" \
  "Continue from the prior work. Address FOLLOW_UP and verify the result."
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
pre-existing configuration cannot widen the child's effective authority: the
profile file is the whole policy. Nothing touches persistent configuration,
so there is no staging or restore step.

## Monitor and verify

Run a long invocation in the background and inspect its output at intervals
appropriate to the task. On completion require a zero exit status and
`"is_error": false` in the result object; treat a nonzero exit, an error
result, or missing output as failure. The `result` field contains the
worker's response.
