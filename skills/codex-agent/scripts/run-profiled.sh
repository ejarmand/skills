#!/usr/bin/env bash
# Transactional profile runner for codex exec.
#
# Assembles a throwaway CODEX_HOME from one named authority profile —
# config.toml and rules/ copied in, auth.json symlinked to the real home so
# token refreshes write through, installed skills symlinked so the child can
# invoke cited skills — runs exactly one profiled `codex exec` session in it,
# and deletes the home afterwards. The root session IS the profiled agent;
# native children it spawns inherit the same sandbox and rules. Nothing
# touches the workspace, so parallel dispatches need no lock. The parent
# coordinator owns workspace lifecycle (create/pin/verify/delete); this
# runner never performs git or worktree operations.
#
# usage: run-profiled.sh --workspace /abs/path --profile NAME [--effort LEVEL] [--] [codex exec args...]
#
# The runner owns the child's authority envelope — CODEX_HOME,
# --sandbox read-only, -C workspace — so child arguments are allowlisted:
# only `--json`, `--output-last-message <path>`, `--model`/`-m`, and the
# prompt pass through. `--ignore-user-config` and `--ignore-rules` silently
# strip the profile's rules while its instructions keep applying; they are
# rejected with every other flag.
#
# Fail-closed preflights: a workspace containing `.codex/` is refused (its
# rules would load into the child's policy with no trust gate, letting the
# work under review grant its own reviewer authority), and a missing real
# auth.json is refused rather than dispatched unauthenticated.
#
# Exit status: the child's, unless the arguments were invalid (2), setup
# failed before launch (71), or cleanup failed after a successful child (70).

set -u -o pipefail

EX_USAGE=2
EX_CLEANUP=70
EX_SETUP=71

err() { printf 'run-profiled: %s\n' "$*" >&2; }

usage() {
  err "usage: run-profiled.sh --workspace /abs/path --profile NAME [--effort LEVEL] [--] [codex exec args...]"
  exit "$EX_USAGE"
}

workspace=""
profile=""
effort=""
while [ $# -gt 0 ]; do
  case "$1" in
    --workspace) [ $# -ge 2 ] || usage; workspace="$2"; shift 2 ;;
    --profile)   [ $# -ge 2 ] || usage; profile="$2"; shift 2 ;;
    --effort)    [ $# -ge 2 ] || usage; effort="$2"; shift 2 ;;
    --) shift; break ;;
    -h|--help) usage ;;
    *) break ;;
  esac
done

[ -n "$workspace" ] || usage
[ -n "$profile" ] || usage
case "$effort" in
  ""|minimal|low|medium|high|xhigh|max|ultra) ;;
  *) err "invalid effort: $effort"; exit "$EX_USAGE" ;;
esac
expect_value=""
for arg in "$@"; do
  if [ -n "$expect_value" ]; then
    expect_value=""
    case "$arg" in
      -*) err "child argument value looks like a flag: $arg"; exit "$EX_USAGE" ;;
    esac
    continue
  fi
  case "$arg" in
    --json) ;;
    --output-last-message|--model|-m) expect_value=1 ;;
    --output-last-message=*|--model=*) ;;
    -*) err "child argument outside the profile allowlist: $arg"; exit "$EX_USAGE" ;;
    *) ;;
  esac
done
[ -z "$expect_value" ] || { err "missing value for the final child argument"; exit "$EX_USAGE"; }
case "$workspace" in
  /*) ;;
  *) err "workspace must be an absolute path: $workspace"; exit "$EX_USAGE" ;;
esac
[ -d "$workspace" ] || { err "workspace is not a directory: $workspace"; exit "$EX_USAGE"; }
workspace="$(cd "$workspace" && pwd -P)" || { err "cannot resolve workspace"; exit "$EX_USAGE"; }

script_dir="$(cd "$(dirname "$0")" && pwd)" || { err "cannot resolve script directory"; exit "$EX_SETUP"; }
profile_dir="$(dirname "$script_dir")/profiles/$profile"
[ -d "$profile_dir" ] || { err "unknown profile: $profile"; exit "$EX_USAGE"; }
[ -f "$profile_dir/config.toml" ] || { err "profile is missing config.toml"; exit "$EX_SETUP"; }

if [ -e "$workspace/.codex" ]; then
  err "workspace contains .codex/ — its rules would load into the child's policy; refusing"
  exit "$EX_SETUP"
fi

real_home="${CODEX_HOME:-$HOME/.codex}"
[ -f "$real_home/auth.json" ] || { err "no auth.json in $real_home; run codex login first"; exit "$EX_SETUP"; }

tmp_home="$(mktemp -d "${TMPDIR:-/tmp}/codex-profile.XXXXXXXX")" || { err "cannot create temporary CODEX_HOME"; exit "$EX_SETUP"; }

setup_fail() {
  err "setup failed; codex was not launched"
  rm -rf "$tmp_home"
  exit "$EX_SETUP"
}

cp "$profile_dir/config.toml" "$tmp_home/config.toml" || setup_fail
if [ -d "$profile_dir/rules" ]; then
  cp -R "$profile_dir/rules" "$tmp_home/rules" || setup_fail
fi
ln -s "$real_home/auth.json" "$tmp_home/auth.json" || setup_fail
if [ -d "$real_home/skills" ]; then
  ln -s "$real_home/skills" "$tmp_home/skills" || setup_fail
fi

child_pid=""
forward_signal() {
  if [ -n "$child_pid" ] && kill -0 "$child_pid" 2>/dev/null; then
    kill -s "$1" "$child_pid" 2>/dev/null
  fi
}
trap 'forward_signal TERM' TERM
trap 'forward_signal INT' INT
trap 'forward_signal HUP' HUP

# stdin closed: codex exec otherwise blocks reading it in headless use.
# No --ephemeral: an ephemeral root registers no thread id, so full-history
# child forks fail ("no thread with id"); session files land in the temp
# home and are removed with it.
effort_args=()
[ -z "$effort" ] || effort_args=(-c "model_reasoning_effort=\"$effort\"")
env CODEX_HOME="$tmp_home" codex exec "${effort_args[@]}" --sandbox read-only \
  -C "$workspace" "$@" < /dev/null &
child_pid=$!

child_exit=""
while :; do
  if wait "$child_pid"; then
    child_exit=0
  else
    child_exit=$?
  fi
  # A trap-interrupted wait returns while the child is still alive; wait again.
  kill -0 "$child_pid" 2>/dev/null || break
done

# rm -rf removes the auth/skills symlinks themselves, never their targets.
if ! rm -rf "$tmp_home"; then
  err "failed to remove temporary CODEX_HOME $tmp_home — inspect and remove it manually"
  if [ "$child_exit" = 0 ]; then
    exit "$EX_CLEANUP"
  fi
fi
exit "$child_exit"
