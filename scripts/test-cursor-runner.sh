#!/usr/bin/env bash
# Hermetic lifecycle tests for skills/cursor-agent/scripts/run-profiled.sh.
# Uses a fake cursor-agent on PATH; no network, no real CLI, no mutation of
# installed user skills or global configuration.
set -u -o pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)" || exit 1
RUNNER="$REPO/skills/cursor-agent/scripts/run-profiled.sh"
PROFILE_DIR="$REPO/skills/cursor-agent/profiles/github-pr-reviewer"

TMP="$(mktemp -d "${TMPDIR:-/tmp}/test-cursor-runner.XXXXXX")" || exit 1
trap 'rm -rf "$TMP"' EXIT

failures=0
fail() { echo "FAIL: $*" >&2; failures=$((failures + 1)); }
pass() { echo "ok: $*"; }

md5() { md5sum < "$1" | cut -d' ' -f1; }
mode_of() { stat -c %a "$1"; }

wait_for_file() {
  local f="$1" n=0
  while [ ! -e "$f" ] && [ "$n" -lt 100 ]; do
    sleep 0.1
    n=$((n + 1))
  done
  [ -e "$f" ]
}

# --- fake cursor-agent -----------------------------------------------------
FAKE_BIN="$TMP/bin"
mkdir -p "$FAKE_BIN" || exit 1
cat > "$FAKE_BIN/cursor-agent" <<'FAKE'
#!/usr/bin/env bash
{
  echo "cwd=$PWD"
  echo "config_dir=${CURSOR_CONFIG_DIR:-}"
  echo "args=$*"
  for f in cli.json sandbox.json; do
    if [ -f ".cursor/$f" ]; then
      echo "ws_${f}_md5=$(md5sum < ".cursor/$f" | cut -d' ' -f1)"
    else
      echo "ws_${f}_md5=absent"
    fi
  done
  if [ -f "${CURSOR_CONFIG_DIR:-/nonexistent}/cli-config.json" ]; then
    echo "global_config=present"
  else
    echo "global_config=absent"
  fi
} >> "${FAKE_OUT:-/dev/null}"
if [ -n "${FAKE_TOUCH:-}" ]; then touch "$FAKE_TOUCH"; fi
if [ -n "${FAKE_SLEEP:-}" ]; then sleep "$FAKE_SLEEP"; fi
echo "fake-cursor-result"
exit "${FAKE_EXIT:-0}"
FAKE
chmod +x "$FAKE_BIN/cursor-agent" || exit 1
export PATH="$FAKE_BIN:$PATH"

profile_cli_md5="$(md5 "$PROFILE_DIR/cli.json")"
profile_sandbox_md5="$(md5 "$PROFILE_DIR/sandbox.json")"

obs() { sed -n "s/^$2=//p" "$1" | head -n 1; }

# --- test 1: success with no pre-existing Cursor config --------------------
t=t1
ws="$TMP/$t"; mkdir -p "$ws"
out="$TMP/$t.obs"
rc=0
FAKE_OUT="$out" "$RUNNER" --workspace "$ws" --profile github-pr-reviewer \
  -- -p --trust "task" > "$TMP/$t.stdout" 2> "$TMP/$t.stderr" || rc=$?
[ "$rc" -eq 0 ] || fail "$t: exit $rc (want 0)"
[ "$(obs "$out" ws_cli.json_md5)" = "$profile_cli_md5" ] || fail "$t: child did not see profile cli.json"
[ "$(obs "$out" ws_sandbox.json_md5)" = "$profile_sandbox_md5" ] || fail "$t: child did not see profile sandbox.json"
[ "$(obs "$out" global_config)" = "present" ] || fail "$t: child did not see temp cli-config.json"
[ "$(obs "$out" cwd)" = "$(cd "$ws" && pwd -P)" ] || fail "$t: child cwd was not the workspace"
[ "$(obs "$out" args)" = "-p --trust task" ] || fail "$t: forwarded args mangled: $(obs "$out" args)"
grep -q "fake-cursor-result" "$TMP/$t.stdout" || fail "$t: child stdout not preserved"
[ ! -e "$ws/.cursor" ] || fail "$t: created .cursor dir not removed"
[ ! -e "$ws/.cursor-profile-txn" ] || fail "$t: transaction dir not removed"
cfg="$(obs "$out" config_dir)"
[ -n "$cfg" ] && [ ! -e "$cfg" ] || fail "$t: temp config dir not removed"
[ "$failures" -eq 0 ] && pass "$t success + full cleanup"

# --- test 2: pre-existing files restored byte-exact with modes -------------
t=t2
ws="$TMP/$t"; mkdir -p "$ws/.cursor"
printf 'user cli config %s\n' "$$" > "$ws/.cursor/cli.json"
printf 'user sandbox config\n' > "$ws/.cursor/sandbox.json"
chmod 600 "$ws/.cursor/cli.json"
chmod 640 "$ws/.cursor/sandbox.json"
cp "$ws/.cursor/cli.json" "$TMP/$t.cli.expected"
cp "$ws/.cursor/sandbox.json" "$TMP/$t.sandbox.expected"
out="$TMP/$t.obs"
rc=0
FAKE_OUT="$out" "$RUNNER" --workspace "$ws" --profile github-pr-reviewer -- -p "x" \
  > /dev/null 2>&1 || rc=$?
[ "$rc" -eq 0 ] || fail "$t: exit $rc (want 0)"
[ "$(obs "$out" ws_cli.json_md5)" = "$profile_cli_md5" ] || fail "$t: profile not installed during run"
cmp -s "$ws/.cursor/cli.json" "$TMP/$t.cli.expected" || fail "$t: cli.json not restored byte-exact"
cmp -s "$ws/.cursor/sandbox.json" "$TMP/$t.sandbox.expected" || fail "$t: sandbox.json not restored byte-exact"
[ "$(mode_of "$ws/.cursor/cli.json")" = "600" ] || fail "$t: cli.json mode not restored"
[ "$(mode_of "$ws/.cursor/sandbox.json")" = "640" ] || fail "$t: sandbox.json mode not restored"
[ -d "$ws/.cursor" ] || fail "$t: pre-existing .cursor dir removed"
[ ! -e "$ws/.cursor-profile-txn" ] || fail "$t: transaction dir not removed"
pass "$t pre-existing files restored (content + mode)"

# --- test 3: child failure propagates, cleanup still runs ------------------
t=t3
ws="$TMP/$t"; mkdir -p "$ws/.cursor"
printf 'keep me\n' > "$ws/.cursor/cli.json"
rc=0
FAKE_EXIT=7 "$RUNNER" --workspace "$ws" --profile github-pr-reviewer -- -p "x" \
  > /dev/null 2>&1 || rc=$?
[ "$rc" -eq 7 ] || fail "$t: exit $rc (want child's 7)"
[ "$(cat "$ws/.cursor/cli.json")" = "keep me" ] || fail "$t: cli.json not restored after child failure"
[ ! -e "$ws/.cursor/sandbox.json" ] || fail "$t: absent sandbox.json not removed after child failure"
[ ! -e "$ws/.cursor-profile-txn" ] || fail "$t: transaction dir not removed"
pass "$t child failure propagates with cleanup"

# --- test 4: setup failure (symlinked policy file) prevents launch ---------
t=t4
ws="$TMP/$t"; mkdir -p "$ws/.cursor"
ln -s /etc/hostname "$ws/.cursor/cli.json"
rc=0
FAKE_TOUCH="$ws/launched" "$RUNNER" --workspace "$ws" --profile github-pr-reviewer -- -p "x" \
  > /dev/null 2>&1 || rc=$?
[ "$rc" -eq 71 ] || fail "$t: exit $rc (want 71)"
[ ! -e "$ws/launched" ] || fail "$t: cursor-agent launched despite setup failure"
[ -L "$ws/.cursor/cli.json" ] || fail "$t: symlink target disturbed"
[ "$(readlink "$ws/.cursor/cli.json")" = "/etc/hostname" ] || fail "$t: symlink rewritten"
[ ! -e "$ws/.cursor-profile-txn" ] || fail "$t: transaction dir not removed"
pass "$t symlinked policy file refused before launch"

# --- test 5: .cursor itself non-regular is refused -------------------------
t=t5
ws="$TMP/$t"; mkdir -p "$ws" "$TMP/$t-elsewhere"
ln -s "$TMP/$t-elsewhere" "$ws/.cursor"
rc=0
FAKE_TOUCH="$ws/launched" "$RUNNER" --workspace "$ws" --profile github-pr-reviewer -- -p "x" \
  > /dev/null 2>&1 || rc=$?
[ "$rc" -eq 71 ] || fail "$t: exit $rc (want 71)"
[ ! -e "$ws/launched" ] || fail "$t: launched despite symlinked .cursor"
[ -L "$ws/.cursor" ] || fail "$t: symlinked .cursor disturbed"
pass "$t symlinked .cursor dir refused"

# --- test 6: termination signal forwarded, cleanup runs --------------------
t=t6
ws="$TMP/$t"; mkdir -p "$ws/.cursor"
printf 'sig original\n' > "$ws/.cursor/cli.json"
out="$TMP/$t.obs"
FAKE_OUT="$out" FAKE_SLEEP=30 "$RUNNER" --workspace "$ws" --profile github-pr-reviewer -- -p "x" \
  > /dev/null 2>&1 &
runner_pid=$!
wait_for_file "$out" || fail "$t: child never launched"
kill -TERM "$runner_pid"
rc=0
wait "$runner_pid" || rc=$?
[ "$rc" -eq 143 ] || fail "$t: exit $rc (want 143 = TERM)"
[ "$(cat "$ws/.cursor/cli.json")" = "sig original" ] || fail "$t: cli.json not restored after signal"
[ ! -e "$ws/.cursor/sandbox.json" ] || fail "$t: installed sandbox.json left after signal"
[ ! -e "$ws/.cursor-profile-txn" ] || fail "$t: transaction dir not removed after signal"
cfg="$(obs "$out" config_dir)"
[ -n "$cfg" ] && [ ! -e "$cfg" ] || fail "$t: temp config dir not removed after signal"
pass "$t signal forwarded, workspace restored"

# --- test 7: same-workspace contention rejected ----------------------------
t=t7
ws="$TMP/$t"; mkdir -p "$ws"
out="$TMP/$t.obs"
FAKE_OUT="$out" FAKE_SLEEP=30 "$RUNNER" --workspace "$ws" --profile github-pr-reviewer -- -p "x" \
  > /dev/null 2>&1 &
runner_pid=$!
wait_for_file "$out" || fail "$t: first runner never launched child"
rc=0
"$RUNNER" --workspace "$ws" --profile github-pr-reviewer -- -p "x" > /dev/null 2>&1 || rc=$?
[ "$rc" -eq 75 ] || fail "$t: second runner exit $rc (want 75)"
kill -TERM "$runner_pid"
wait "$runner_pid" 2>/dev/null
[ ! -e "$ws/.cursor-profile-txn" ] || fail "$t: transaction dir not removed after first runner finished"
pass "$t concurrent same-workspace runner rejected"

# --- test 8: cleanup failure reported even when child succeeds -------------
t=t8
ws="$TMP/$t"; mkdir -p "$ws/.cursor"
printf 'cleanup original\n' > "$ws/.cursor/cli.json"
out="$TMP/$t.obs"
FAKE_OUT="$out" FAKE_SLEEP=3 "$RUNNER" --workspace "$ws" --profile github-pr-reviewer -- -p "x" \
  > /dev/null 2>&1 &
runner_pid=$!
wait_for_file "$out" || fail "$t: child never launched"
rm -f "$ws/.cursor-profile-txn/backup/cli.json"
rc=0
wait "$runner_pid" || rc=$?
[ "$rc" -eq 70 ] || fail "$t: exit $rc (want 70 = cleanup failure)"
[ -e "$ws/.cursor-profile-txn" ] || fail "$t: failed transaction dir should be left for recovery"
pass "$t cleanup failure surfaces as failure"

# --- test 9: stale transaction recovered on next invocation ----------------
t=t9
ws="$TMP/$t"; mkdir -p "$ws/.cursor"
txn="$ws/.cursor-profile-txn"; mkdir -p "$txn/backup"
stale_cfg="$TMP/$t-stale-config"; mkdir -p "$stale_cfg"
printf 'stale leftover\n' > "$stale_cfg/cli-config.json"
printf 'original cli\n' > "$txn/backup/cli.json"
cp "$PROFILE_DIR/cli.json" "$ws/.cursor/cli.json"        # crashed run left profile installed
cp "$PROFILE_DIR/sandbox.json" "$ws/.cursor/sandbox.json"
{
  echo "cursordir preexisting"
  echo "file cli.json present 600"
  echo "file sandbox.json absent"
  echo "tmpconfig $stale_cfg"
} > "$txn/manifest"
sleep 0.01 & dead_pid=$!; wait "$dead_pid" 2>/dev/null   # a real, definitely-dead pid
echo "pid=$dead_pid" > "$txn/owner"
rc=0
"$RUNNER" --workspace "$ws" --profile github-pr-reviewer -- -p "x" > /dev/null 2>&1 || rc=$?
[ "$rc" -eq 0 ] || fail "$t: exit $rc (want 0)"
[ "$(cat "$ws/.cursor/cli.json")" = "original cli" ] || fail "$t: stale cli.json not recovered"
[ "$(mode_of "$ws/.cursor/cli.json")" = "600" ] || fail "$t: recovered cli.json mode wrong"
[ ! -e "$ws/.cursor/sandbox.json" ] || fail "$t: stale sandbox.json not removed"
[ ! -e "$stale_cfg" ] || fail "$t: stale temp config dir not removed"
[ ! -e "$txn" ] || fail "$t: transaction dir not removed after recovery"
pass "$t stale transaction recovered, then normal run"

# --- test 10: argument validation ------------------------------------------
t=t10
rc=0; "$RUNNER" --profile github-pr-reviewer > /dev/null 2>&1 || rc=$?
[ "$rc" -eq 2 ] || fail "$t: missing workspace exit $rc (want 2)"
rc=0; "$RUNNER" --workspace relative/path --profile github-pr-reviewer > /dev/null 2>&1 || rc=$?
[ "$rc" -eq 2 ] || fail "$t: relative workspace exit $rc (want 2)"
ws="$TMP/$t"; mkdir -p "$ws"
rc=0; "$RUNNER" --workspace "$ws" --profile no-such-profile > /dev/null 2>&1 || rc=$?
[ "$rc" -eq 2 ] || fail "$t: unknown profile exit $rc (want 2)"
pass "$t argument validation"

# ---------------------------------------------------------------------------
if [ "$failures" -gt 0 ]; then
  echo "$failures test failure(s)" >&2
  exit 1
fi
echo "all cursor-runner tests passed"
