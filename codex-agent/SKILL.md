---
name: codex-agent
description: Run Codex CLI as an independent coding worker for implementation, investigation, planning, or review, then monitor and verify its result. Use when asked to delegate work through `codex exec`, get a separate Codex pass, capture a Codex session ID for follow-up work, or resume, continue, consult, or "adopt" a prior Codex session or thread ID.
---

# Codex Agent

Run `codex exec` from the intended workspace, give it a bounded outcome, monitor
it at the task's time scale, and preserve its session ID when follow-up work is
likely.

Treat explicit invocation as authorization to run Codex CLI for the requested
task. Do not extend that authorization to pushes, merges, destructive actions,
unrelated edits, broader access, or other external side effects.

## Check the CLI and authentication

Treat installed help as authoritative because Codex CLI evolves:

```bash
codex --version
codex exec --help
codex exec resume --help
codex login status
```

If authentication is missing, ask the user to run `codex login`. Never display,
copy, or embed authentication files or tokens.

Omit `--model` unless the user requests a particular model. Otherwise use the
configured default rather than hard-coding a model name.

## Start a worker

Resolve the intended working directory and whether the task may edit files.
Default analysis, planning, and review to a read-only sandbox:

```bash
codex exec --json --sandbox read-only -C /absolute/path/to/repo \
  "Act as an independent worker for the current task. Complete TASK. Do not make changes or perform external side effects. Return a concise evidence-backed result."
```

Use workspace write access only when the user's task authorizes implementation:

```bash
codex exec --json --sandbox workspace-write -C /absolute/path/to/repo \
  "Act as an independent worker for the current task. Implement TASK within SCOPE, verify it, do not push or modify unrelated files, do not spawn more agents, and report changed files and checks."
```

Give the worker the objective, permitted files and side effects, required
verification, and desired response shape. For review-only work, explicitly
prohibit edits. Do not send secrets or unrelated parent-thread context.

Use `--output-schema` when downstream automation requires stable structured
output. Use `--output-last-message` when a separate final-result file is useful;
keep result files and JSONL logs in a temporary location unless the user asks to
retain them because they may contain prompts, paths, or file content.

## Capture the session ID

Use `--json` whenever later continuation or structured monitoring matters. The
initial event has this form:

```json
{"type":"thread.started","thread_id":"SESSION_ID"}
```

Record that exact `thread_id` as soon as it appears so an interrupted run can
still be resumed. Do not use `--ephemeral` when follow-up work is likely.

## Resume or adopt a worker

Resume a specific session sequentially from the intended checkout:

```bash
codex exec --json --sandbox read-only -C /absolute/path/to/repo \
  resume SESSION_ID \
  "Continue as an independent worker for the current task. Complete FOLLOW_UP without making changes and return an evidence-backed result."
```

Use `--sandbox workspace-write` only for authorized edits. Put global
`codex exec` options before `resume`. Add `--all` after `resume` only when
explicit lookup needs cwd filtering disabled:

```bash
codex exec --json --sandbox read-only -C /absolute/path/to/repo \
  resume --all SESSION_ID "Complete FOLLOW_UP without making changes."
```

Prefer an explicit ID. Use `--last` only when the user explicitly requests the
most recent session and its identity is unambiguous. If the original workspace
is unknown, do not authorize edits until the target checkout is resolved.

Tell a resumed worker that the current objective and scope supersede stale task
assumptions from its prior transcript. Never resume the same session
concurrently; competing turns can corrupt the intended workflow.

When a user calls this "adoption," preserve the boundary:

- This continues an external Codex CLI session; it does not re-parent it.
- It does not appear under `/agent` or `/subagents`.
- Native collaboration controls cannot steer or close it.
- Control it through the CLI process and later `codex exec resume` calls.

## Monitor and collect

Keep long-running CLI work attached and inspect new output at intervals
appropriate to the task. Do not restart a quiet process. Surface failures or
approval needs promptly.

With `--json`, require a successful process exit and a terminal
`turn.completed` event. Treat `turn.failed`, `error`, a nonzero exit, or a
mismatched thread ID as failure. The final `item.completed` whose item type is
`agent_message` contains the worker's result.

When a required CLI call fails because the surrounding sandbox blocks network
access, retry the same scoped command using the environment's approval or
network-escalation mechanism. Do not misreport a DNS or sandbox denial as an
authentication failure.

Use the least authority that completes the task. Never add
`--dangerously-bypass-approvals-and-sandbox`, `danger-full-access`,
`--ignore-rules`, or `--dangerously-bypass-hook-trust` merely to make a run
unattended.

## Verify and hand off

Treat the worker's response like any external agent result:

1. Inspect relevant files or the Git diff independently.
2. Run task-appropriate checks when edits occurred.
3. Reconcile its result with the current task instead of forwarding it blindly.
4. Report the outcome, verification, and session ID.

Use the same session ID for later refinements that depend on its history. Start
a fresh session when the repository, task, or trust boundary changes.
