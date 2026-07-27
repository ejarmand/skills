---
name: pr-ping-pong
description: Drive an issue or pull request through alternating rounds of implementation and cross-provider review — one agent implements, agents from other providers review, findings feed back, repeat. Use when asked to ping-pong a PR, iterate an issue to review-clean, get adversarial cross-model review rounds on a change, or run implement/review rallies until a PR passes.
disable-model-invocation: true
---

# PR Ping Pong

Alternate an implementation agent against reviewers from *other* providers until
the change is review-clean or the rally budget runs out. Coding agents catch
defects in code they did not write far more reliably than in their own, so the
entire value of this skill comes from one invariant:

**A reviewer must never share a session with the agent that wrote the code under
review.** When the same provider both implements and reviews, the reviewer runs
in a separate session that has never seen the implementation transcript.

Treat explicit invocation as authorization to run the agent CLIs, commit, and
push to the PR branch for this task. It does not authorize merging, force
pushes, edits outside the change, or unrelated external actions.

## Parameters

Resolve these from the user's request, then state the resolved set before
starting.

| Parameter | Default |
|---|---|
| target | required — issue or PR number, or URL |
| implementer | `claude` |
| reviewers | derived from implementer (below) |
| max rallies | `3` |
| merge on pass | `false` |

Default reviewer sets:

- implementer `claude` → reviewers `codex`, `cursor-grok`
- implementer `codex` → reviewers `cursor-grok`, `codex` (fresh session)

Other implementers are out of scope; if asked for one, say so and offer the
supported pair. Honor explicit overrides, but refuse a reviewer set that would
review its own implementation session and explain why.

## Preflight

```bash
gh auth status
gh repo view --json nameWithOwner,defaultBranchRef
gh_user="$(gh api user --jq .login)"

codex login status          # if Codex is implementing or reviewing
cursor-agent status --format json   # if Cursor is reviewing
```

If any CLI is unauthenticated, stop and ask the user to run `codex login`,
`cursor-agent login`, or `gh auth login`. Never print or embed a token. These
CLIs evolve, so treat installed `--help` as authoritative over the commands
below. The sibling `codex-agent` and `cursor-agent` skills, when present, carry
deeper guidance on sessions and sandboxes, but this skill does not require them.

Resolve the target to a PR on a branch:

- **PR given** — check out its branch, confirm it is not already merged or
  closed, and record its head SHA.
- **Issue given** — branch from the default branch as `ppp/issue-<n>-<slug>`,
  run rally 1's implementation, push, then open a *draft* PR that closes the
  issue. Keep it draft for the duration; mark ready only at a passing finish.

Record the PR author. Because agents push under the user's own credentials, the
PR is normally authored by `$gh_user`, and **GitHub rejects approve and
request-changes on your own PR**. In that case publish every review as a
comment. Use real review events only when the author differs from `$gh_user`.

Open a rally log at `${TMPDIR:-/tmp}/pr-ping-pong/<owner>-<repo>-<pr>.md` and
keep it current: resolved parameters, session IDs, and per rally the head SHA,
each verdict, each finding, and its triage outcome. It is the record that makes
an interrupted run resumable, and it is what you summarize at the end.

## The verdict contract

Three CLIs with three output formats need one machine-readable signal, so every
reviewer prompt must require this and nothing fancier — the last line of the
response is exactly one of:

```
VERDICT: CLEAN
VERDICT: NON_BLOCKING
VERDICT: BLOCKING
```

Above it, findings as a numbered list, each with severity, `file:line`, the
concrete failure it causes, and a suggested fix. Demand a failure scenario;
findings without one are style opinions and triage as such.

If a reviewer returns no parseable verdict, re-ask that reviewer once for the
verdict line alone. A second failure is a reviewer error — log it, exclude that
reviewer from the rally's pass decision, and tell the user.

## The rally

One rally is one implementation pass followed by all reviewers. Run at most the
budgeted number.

### 1. Implement

Preallocate the implementer's session so it survives an interrupted turn, and
resume that same session on every later rally — the implementer *should* carry
its context forward.

Claude implementer, first rally:

```bash
impl_session="$(uuidgen)"
claude -p --session-id "$impl_session" --permission-mode acceptEdits \
  --output-format json \
  "Implement the change for PR #N in this checkout. Scope: SCOPE. Commit your work with a clear message. Do not push, merge, or edit files outside the scope. Report changed files and the checks you ran."
```

Later rallies resume it with `claude -p --resume "$impl_session"`.

Codex implementer, first rally:

```bash
codex exec --json --sandbox workspace-write -C /absolute/path/to/repo \
  "Implement the change for PR #N in this checkout. Scope: SCOPE. Commit your work with a clear message. Do not push, merge, edit outside the scope, or spawn more agents. Report changed files and the checks you ran."
```

Capture `impl_session` from the first event, `{"type":"thread.started",
"thread_id":"..."}`, the moment it appears. Resume on later rallies — global
options go **before** `resume`, and omitting `--json` loses the event stream:

```bash
codex exec --json --sandbox workspace-write -C /absolute/path/to/repo \
  resume "$impl_session" "Address the triaged findings below. FINDINGS"
```

Require a successful exit and a terminal `turn.completed`; treat `turn.failed`,
`error`, a nonzero exit, or a mismatched thread ID as a failed rally. Never
resume one session concurrently, and never add
`--dangerously-bypass-approvals-and-sandbox` to make a run unattended.

Give the implementer the objective, the permitted scope, the required
verification, and — from rally 2 on — the triaged findings. Never let it push,
merge, or spawn further agents.

### 2. Push

Verify the implementer's work yourself before it reaches a reviewer: inspect the
diff, confirm the commits are scoped, and run the repo's checks. Then push the
branch and record the new head SHA. Reviewing an unpushed or unverified state
wastes a full rally.

### 3. Review

Run reviewers **concurrently in the background** — they are independent, and
serializing them doubles the wall clock of every rally.

Reviewers are read-only. They analyze; *you* publish. That keeps one publishing
path across three CLIs and means no reviewer needs write or network authority.

Cursor Grok reviewer:

```bash
cursor-agent -p --output-format json --mode plan --trust \
  --model cursor-grok-4.5-high \
  --resume="$cursor_review_session" \
  "Review the diff of PR #N against its base in this checkout. Report only concrete defects introduced by this change — correctness, security, data loss, broken contracts, missing tests for changed behavior. For each: severity, file:line, the failure it causes, and a fix. Make no edits and no GitHub calls. End with the verdict line."
```

Codex reviewer — a **different** `thread_id` than the Codex implementer, always:

```bash
codex exec --json --sandbox read-only -C /absolute/path/to/repo \
  resume "$codex_review_session" \
  "Review the diff of PR #N against its base in this checkout. Report only concrete defects introduced by this change — correctness, security, data loss, broken contracts, missing tests for changed behavior. For each: severity, file:line, the failure it causes, and a fix. Make no changes. End with the verdict line."
```

Drop `resume "$codex_review_session"` on rally 1 and record the `thread_id` the
run reports.

Claude reviewer (only if the user overrides the defaults, since the implementer
is normally Claude): `claude -p --permission-mode plan`.

Allocate each reviewer a session on rally 1 (`cursor-agent create-chat`,
`uuidgen` for Claude, the captured `thread_id` for Codex) and **resume the same
reviewer session across rallies**. A reviewer never wrote the code, so
continuity costs nothing and buys the two things a fresh session cannot do:
confirm its earlier findings were actually fixed, and notice when they were not.

### 4. Publish

Post each review to the PR verbatim, one comment per reviewer per rally, headed
with the reviewer's model and the rally number so the timeline stays readable:

```bash
gh pr comment N --body-file <path>
```

When the PR author is not `$gh_user`, use `gh pr review N --comment`,
`--request-changes`, or `--approve` to match the verdict instead.

### 5. Triage

Reviewers are wrong sometimes, and an implementer that obeys every finding will
churn or regress. Adjudicate each blocking finding yourself against the code:

- **Accept** — real defect. Goes to the implementer as must-fix.
- **Reject** — wrong, out of scope, or a style preference with no failure
  scenario. Post a brief reply on the PR saying which finding and why.

Log every decision. Where reviewers disagree, decide on the code and record the
reasoning rather than deferring to whichever spoke last.

## Stopping

Stop and report at the first of these:

1. **Pass** — every reviewer returned `CLEAN` or `NON_BLOCKING`, and no accepted
   blocking finding is outstanding.
2. **Budget** — the rally cap is reached. Report the surviving findings.
3. **No progress** — a reviewer repeats a blocking finding from the previous
   rally and the diff since then does not touch the cited location. Two agents
   talking past each other will not converge; stop and bring it to the user.
4. **Failure** — an implementer errors, cannot proceed, or the branch stops
   building. Report the state; do not burn remaining rallies on a broken tree.

Non-blocking findings never justify another rally. Carry them into the summary.

## Merge

Merge only when the user set merge-on-pass **and** every one of these holds:

```bash
gh pr checks N          # all required checks passing
gh pr view N --json mergeable,mergeStateStatus,isDraft,reviewDecision
```

- the run finished on **Pass**, not budget or no-progress
- required checks are green
- `mergeable` is `MERGEABLE`, with no conflicts
- the PR is not a draft — mark it ready first if it was opened as one

Use the repository's configured merge method. If any condition fails, do not
merge: report exactly which one blocked it and leave the PR for the user. A
passing rally is not authorization to merge a red build.

## Report

Close with a compact rally table — per rally, the head SHA, each reviewer's
verdict, findings accepted and rejected — then the final state, surviving
non-blocking findings, the merge outcome or the reason it was skipped, the PR
URL, and the rally log path. Keep every session ID in the log so the user can
resume any participant directly.
