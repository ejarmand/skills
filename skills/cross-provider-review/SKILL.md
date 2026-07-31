---
name: cross-provider-review
description: Run and publish a single-shot review of a GitHub pull request or issue implementation through an independent provider. Use for a sharp second pass outside the implementation context; pin the reviewed base and head, keep the reviewer read-only, and publish only after successful execution.
disable-model-invocation: true
---

# Cross-Provider Review

The reviewer analyzes read-only; the caller publishes. This skill owns the fixed
point, review contract, and publication policy. The provider adapter owns its
CLI authentication, authority, session, monitoring, and success checks.

## Resolve and pin the review

Resolve an issue to its implementation PR, check out that PR branch, and require
authenticated `gh`. Immediately before dispatch, fetch the PR's base, record its
base and head OIDs, confirm both resolve, and confirm the checkout is exactly at
the recorded head. Stop on any mismatch.

The initial execution adapter is `/cursor-agent`. Invoke it in read-only mode
from the pinned checkout. Do not hard-code a model; honor a user override or let
the adapter use the configured default. Start a fresh session that did not
implement the change.

Require this review contract:

- analyze `git diff BASE_OID...HEAD_OID`
- report only concrete defects introduced by the change
- for each finding include severity, `file:line`, failure scenario, and fix
- make no changes and no GitHub calls
- finish with exactly `VERDICT: CLEAN`, `VERDICT: NON_BLOCKING`, or
  `VERDICT: BLOCKING`

Publish only after `/cursor-agent` reports a successful terminal result and the
caller has verified that the checkout still matches the pinned head. Use a
normal PR comment when the authenticated GitHub user authored the PR; otherwise
submit a matching comment review. Keep the reviewer output verbatim beneath a
heading that identifies the provider and reviewed head OID.

Do not push, merge, modify the checkout, or perform unrelated repository
mutations.
