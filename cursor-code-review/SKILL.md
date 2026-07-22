---
name: cursor-code-review
description: Use Cursor Grok 4.5 through the headless Cursor Agent CLI to review a GitHub pull request, or the implementation associated with a GitHub issue, and publish the result through GitHub CLI. Use for a sharp second-pass code review; Cursor should submit a review for another author's PR and leave a normal comment when reviewing its authenticated user's own PR.
---

# Cursor Code Review

Run `cursor-agent` from a checkout of the target repository and give it the issue or PR. Let Cursor use `gh` and the local codebase to investigate, review, and publish the result itself.

Use `cursor-grok-4.5-high` by default:

```bash
cursor-agent -p --auto-review --trust \
  --model cursor-grok-4.5-high \
  "Review ISSUE_OR_PR and publish your code review on GitHub. If the authenticated GitHub user authored the PR, leave a normal comment instead of approving or requesting changes."
```

Adapt the prompt to the user's request and available context. Cursor should resolve an issue to the relevant implementation PR, focus on concrete defects introduced by the change, and make only the requested GitHub review/comment—no code changes, pushes, merges, or other repository mutations.

Require authenticated `cursor-agent` and `gh`. If either is unauthenticated, ask the user to run `cursor-agent login` or `gh auth login`.
