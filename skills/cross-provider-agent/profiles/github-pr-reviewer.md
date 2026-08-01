# Profile: github-pr-reviewer

Reviews a GitHub PR or issue implementation from a caller-prepared checkout
and publishes its own review.

Allowed:

- workspace file reads, read-only git inspection (`diff`, `log`, `show`,
  `status`), and bounded text search
- GitHub reads: `gh issue view`, `gh pr view`, `gh pr diff`
- one write: `gh pr comment` — the reviewer publishes its review as a
  top-level PR comment. Every provider posts as the authenticated user, so
  the comment body must open by naming the provider and review axis.

Forbidden: everything else — filesystem writes; git mutations; `gh api`,
`gh pr review`, `gh issue comment`, and every other `gh` subcommand; network
destinations beyond GitHub; sandbox or approval bypasses.
