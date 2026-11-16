---
name: pr-ping-pong
description: Drive an issue or pull request through alternating rallies of implementation and cross-provider review until it is review-clean.
disable-model-invocation: true
---

# PR Ping Pong

Alternate an implementation agent against two reviewers from other model
providers plus the bonus roster until the change is review-clean or the rally
budget runs out. Every agent is a T3 Code `delegate_task` child of this thread.

**A reviewer must never share a session with the agent that wrote the code under
review.** Agents catch defects in code they did not write far more reliably than
in their own.

Invocation authorizes delegating, committing, and pushing to the PR branch. It
does not authorize merging, force pushes, edits outside the change, or
unrelated external actions.

## Parameters

Resolve from the request, then state the resolved set before starting.

| Parameter | Default |
|---|---|
| target | required — issue or PR number, or URL |
| implementer | this thread's model |
| reviewers | the default pair and bonus roster below |
| max rallies | `3` |
| merge on pass | `false` |

## The rally

One rally is one implementation pass, a push, all reviews, and adjudication. Run
at most the budgeted number.

### 1. Implement

One implementer serves the whole run. Start it in its own worktree
(`isolation:"worktree"`), or sharing this checkout when this thread is already
on the PR branch. Continue it on later rallies with `t3_thread_send` to its
`childThreadId`, so it carries its decisions forward.

- **Issue given** — it branches from the default branch as
  `ppp/issue-<n>-<slug>` and opens a draft PR that closes the issue. Mark the
  PR ready only at a passing finish.
- **PR given** — confirm the PR is not merged or closed. The implementer checks
  out its branch.

Give it the objective, the permitted scope, the required verification, and —
from rally 2 on — the accepted findings. It works through `/implement`, pushes,
and reports the head OID. It never merges or starts further agents.

### 2. Pin

Take the head from the implementer's report; `gh pr view` can lag a push. Take
the base from `gh pr view N --json baseRefName,baseRefOid` and fetch that ref.
Every reviewer brief carries `git diff BASE_OID...HEAD_OID`.

### 3. Review

Each reviewer is one `delegate_task` child for the whole run, sharing this
checkout. Start them together in rally 1. On later rallies continue each with
`t3_thread_send` to its `childThreadId`, giving it the new head, the diff since
the head it last reviewed, and the findings you rejected with the reasons. This
replaces T3's rule of a fresh delegate for every re-check.

The rally 1 brief says:

- Run `/code-review` on the pinned diff and start its two sub-agents. A T3
  child starts none unless its task says to.
- This checkout's working tree is not at the head unless this thread is on the
  PR branch. Read files with `git show HEAD_OID:<path>`.
- The spec is the tagged issue or PR. Read it with
  `gh issue view N --json title,body,comments`; `--comments` alone drops the
  body.
- Review only: no edits, commits, or pushes.
- Label each finding `blocker` (behaviour the spec asks for is wrong or
  missing), `should` (a real defect, or a broken binding rule of the
  standard), or `nit` (everything else).
- Each rally, post both axis reports as one top-level PR comment whose first
  line is `<model> / rally <n> / <head OID>`, and return the same report.

The rally waits for the default pair. A bonus review that lands after
adjudication goes into the next rally; cancel any still running when the run
ends.

#### Review agent defaults

Run the two default adversarial reviewers and every permitted free reviewer on
each rally.

Leave a reviewer out, without a replacement, and name it in the report when:

- This thread's `runtimeMode` is below `full-access` and the reviewer runs on
  OpenCode or Muse Code. Those children stop for approval on every shell
  command.
- Its provider rejects the dispatch, as with an expired key.
- Repository policy prohibits it. Muse Spark 1.3 Contributor and
  MiMo-V2.6-Flash Free collect data that may be used to improve the model, so
  a policy against one covers both, including explicit reviewer overrides.

| Implementer model provider | Default reviewer 1 | Default reviewer 2 |
|---|---|---|
| OpenAI | Muse Spark 1.3 Contributor (`high`) | Claude Opus (`high`) |
| Any other provider | GPT-6.1 Sol (`high`) | Muse Spark 1.3 Contributor (`high`) |

| Free model | T3 provider | Effort |
|---|---|---|
| GPT-6 Luna | Codex | `high` |
| Muse Spark 1.3 Contributor (`openrouter/meta/muse-spark-1.3-contributor`) | OpenCode | `high` |
| MiMo-V2.6-Flash Free (`opencode/mimo-v2.6-flash-free`) | OpenCode | Model default |

Permitted free reviewers should be used even if they duplicate the implementer,
just use a fresh context. Outside the Opus seat above, do not select Fable or
Opus unless the user asks for them directly.

### 4. Adjudicate findings

Reviewers are wrong sometimes, and an implementer that obeys every finding will
churn or regress. Adjudicate the returned reports against the code:

- **Accept** — a real `blocker` or `should`, by your own grading rather than
  the label it came with. Goes to the implementer as must-fix.
- **Nit** — stays out of the implementer's queue and goes in the report.
- **Reject** — wrong, out of scope, or a style preference. Post a brief reply on
  the PR saying which finding and why.

Where reviewers disagree, use your judgement.

If review fixes grew the diff since the last rally (`git diff --shortstat
BASE_OID...HEAD_OID`), tell the implementer to cut first: delete or narrow
rather than add a helper, guard, or option.

A finding you rejected that a reviewer raises again for a second rally goes to
the user: state both sides in two or three lines each in the report, and stop
sending it back to that reviewer.

## Stopping

Stop and report at the first of these:

1. **Pass** — every default reviewer that ran has reported and no `blocker`
   or `should` remains after adjudication.
2. **Budget** — rally cap reached. Report the surviving findings and the
   reviewers left out.
3. **Failure** — the implementer errors or cannot proceed, or the branch stops
   building. Report the state; do not burn rallies on a broken tree.

## Merge

When the user set merge-on-pass and the rally ended in a **Pass**, read
[MERGE.md](MERGE.md) and merge only if every condition there holds. Otherwise
leave the PR unmerged and say why in the report.

## Report

Close with a rally table — per rally, the base and head SHAs, each model
review's outcome, findings accepted and rejected — then the final state,
surviving non-blocking findings, the merge outcome or why it was skipped, and
the PR URL. Link the implementer's thread so the user can continue it.
