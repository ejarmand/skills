#!/usr/bin/env bash
set -euo pipefail

# Links all skills in the repository into the local skill directories used by
# each agent harness:
#   - ~/.claude/skills  — Claude Code
#   - ~/.agents/skills  — Codex and other Agent Skills-compatible harnesses
# Each entry is a symlink into this repo, so `git pull` updates its contents.
# Rerun this script to link new skills and prune dangling repo-owned links.
#
# Existing non-symlink paths that collide with link names (for example, real
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
SKILL_DESTS=(
  "${CLAUDE_SKILLS_DIR:-"$HOME/.claude/skills"}"
  "${AGENTS_SKILLS_DIR:-"$HOME/.agents/skills"}"
)

# Collect every link as a target/source pair: each skill into every skill
# destination.
targets=()
sources=()
skill_count=0
while IFS= read -r -d '' skill_md; do
  src="$(dirname "$skill_md")"
  for DEST in "${SKILL_DESTS[@]}"; do
    targets+=("$DEST/$(basename "$src")")
    sources+=("$src")
  done
  skill_count=$((skill_count + 1))
done < <(find "$REPO/skills" -mindepth 2 -maxdepth 2 -name SKILL.md -print0 | sort -z)

if [ "$skill_count" -eq 0 ]; then
  echo "error: no canonical skills found under $REPO/skills." >&2
  exit 1
fi

# Validate destinations and detect conflicts before touching anything.
for DEST in "${SKILL_DESTS[@]}"; do
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
done

conflicts=()
for target in "${targets[@]}"; do
  if [ -e "$target" ] && [ ! -L "$target" ]; then
    conflicts+=("$target")
  fi
done

if [ "${#conflicts[@]}" -gt 0 ]; then
  echo "These existing paths are not symlinks and collide with link names:"
  printf '  %s\n' "${conflicts[@]}"
  echo "They must be deleted so they can be linked from this repo."
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

# Remove dangling links into this checkout's skills tree after all conflict
# checks. Never remove a real path or a link owned by another checkout.
for DEST in "${SKILL_DESTS[@]}"; do
  for target in "$DEST"/*; do
    if [ -L "$target" ] && [ ! -e "$target" ]; then
      source="$(readlink -m "$target")"
      case "$source" in
        "$REPO"/skills/*)
          rm -- "$target"
          echo "removed retired link $target"
          ;;
      esac
    fi
  done
done

for i in "${!targets[@]}"; do
  target="${targets[$i]}"
  src="${sources[$i]}"
  mkdir -p "$(dirname "$target")"

  # Conflicts were cleared above; anything non-symlink appearing now is a
  # race with another writer, so stop rather than delete it unprompted.
  if [ -e "$target" ] && [ ! -L "$target" ]; then
    echo "error: refusing to replace non-symlink path $target." >&2
    exit 1
  fi

  ln -sfn "$src" "$target"
  echo "linked $(basename "$target") -> $src ($(dirname "$target"))"
done
