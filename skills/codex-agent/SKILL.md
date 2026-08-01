---
name: codex-agent
description: Run Codex CLI as an independent coding worker for implementation, investigation, planning, or review, then monitor and verify its result. Use when asked to delegate work through `codex exec`, get a separate Codex pass, capture a Codex session ID for follow-up work, or resume, continue, consult, or "adopt" a prior Codex session or thread ID.
---

# Codex Agent

Run `codex exec` from the intended workspace, give it a bounded outcome, monitor
it at the task's time scale, and preserve its session ID when follow-up work is
likely.

Doctrine — authorization scope, least authority, prompt discipline, session
and verification rules — lives in `/cross-provider-agent`. This skill is the
Codex transport.

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

When a user calls this "adoption," preserve the boundary:

- This continues an external Codex CLI session; it does not re-parent it.
- It does not appear under `/agent` or `/subagents`.
- Native collaboration controls cannot steer or close it.
- Control it through the CLI process and later `codex exec resume` calls.

## Monitor and collect

With `--json`, require a successful process exit and a terminal
`turn.completed` event. Treat `turn.failed`, `error`, a nonzero exit, or a
mismatched thread ID as failure. The final `item.completed` whose item type is
`agent_message` contains the worker's result.

`codex exec` hardcodes never-ask approvals: a sandboxed command that needs
network fails (on Linux, a bubblewrap loopback error) with no runtime
escalation path. Pre-authorize the specific commands with execpolicy rules —
see profiled dispatch below — instead of widening the sandbox.

Use the least authority that completes the task. Never add
`--dangerously-bypass-approvals-and-sandbox`, `danger-full-access`,
`--ignore-rules`, or `--dangerously-bypass-hook-trust` merely to make a run
unattended.

## Profiled dispatch: github-pr-reviewer

`profiles/github-pr-reviewer/` encodes the profile from
`/cross-provider-agent` as an agent config layer (`reviewer.toml`) plus a
sibling `rules/` directory. The execpolicy rules allow exactly the profile's
`gh` surface to run outside the read-only sandbox; local reads need no rules
because they run inside it.

Load the profile for one invocation by absolute path — the workspace stays
untouched:

```bash
codex exec --json --sandbox read-only -C /absolute/path/to/workspace \
  -c 'agents.github_pr_reviewer.description="Profiled PR reviewer."' \
  -c 'agents.github_pr_reviewer.config_file="/absolute/path/to/codex-agent/profiles/github-pr-reviewer/reviewer.toml"' \
  "Spawn one fresh github_pr_reviewer child (no full-history fork) for REVIEW_TASK, wait for it, and relay its result verbatim."
```

The child must be a fresh spawn; a full-history fork rejects `agent_type`.
Role binding has an open reliability bug (openai/codex#32587) that fails
closed here: a child without the role gets no rules, hence no network escape.
This dispatch nests a parent CLI agent around the child, roughly doubling
token cost — the price of leaving the workspace untouched.

Verify a rule offline before relying on it:

```bash
codex execpolicy check \
  --rules /absolute/path/to/codex-agent/profiles/github-pr-reviewer/rules/github-pr-reviewer.rules \
  -- gh pr comment 1 --body test
```

Rules are experimental. Keep only narrow `allow` prefixes and never add a
fallback rule: most-restrictive-wins would turn a broad `prompt` decision
into a blocker under exec's never-ask approvals.

Known limitation (0.146.0, live-verified): the read-only sandbox governs
shell commands but not Codex's native file-modification tools — an instructed
write landed in the workspace during conformance, and no config kill switch
exists (see `research/agent-permission-allowlists.md` §7). File-write denial
is therefore detect-and-reject on Codex: after dispatch, verify the workspace
still matches the pinned head with a clean tree, and discard the child's
output if it does not.
