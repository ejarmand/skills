---
name: cursor-code-review
description: Use Cursor Grok 4.5 through the headless Cursor Agent CLI to review a GitHub pull request, or the implementation associated with a GitHub issue, then publish the result through GitHub CLI. Use for a sharp second-pass code review; submit a review for another author's PR and leave a normal comment when reviewing the authenticated user's own PR.
disable-model-invocation: true
---

# Cursor Code Review

Cursor reviews read-only; you publish. Resolve an issue to its implementation PR, check out the PR branch, and require authenticated `cursor-agent` and `gh`.

Fetch the current base and capture Cursor's plain-text review:

```bash
set -e
N=123
base_ref="$(gh pr view "$N" --json baseRefName --jq .baseRefName)"
git fetch origin "$base_ref"
review_file="$(mktemp -t cursor-review-XXXXXX)"

cursor-agent -p --output-format text --mode plan --trust \
  --model cursor-grok-4.5-high \
  "Review git diff origin/$base_ref...HEAD for PR #$N. Report only concrete defects introduced by the change, with severity, file:line, failure scenario, and fix. Make no changes and no GitHub calls." \
  >"$review_file"
```

Publish only after Cursor exits successfully. Use `gh pr comment "$N" --body-file "$review_file"` when the authenticated user authored the PR; otherwise use `gh pr review "$N" --comment --body-file "$review_file"`. Adapt the prompt to the request, but keep Cursor read-only and make no other repository mutations.
