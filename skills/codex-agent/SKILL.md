---
name: codex-agent
description: CLI fallback for launching Codex workers or resuming existing Codex CLI sessions. Use when harness delegation cannot run the requested task or the user requests CLI execution.
---

# Codex Agent

For CLI fallback launches or existing CLI sessions, read
`/cross-provider-agent` and run `codex exec` from the intended
checkout. Preserve the session ID for follow-up work.

Treat installed help as authoritative because Codex CLI evolves:

```bash
codex --version
codex exec --help
codex exec resume --help
codex login status
```

If authentication is missing, ask the user to run `codex login`. Never display,
copy, or embed authentication files or tokens.

## Start a worker

Resolve the intended working directory and whether the task may edit files.
Default analysis, planning, and review to a read-only sandbox:

```bash
codex exec --json --sandbox read-only -C /absolute/path/to/repo \
  "[message]"
```

Use `--sandbox workspace-write`  when the user's task authorizes implementation.

Use `--output-last-message` when a separate final-result file is useful;
keep result files and JSONL logs in a temporary location unless the user asks to
retain them because they may contain prompts, paths, or file content.

## Capture the session ID

Use `--json` whenever later continuation or structured monitoring matters. The
initial event has this form:

```json
{"type":"thread.started","thread_id":"SESSION_ID"}
```

Record that exact `thread_id` as soon as it appears so an interrupted run can
still be resumed.

## Resume or adopt a worker

Resume a specific session sequentially from the intended checkout:

```bash
codex exec --json --sandbox read-only -C /absolute/path/to/repo \
  resume SESSION_ID \
  "[message]"
```
Put global `codex exec` options before `resume`.

## Monitor and collect

With `--json`, check the process exit and terminal `turn.completed` event for
the recorded thread. The final `item.completed` whose item type is
`agent_message` contains the result. Recover unresolved failures; assess the
completed task rather than rejecting it for an earlier recovered error.

## Profiled dispatch

Use this section when the task requests a named CLI authority profile.

`codex exec` hardcodes never-ask approvals: a sandboxed command that needs
network fails (on Linux, a bubblewrap loopback error) with no runtime
escalation path. Pre-authorize the specific commands with execpolicy rules 
 instead of widening the sandbox

Use the transactional runner with scoped profiles : `/absolute/path/to/codex-agent/scripts/run-profiled.sh`

The transactional runner assembles a throwaway home from the profile installed
skills symlinked so the child can invoke cited skills — runs one session as
the profiled agent, and deletes the home afterwards:

```bash
/absolute/path/to/codex-agent/scripts/run-profiled.sh \
  --workspace /absolute/path/to/workspace \
  [--effort [effort level]] \
  --profile github-pr-reviewer \
  -- --json "REVIEW_TASK"
```

The root session is the profiled agent — no bootstrap relay — and native
children it spawns inherit the same sandbox and rules. Nothing touches the
workspace, so parallel Codex dispatches need no lock.

Known gap (0.146.0, live-verified): native file tools bypass the read-only
sandbox, so file-write denial is detect-and-reject — verify the pinned head
and a clean tree after dispatch and discard the child's output otherwise
The runner refuses a workspace containing `.codex/`: its rules load into the child's policy with
no trust gate.

Verify a rule offline before relying on it:

```bash
codex execpolicy check \
  --rules /absolute/path/to/codex-agent/profiles/github-pr-reviewer/rules/github-pr-reviewer.rules \
  -- gh pr comment 1 --body test
```

Rules are experimental. Keep only narrow `allow` prefixes and never add a
fallback rule: most-restrictive-wins would turn a broad `prompt` decision
into a blocker under exec's never-ask approvals. A failed rule match fails
closed — the command stays sandboxed with no network escape.

### available profiles
**github-pr-reviewer** : `profiles/github-pr-reviewer/` encodes the profile from
`/cross-provider-agent` as a complete `CODEX_HOME` layer: `config.toml`
(read-only sandbox + role instructions) plus a `rules/` directory whose
execpolicy allows exactly the profile's `gh` surface to run outside the
sandbox; local reads need no rules because they run inside it.
