# Issue → branch, worktree, and draft PR

When the target is an issue, the rally needs a PR to play against. Create it
like this before rally 1.

Branch from the default branch as `ppp/issue-<n>-<slug>`, create a linked
worktree at `REPO_ROOT/worktrees/[branch]` (e.g.
`worktrees/ppp/issue-42-fix-cache`), and use that worktree as `checkout`. Run
rally 1 there, push, then open a *draft* PR that closes the issue. Mark it
ready only at a passing finish.

Leave the primary checkout on its current branch and exclude `/worktrees/` via
Git info exclude — no tracked `.gitignore` change unless asked.

```bash
repo_root="$(git rev-parse --show-toplevel)"
branch="ppp/issue-N-slug"
worktree_path="$repo_root/worktrees/$branch"
exclude_file="$(git -C "$repo_root" rev-parse --path-format=absolute --git-path info/exclude)"
grep -qxF /worktrees/ "$exclude_file" ||
  printf '\n/worktrees/\n' >>"$exclude_file"
mkdir -p "$(dirname "$worktree_path")"
git -C "$repo_root" fetch origin "$default_branch"
git -C "$repo_root" worktree add -b "$branch" "$worktree_path" \
  "origin/$default_branch"
checkout="$worktree_path"
```
