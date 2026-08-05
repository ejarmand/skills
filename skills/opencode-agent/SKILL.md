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
environment variables. Never print or copy credentials into prompts.

## Start and monitor a worker

```bash
cd /absolute/path/to/workspace && \
  opencode run --format json --model provider/model "TASK"
```

Do not add `--auto` merely to make a headless run unattended. OpenCode
permissions guide tool use but are not an OS sandbox; use an external boundary
when the task requires enforced isolation.

Capture `sessionID` from the first JSON event. Resume the same session with
`--session SESSION_ID`; add `--fork` when follow-up work must branch from it.
On completion require a successful process exit, no error event or failed tool,
and a final `step_finish` whose reason is `stop`. The calling agent owns
monitoring and termination.

## Profiled dispatch

The `github-pr-reviewer` profile is supported on Linux with OpenCode 1.18.13
and bubblewrap. Supply provider and GitHub credentials through their normal
environment variables:

```bash
/absolute/path/to/opencode-agent/scripts/run-profiled.sh \
  --workspace /absolute/path/to/workspace \
  --profile github-pr-reviewer \
  --model provider/model \
  -- "REVIEW_TASK"
```

The runner gives the workspace and this repository's skills read-only mounts,
keeps OpenCode state disposable, and suppresses project and external skill
configuration. The selected model is also used by the profile's Standards and
Spec children. The reviewer publishes its result directly with
`gh pr comment`.

### available profiles

**github-pr-reviewer**: `profiles/github-pr-reviewer/config.json` encodes the
provider-neutral contract from `/cross-provider-agent`, including the
`code-review` skill and its two named child agents.
