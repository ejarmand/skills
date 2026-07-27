---
name: cursor-code-review
description: Use Cursor Grok 4.5 through the headless Cursor Agent CLI to review a GitHub pull request, or the implementation associated with a GitHub issue, then publish the result yourself through GitHub CLI. Use for a sharp second-pass code review; submit a review for another author's PR and leave a normal comment when reviewing the authenticated user's own PR.
disable-model-invocation: true
---

# Cursor Code Review

Run `cursor-agent` from a checkout of the target repository and give it the issue or PR. **Cursor reviews; you publish.** Cursor reads the local codebase and returns its review as text — it makes no code changes and no GitHub calls. Keeping the only mutation on your side means nothing lands on a public PR unattended, and a bad review costs a retry rather than a comment you have to walk back.

Resolve the target first, since Cursor cannot: an issue resolves to its implementation PR, and you record that PR number.

Use `cursor-grok-4.5-high` by default, in plan mode so the session is read-only:

```bash
cursor-agent -p --output-format json --mode plan --trust \
  --model cursor-grok-4.5-high \
  "Review the diff of PR #N against its base in this checkout. Report only concrete defects introduced by this change — correctness, security, data loss, broken contracts, missing tests for changed behavior. For each: severity, file:line, the failure it causes, and a fix. Make no changes and no GitHub calls."
```

Adapt the prompt to the user's request and available context, keeping the review focused on concrete defects introduced by the change.

Then publish the review yourself, verbatim, via a file rather than an inline body so backticks and newlines survive:

```bash
gh pr comment N --body-file <path>
```

GitHub rejects approve and request-changes on your own PR, so check the author first — `gh pr view N --json author` against `gh api user --jq .login`. When the author is someone else, publish with `gh pr review N --comment`, `--request-changes`, or `--approve` to match the review's conclusion; when the PR is the authenticated user's own, `gh pr comment` is the only option.

Require authenticated `cursor-agent` and `gh`. If either is unauthenticated, ask the user to run `cursor-agent login` or `gh auth login`. These CLIs evolve — treat installed `--help` as authoritative over the commands above.
