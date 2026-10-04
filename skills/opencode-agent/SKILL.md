---
name: opencode-agent
description: CLI fallback for launching OpenCode workers or resuming existing OpenCode sessions. Use when harness delegation cannot run the requested task or the user requests CLI execution.
---

# OpenCode Agent

For CLI fallback launches or existing CLI sessions, read
`/cross-provider-agent` and run `opencode run` from the intended
checkout with the selected `provider/model`.

## Check the transport

Treat installed help as authoritative:

```bash
opencode --version
opencode run --help
opencode auth list
```

OpenCode accepts stored provider credentials and providers' conventional
environment variables.

## Choose the provider route

The `provider/` prefix decides who sees the prompt.

- Paid models: use `opencode/<model>` (OpenCode Zen). Zen's paid models
  follow its zero-retention policy; OpenAI and Anthropic models there are
  retained 30 days.
- Free, trial and Contributor models on Zen collect data. Use them only
  where repository policy allows.

## Start and monitor a worker

```bash
cd /absolute/path/to/workspace && \
  opencode run --format json --model opencode/<model> "TASK"
```


Capture `sessionID` from the first JSON event. Resume the same session with
`--session SESSION_ID`; add `--fork` when follow-up work must branch from it.
Check the process exit, final `step_finish` with reason `stop`, and the returned
result. An unresolved error or incomplete task needs recovery; a failed tool
call that the worker recovered from does not require repeating the work.

## Profiled dispatch

Use this section when the task requests a named CLI authority profile.

For running limited opencode sessions based on particular profiles use 

```bash
/absolute/path/to/opencode-agent/scripts/run-profiled.sh \
  --workspace /absolute/path/to/workspace \
  --profile github-pr-reviewer \
  --model opencode/deepseek-v4-flash \
  -- "REVIEW_TASK"
```

Add `--variant high` before `--` when the review calls for high effort. The
runner passes the optional variant to OpenCode, which reports an error if the
selected model does not support it. `--agent` picks another primary agent from
the profile; the runner refuses subagents, which OpenCode would otherwise
silently swap for its default agent.

The runner mounts the workspace read-only at its own path, and a linked
worktree's repository git dir with it, so `git` and `gh` work inside as they do
outside; `gh` needs no `--repo`.

OpenCode prints nothing while it waits on a provider, so the runner bounds
those waits:

- `--provider-timeout SECONDS` (default 120) limits the wait for response
  headers and between stream chunks. OpenCode retries a timed-out request a
  few times, then emits an error event and exits nonzero. Timeouts the profile
  sets for that provider win.
- When OpenCode logs a provider rate limit or overload (429, 503, 529) and
  then emits no event for `--rate-limit-grace SECONDS` (default 60), the
  runner prints the logged error and exits 76 instead of waiting out
  OpenCode's silent retries.
  Retry later or dispatch another provider.
- A run with no event for `--idle-timeout SECONDS` (default 1800) is stopped
  with exit 75, after the runner prints what OpenCode was waiting on (its
  stdin, kernel wait channel and TCP connections) and its log tail. Treat 75
  as a failed run and report those lines rather than retrying blindly.

### available profiles

**github-pr-reviewer**: `profiles/github-pr-reviewer/config.json` encodes the
provider-neutral contract from `/cross-provider-agent`, including the
`code-review` skill and its two named child agents.
