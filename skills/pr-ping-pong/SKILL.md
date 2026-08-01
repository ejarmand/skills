---
name: pr-ping-pong
description: Drive an issue or pull request through alternating rallies of implementation and cross-provider review until it is review-clean.
disable-model-invocation: true
---

# PR Ping Pong

Alternate an implementation agent against reviewers from *other* providers until
the change is review-clean or the rally budget runs out.

**A reviewer must never share a session with the agent that wrote the code under
review.** Agents catch defects in code they did not write far more reliably than
in their own. When the same provider implements and reviews, the reviewer runs in
a separate session that never saw the implementation transcript.

Invocation authorizes running the agent CLIs, committing, and pushing to the PR
branch. It does not authorize merging, force pushes, edits outside the change, or
unrelated external actions.

## Parameters

Resolve from the request, then state the resolved set before starting.

| Parameter | Default |
|---|---|
| target | required — issue or PR number, or URL |
| implementer | `native subagent` |
| reviewers | every installed external provider except the implementer's |
| max rallies | `3` |
| merge on pass | `false` |
| new PR worktree | `REPO_ROOT/worktrees/[branch]` |

Honor explicit provider overrides. Refuse a reviewer set that would review its
own implementation session, and explain why. Provider separation is the
invariant; the exact model is not.

## Preflight

Require authenticated `gh`. Resolve the target to a PR on a branch and set
`checkout` — the directory every agent and repository check uses. Run all Git,
diff, test, commit, and push steps from `checkout`; use the repository root only
to create or inspect worktrees.

- **PR given** — check out its branch, confirm it is not merged or closed;
  that checkout is `checkout`.
- **Issue given** — read [WORKTREE.md](WORKTREE.md) and follow it to create the
  branch, linked worktree (which becomes `checkout`), and draft PR.

## The rally

One rally is one implementation pass, a push, all reviews, and triage. Run at
most the budgeted number. The implementer keeps **one session across rallies** —
resume it, never concurrently — so it carries its decisions forward. Reviewers
get **fresh sessions every rally**.

### 1. Implement

- **Native subagent (default):** dispatch one implementation worker through the
  current harness's native agent interface. Record its agent/session ID and
  resume that same worker on later rallies; if the harness cannot resume it,
  start a replacement with the prior rallies' accepted findings and say so.
- **Provider override:** dispatch through `/cross-provider-agent` with the least
  write authority that permits the implementation, and resume that session on
  later rallies.

Give the implementer the absolute `checkout`, the objective, the permitted scope,
the required verification, and — from rally 2 on — the accepted findings. Never
let it push, merge, or spawn further agents. A missing successful terminal
result is a failed rally.

### 2. Push and pin

Verify the work yourself first: inspect the diff, confirm the commits are scoped,
run the repo's checks. Reviewing an unpushed or unverified state wastes a full
rally. Push, then pin the exact base and head — the pinned head must be the
`HEAD` you just pushed, so poll until the API reflects it:

```bash
local_head="$(git -C "$checkout" rev-parse HEAD)" || exit 1
for attempt in 1 2 3 4 5; do
  meta="$(gh pr view N --json baseRefName,baseRefOid,headRefOid \
    --jq '[.baseRefName, .baseRefOid, .headRefOid] | @tsv')" || exit 1
  read -r base_ref base_oid head_oid <<<"$meta"
  test "$head_oid" = "$local_head" && break
  test "$attempt" -lt 5 || exit 1
  sleep 3
done
git -C "$checkout" fetch origin "$base_ref" || exit 1
git -C "$checkout" cat-file -e "${base_oid}^{commit}" || exit 1
```

Stop if the block fails. Substitute the recorded OIDs into every reviewer
prompt as `git diff BASE_OID...HEAD_OID`.

### 3. Review

Each reviewer provider runs **two fresh sessions per rally — one per axis**
(Standards, Spec). Dispatch each through `/cross-provider-agent` under the
`github-pr-reviewer` profile with the absolute `checkout` and a prompt built
from the matching axis brief in
[code-review step 4](../code-review/SKILL.md) — the single copy of both briefs.
On top of the brief, each prompt sets:

- the pinned `git diff BASE_OID...HEAD_OID` as the diff command;
- for the Spec session, the tagged issue or PR as the spec source, fetched
  through the profile's `gh` reads;
- publication: post the review as one top-level PR comment whose first line is
  `<provider> / <axis> / rally <n> / <head OID>`.

The sessions are independent — run them concurrently. After they finish, read
the posted comments back; they are the triage input.

### 4. Triage

Reviewers are wrong sometimes, and an implementer that obeys every finding will
churn or regress. Adjudicate each blocking finding against the code:

- **Accept** — real defect. Goes to the implementer as must-fix.
- **Reject** — wrong, out of scope, or a style preference. Post a brief reply on
  the PR saying which finding and why.

Where reviewers disagree, decide on the code and record the reasoning rather
than deferring to whichever spoke last.

## Stopping

Stop and report at the first of these:

1. **Pass** — no accepted blocking finding outstanding after triage.
2. **Budget** — rally cap reached. Report the surviving findings.
3. **Failure** — an implementer errors, cannot proceed, or the branch stops
   building. Report the state; do not burn rallies on a broken tree.

Non-blocking findings never justify another rally. Carry them into the summary.

## Merge

When the user set merge-on-pass and the rally ended in a **Pass**, read
[MERGE.md](MERGE.md) and merge only if every condition there holds. Otherwise
leave the PR unmerged and say why in the report.

## Report

Close with a rally table — per rally, the base and head SHAs, each review
session's outcome, findings accepted and rejected — then the final state,
surviving non-blocking findings, the merge outcome or why it was skipped, and
the PR URL. Report the implementer's session ID so the user can resume it. For
a new PR, also report the worktree path.
