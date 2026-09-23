#!/usr/bin/env bash
set -euo pipefail

# Links all skills in the repository into the local skill directories used by
# each agent harness, and every executable under skills/*/bin/ onto PATH:
#   - ~/.claude/skills  — Claude Code
#   - ~/.agents/skills  — Codex and other Agent Skills-compatible harnesses
#   - ~/.local/bin      — skill CLIs such as agent-resume
# Each entry is a symlink into this repo, so a `git pull` is all that's needed
# to keep installed skills up to date.
#
# Existing non-symlink paths that collide with link names (for example, real
# directory copies from an earlier install method) are detected upfront, listed,
# and deleted only after confirmation. Pass --yes to skip the prompt for
# unattended runs. Nothing is linked or deleted before confirmation.
#
# Afterwards, on a terminal and without --yes, it offers to set
# crossSessionInbound to "accept" in the Claude settings file so agent-resume
# messages reach bypass-permissions sessions without approval.
#
# Set CLAUDE_SKILLS_DIR, AGENTS_SKILLS_DIR, BIN_DIR and/or CLAUDE_SETTINGS_FILE
# to override the destinations. This is useful for hermetic smoke tests and
# non-default harness layouts.

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
BIN_DIR="${BIN_DIR:-"$HOME/.local/bin"}"
SETTINGS="${CLAUDE_SETTINGS_FILE:-"$HOME/.claude/settings.json"}"

# Collect every link as a target/source pair: each skill into every skill
# destination, and each skill executable into BIN_DIR.
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

while IFS= read -r -d '' bin; do
  targets+=("$BIN_DIR/$(basename "$bin")")
  sources+=("$bin")
done < <(find "$REPO/skills" -mindepth 3 -maxdepth 3 -path '*/bin/*' -type f -perm -u+x -print0 | sort -z)

# Validate destinations and detect conflicts before touching anything.
for DEST in "${SKILL_DESTS[@]}" "$BIN_DIR"; do
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

# agent-resume posts into live Claude sessions from a process the session did
# not start; a bypassPermissions session holds such messages for approval
# unless crossSessionInbound is "accept". Only a person at a terminal may
# loosen that, so --yes and non-interactive runs leave the file alone.
if python3 -c 'import json, sys; sys.exit(json.load(open(sys.argv[1])).get("crossSessionInbound") != "accept")' \
  "$SETTINGS" 2>/dev/null; then
  :
elif [ "$ASSUME_YES" -eq 1 ] || [ ! -t 0 ]; then
  echo "note: crossSessionInbound is not \"accept\" in $SETTINGS; agent-resume messages to bypassPermissions Claude sessions will wait for approval. Re-run on a terminal without --yes to set it."
else
  read -r -p "Set crossSessionInbound to \"accept\" in $SETTINGS so agent-resume messages reach bypassPermissions Claude sessions without approval? [y/N] " reply
  case "$reply" in
    y|Y|yes|YES)
      # The links are already in place, so a bad settings file is reported
      # without failing the install.
      if python3 - "$SETTINGS" <<'PY'
import json, os, sys
path = sys.argv[1]
try:
    settings = json.load(open(path)) if os.path.exists(path) else {}
except ValueError as error:
    sys.exit(f"error: {path} is not valid JSON ({error}); left it unchanged. "
             'Fix it and re-run, or set "crossSessionInbound": "accept" by hand.')
settings["crossSessionInbound"] = "accept"
os.makedirs(os.path.dirname(os.path.abspath(path)), exist_ok=True)
with open(path, "w") as out:
    json.dump(settings, out, indent=2)
    out.write("\n")
PY
      then
        echo "set crossSessionInbound to \"accept\" in $SETTINGS"
      fi
      ;;
    *)
      echo "left $SETTINGS unchanged."
      ;;
  esac
fi
