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
