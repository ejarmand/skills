---
name: cross-provider-agent
description: Launch independent provider CLI workers when harness delegation cannot run the requested task, or resume an existing CLI session.
---

# Cross-provider CLI fallback

For ordinary delegation, use the harness's tools, including Orchestrator V2,
when they support the requested provider, model, and workspace. Follow those
tools' own dispatch and lifecycle instructions. These skills cover CLI launches and CLI-session
continuation:

- `/claude-agent`
- `/codex-agent`
- `/cursor-agent`
- `/opencode-agent`

Preserve the requested model, effort, provider route, and subscription preference.
Use subscription-backed Claude Code, Codex, and Cursor for their models, and
OpenCode Zen for its models, unless the user chooses another route.

Give the worker its task, absolute checkout path, relevant context, and expected
result. For an independent review, use a fresh context separate from implementation.
Verify the result against the task; a recovered tool error does not invalidate
completed work.

## Named authority profiles

When the task requests a named profile, use an adapter that enforces it.
[`github-pr-reviewer`](profiles/github-pr-reviewer.md) is the strict CLI review
profile; adapter encodings live under `profiles/<name>/`. A runtime mode alone
does not enforce its command and network allowlists.

## CLI transport failures

Transport errors (`dial`, `lookup`, `connect`, loopback failures) can indicate
sandboxed network access; an HTTP 401 "Bad credentials" response indicates
authentication failure. Correct the dispatch within the task's permissions.
