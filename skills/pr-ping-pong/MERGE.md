# Merge gate

Fires only when the user set merge-on-pass. Gather the state:

```bash
gh pr checks N
gh pr view N --json mergeable,mergeStateStatus,isDraft,reviewDecision
```

Merge only when every condition holds:

- The rally ended in a **Pass**.
- All required checks are passing.
- `mergeable` is `MERGEABLE`.
- The PR is not a draft.
- `mergeStateStatus` is `CLEAN` or `HAS_HOOKS`.
- `reviewDecision` is empty or `APPROVED`.

Never use `--admin`. If any condition fails, report which one and leave the PR
unmerged.
