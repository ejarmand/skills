#!/usr/bin/env bash
set -euo pipefail

# Links all skills in the repository into the local skill directories used by
# each agent harness:
#   - ~/.claude/skills  — Claude Code
#   - ~/.agents/skills  — Codex and other Agent Skills-compatible harnesses
# Each entry is a symlink into this repo, so a `git pull` is all that's needed
# to keep installed skills up to date.
#
# Existing non-symlink paths that collide with skill names (for example, real
# directory copies from an earlier install method) are detected upfront, listed,
# and deleted only after confirmation. Pass --yes to skip the prompt for
# unattended runs. Nothing is linked or deleted before confirmation.
#
# Set CLAUDE_SKILLS_DIR and/or AGENTS_SKILLS_DIR to override the destinations.
# This is useful for hermetic smoke tests and non-default harness layouts.

ASSUME_YES=0
case "${1:-}" in
  --yes|-y) ASSUME_YES=1 ;;
  "") ;;
  *)
    echo "usage: $0 [--yes]" >&2
    exit 2
    ;;
esac

REPO="$(cd "$(dirname "$0")/.." && pwd)"
DESTS=(
  "${CLAUDE_SKILLS_DIR:-"$HOME/.claude/skills"}"
  "${AGENTS_SKILLS_DIR:-"$HOME/.agents/skills"}"
)

# Collect the repo's skills once, link into every destination.
names=()
srcs=()
while IFS= read -r -d '' skill_md; do
  src="$(dirname "$skill_md")"
  names+=("$(basename "$src")")
  srcs+=("$src")
done < <(find "$REPO/skills" -mindepth 2 -maxdepth 2 -name SKILL.md -print0 | sort -z)

if [ "${#names[@]}" -eq 0 ]; then
  echo "error: no canonical skills found under $REPO/skills." >&2
  exit 1
fi

# Validate destinations and detect conflicts before touching anything.
conflicts=()
for DEST in "${DESTS[@]}"; do
  # If $DEST is a symlink that resolves into this repo, we'd end up writing the
  # per-skill symlinks back into the repo's own skills/ tree. Detect and bail
  # out instead of polluting the working copy.
  if [ -L "$DEST" ]; then
    resolved="$(readlink -f "$DEST")"
    case "$resolved" in
      "$REPO"|"$REPO"/*)
        echo "error: $DEST is a symlink into this repo ($resolved)." >&2
        echo "Remove it (rm \"$DEST\") and re-run; the script will recreate it as a real dir." >&2
        exit 1
        ;;
    esac
  fi

  for name in "${names[@]}"; do
    target="$DEST/$name"
    if [ -e "$target" ] && [ ! -L "$target" ]; then
      conflicts+=("$target")
    fi
  done
done

if [ "${#conflicts[@]}" -gt 0 ]; then
  echo "These existing paths are not symlinks and collide with skill names:"
  printf '  %s\n' "${conflicts[@]}"
  echo "They must be deleted so the skills can be linked from this repo."
  if [ "$ASSUME_YES" -ne 1 ]; then
    if [ ! -t 0 ]; then
      echo "error: cannot confirm deletion without a terminal; re-run interactively or pass --yes." >&2
      exit 1
    fi
    read -r -p "Delete these ${#conflicts[@]} paths and replace them with symlinks? [y/N] " reply
    case "$reply" in
      y|Y|yes|YES) ;;
      *)
        echo "aborted; nothing was changed."
        exit 1
        ;;
    esac
  fi
  rm -rf -- "${conflicts[@]}"
fi

for DEST in "${DESTS[@]}"; do
  mkdir -p "$DEST"

  for i in "${!names[@]}"; do
    name="${names[$i]}"
    src="${srcs[$i]}"
    target="$DEST/$name"

    # Conflicts were cleared above; anything non-symlink appearing now is a
    # race with another writer, so stop rather than delete it unprompted.
    if [ -e "$target" ] && [ ! -L "$target" ]; then
      echo "error: refusing to replace non-symlink path $target." >&2
      exit 1
    fi

    ln -sfn "$src" "$target"
    echo "linked $name -> $src ($DEST)"
  done
done
