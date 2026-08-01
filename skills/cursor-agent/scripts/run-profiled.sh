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
# The runner owns the child's authority envelope — workspace (cwd), config
# isolation (CURSOR_CONFIG_DIR), and the staged profile — so child arguments
# are allowlisted: only `-p`/`--print`, `--trust`, `--output-format`,
# `--model`, and the prompt pass through; every other flag is rejected.
#
# Stale-journal recovery is authenticated against runner-owned state outside
# the workspace (a per-workspace registry entry under
# $CURSOR_PROFILE_STATE_DIR, default $XDG_STATE_HOME/cursor-profile-runner):
# a journal whose nonce has no matching registry entry is left untouched and
# the runner fails closed, so a pre-seeded workspace journal cannot direct
# the removal of an unrelated .cursor directory or temp path.
#
# Exit status: the child's, unless the arguments were invalid (2), setup
# failed before launch with a clean rollback (71), another live runner holds
# the workspace (75), or a rollback/cleanup failure left the journal in
# place for recovery (70) — whether that failure happened before launch or
# after a successful child.
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
    -p|--print|--trust) ;;
    --output-format|--model|-m) expect_value=1 ;;
    --output-format=*|--model=*) ;;
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
for f in "${TARGETS[@]}"; do
  [ -f "$profile_dir/$f" ] || { err "profile is missing $f"; exit "$EX_SETUP"; }
done
command -v jq > /dev/null 2>&1 || { err "jq is required to derive cli-config.json"; exit "$EX_SETUP"; }

cursor_dir="$workspace/.cursor"
txn_dir="$workspace/.cursor-profile-txn"
manifest="$txn_dir/manifest"
backup_dir="$txn_dir/backup"
tmp_config=""
cursordir_created=0

# Runner-owned state outside the workspace: authenticates stale journals and
# records the facts (created .cursor, temp-config path) that recovery may act
# on. The workspace journal alone is never trusted for those actions.
reg_dir="${CURSOR_PROFILE_STATE_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/cursor-profile-runner}"
ws_key="$(printf '%s' "$workspace" | md5sum | cut -d' ' -f1)" || { err "cannot derive workspace key"; exit "$EX_SETUP"; }
reg_entry="$reg_dir/$ws_key"

# --- file restoration (shared by cleanup, setup rollback, and recovery) ----
# Restores exactly the two policy files the manifest records. The manifest is
# workspace-resident and thus untrusted, so names and modes are validated and
# anything else fails closed. Deliberately does NOT remove directories or
# temp paths — those actions come only from in-process facts or the
# authenticated registry.
restore_targets() {
  local failed=0 kind name state mode
  [ -f "$manifest" ] || return 0  # crash before the manifest: nothing was installed
  while read -r kind name state mode; do
    [ "$kind" = file ] || continue
    case "$name" in
      cli.json|sandbox.json) ;;
      *) err "manifest names an unexpected file '$name'; refusing"
         failed=1; continue ;;
    esac
    if [ "$state" = present ]; then
      case "$mode" in
        [0-7][0-7][0-7]|[0-7][0-7][0-7][0-7]) ;;
        *) err "manifest carries invalid mode '$mode' for $name; refusing"
           failed=1; continue ;;
      esac
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
  return "$failed"
}

remove_registered_tmp() {
  # $1: temp-config path from a trusted source (in-process var or registry).
  [ -n "$1" ] && [ -e "$1" ] || return 0
  case "$1" in
    "${TMPDIR:-/tmp}"/cursor-profile.????????) ;;
    *) err "temp-config path is outside the runner's temp root; refusing: $1"
       return 1 ;;
  esac
  if [ -L "$1" ] || [ ! -d "$1" ]; then
    err "temp-config path is not a plain directory; refusing: $1"
    return 1
  fi
  rm -rf "$1" || { err "failed to remove temporary config dir $1"; return 1; }
}

setup_fail() {
  err "setup failed; cursor-agent was not launched"
  local rollback_ok=1
  restore_targets || rollback_ok=0
  if [ "$rollback_ok" = 1 ] && [ "$cursordir_created" = 1 ] && [ -d "$cursor_dir" ]; then
    rm -rf "$cursor_dir" || rollback_ok=0
  fi
  if [ "$rollback_ok" = 1 ]; then
    remove_registered_tmp "$tmp_config" || rollback_ok=0
  fi
  if [ "$rollback_ok" = 1 ]; then
    rm -rf "$txn_dir"
    rm -f "$reg_entry"
    exit "$EX_SETUP"
  fi
  err "rollback also failed; leaving $txn_dir and $reg_entry for recovery or inspection"
  exit "$EX_CLEANUP"
}

# --- lock acquisition with authenticated stale-transaction recovery --------
if ! mkdir "$txn_dir" 2>/dev/null; then
  [ -d "$txn_dir" ] || { err "cannot create transaction dir $txn_dir"; exit "$EX_SETUP"; }
  owner_pid="$(sed -n 's/^pid=//p' "$txn_dir/owner" 2>/dev/null | head -n 1)"
  if [ -n "$owner_pid" ] && kill -0 "$owner_pid" 2>/dev/null; then
    err "workspace is locked by a live profile runner (pid $owner_pid); parallel dispatches need separate workspaces"
    exit "$EX_CONTENTION"
  fi
  journal_nonce="$(sed -n 's/^nonce=//p' "$txn_dir/owner" 2>/dev/null | head -n 1)"
  reg_nonce="$(sed -n 's/^nonce //p' "$reg_entry" 2>/dev/null | head -n 1)"
  if [ -z "$journal_nonce" ] || [ -z "$reg_nonce" ] || [ "$journal_nonce" != "$reg_nonce" ]; then
    err "stale transaction in $txn_dir is not authenticated by runner-owned state ($reg_entry); refusing to touch it — inspect and remove it manually"
    exit "$EX_CLEANUP"
  fi
  err "recovering stale profile transaction in $txn_dir"
  recovery_failed=0
  restore_targets || recovery_failed=1
  if [ "$recovery_failed" = 0 ] && grep -q '^cursordir created$' "$reg_entry" && [ -d "$cursor_dir" ]; then
    rm -rf "$cursor_dir" || recovery_failed=1
  fi
  if [ "$recovery_failed" = 0 ]; then
    remove_registered_tmp "$(sed -n 's/^tmpconfig //p' "$reg_entry" | head -n 1)" || recovery_failed=1
  fi
  if [ "$recovery_failed" != 0 ]; then
    err "stale recovery failed; inspect $txn_dir manually"
    exit "$EX_CLEANUP"
  fi
  rm -rf "$txn_dir" || { err "failed to clear recovered transaction dir"; exit "$EX_CLEANUP"; }
  rm -f "$reg_entry"
  mkdir "$txn_dir" 2>/dev/null || { err "workspace was relocked during recovery"; exit "$EX_CONTENTION"; }
fi
nonce="$(od -An -N16 -tx1 /dev/urandom | tr -d ' \n')" || { rm -rf "$txn_dir"; err "cannot generate nonce"; exit "$EX_SETUP"; }
{ echo "pid=$$"; echo "nonce=$nonce"; } > "$txn_dir/owner" || setup_fail
mkdir -p "$reg_dir" || setup_fail
{ echo "workspace $workspace"; echo "nonce $nonce"; } > "$reg_entry" || setup_fail
mkdir "$backup_dir" || setup_fail

# --- snapshot --------------------------------------------------------------
if [ -L "$cursor_dir" ] || { [ -e "$cursor_dir" ] && [ ! -d "$cursor_dir" ]; }; then
  err "$cursor_dir exists but is not a regular directory; refusing"
  setup_fail
fi
if [ -d "$cursor_dir" ]; then
  echo "cursordir preexisting" >> "$reg_entry" || setup_fail
else
  cursordir_created=1
  echo "cursordir created" >> "$reg_entry" || setup_fail
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
# cli.json is the profile's canonical permissions object; the global config
# Cursor requires is derived from it here, so the two can never drift.
tmp_config="$(mktemp -d "${TMPDIR:-/tmp}/cursor-profile.XXXXXXXX")" || setup_fail
echo "tmpconfig $tmp_config" >> "$reg_entry" || setup_fail
jq '{version: 1} + .' "$profile_dir/cli.json" > "$tmp_config/cli-config.json" || setup_fail

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
restore_targets || cleanup_status=1
if [ "$cursordir_created" = 1 ] && [ -d "$cursor_dir" ]; then
  rm -rf "$cursor_dir" || cleanup_status=1
fi
remove_registered_tmp "$tmp_config" || cleanup_status=1
if [ "$cleanup_status" = 0 ]; then
  rm -rf "$txn_dir" || cleanup_status=1
  [ "$cleanup_status" = 0 ] && rm -f "$reg_entry"
fi
if [ "$cleanup_status" != 0 ]; then
  err "leaving $txn_dir and $reg_entry for inspection and stale recovery"
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
