---
name: cursor-code-review
description: Use Cursor Grok 4.5 through the headless Cursor Agent CLI to review a GitHub pull request, or the implementation associated with a GitHub issue, then publish the result yourself through GitHub CLI. Use for a sharp second-pass code review; submit a review for another author's PR and leave a normal comment when reviewing the authenticated user's own PR.
disable-model-invocation: true
---

# Cursor Code Review

Run `cursor-agent` from a checkout of the target repository and give it the issue or PR. **Cursor reviews; you publish.** Cursor reads the local codebase and returns its review as text — it makes no code changes and no GitHub calls. Keeping the only mutation on your side means nothing lands on a public PR unattended, and a bad review costs a retry rather than a comment you have to walk back.

Require authenticated `cursor-agent` and `gh`. If either is unauthenticated, ask the user to run `cursor-agent login` or `gh auth login`. These CLIs evolve — treat installed `--help` as authoritative over the commands below.

## Resolve and pin the diff

Resolve the target first, since Cursor cannot: an issue resolves to its implementation PR, and you record that PR number as `N`. Then pin the exact commits under review. "The diff against its base" is not a stable instruction — a base branch that advances, or a head pushed from elsewhere, changes what Cursor reads without changing a word of the prompt.

Each check fails closed on its own, so a later success cannot mask an earlier failure:

```bash
pr_meta="$(gh pr view N --json baseRefName,baseRefOid,headRefOid \
  --jq '[.baseRefName, .baseRefOid, .headRefOid] | @tsv')" ||
  { echo "gh pr view N failed" >&2; exit 1; }
read -r base_ref base_oid head_oid <<<"$pr_meta"
[ -n "$base_ref" ] && [ -n "$base_oid" ] && [ -n "$head_oid" ] ||
  { echo "incomplete base/head metadata for PR N: $pr_meta" >&2; exit 1; }

git fetch origin "$base_ref" ||
  { echo "fetch of $base_ref failed" >&2; exit 1; }
git cat-file -e "${base_oid}^{commit}" ||
  { echo "base $base_oid is not present after fetching $base_ref" >&2; exit 1; }
test "$(git rev-parse HEAD)" = "$head_oid" ||
  { echo "checkout HEAD is not PR N head $head_oid — check out the PR branch first" >&2; exit 1; }
```

A local `HEAD` that differs from `headRefOid` means you would review a tree GitHub is not showing. Stop and check out the PR branch; do not review the local state, and do not move the remote branch to match it.

## Review

Use `cursor-grok-4.5-high` by default, in plan mode so the session is read-only. Substitute the resolved SHAs into the prompt, and require a verdict line as the last line — publication below is author-dependent, and the verdict is what selects between approving, blocking, and commenting:

```bash
review_json="$(mktemp -t cursor-review-XXXXXX.json)"
body_file="$(mktemp -t cursor-review-XXXXXX.md)"

cursor-agent -p --output-format json --mode plan --trust \
  --model cursor-grok-4.5-high \
  "Review the diff of PR #N in this checkout: \`git diff $base_oid...$head_oid\`. Report only concrete defects introduced by this change — correctness, security, data loss, broken contracts, missing tests for changed behavior. For each: severity, file:line, the failure it causes, and a fix. Make no changes and no GitHub calls. End with a last line that is exactly one of: VERDICT: CLEAN, VERDICT: NON_BLOCKING, VERDICT: BLOCKING." \
  >"$review_json" ||
  { echo "cursor-agent exited nonzero; raw output in $review_json" >&2; exit 1; }
```

Adapt the prompt to the user's request and available context, keeping the review focused on concrete defects introduced by the change and keeping the verdict line intact.

## Extract the review body

Publish the review text, not the JSON envelope. Extract it into a real file and fail closed if there is nothing usable — an empty or errored result must never reach the PR:

```bash
jq -e -r 'select(.result != null and .is_error != true) | .result' \
  "$review_json" >"$body_file" ||
  { echo "no usable .result from cursor-agent; raw output in $review_json" >&2; exit 1; }
[ -s "$body_file" ] ||
  { echo "cursor-agent returned an empty review; raw output in $review_json" >&2; exit 1; }
```

The envelope shape varies by CLI version, so if extraction fails, inspect `$review_json` rather than publishing whatever came through. Keep `$review_json` until the review is published — it is the only record of what Cursor actually returned.

## Publish

GitHub rejects approve and request-changes on your own PR, so branch on the author. Both paths publish: a self-authored PR still gets the review, as a comment.

```bash
pr_author="$(gh pr view N --json author --jq .author.login)" ||
  { echo "gh pr view N failed" >&2; exit 1; }
gh_user="$(gh api user --jq .login)" ||
  { echo "gh api user failed" >&2; exit 1; }
verdict="$(tail -n 1 "$body_file")"

if [ "$pr_author" = "$gh_user" ]; then
  gh pr comment N --body-file "$body_file"
else
  case "$verdict" in
    "VERDICT: CLEAN")        gh pr review N --approve         --body-file "$body_file" ;;
    "VERDICT: NON_BLOCKING") gh pr review N --comment         --body-file "$body_file" ;;
    "VERDICT: BLOCKING")     gh pr review N --request-changes --body-file "$body_file" ;;
    *) echo "no recognized verdict line; publishing as a plain comment" >&2
       gh pr comment N --body-file "$body_file" ;;
  esac
fi
```

Publish from a file rather than an inline `--body` so backticks and newlines survive. A missing or unrecognized verdict downgrades to a comment: an unparsed review is not evidence for approving or blocking a PR.
