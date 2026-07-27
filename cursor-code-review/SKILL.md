---
name: cursor-code-review
description: Use Cursor Grok 4.5 through the headless Cursor Agent CLI to review a GitHub pull request, or the implementation associated with a GitHub issue, then publish the result yourself through GitHub CLI. Use for a sharp second-pass code review; submit a review for another author's PR and leave a normal comment when reviewing the authenticated user's own PR.
disable-model-invocation: true
---

# Cursor Code Review

Run `cursor-agent` from a checkout of the target repository and give it the issue or PR. **Cursor reviews; you publish.** Cursor reads the local codebase and returns its review as text — it makes no code changes and no GitHub calls. Keeping the only mutation on your side means nothing lands on a public PR unattended, and a bad review costs a retry rather than a comment you have to walk back.

Require authenticated `cursor-agent` and `gh`. If either is unauthenticated, ask the user to run `cursor-agent login` or `gh auth login`. These CLIs evolve — treat installed `--help` as authoritative over the commands below.

## Run the review

Resolve the target first, since Cursor cannot: an issue resolves to its implementation PR, and you record that PR number.

Then run the whole workflow — resolve, review, extract, publish — as **one script**. Every Bash call is a fresh shell, so `base_oid`, `review_json`, and `body_file` do not survive being split across blocks: run in pieces, Cursor gets a prompt with empty SHAs and publication reads an unset path.

```bash
set -uo pipefail
N=123                                   # the resolved PR number

# --- resolve and pin the commits under review ---
# "The diff against its base" is not a stable instruction: a base that advances,
# or a head pushed from elsewhere, changes what Cursor reads without changing a
# word of the prompt. Each check fails closed on its own, so a later success
# cannot mask an earlier failure.
pr_meta="$(gh pr view "$N" --json baseRefName,baseRefOid,headRefOid \
  --jq '[.baseRefName, .baseRefOid, .headRefOid] | @tsv')" ||
  { echo "gh pr view $N failed" >&2; exit 1; }
read -r base_ref base_oid head_oid <<<"$pr_meta"
[ -n "$base_ref" ] && [ -n "$base_oid" ] && [ -n "$head_oid" ] ||
  { echo "incomplete base/head metadata for PR $N: $pr_meta" >&2; exit 1; }

git fetch origin "$base_ref" ||
  { echo "fetch of $base_ref failed" >&2; exit 1; }
git cat-file -e "${base_oid}^{commit}" ||
  { echo "base $base_oid is not present after fetching $base_ref" >&2; exit 1; }
test "$(git rev-parse HEAD)" = "$head_oid" ||
  { echo "checkout HEAD is not PR $N head $head_oid — check out the PR branch first" >&2; exit 1; }

# --- review, read-only ---
review_json="$(mktemp -t cursor-review-XXXXXX.json)"
body_file="$(mktemp -t cursor-review-XXXXXX.md)"

cursor-agent -p --output-format json --mode plan --trust \
  --model cursor-grok-4.5-high \
  "Review the diff of PR #$N in this checkout: \`git diff $base_oid...$head_oid\`. Report only concrete defects introduced by this change — correctness, security, data loss, broken contracts, missing tests for changed behavior. For each: severity, file:line, the failure it causes, and a fix. Make no changes and no GitHub calls. End with a last line that is exactly one of: VERDICT: CLEAN, VERDICT: NON_BLOCKING, VERDICT: BLOCKING." \
  >"$review_json" ||
  { echo "cursor-agent exited nonzero; raw output in $review_json" >&2; exit 1; }

# --- extract the review text, not the JSON envelope ---
jq -e -r 'select(.result != null and .is_error != true) | .result' \
  "$review_json" >"$body_file" ||
  { echo "no usable .result from cursor-agent; raw output in $review_json" >&2; exit 1; }
[ -s "$body_file" ] ||
  { echo "cursor-agent returned an empty review; raw output in $review_json" >&2; exit 1; }

# --- verdict: last recognized line, tolerating CRLF and trailing blank lines ---
verdict="$(tr -d '\r' <"$body_file" \
  | grep -E '^VERDICT: (CLEAN|NON_BLOCKING|BLOCKING)$' \
  | tail -n 1)"
[ -n "$verdict" ] ||
  { echo "no recognized verdict in $body_file; refusing to publish" >&2; exit 1; }

# --- publish ---
pr_author="$(gh pr view "$N" --json author --jq .author.login)" ||
  { echo "gh pr view $N failed" >&2; exit 1; }
gh_user="$(gh api user --jq .login)" ||
  { echo "gh api user failed" >&2; exit 1; }

if [ "$pr_author" = "$gh_user" ]; then
  gh pr comment "$N" --body-file "$body_file"
else
  case "$verdict" in
    "VERDICT: CLEAN")        gh pr review "$N" --approve         --body-file "$body_file" ;;
    "VERDICT: NON_BLOCKING") gh pr review "$N" --comment         --body-file "$body_file" ;;
    "VERDICT: BLOCKING")     gh pr review "$N" --request-changes --body-file "$body_file" ;;
    *) echo "unreachable verdict $verdict" >&2; exit 1 ;;
  esac
fi
```

Adapt the prompt to the user's request and available context, keeping the review focused on concrete defects introduced by the change and keeping the verdict line requirement intact.

Notes on the guards, in the order they fire:

- A local `HEAD` that differs from `headRefOid` means you would review a tree GitHub is not showing. Stop and check out the PR branch; do not review the local state, and do not move the remote branch to match it.
- The JSON envelope shape varies by CLI version. If extraction fails, inspect `$review_json` rather than publishing whatever came through — it is the only record of what Cursor actually returned, so keep it until the review is published.
- **No verdict, no publication.** An unparsed review is not evidence for approving, blocking, *or* commenting, and a downgrade-to-comment path would quietly turn a failed extraction into a PR comment. Re-run the review instead.
- GitHub rejects approve and request-changes on your own PR, so publication branches on the author. Both paths publish; a self-authored PR gets the review as a comment.
- Publish from a file rather than an inline `--body` so backticks and newlines survive.

## Check the verdict parser

`.result` usually ends with a trailing newline, sometimes several, and CRLF appears often enough to matter — `tail -n 1` on the raw file returns an empty string for all of those and would have silently lost the verdict. Confirm the pipeline before trusting it:

```bash
parse() { tr -d '\r' | grep -E '^VERDICT: (CLEAN|NON_BLOCKING|BLOCKING)$' | tail -n 1; }

printf 'findings\nVERDICT: CLEAN\n'              | parse   # VERDICT: CLEAN
printf 'findings\nVERDICT: BLOCKING\n\n\n'       | parse   # VERDICT: BLOCKING
printf 'findings\r\nVERDICT: NON_BLOCKING\r\n'   | parse   # VERDICT: NON_BLOCKING
printf 'VERDICT: BLOCKING\nVERDICT: CLEAN\n'     | parse   # VERDICT: CLEAN  (last wins)
printf 'findings, no verdict line\n'             | parse   # (empty → refuse to publish)
```

The pipeline is the same one the script runs inline. Anchoring both ends keeps prose mentions, trailing text, and partial verdicts from matching; `tail -n 1` takes the last exact verdict — the line Cursor was asked to end with.
