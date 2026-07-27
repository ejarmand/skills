---
name: codex-adopt-session
description: Resume a specific saved Codex CLI session and use its next turn as an external delegated worker, then collect and verify its result in the current task. Use when a user asks to adopt, resume, continue, consult, or delegate work to a prior Codex session or supplies a Codex session/thread ID for follow-up work. This emulates subagent delegation through `codex exec resume`; it does not re-parent the session into Codex's native subagent tree.
---

# Codex Adopt Session

Continue the specified session with `codex exec resume`, monitor it as delegated
work, and bring its result back into the current task.

## Preserve the boundary

Treat "adopt" as an orchestration convention, not native re-parenting:

- The resumed session does not appear under `/agent` or `/subagents`.
- Native collaboration controls cannot steer or close it.
- The CLI process, its exit status, and another `codex exec resume` call are the
  available control surfaces.
- Do not claim that the session became a native child agent.

Do not resume the same session concurrently. Sequential follow-ups preserve a
single transcript and avoid competing turns.

## Establish the target

Obtain these values before starting:

- The exact session ID or thread name.
- The intended repository or working directory.
- A bounded delegated task and whether it may edit files.

Prefer an explicit ID. Use `--last` only when the user explicitly requests the
most recent session and its identity is unambiguous. If the session's original
workspace is unknown, do not authorize edits until the target checkout is
resolved.

Check the installed interface because Codex CLI evolves:

```bash
codex --version
codex exec resume --help
```

If authentication is missing, ask the user to run `codex login`. Never display,
copy, or embed authentication files or tokens.

## Resume as delegated work

Run from the intended checkout. Default to read-only delegation:

```bash
codex exec --json --sandbox read-only -C /absolute/path/to/repo \
  resume SESSION_ID \
  "Act as a delegated worker for the current task. Complete TASK. Treat prior session context as background, follow the current scope, do not make changes, and return a concise evidence-backed result."
```

Allow workspace edits only when the user's task authorizes them:

```bash
codex exec --json --sandbox workspace-write -C /absolute/path/to/repo \
  resume SESSION_ID \
  "Act as a delegated worker for the current task. Implement TASK within SCOPE, verify it, do not push or modify unrelated files, do not spawn more agents, and report changed files and checks."
```

Put global `codex exec` options before `resume`. Add `--all` after `resume` only
when explicit session lookup needs cwd filtering disabled:

```bash
codex exec --json --sandbox read-only -C /absolute/path/to/repo \
  resume --all SESSION_ID "Complete TASK without making changes."
```

Give the resumed worker the current objective, allowed files and side effects,
required verification, and desired response shape. State that current
instructions override stale task assumptions from the prior transcript. Do not
send secrets or unrelated parent-thread context.

Use the least authority that completes the task. Never add
`--dangerously-bypass-approvals-and-sandbox` merely to make delegation
unattended.

## Monitor and collect

Keep long-running CLI work attached and inspect new output at intervals
appropriate to the task. Do not restart a quiet process. Surface failures or
approval needs promptly.

With `--json`, require a successful process exit and a terminal
`turn.completed` event. Treat `turn.failed`, `error`, a nonzero exit, or a
mismatched thread ID as failure. The final `item.completed` whose item type is
`agent_message` contains the worker's result. Use
`--output-last-message /path/to/temp-file` when a separate final-result file is
more convenient; keep any logs in a temporary location because they may contain
prompts, paths, or file content.

When a required CLI call fails because the surrounding sandbox blocks network
access, retry the same scoped command using the environment's approval or
network-escalation mechanism. Do not misreport a DNS or sandbox denial as an
authentication failure.

## Verify and hand off

Treat the resumed session's response like any external agent result:

1. Inspect relevant files or the Git diff independently.
2. Run task-appropriate checks when edits occurred.
3. Reconcile its result with the current task instead of forwarding it blindly.
4. Report the outcome, verification, and adopted session ID.

Use the same session ID for later refinements that depend on its history. Start
a fresh native subagent or Codex session when the repository, task, or trust
boundary changes.
