---
name: claude-agent
description: CLI fallback for launching headless Claude Code workers or resuming existing Claude CLI sessions. Use when harness delegation cannot run the requested task or the user requests CLI execution.
---

# Claude Agent

For CLI fallback launches or existing CLI sessions, read
`/cross-provider-agent` and run `claude -p` from the intended
checkout. Preserve the session ID for follow-up work.

## Check the CLI and authentication

Treat installed help as authoritative because Claude Code evolves:

```bash
claude --version
claude --help
```

If a run fails with an authentication error, ask the user to run `claude`
interactively and `/login`. Never display, copy, or embed authentication
files or tokens.

## agent permissions

For analysis and review, use `--permission-mode plan`. For implementation,
use the task's authorized tools with `--allowedTools`.

## Start a worker

Run from the intended workspace directory — the working directory is the
workspace.

```bash
cd /absolute/path/to/workspace && claude -p --output-format json \
  --permission-mode plan \
  "[message]"
```

## Capture the session ID

When the ID must be known even if the first turn is interrupted, allocate it
up front and pass it with `--session-id "$(uuidgen)"`. Otherwise read
`session_id` from the terminal result object.

## Resume a session

Resume with `--resume "$claude_session_id"`. Use `--continue` only when
continuing the most recent conversation is unambiguous. Add `--fork-session`
when the follow-up must not extend the original session's history.

## Monitor and verify

On completion require a zero exit status and `"is_error": false` in the
result object; the `result` field contains the worker's response.

## Profiled dispatch

Use this section when the task requests a named CLI authority profile.

```bash
cd /absolute/path/to/workspace && claude -p --output-format json \
  --settings /absolute/path/to/claude-agent/profiles/github-pr-reviewer/settings.json \
  --setting-sources "" \
  --plugin-dir /absolute/path/to/skills-repo \
  "REVIEW_TASK"
```

`--setting-sources ""` keeps pre-existing configuration from widening the
child's authority, but also unloads installed skills, so `--plugin-dir` loads
the skills repository root — always the repo that provides this adapter,
never the workspace under review. Cite skills by namespaced name
(`skills-repo:code-review`); the bare name resolves to Claude's bundled
code-review, which rejects model invocation.

### available profiles
**github-pr-reviewer** : `profiles/github-pr-reviewer/settings.json` encodes
the profile from `/cross-provider-agent` as pure permission rules: `dontAsk`
default mode (auto-denies anything not pre-approved, so a headless run never
stalls on a prompt), narrow allows for workspace reads and the profile's `gh`
surface, and explicit denies for the nearby writes.
