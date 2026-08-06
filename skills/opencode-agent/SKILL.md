---
name: opencode-agent
description: Run OpenCode CLI as an independent coding agent across its provider catalog, capture its session, or dispatch its profiled GitHub PR reviewer.
---

# OpenCode Agent

Run `opencode run` from the intended workspace with one selected
`provider/model`. Read `/cross-provider-agent` first; backend choice and
authority doctrine live there.

## Check the transport

Treat installed help as authoritative:

```bash
opencode --version
opencode run --help
opencode auth list
```

OpenCode accepts stored provider credentials and providers' conventional
environment variables.

## Start and monitor a worker

```bash
cd /absolute/path/to/workspace && \
  opencode run --format json --model provider/model "TASK"
```


Capture `sessionID` from the first JSON event. Resume the same session with
`--session SESSION_ID`; add `--fork` when follow-up work must branch from it.
On completion require a successful process exit, no error event or failed tool,
and a final `step_finish` whose reason is `stop`. The calling agent owns
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


Which combines bubblewrap and agent profiles.

### available profiles

**github-pr-reviewer**: `profiles/github-pr-reviewer/config.json` encodes the
provider-neutral contract from `/cross-provider-agent`, including the
`code-review` skill and its two named child agents.
