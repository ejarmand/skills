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
| reviewers | independent `codex` and `cursor` sessions, excluding the implementer's provider |
| max rallies | `3` |
| merge on pass | `false` |
| new PR worktree | `REPO_ROOT/worktrees/[branch]` |

Honor explicit provider overrides when a matching native or installed adapter
exists. Refuse a reviewer set that would review its own implementation session,
and explain why. Provider separation is the invariant; the exact model is not.

## Preflight

```bash
gh auth status
gh repo view --json nameWithOwner,defaultBranchRef
gh_user="$(gh api user --jq .login)"
```

For each configured external participant, invoke `/codex-agent` or
`/cursor-agent`. Each adapter owns authentication, authority selection, session
capture, monitoring, terminal success, and result extraction — let it perform
its own installed-help and authentication preflight. If an adapter reports
missing authentication, stop and ask the user to log in. Never print or embed a
token.

Resolve the target to a PR on a branch and set `checkout` — the directory every
agent and repository check uses. Run all Git, diff, test, commit, and push steps
from `checkout`; use the repository root only to create or inspect worktrees.

- **PR given** — check out its branch, confirm it is not merged or closed, record
  its head SHA; that checkout is `checkout`.
- **Issue given** — read [WORKTREE.md](WORKTREE.md) and follow it to create the
  branch, linked worktree (which becomes `checkout`), and draft PR.

Pass the absolute `checkout` path and the permitted authority to every native
worker or provider adapter.

Record the PR author. Agents push under the user's credentials, so the PR is
normally authored by `$gh_user`, and **GitHub rejects approve and
request-changes on your own PR** — then publish every review as a comment. Use
review events only when the author differs from `$gh_user`.

Keep a rally log at `${TMPDIR:-/tmp}/pr-ping-pong/<owner>-<repo>-<pr>.md`:
resolved parameters, session IDs, and per rally the base and head SHAs, each
verdict, each finding, and its triage outcome. It makes an interrupted run
resumable and is what you summarize at the end.

## The verdict contract

All providers and harnesses share one machine-readable signal. Every reviewer
prompt must require that its last line is exactly one of:

```
VERDICT: CLEAN
VERDICT: NON_BLOCKING
VERDICT: BLOCKING
```

Above it, findings as a numbered list, each with severity, `file:line`, the
concrete failure it causes, and a suggested fix. Findings without a failure
scenario are style opinions and triage as such.

If a reviewer returns no parseable verdict, re-ask that reviewer once for the
verdict line alone. A second failure is a reviewer error — log it, exclude that
reviewer from the rally's pass decision, and tell the user.

## The rally

One rally is one implementation pass followed by all reviewers. Run at most the
budgeted number. Allocate each participant — implementer and every reviewer —
its session on rally 1 and resume that same session on later rallies so it
carries its decisions and findings forward. Never resume one session
concurrently.

### 1. Implement

- **Native subagent (default):** dispatch one implementation worker through the
  current harness's native agent interface. Give it the absolute checkout,
  objective, permitted files and side effects, required checks, and the report
  shape. Record its agent/session ID in the rally log. Send later accepted
  findings back to that same worker. If the harness cannot resume a native
  worker, start a fresh native worker with the prior rally log and record the
  replacement explicitly.
- **Codex override:** invoke `/codex-agent` with workspace-write authority and
  require it to preserve and later resume its session ID.
- **Cursor override:** invoke `/cursor-agent` with the least write authority
  that permits the implementation and require it to preserve and later resume
  its session ID.

Give the implementer the objective, the permitted scope, the required
verification, and — from rally 2 on — the triaged findings. Never let it push,
merge, or spawn further agents. A missing successful terminal result from an
adapter or native worker is a failed rally.

### 2. Push

Verify the work yourself first: inspect the diff, confirm the commits are scoped,
run the repo's checks. Then push and record the new head SHA. Reviewing an
unpushed or unverified state wastes a full rally.

### 3. Review

Immediately before each review rally, pin the exact base and head and confirm the
checkout matches. Run this as one shell block:

```bash
set -e
meta="$(gh pr view N --json baseRefName,baseRefOid,headRefOid \
  --jq '[.baseRefName, .baseRefOid, .headRefOid] | @tsv')"
read -r base_ref base_oid head_oid <<<"$meta"
git -C "$checkout" fetch origin "$base_ref"
git -C "$checkout" cat-file -e "${base_oid}^{commit}"
test "$(git -C "$checkout" rev-parse HEAD)" = "$head_oid"
```

Record both OIDs and substitute them into every reviewer's
`git diff BASE_OID...HEAD_OID` prompt. Stop if any command fails.

Run reviewers concurrently — they are independent. Reviewers are read-only:
they analyze, *you* publish. That keeps one publishing path and means no
reviewer needs write or GitHub authority.

Every reviewer gets the same prompt, with the resolved SHAs substituted so all
reviewers judge the same diff:

```
Review the diff of PR #N in this checkout: `git diff BASE_OID...HEAD_OID`. Report
only concrete defects introduced by this change — correctness, security, data
loss, broken contracts, missing tests for changed behavior. For each: severity,
file:line, the failure it causes, and a fix. Make no changes and no GitHub calls.
End with the verdict line.
```

Invoke `/codex-agent` and `/cursor-agent` in read-only mode for their respective
reviewers. If a native reviewer is explicitly configured, dispatch a read-only
native subagent in a session separate from the implementer.

Reviewer session continuity costs nothing — the reviewer never wrote the code —
and buys what a fresh session cannot: confirming earlier findings were fixed,
and noticing when they were not.

### 4. Publish

Post each review verbatim, one comment per reviewer per rally, headed with the
reviewer's model and the rally number:

```bash
gh pr comment N --body-file <path>
```

When the PR author is not `$gh_user`, use `gh pr review N --comment`,
`--request-changes`, or `--approve` to match the verdict.

### 5. Triage

Reviewers are wrong sometimes, and an implementer that obeys every finding will
churn or regress. Adjudicate each blocking finding against the code:

- **Accept** — real defect. Goes to the implementer as must-fix.
- **Reject** — wrong, out of scope, or a style preference with no failure
  scenario. Post a brief reply on the PR saying which finding and why.

Log every decision. Where reviewers disagree, decide on the code and record the
reasoning rather than deferring to whichever spoke last.

## Stopping

Stop and report at the first of these:

1. **Pass** — every reviewer returned `CLEAN` or `NON_BLOCKING`, no accepted
   blocking finding outstanding.
2. **Budget** — rally cap reached. Report the surviving findings.
3. **No progress** — a reviewer repeats a blocking finding and the diff since
   then does not touch the cited location. Two agents talking past each other
   will not converge; bring it to the user.
4. **Failure** — an implementer errors, cannot proceed, or the branch stops
   building. Report the state; do not burn rallies on a broken tree.

Non-blocking findings never justify another rally. Carry them into the summary.

## Merge

When the user set merge-on-pass and the rally ended in a **Pass**, read
[MERGE.md](MERGE.md) and merge only if every condition there holds. Otherwise
leave the PR unmerged and say why in the report.

## Report

Close with a rally table — per rally, the base and head SHAs, each reviewer's
verdict, findings accepted and rejected — then the final state, surviving non-blocking
findings, the merge outcome or why it was skipped, the PR URL, and the rally log
path. Keep every session ID in the log so the user can resume any participant.
For a new PR, also report the worktree path.
