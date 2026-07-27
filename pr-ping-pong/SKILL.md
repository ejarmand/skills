---
name: pr-ping-pong
description: Drive an issue or pull request through alternating rounds of implementation and cross-provider review — one agent implements, agents from other providers review, findings feed back, repeat. Use when asked to ping-pong a PR, iterate an issue to review-clean, get adversarial cross-model review rounds on a change, or run implement/review rallies until a PR passes.
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
| implementer | `claude` |
| reviewers | `claude` → `codex`, `cursor-grok`; `codex` → `cursor-grok`, `codex` (fresh session) |
| max rallies | `3` |
| merge on pass | `false` |
| new PR worktree | `REPO_ROOT/worktrees/[branch]` |

Other implementers are out of scope — say so and offer the supported pair. Honor
explicit overrides, but refuse a reviewer set that would review its own
implementation session, and explain why.

## Preflight

```bash
gh auth status
gh repo view --json nameWithOwner,defaultBranchRef
gh_user="$(gh api user --jq .login)"

claude auth status                  # if Claude implements or reviews — the default implementer
codex login status                  # if Codex implements or reviews
cursor-agent status --format json   # if Cursor reviews
```

If a CLI is unauthenticated, stop and ask the user to log in. Never print or
embed a token. These CLIs evolve — treat installed `--help` as authoritative over
the commands below.

Resolve the target to a PR on a branch and set `checkout` — the directory every
agent and repository check uses. Run all Git, diff, test, commit, and push steps
from `checkout`; use the repository root only to create or inspect worktrees.

- **PR given** — check out its branch, confirm it is not merged or closed, record
  its head SHA; that checkout is `checkout`.
- **Issue given** — branch from the default branch as `ppp/issue-<n>-<slug>`,
  create a linked worktree at `REPO_ROOT/worktrees/[branch]` (e.g.
  `worktrees/ppp/issue-42-fix-cache`), use it as `checkout`. Run rally 1 there,
  push, then open a *draft* PR that closes the issue. Mark ready only at a
  passing finish.

For a new PR, leave the primary checkout on its current branch and exclude
`/worktrees/` via Git info exclude — no tracked `.gitignore` change unless asked.

```bash
repo_root="$(git rev-parse --show-toplevel)"
branch="ppp/issue-N-slug"
worktree_path="$repo_root/worktrees/$branch"
exclude_file="$(git -C "$repo_root" rev-parse --path-format=absolute --git-path info/exclude)"
grep -qxF /worktrees/ "$exclude_file" ||
  printf '\n/worktrees/\n' >>"$exclude_file"
mkdir -p "$(dirname "$worktree_path")"
git -C "$repo_root" fetch origin "$default_branch"
git -C "$repo_root" worktree add -b "$branch" "$worktree_path" \
  "origin/$default_branch"
checkout="$worktree_path"
```

Claude and Cursor commands below take no working-directory option, so run them
from `checkout`; pass `checkout` to Codex via `-C`.

Record the PR author. Agents push under the user's credentials, so the PR is
normally authored by `$gh_user`, and **GitHub rejects approve and
request-changes on your own PR** — then publish every review as a comment. Use
review events only when the author differs from `$gh_user`.

Keep a rally log at `${TMPDIR:-/tmp}/pr-ping-pong/<owner>-<repo>-<pr>.md`:
resolved parameters, session IDs, and per rally the base and head SHAs, each
verdict, each finding, and its triage outcome. It makes an interrupted run
resumable and is what you summarize at the end.

## The verdict contract

Three CLIs, three output formats, one machine-readable signal. Every reviewer
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
budgeted number.

### 1. Implement

Preallocate the implementer's session so it survives an interrupted turn, and
resume it every later rally — the implementer *should* carry context forward.

Claude implementer, rally 1:

```bash
impl_session="$(uuidgen)"
claude -p --session-id "$impl_session" --permission-mode acceptEdits \
  --output-format json \
  "Implement the change for PR #N in this checkout. Scope: SCOPE. Commit your work with a clear message. Do not push, merge, or edit files outside the scope. Report changed files and the checks you ran."
```

Later rallies: `claude -p --resume "$impl_session"`.

Codex implementer, rally 1:

```bash
codex exec --json --sandbox workspace-write -C "$checkout" \
  "Implement the change for PR #N in this checkout. Scope: SCOPE. Commit your work with a clear message. Do not push, merge, edit outside the scope, or spawn more agents. Report changed files and the checks you ran."
```

Capture `impl_session` from the first event, `{"type":"thread.started",
"thread_id":"..."}`. Resume on later rallies — global options go **before**
`resume`, and omitting `--json` loses the event stream:

```bash
codex exec --json --sandbox workspace-write -C "$checkout" \
  resume "$impl_session" "Address the triaged findings below. FINDINGS"
```

Require a successful exit and a terminal `turn.completed`; `turn.failed`,
`error`, a nonzero exit, or a mismatched thread ID is a failed rally. Never
resume one session concurrently, and never add
`--dangerously-bypass-approvals-and-sandbox`.

Give the implementer the objective, the permitted scope, the required
verification, and — from rally 2 on — the triaged findings. Never let it push,
merge, or spawn further agents.

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

Run reviewers **concurrently in the background** — they are independent, and
serializing them doubles every rally's wall clock. Reviewers are read-only: they
analyze, *you* publish. That keeps one publishing path across three CLIs and
means no reviewer needs write or network authority.

Every reviewer gets the same prompt, with the resolved SHAs substituted so all
reviewers judge the same diff:

```
Review the diff of PR #N in this checkout: `git diff BASE_OID...HEAD_OID`. Report
only concrete defects introduced by this change — correctness, security, data
loss, broken contracts, missing tests for changed behavior. For each: severity,
file:line, the failure it causes, and a fix. Make no changes and no GitHub calls.
End with the verdict line.
```

```bash
# Cursor Grok
cursor-agent -p --output-format json --mode plan --trust \
  --model cursor-grok-4.5-high --resume="$cursor_review_session" "PROMPT"

# Codex — a different thread_id than the Codex implementer, always.
# Drop `resume ...` on rally 1 and record the reported thread_id.
codex exec --json --sandbox read-only -C "$checkout" \
  resume "$codex_review_session" "PROMPT"

# Claude — only if the user overrides the defaults, since Claude normally implements.
claude -p --permission-mode plan "PROMPT"
```

Allocate each reviewer a session on rally 1 (`cursor-agent create-chat`,
`uuidgen` for Claude, the captured `thread_id` for Codex) and **resume the same
reviewer session across rallies**. A reviewer never wrote the code, so continuity
costs nothing and buys what a fresh session cannot: confirming earlier findings
were fixed, and noticing when they were not.

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

Merge only when the user set merge-on-pass **and** all of these hold:

```bash
gh pr checks N          # all required checks passing
gh pr view N --json mergeable,mergeStateStatus,isDraft,reviewDecision
```

Merge only after a **Pass**, green required checks, `mergeable=MERGEABLE`, a
non-draft PR, `mergeStateStatus` of `CLEAN` or `HAS_HOOKS`, and
`reviewDecision` that is empty or `APPROVED`. Never merge
`CHANGES_REQUESTED` or `REVIEW_REQUIRED`, and never use `--admin`. If any
condition fails, report it and leave the PR unmerged.

## Report

Close with a rally table — per rally, the base and head SHAs, each reviewer's
verdict, findings accepted and rejected — then the final state, surviving non-blocking
findings, the merge outcome or why it was skipped, the PR URL, and the rally log
path. Keep every session ID in the log so the user can resume any participant.
For a new PR, also report the worktree path.
