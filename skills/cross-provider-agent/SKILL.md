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

## common failuress: 
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
for exactly one invocation of one fresh child. Profiles carry authority only.

### Profile index

- `github-pr-reviewer` — reviews a GitHub PR or issue implementation from a
  caller-prepared checkout and publishes its own review. When it is selected,
  read and enforce [profiles/github-pr-reviewer.md](profiles/github-pr-reviewer.md)
  before choosing an adapter.

## Dispatch requires:

1. Require from the caller: an absolute path to a prepared workspace, the
   task prompt, and any profile and backend selection. The caller owns
   workspace lifecycle — creating, pinning, verifying, and deleting
   checkouts never happens here or in an adapter.
2. Fail closed when the workspace contains `.codex/` or `.cursor/`:
   workspace-resident provider config loads into the child's policy with no
   trust gate, letting the work under review grant its own reviewer
   authority. (Claude is immune) 
