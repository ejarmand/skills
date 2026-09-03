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

Invocation authorizes running the agent CLIs, committing, and pushing to the PR
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

## Defaults

Run the two default adversarial reviewers and every bonus reviewer on each
rally. Select the default pair by the provider that produced the implementation,
not by the CLI that carried it.

| Implementer model provider | Default reviewer 1 | Default reviewer 2 |
|---|---|---|
| OpenAI | Muse Spark 1.3 Contributor Free through OpenCode Zen (`high`) | Cursor Grok 4.5 (`high`, standard speed) |
| Cursor/SpaceXAI Grok | GPT-5.6 Sol through Codex (`high`) | Muse Spark 1.3 Contributor Free through OpenCode Zen (`high`) |
| Any other provider | GPT-5.6 Sol through Codex (`high`) | Cursor Grok 4.5 (`high`, standard speed) |

| Bonus model | Transport | Effort |
|---|---|---|
| GPT-5.6 Luna | Codex | `xhigh` |
| Muse Spark 1.3 Contributor Free | OpenCode Zen | `high` |
| GLM 5.3 Flash | OpenCode through OpenRouter | `high` |

Combine the tables and deduplicate identical reviewer models. Do not remove a
bonus because its provider or model matches the implementer; give it a fresh
session. Muse is enabled by default. Its Contributor Free endpoint permits the
use of prompts and completions to train future Meta models.

Use subscription-backed native CLIs for OpenAI, Anthropic, and Cursor models.
Use OpenCode for Muse and GLM. Do not select Fable or Opus unless the user asks
for them directly.

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

One rally is one implementation pass, a push, all reviews, and adjudication. Run at
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

Each selected reviewer model runs **one fresh review coordinator per rally**,
dispatched through `/cross-provider-agent` under the `github-pr-reviewer`
profile with the absolute `checkout`. The coordinator invokes `/code-review`
— the single copy of the review contract — which spawns its two
context-isolated native children (Standards, Spec) inside the profile's
authority. On top of that, each coordinator's prompt sets:

- the pinned `git diff BASE_OID...HEAD_OID` as the fixed point;
- the tagged issue or PR as the spec source, fetched through the profile's
  `gh` reads;
- publication: aggregate both axis reports into one top-level PR comment
  whose first line is `<model> / rally <n> / <head OID>`.

Reviewer coordinators must not share `checkout` at the same time when one uses
Cursor — its runner stages workspace config that trips another dispatch's
clean-tree verification. Run reviewers sequentially, or pin one checkout per
reviewer. After they finish, read the posted comments back;
they are the adjudication input.

### 4. Adjudicate findings

Reviewers are wrong sometimes, and an implementer that obeys every finding will
churn or regress. Adjudicate each blocking finding against the code:

- **Accept** — real defect. Goes to the implementer as must-fix.
- **Reject** — wrong, out of scope, or a style preference. Post a brief reply on
  the PR saying which finding and why.

Where reviewers disagree, decide on the code and record the reasoning rather
than deferring to whichever spoke last.

## Stopping

Stop and report at the first of these:

1. **Pass** — no accepted blocking finding outstanding after adjudication.
2. **Budget** — rally cap reached. Report the surviving findings.
3. **Failure** — an implementer errors, cannot proceed, or the branch stops
   building. Report the state; do not burn rallies on a broken tree.

Non-blocking findings never justify another rally. Carry them into the summary.

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
