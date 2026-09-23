#!/usr/bin/env bash
set -euo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
test_root="$(mktemp -d -t skills-link-test-XXXXXX)"
trap 'rm -rf "$test_root"' EXIT

claude_dest="$test_root/claude"
agents_dest="$test_root/agents"
bin_dest="$test_root/bin"
# Every run points the Claude settings file into the temporary tree so the
# developer's real settings are never read or written.
export CLAUDE_SETTINGS_FILE="$test_root/settings.json"

CLAUDE_SKILLS_DIR="$claude_dest" \
AGENTS_SKILLS_DIR="$agents_dest" \
BIN_DIR="$bin_dest" \
  "$REPO/scripts/link-skills.sh" >/dev/null </dev/null

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

bins="$(find "$REPO/skills" -mindepth 3 -maxdepth 3 -path '*/bin/*' -type f -perm -u+x | sort)"
if [ -z "$bins" ]; then
  echo "error: expected at least one skill executable under skills/*/bin/." >&2
  exit 1
fi
while IFS= read -r bin; do
  target="$bin_dest/$(basename "$bin")"
  if [ ! -L "$target" ] || [ "$(readlink -f "$target")" != "$(readlink -f "$bin")" ]; then
    echo "error: $target is not a link to $bin." >&2
    exit 1
  fi
done <<< "$bins"
if [ "$(find "$bin_dest" -mindepth 1 | wc -l)" -ne "$(wc -l <<< "$bins")" ]; then
  echo "error: $bin_dest holds entries other than the skill executables." >&2
  exit 1
fi

echo "linked every skills/*/bin executable into the temporary bin directory"

# Conflict handling: a real directory colliding with a skill name must be
# detected, refused without confirmation, and deleted only with --yes.
conflict_claude="$test_root/conflict-claude"
conflict_agents="$test_root/conflict-agents"
conflict_name="$(basename "$(dirname "$(find "$REPO/skills" -mindepth 2 -maxdepth 2 -name SKILL.md | sort | head -n 1)")")"
mkdir -p "$conflict_claude/$conflict_name"
touch "$conflict_claude/$conflict_name/sentinel"

if CLAUDE_SKILLS_DIR="$conflict_claude" AGENTS_SKILLS_DIR="$conflict_agents" \
  BIN_DIR="$test_root/conflict-bin" \
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
  BIN_DIR="$test_root/conflict-bin" \
  "$REPO/scripts/link-skills.sh" --yes >/dev/null </dev/null

if [ ! -L "$conflict_claude/$conflict_name" ]; then
  echo "error: --yes run did not replace the conflicting path with a symlink." >&2
  exit 1
fi

echo "conflict detection refused without confirmation and replaced with --yes"

# A real file in BIN_DIR colliding with a skill executable gets the same rule.
bin_name="$(basename "$(head -n 1 <<< "$bins")")"
clobber_bin="$test_root/clobber-bin"
mkdir -p "$clobber_bin"
echo sentinel > "$clobber_bin/$bin_name"
link_into_clobber_bin() {
  CLAUDE_SKILLS_DIR="$test_root/clobber-claude" AGENTS_SKILLS_DIR="$test_root/clobber-agents" \
    BIN_DIR="$clobber_bin" "$REPO/scripts/link-skills.sh" "$@" </dev/null
}

if link_into_clobber_bin >/dev/null 2>&1; then
  echo "error: link-skills.sh replaced a real file in BIN_DIR without confirmation." >&2
  exit 1
fi
if [ -L "$clobber_bin/$bin_name" ] || [ "$(cat "$clobber_bin/$bin_name")" != sentinel ]; then
  echo "error: refused run still replaced the file in BIN_DIR." >&2
  exit 1
fi
if [ -e "$test_root/clobber-claude" ]; then
  echo "error: refused run still linked skills." >&2
  exit 1
fi

link_into_clobber_bin --yes >/dev/null
if [ ! -L "$clobber_bin/$bin_name" ]; then
  echo "error: --yes run did not replace the file in BIN_DIR with a symlink." >&2
  exit 1
fi

echo "BIN_DIR conflicts refused without confirmation and replaced with --yes"

# crossSessionInbound prompt: never asked or written without a terminal or
# under --yes; on a terminal, "y" sets it, anything else leaves the file.
settings="$CLAUDE_SETTINGS_FILE"
echo '{"theme": "dark"}' > "$settings"
link_into_settings() {
  CLAUDE_SKILLS_DIR="$test_root/settings-claude" AGENTS_SKILLS_DIR="$test_root/settings-agents" \
    BIN_DIR="$test_root/settings-bin" "$REPO/scripts/link-skills.sh" "$@"
}

link_into_settings </dev/null | grep -Fq 'crossSessionInbound is not "accept"'
link_into_settings --yes </dev/null >/dev/null
if [ "$(cat "$settings")" != '{"theme": "dark"}' ]; then
  echo "error: a non-interactive or --yes run changed the settings file." >&2
  exit 1
fi

if ! command -v script >/dev/null; then
  echo "skipped terminal prompt checks: util-linux script is not installed"
  exit 0
fi
on_terminal() { # on_terminal <answer>: run the installer on a pseudo-terminal
  printf '%s\n' "$1" | CLAUDE_SKILLS_DIR="$test_root/settings-claude" \
    AGENTS_SKILLS_DIR="$test_root/settings-agents" BIN_DIR="$test_root/settings-bin" \
    script -qec "$REPO/scripts/link-skills.sh" /dev/null >/dev/null
}

on_terminal n
if [ "$(cat "$settings")" != '{"theme": "dark"}' ]; then
  echo "error: answering n changed the settings file." >&2
  exit 1
fi
on_terminal y
if ! python3 -c 'import json, sys; d = json.load(open(sys.argv[1])); sys.exit(d != {"theme": "dark", "crossSessionInbound": "accept"})' "$settings"; then
  echo "error: answering y did not set crossSessionInbound while keeping other settings." >&2
  exit 1
fi

echo "crossSessionInbound prompt skipped without a terminal or with --yes, and honoured on a terminal"
