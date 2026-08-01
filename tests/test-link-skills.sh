#!/usr/bin/env bash
set -euo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
test_root="$(mktemp -d -t skills-link-test-XXXXXX)"
trap 'rm -rf "$test_root"' EXIT

claude_dest="$test_root/claude"
agents_dest="$test_root/agents"

CLAUDE_SKILLS_DIR="$claude_dest" \
AGENTS_SKILLS_DIR="$agents_dest" \
  "$REPO/scripts/link-skills.sh" >/dev/null

expected="$(find "$REPO/skills" -mindepth 2 -maxdepth 2 -name SKILL.md | wc -l)"

for dest in "$claude_dest" "$agents_dest"; do
  actual="$(find "$dest" -mindepth 1 -maxdepth 1 -type l | wc -l)"
  if [ "$actual" -ne "$expected" ]; then
    echo "error: expected $expected skill links in $dest, found $actual." >&2
    exit 1
  fi

  while IFS= read -r skill_md; do
    skill_dir="$(dirname "$skill_md")"
    name="$(basename "$skill_dir")"
    target="$dest/$name"

    if [ ! -L "$target" ]; then
      echo "error: missing link $target." >&2
      exit 1
    fi

    if [ "$(readlink -f "$target")" != "$(readlink -f "$skill_dir")" ]; then
      echo "error: $target does not resolve to $skill_dir." >&2
      exit 1
    fi
  done < <(find "$REPO/skills" -mindepth 2 -maxdepth 2 -name SKILL.md | sort)
done

echo "linked $expected canonical skills into both temporary destinations"

# Conflict handling: a real directory colliding with a skill name must be
# detected, refused without confirmation, and deleted only with --yes.
conflict_claude="$test_root/conflict-claude"
conflict_agents="$test_root/conflict-agents"
conflict_name="$(basename "$(dirname "$(find "$REPO/skills" -mindepth 2 -maxdepth 2 -name SKILL.md | sort | head -n 1)")")"
mkdir -p "$conflict_claude/$conflict_name"
touch "$conflict_claude/$conflict_name/sentinel"

if CLAUDE_SKILLS_DIR="$conflict_claude" AGENTS_SKILLS_DIR="$conflict_agents" \
  "$REPO/scripts/link-skills.sh" >/dev/null 2>&1 </dev/null; then
  echo "error: link-skills.sh deleted a conflicting path without confirmation." >&2
  exit 1
fi

if [ ! -f "$conflict_claude/$conflict_name/sentinel" ]; then
  echo "error: refused run still removed the conflicting path." >&2
  exit 1
fi

if [ -e "$conflict_agents/$conflict_name" ]; then
  echo "error: refused run still linked skills into another destination." >&2
  exit 1
fi

CLAUDE_SKILLS_DIR="$conflict_claude" AGENTS_SKILLS_DIR="$conflict_agents" \
  "$REPO/scripts/link-skills.sh" --yes >/dev/null

if [ ! -L "$conflict_claude/$conflict_name" ]; then
  echo "error: --yes run did not replace the conflicting path with a symlink." >&2
  exit 1
fi

echo "conflict detection refused without confirmation and replaced with --yes"
