---
name: cross-provider-agent
description: Dispatch one bounded task to an external-provider coding agent (Claude, Codex, or Cursor CLI) under least authority, then monitor and verify the result. Use when work needs an independent provider's pass, when a task should run under a named authority profile, or when another skill needs an external subagent.
---

# Cross-Provider Agent

The dispatch primitive: run one external-provider subagent for one bounded
task. This skill owns the doctrine, the backend choice, and the authority
profiles. The adapters — `/claude-agent`, `/codex-agent`, `/cursor-agent` —
own their CLI transport: authentication, invocation forms, session capture,
resume syntax, and provider quirks.

## Doctrine

**Authorization.** Invocation — by the user or by a skill the user invoked —
authorizes running the chosen provider CLI for the requested task, including
reading the necessary files in the intended workspace. It does not extend to
pushes, merges, destructive actions, unrelated edits, or broader access.

**Least authority.** Give the child the narrowest authority that completes
the task: read-only or plan modes for analysis, planning, and review; write
access only when the task authorizes implementation; a named profile when one
fits. Never bypass sandboxes or approvals merely to make a run unattended.

**Prompt discipline.** State the objective, permitted side effects, required
verification, and desired response shape. For review work, permit exactly the
profile's write surface and prohibit edits. Send no secrets and no unrelated
parent-thread context.

**Session skeleton.** Capture the session ID as soon as the provider emits
it; never rely on "latest". Resume sequentially, never concurrently. Start a
fresh session when the repository, task, or trust boundary changes.

**Monitor, then verify.** Poll at the task's timescale without restarting a
quiet process. Success requires both a clean process exit and the provider's
terminal success event. Inspect the resulting files or Git diff yourself,
then report outcome, verification, and session ID.

**Sandbox denial is not auth failure.** Transport errors (`dial`, `lookup`,
`connect`, loopback failures) mean the sandbox denied network; an HTTP 401
"Bad credentials" body means auth. Diagnose before reporting either.

## Choose the backend

1. A user override wins.
2. Otherwise, any installed, authenticated backend.
3. When independence matters — reviewing or judging work — exclude the
   provider that produced the work.

## Authority profiles

A profile is a named, provider-neutral authority contract. Each adapter
encodes it under `profiles/<name>/` beside its SKILL.md and owns applying it
for exactly one invocation of one fresh child. Profiles carry authority only;
task instructions travel in the dispatch prompt. If pre-existing user,
project, or enterprise policy would make the child's effective authority
broader than the profile, fail closed instead of dispatching.

### github-pr-reviewer

Reviews a GitHub PR or issue implementation from a caller-prepared checkout
and publishes its own review.

Allowed:

- workspace file reads, read-only git inspection (`diff`, `log`, `show`,
  `status`), and bounded text search
- GitHub reads: `gh issue view`, `gh pr view`, `gh pr diff`
- one write: `gh pr comment` — the reviewer publishes its review as a
  top-level PR comment. Every provider posts as the authenticated user, so
  the comment body must open by naming the provider and review axis.

Forbidden: everything else — filesystem writes; git mutations; `gh api`,
`gh pr review`, `gh issue comment`, and every other `gh` subcommand; network
destinations beyond GitHub; sandbox or approval bypasses.

## Dispatch

1. Require from the caller: an absolute path to a prepared workspace, the
   task prompt, and any profile and backend selection. The caller owns
   workspace lifecycle — creating, pinning, verifying, and deleting
   checkouts never happens here or in an adapter.
2. Invoke the chosen adapter with the workspace, profile name, and prompt.
   The adapter applies its profile encoding, runs one fresh child, preserves
   output and session ID, and removes any configuration it staged.
3. Verify per doctrine. When the caller pinned the workspace to a head,
   confirm the workspace still points at it after the child exits.
