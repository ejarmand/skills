---
name: opencode-agent
description: Run OpenCode CLI as an independent coding agent across its provider catalog, capture its session, or dispatch its profiled GitHub PR reviewer.
---

# OpenCode Agent

Run `opencode run` from the intended workspace with one selected
`provider/model`. Read `/cross-provider-agent` first; backend choice and
authority doctrine live there.

## Check the transport

This skill targets OpenCode 2 (verified against 2.0.28). Treat installed help
as authoritative:

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

Pass the task as a plain argument, not after `--`: OpenCode 2 sends anything
after `--` twice. Select a variant in the model, as `opencode/<model>#high`.
`run` attaches to the user's background OpenCode service unless given
`--standalone`.

Capture `sessionID` from the first JSON event. Resume the same session with
`--session SESSION_ID`; add `--fork` when follow-up work must branch from it.
On completion require a successful process exit and no error event or failed
tool. OpenCode 2 exits nonzero when a step fails or the run is interrupted,
and does not always emit a final `step_finish`. The calling agent owns
monitoring and termination.

## Profiled dispatch

For running limited opencode sessions based on particular profiles use 

```bash
/absolute/path/to/opencode-agent/scripts/run-profiled.sh \
  --workspace /absolute/path/to/workspace \
  --profile github-pr-reviewer \
  --model opencode/deepseek-v4-flash \
  -- "REVIEW_TASK"
```

Add `--variant high` before `--` when the review calls for high effort. The
runner passes it to OpenCode in the model, as `opencode/<model>#high`. The
prompt must not start with `-`. `--agent` picks another primary agent from the
profile; the runner refuses subagents, which OpenCode would otherwise silently
swap for its default agent.

The runner starts OpenCode with `--standalone`, a private server inside the
sandbox, so a profiled run never attaches to the user's background service and
its config and credentials. OpenCode sees no user, project or system
(`/etc/opencode`) config or plugins; the only plugin is the runner's own,
below.

The runner mounts the workspace read-only at its own path, and a linked
worktree's repository git dir with it, so `git` and `gh` work inside as they do
outside; `gh` needs no `--repo`.

OpenCode prints nothing while it waits on a provider, so the runner bounds
those waits:

- `--provider-timeout SECONDS` (default 120) limits the wait for response
  headers and between stream chunks. OpenCode retries a timed-out request a
  few times, then emits an error event and exits nonzero. Timeouts the profile
  sets for that provider win.
- A run with no event for `--idle-timeout SECONDS` (default 1800) is stopped
  with exit 75, after the runner prints what each OpenCode process was waiting
  on (its stdin, kernel wait channel and TCP connections) and the log tail.
  Treat 75 as a failed run and report those lines rather than retrying
  blindly.
- OpenCode 2 waits out a provider's rate limit or overload (429, 503, 529)
  silently, honoring retry-after up to 15 minutes a retry. The runner's plugin
  lets it wait at most `--rate-limit-grace SECONDS` (default 60); a longer
  retry-after fails the run, and the runner prints the provider's error and
  exits 76. Retry later or dispatch another provider.

### available profiles

**github-pr-reviewer**: `profiles/github-pr-reviewer/config.json` encodes the
provider-neutral contract from `/cross-provider-agent`, including the
`code-review` skill and its two named child agents.
