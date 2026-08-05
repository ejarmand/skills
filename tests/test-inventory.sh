#!/usr/bin/env bash
set -euo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
router="$REPO/skills/skill-router/SKILL.md"
readme="$REPO/README.md"

declare -A declared_names=()
count=0

for skill_dir in "$REPO"/skills/*; do
  skill_md="$skill_dir/SKILL.md"
  if [ ! -f "$skill_md" ]; then
    echo "error: canonical skill directory lacks SKILL.md: $skill_dir" >&2
    exit 1
  fi

  dir_name="$(basename "$skill_dir")"
  declared_name="$(sed -n 's/^name: //p' "$skill_md" | head -n 1)"

  if [ "$dir_name" != "$declared_name" ]; then
    echo "error: $skill_md declares '$declared_name', expected '$dir_name'." >&2
    exit 1
  fi

  if [ -n "${declared_names[$declared_name]:-}" ]; then
    echo "error: duplicate skill name '$declared_name'." >&2
    exit 1
  fi
  declared_names[$declared_name]=1

  if ! grep -Fq "\`$dir_name\`" "$readme"; then
    echo "error: README inventory omits '$dir_name'." >&2
    exit 1
  fi

  if [ "$dir_name" != skill-router ] &&
    ! grep -Fq "\`/$dir_name\`" "$router"; then
    echo "error: skill router omits '$dir_name'." >&2
    exit 1
  fi

  skill_yaml="$skill_dir/agents/openai.yaml"
  dmi=0
  if grep -q '^disable-model-invocation: true' "$skill_md"; then dmi=1; fi
  aii=0
  if [ -f "$skill_yaml" ] && grep -q 'allow_implicit_invocation: false' "$skill_yaml"; then aii=1; fi
  if [ "$dmi" != "$aii" ]; then
    echo "error: $dir_name invocation flags disagree: SKILL.md disable-model-invocation=$dmi but openai.yaml allow_implicit_invocation:false=$aii." >&2
    exit 1
  fi

  count=$((count + 1))
done

if grep -En 'ask-matt|cursor-code-review|pr-pping-pong' "$router" "$readme"; then
  echo "error: stale skill name found in public inventory." >&2
  exit 1
fi

# The repo-root .claude-plugin/ is this repo's own plugin manifest (the
# claude-agent profiled-dispatch skill transport), not an upstream artifact.
if find "$REPO" -path "$REPO/.claude-plugin" -prune -o \
  -path "$REPO/worktrees" -prune -o \
  \( -path '*/.claude-plugin/*' -o -path '*/deprecated/*' -o -path '*/in-progress/*' \) \
  -print -quit | grep -q .; then
  echo "error: upstream distribution-only paths were promoted." >&2
  exit 1
fi

echo "validated $count canonical skills across filesystem, frontmatter, router, and README"
