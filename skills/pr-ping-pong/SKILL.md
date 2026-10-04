---
name: pr-ping-pong
description: Drive an issue or pull request through alternating rallies of implementation and cross-provider review until it is review-clean.
disable-model-invocation: true
---

# PR Ping Pong

Alternate an implementation agent against two reviewers from other model
providers plus the bonus roster until the change is review-clean or the rally
budget runs out.

**A reviewer must never share a session with the agent that wrote the code under
review.** Agents catch defects in code they did not write far more reliably than
in their own. When the same provider implements and reviews, the reviewer runs in
a separate session that never saw the implementation transcript.

Invocation authorizes delegation, committing, and pushing to the PR
branch. It does not authorize merging, force pushes, edits outside the change, or
unrelated external actions.

## Parameters

Resolve from the request, then state the resolved set before starting.

| Parameter | Default |
|---|---|
| target | required — issue or PR number, or URL |
| implementer | `native subagent` |
| reviewers | the default pair and bonus roster below |
| max rallies | `3` |
| merge on pass | `false` |
| new PR worktree | `REPO_ROOT/worktrees/[branch]` |

Honor explicit reviewer overrides. Never let a reviewer share the implementation
session.

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

One rally is one implementation pass, a push, all reviews, and adjudication.
Run at most the budgeted number. Continue the implementer when the harness
supports it; otherwise give the replacement its earlier decisions and accepted
findings. Reviewers get fresh contexts every rally.

Use the harness's delegation tools, including Orchestrator V2, for supported
providers, models, and workspaces. Follow the tools' own dispatch and lifecycle
instructions. Use `/cross-provider-agent` and its CLI adapters only when a CLI
launch or existing CLI session is needed.

### 1. Implement

Dispatch one implementation worker using the resolved model and checkout.

Give the implementer the absolute `checkout`, the objective, the permitted scope,
the required verification, and — from rally 2 on — the accepted findings. Never
let it push, merge, or spawn further agents. Verify its result before review.

### 2. Push and pin

Inspect the diff, confirm the commits are scoped, and run the repo's checks.
Push, then record the PR's exact base and head OIDs. Confirm the head is the
commit just pushed and that the checkout has both commits before dispatch.
Use `git diff BASE_OID...HEAD_OID` in every reviewer prompt.

### 3. Review

Each selected model runs a fresh review coordinator per rally. The coordinator
invokes `/code-review` with two context-isolated children, Standards and Spec.
Children return findings to the coordinator; the coordinator publishes one
combined top-level PR comment headed `<model> / rally <n> / <head OID>`.

Give the coordinator the absolute checkout, pinned diff, and issue or PR spec,
including its body and relevant decisions. Fetch issue text with
`gh issue view N --json title,body,comments`; `--comments` alone can omit the body.
Use a named authority profile when the task requests one.

Before every reviewer dispatch, apply the data-sharing restrictions under
review agent defaults below. Then record the current PR comment IDs using
`gh api repos/{owner}/{repo}/issues/N/comments --paginate`. After its run,
read the comments again. Count the review as complete only if a new comment
ID identifies a comment whose body first line exactly matches that reviewer's
model, rally number, and pinned head. A successful agent exit without that
comment is a failed review.
Dispatch duplicate model entries sequentially so each has its own before and
after snapshot. Do not count a failed review toward Pass.

A recovered tool error does not invalidate a completed review. If only
publication failed, retry publication using the completed report. For an
incomplete review, correct the dispatch or choose a permitted replacement,
keeping other verified reviews on the same head. Continue the remaining work;
report a slot as unresolved when recovery is exhausted.

For CLI fallback reviews, bound the process with `timeout` (45 minutes is ample).

When using the profiled Cursor CLI runner, give Cursor its own pinned checkout
or run it separately from the other reviewers. Its temporary `.cursor/` files
can fail another reviewer's clean-tree check, and two Cursor runners cannot
share a checkout. If cleanup fails with exit 70, recover that checkout before
reusing it; other reviewer slots can proceed in their own checkouts.

#### review agent defaults

Run the two default adversarial reviewers and every permitted free reviewer on
each rally.

MiMo-V2.6-Flash Free collects data that may be used to improve the model; see
[OpenCode Zen privacy](https://opencode.ai/docs/zen/#privacy). Wherever repository
policy prohibits Muse's Contributor tier, also prohibit MiMo Free, including
explicit reviewer overrides. Replace only prohibited default-pair seats with
permitted reviewers from another provider than the implementer when available,
and keep the permitted seats. Omit prohibited bonus reviewers. Choose replacements
consistent with explicit model choices; if none are permitted, report the slot
as unresolved. Explain exclusions and replacements before dispatch.

| Implementer model provider | Default reviewer 1 | Default reviewer 2 |
|---|---|---|
| OpenAI | Muse Spark 1.3 Contributor Free through OpenCode Zen (`high`) | Cursor Grok 4.5 (`high`, standard speed) |
| Cursor | GPT-6.1 Sol through Codex (`high`) | Muse Spark 1.3 Contributor Free through OpenCode Zen (`high`) |
| Any other provider | GPT-6.1 Sol through Codex (`high`) | Muse Spark 1.3 Contributor Free through OpenCode Zen (`high`) |

| Free model | Provider route | Effort |
|---|---|---|
| GPT-6 Luna | Codex | `high` |
| Muse Spark 1.3 Contributor Free | OpenCode Zen | `high` |
| MiMo-V2.6-Flash Free (`opencode/mimo-v2.6-flash-free`) | OpenCode Zen | Model default |

Permitted free reviewers should be used even if they duplicate the implementer,
just use a fresh context.

Preserve subscription-backed provider routes for OpenAI, Anthropic, and Cursor,
and OpenCode Zen for Muse and MiMo. For OpenCode CLI fallback, Muse uses
`--variant high`; MiMo uses model-default effort without a `high` variant.
Do not select Fable or Opus unless the user asks for them directly.

### 4. Adjudicate findings

Reviewers are wrong sometimes, and an implementer that obeys every finding will
churn or regress. Read the reviewers comments to adjudicate findings against the code:

- **Accept** — real defect. Goes to the implementer as must-fix.
- **Reject** — wrong, out of scope, or a style preference. Post a brief reply on
  the PR saying which finding and why.

Where reviewers disagree, use your judgement 

## Stopping

Stop and report at the first of these:

1. **Pass** — every required reviewer slot has a verified comment and no
   meaningful findings remain after adjudication.
2. **Budget** — rally cap reached. Report the surviving findings and unresolved
   reviewer slots.
3. **Blocked** — required implementation, checks, or reviews cannot be completed
   after recovery. Report what remains unresolved.

## Merge

When the user set merge-on-pass and the rally ended in a **Pass**, read
[MERGE.md](MERGE.md) and merge only if every condition there holds. Otherwise
leave the PR unmerged and say why in the report.

## Report

Close with a rally table — per rally, the base and head SHAs, each model
review's outcome, findings accepted and rejected — then the final state,
surviving non-blocking findings, the merge outcome or why it was skipped, and
the PR URL. Report the implementer's session ID so the user can resume it. For
a new PR, also report the worktree path.
