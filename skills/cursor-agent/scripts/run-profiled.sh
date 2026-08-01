#!/usr/bin/env bash
# Transactional profile runner for cursor-agent.
#
# Applies one named authority profile to an already-prepared workspace for
# exactly one supervised cursor-agent invocation, then restores the
# workspace's Cursor configuration byte-for-byte. The parent coordinator owns
# workspace lifecycle (create/pin/verify/delete); this runner never performs
# git or worktree operations.
#
# usage: run-profiled.sh --workspace /abs/path --profile NAME [--] [cursor-agent args...]
#
# Exit status: the child's, unless the arguments were invalid (2), setup
# failed before launch (71), another live runner holds the workspace (75),
# or cleanup failed after a successful child (70).
#
# Signals: INT/TERM/HUP are forwarded to the child; cleanup then runs on the
# normal path. SIGKILL and machine failure cannot be trapped — the next
# invocation against the same workspace recovers the stale transaction from
# its journal before proceeding.

set -u -o pipefail

EX_USAGE=2
EX_CLEANUP=70
EX_SETUP=71
EX_CONTENTION=75

TARGETS=("cli.json" "sandbox.json")

err() { printf 'run-profiled: %s\n' "$*" >&2; }

usage() {
  err "usage: run-profiled.sh --workspace /abs/path --profile NAME [--] [cursor-agent args...]"
  exit "$EX_USAGE"
}

workspace=""
profile=""
while [ $# -gt 0 ]; do
  case "$1" in
    --workspace) [ $# -ge 2 ] || usage; workspace="$2"; shift 2 ;;
    --profile)   [ $# -ge 2 ] || usage; profile="$2"; shift 2 ;;
    --) shift; break ;;
    -h|--help) usage ;;
    *) break ;;
  esac
done

[ -n "$workspace" ] || usage
[ -n "$profile" ] || usage
case "$workspace" in
  /*) ;;
  *) err "workspace must be an absolute path: $workspace"; exit "$EX_USAGE" ;;
esac
[ -d "$workspace" ] || { err "workspace is not a directory: $workspace"; exit "$EX_USAGE"; }

script_dir="$(cd "$(dirname "$0")" && pwd)" || { err "cannot resolve script directory"; exit "$EX_SETUP"; }
profile_dir="$(dirname "$script_dir")/profiles/$profile"
[ -d "$profile_dir" ] || { err "unknown profile: $profile"; exit "$EX_USAGE"; }
for f in "${TARGETS[@]}" cli-config.json; do
  [ -f "$profile_dir/$f" ] || { err "profile is missing $f"; exit "$EX_SETUP"; }
done

cursor_dir="$workspace/.cursor"
txn_dir="$workspace/.cursor-profile-txn"
manifest="$txn_dir/manifest"
backup_dir="$txn_dir/backup"
tmp_config=""

# --- restoration (shared by cleanup, setup rollback, and stale recovery) ---
# Reads the manifest and puts the workspace back exactly as recorded.
restore_from_manifest() {
  local failed=0 kind name state mode
  [ -f "$manifest" ] || return 0  # crash before the manifest: nothing was installed
  while read -r kind name state mode; do
    [ "$kind" = file ] || continue
    if [ "$state" = present ]; then
      if ! cp "$backup_dir/$name" "$cursor_dir/$name" || ! chmod "$mode" "$cursor_dir/$name"; then
        err "failed to restore $cursor_dir/$name"
        failed=1
      fi
    else
      if ! rm -f "$cursor_dir/$name"; then
        err "failed to remove $cursor_dir/$name"
        failed=1
      fi
    fi
  done < "$manifest"
  if [ -d "$cursor_dir" ]; then
    rm -f "$cursor_dir"/.staging.* 2>/dev/null
  fi
  if grep -q '^cursordir created$' "$manifest" 2>/dev/null && [ -d "$cursor_dir" ]; then
    if ! rm -rf "$cursor_dir"; then
      err "failed to remove created $cursor_dir"
      failed=1
    fi
  fi
  local tmp
  tmp="$(sed -n 's/^tmpconfig //p' "$manifest" | head -n 1)"
  if [ -n "$tmp" ] && [ -d "$tmp" ]; then
    if ! rm -rf "$tmp"; then
      err "failed to remove temporary config dir $tmp"
      failed=1
    fi
  fi
  return "$failed"
}

setup_fail() {
  err "setup failed; cursor-agent was not launched"
  restore_from_manifest
  rm -rf "$txn_dir"
  [ -n "$tmp_config" ] && rm -rf "$tmp_config"
  exit "$EX_SETUP"
}

# --- lock acquisition with stale-transaction recovery ----------------------
if ! mkdir "$txn_dir" 2>/dev/null; then
  [ -d "$txn_dir" ] || { err "cannot create transaction dir $txn_dir"; exit "$EX_SETUP"; }
  owner_pid="$(sed -n 's/^pid=//p' "$txn_dir/owner" 2>/dev/null | head -n 1)"
  if [ -n "$owner_pid" ] && kill -0 "$owner_pid" 2>/dev/null; then
    err "workspace is locked by a live profile runner (pid $owner_pid); parallel dispatches need separate workspaces"
    exit "$EX_CONTENTION"
  fi
  err "recovering stale profile transaction in $txn_dir"
  if ! restore_from_manifest; then
    err "stale recovery failed; inspect $txn_dir manually"
    exit "$EX_CLEANUP"
  fi
  rm -rf "$txn_dir" || { err "failed to clear recovered transaction dir"; exit "$EX_CLEANUP"; }
  mkdir "$txn_dir" 2>/dev/null || { err "workspace was relocked during recovery"; exit "$EX_CONTENTION"; }
fi
echo "pid=$$" > "$txn_dir/owner" || setup_fail
mkdir "$backup_dir" || setup_fail

# --- snapshot --------------------------------------------------------------
if [ -L "$cursor_dir" ] || { [ -e "$cursor_dir" ] && [ ! -d "$cursor_dir" ]; }; then
  err "$cursor_dir exists but is not a regular directory; refusing"
  setup_fail
fi
if [ -d "$cursor_dir" ]; then
  echo "cursordir preexisting" >> "$manifest" || setup_fail
else
  echo "cursordir created" >> "$manifest" || setup_fail
fi
for t in "${TARGETS[@]}"; do
  path="$cursor_dir/$t"
  if [ -L "$path" ] || { [ -e "$path" ] && [ ! -f "$path" ]; }; then
    err "$path exists but is not a regular file; refusing"
    setup_fail
  fi
  if [ -f "$path" ]; then
    mode="$(stat -c %a "$path")" || setup_fail
    cp "$path" "$backup_dir/$t" || setup_fail
    cmp -s "$path" "$backup_dir/$t" || setup_fail
    echo "file $t present $mode" >> "$manifest" || setup_fail
  else
    echo "file $t absent" >> "$manifest" || setup_fail
  fi
done

# --- temporary global config (isolates the user's CURSOR_CONFIG_DIR) -------
tmp_config="$(mktemp -d "${TMPDIR:-/tmp}/cursor-profile.XXXXXXXX")" || setup_fail
echo "tmpconfig $tmp_config" >> "$manifest" || setup_fail
cp "$profile_dir/cli-config.json" "$tmp_config/cli-config.json" || setup_fail

# --- atomic install --------------------------------------------------------
mkdir -p "$cursor_dir" || setup_fail
for t in "${TARGETS[@]}"; do
  staged="$(mktemp "$cursor_dir/.staging.$t.XXXXXX")" || setup_fail
  if ! cp "$profile_dir/$t" "$staged" || ! chmod 644 "$staged" || ! mv -f "$staged" "$cursor_dir/$t"; then
    rm -f "$staged"
    setup_fail
  fi
done

# --- supervised launch -----------------------------------------------------
child_pid=""
forward_signal() {
  if [ -n "$child_pid" ] && kill -0 "$child_pid" 2>/dev/null; then
    kill -s "$1" "$child_pid" 2>/dev/null
  fi
}
trap 'forward_signal TERM' TERM
trap 'forward_signal INT' INT
trap 'forward_signal HUP' HUP

( cd "$workspace" && CURSOR_CONFIG_DIR="$tmp_config" exec cursor-agent "$@" ) &
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

# --- cleanup ---------------------------------------------------------------
cleanup_status=0
restore_from_manifest || cleanup_status=1
if [ "$cleanup_status" = 0 ]; then
  rm -rf "$txn_dir" || cleanup_status=1
else
  err "leaving $txn_dir for inspection and stale recovery"
fi

if [ "$cleanup_status" != 0 ]; then
  if [ "$child_exit" = 0 ]; then
    err "child succeeded but cleanup failed"
    exit "$EX_CLEANUP"
  fi
  err "cleanup failed after child exit $child_exit"
  exit "$child_exit"
fi
exit "$child_exit"
