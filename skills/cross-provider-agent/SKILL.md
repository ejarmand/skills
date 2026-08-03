---
name: cross-provider-agent
description: Dispatch a bounded task to a Claude, Codex, or Cursor CLI agent with least authority. Use for independent reviews, named authority profiles, or external-provider subagents.
---

# Cross-Provider Agent

Choose the backend and authority profile here. Delegate authentication,
invocation, sessions, monitoring, and provider quirks to `/claude-agent`,
`/codex-agent`, or `/cursor-agent`.

## Choose the backend

1. A user override wins.
2. Otherwise, any installed, authenticated backend.
3. When independence matters — reviewing or judging work — exclude the
   provider that produced the work.

## Authority profiles

Profiles are provider-neutral authority contracts applied by adapters to one
fresh child. Adapter encodings live under `profiles/<name>/` beside each
adapter's SKILL.md.

### Profile index

- [`github-pr-reviewer`](profiles/github-pr-reviewer.md) — read and enforce
  before choosing an adapter.

## Workspace ownership

Require an absolute path to a caller-prepared workspace. The caller owns
checkout creation, pinning, verification, and deletion.

## Distinguish network denial from authentication failure

Transport errors (`dial`, `lookup`, `connect`, loopback failures) indicate
sandboxed network access; an HTTP 401 "Bad credentials" response indicates
authentication failure.
