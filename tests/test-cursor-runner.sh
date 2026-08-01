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
    echo "global_config_md5=$(md5sum < "$CURSOR_CONFIG_DIR/cli-config.json" | cut -d' ' -f1)"
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

# Fault-injection cp: passes through to the real cp except at two env-gated
# points the rollback-failure test (t13) uses; other tests are unaffected.
cat > "$FAKE_BIN/cp" <<'FAKE'
#!/usr/bin/env bash
if [ "${FAKE_CP_FAIL:-}" = 1 ]; then
  case "$1" in
    */profiles/github-pr-reviewer/sandbox.json) echo "cp: injected install failure" >&2; exit 1 ;;
    */.cursor-profile-txn/backup/*) echo "cp: injected restore failure" >&2; exit 1 ;;
  esac
fi
exec /bin/cp "$@"
FAKE
chmod +x "$FAKE_BIN/cp" || exit 1
export PATH="$FAKE_BIN:$PATH"

# Hermetic registry root: the runner's recovery authentication state.
export CURSOR_PROFILE_STATE_DIR="$TMP/state"

profile_cli_md5="$(md5 "$PROFILE_DIR/cli.json")"
profile_sandbox_md5="$(md5 "$PROFILE_DIR/sandbox.json")"

obs() { sed -n "s/^$2=//p" "$1" | head -n 1; }

# --- test 0: global config is derived from cli.json, never a second copy ---
t=t0
if [ -e "$PROFILE_DIR/cli-config.json" ]; then
  fail "$t: profile ships a cli-config.json copy; cli.json is the single source"
else
  pass "$t cli.json is the only permissions source in the profile"
fi
derived_config_md5="$(jq '{version: 1} + .' "$PROFILE_DIR/cli.json" | md5sum | cut -d' ' -f1)"

# --- test 1: success with no pre-existing Cursor config --------------------
t=t1
ws="$TMP/$t"; mkdir -p "$ws" || exit 1
out="$TMP/$t.obs"
rc=0
FAKE_OUT="$out" "$RUNNER" --workspace "$ws" --profile github-pr-reviewer \
  -- -p --trust "task" > "$TMP/$t.stdout" 2> "$TMP/$t.stderr" || rc=$?
[ "$rc" -eq 0 ] || fail "$t: exit $rc (want 0)"
[ "$(obs "$out" ws_cli.json_md5)" = "$profile_cli_md5" ] || fail "$t: child did not see profile cli.json"
[ "$(obs "$out" ws_sandbox.json_md5)" = "$profile_sandbox_md5" ] || fail "$t: child did not see profile sandbox.json"
[ "$(obs "$out" global_config)" = "present" ] || fail "$t: child did not see temp cli-config.json"
[ "$(obs "$out" global_config_md5)" = "$derived_config_md5" ] || fail "$t: temp cli-config.json is not derived from cli.json"
[ "$(obs "$out" cwd)" = "$(cd "$ws" && pwd -P)" ] || fail "$t: child cwd was not the workspace"
[ "$(obs "$out" args)" = "-p --trust task" ] || fail "$t: forwarded args mangled: $(obs "$out" args)"
grep -q "fake-cursor-result" "$TMP/$t.stdout" || fail "$t: child stdout not preserved"
[ ! -e "$ws/.cursor" ] || fail "$t: created .cursor dir not removed"
[ ! -e "$ws/.cursor-profile-txn" ] || fail "$t: transaction dir not removed"
cfg="$(obs "$out" config_dir)"
[ -n "$cfg" ] && [ ! -e "$cfg" ] || fail "$t: temp config dir not removed"
pass "$t success + full cleanup"

# --- test 2: pre-existing files restored byte-exact with modes -------------
t=t2
ws="$TMP/$t"; mkdir -p "$ws/.cursor" || exit 1
printf 'user cli config %s\n' "$$" > "$ws/.cursor/cli.json"
printf 'user sandbox config\n' > "$ws/.cursor/sandbox.json"
chmod 600 "$ws/.cursor/cli.json"
chmod 640 "$ws/.cursor/sandbox.json"
cp "$ws/.cursor/cli.json" "$TMP/$t.cli.expected" || exit 1
cp "$ws/.cursor/sandbox.json" "$TMP/$t.sandbox.expected" || exit 1
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
ws="$TMP/$t"; mkdir -p "$ws/.cursor" || exit 1
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
ws="$TMP/$t"; mkdir -p "$ws/.cursor" || exit 1
ln -s /etc/hostname "$ws/.cursor/cli.json" || exit 1
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
ws="$TMP/$t"; mkdir -p "$ws" "$TMP/$t-elsewhere" || exit 1
ln -s "$TMP/$t-elsewhere" "$ws/.cursor" || exit 1
rc=0
FAKE_TOUCH="$ws/launched" "$RUNNER" --workspace "$ws" --profile github-pr-reviewer -- -p "x" \
  > /dev/null 2>&1 || rc=$?
[ "$rc" -eq 71 ] || fail "$t: exit $rc (want 71)"
[ ! -e "$ws/launched" ] || fail "$t: launched despite symlinked .cursor"
[ -L "$ws/.cursor" ] || fail "$t: symlinked .cursor disturbed"
pass "$t symlinked .cursor dir refused"

# --- test 6: termination signal forwarded, cleanup runs --------------------
t=t6
ws="$TMP/$t"; mkdir -p "$ws/.cursor" || exit 1
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
ws="$TMP/$t"; mkdir -p "$ws" || exit 1
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
ws="$TMP/$t"; mkdir -p "$ws/.cursor" || exit 1
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
ws="$TMP/$t"; mkdir -p "$ws/.cursor" || exit 1
txn="$ws/.cursor-profile-txn"; mkdir -p "$txn/backup" || exit 1
# The stale tmpconfig must sit where the runner's own mktemp would have put
# it — recovery refuses to delete anything else.
stale_cfg="$(mktemp -d "${TMPDIR:-/tmp}/cursor-profile.XXXXXXXX")" || exit 1
printf 'stale leftover\n' > "$stale_cfg/cli-config.json"
printf 'original cli\n' > "$txn/backup/cli.json"
cp "$PROFILE_DIR/cli.json" "$ws/.cursor/cli.json" || exit 1   # crashed run left profile installed
cp "$PROFILE_DIR/sandbox.json" "$ws/.cursor/sandbox.json" || exit 1
{
  echo "file cli.json present 600"
  echo "file sandbox.json absent"
} > "$txn/manifest"
sleep 0.01 & dead_pid=$!; wait "$dead_pid" 2>/dev/null   # a real, definitely-dead pid
{ echo "pid=$dead_pid"; echo "nonce=cafe$t"; } > "$txn/owner"
# The registry entry outside the workspace is what authenticates the journal
# and carries the removal-directing facts.
ws_key="$(printf '%s' "$(cd "$ws" && pwd -P)" | md5sum | cut -d' ' -f1)"
mkdir -p "$CURSOR_PROFILE_STATE_DIR" || exit 1
{
  echo "workspace $ws"
  echo "nonce cafe$t"
  echo "cursordir preexisting"
  echo "tmpconfig $stale_cfg"
} > "$CURSOR_PROFILE_STATE_DIR/$ws_key"
rc=0
"$RUNNER" --workspace "$ws" --profile github-pr-reviewer -- -p "x" > /dev/null 2>&1 || rc=$?
[ "$rc" -eq 0 ] || fail "$t: exit $rc (want 0)"
[ ! -e "$CURSOR_PROFILE_STATE_DIR/$ws_key" ] || fail "$t: registry entry not cleared after recovery + clean run"
[ "$(cat "$ws/.cursor/cli.json")" = "original cli" ] || fail "$t: stale cli.json not recovered"
[ "$(mode_of "$ws/.cursor/cli.json")" = "600" ] || fail "$t: recovered cli.json mode wrong"
[ ! -e "$ws/.cursor/sandbox.json" ] || fail "$t: stale sandbox.json not removed"
[ ! -e "$stale_cfg" ] || fail "$t: stale temp config dir not removed"
[ ! -e "$txn" ] || fail "$t: transaction dir not removed after recovery"
pass "$t stale transaction recovered, then normal run"

# --- test 9b: hostile stale manifest fails closed --------------------------
# A prepared checkout can pre-seed the transaction journal; without a
# matching runner-owned registry entry, recovery refuses it wholesale —
# traversal names and out-of-root deletion targets never even get parsed.
t=t9b
ws="$TMP/$t"; mkdir -p "$ws/.cursor" || exit 1
txn="$ws/.cursor-profile-txn"; mkdir -p "$txn/backup" || exit 1
decoy="$TMP/$t-decoy"; mkdir -p "$decoy" || exit 1
printf 'precious\n' > "$decoy/keep"
printf 'attacker payload\n' > "$txn/backup/cli.json"
{
  echo "cursordir preexisting"
  echo "file ../outside present 644"
  echo "file cli.json present 644"
  echo "tmpconfig $decoy"
} > "$txn/manifest"
sleep 0.01 & dead_pid=$!; wait "$dead_pid" 2>/dev/null
echo "pid=$dead_pid" > "$txn/owner"
rc=0
FAKE_TOUCH="$ws/launched" "$RUNNER" --workspace "$ws" --profile github-pr-reviewer -- -p "x" \
  > /dev/null 2>&1 || rc=$?
[ "$rc" -eq 70 ] || fail "$t: exit $rc (want 70 = fail closed)"
[ ! -e "$ws/launched" ] || fail "$t: launched despite hostile stale manifest"
[ ! -e "$ws/outside" ] || fail "$t: traversal manifest name escaped .cursor"
[ -f "$decoy/keep" ] || fail "$t: out-of-root tmpconfig target was deleted"
[ -e "$txn" ] || fail "$t: refused transaction dir should be left for inspection"
pass "$t hostile stale manifest refused, targets intact"

# --- test 10: argument validation ------------------------------------------
t=t10
rc=0; "$RUNNER" --profile github-pr-reviewer > /dev/null 2>&1 || rc=$?
[ "$rc" -eq 2 ] || fail "$t: missing workspace exit $rc (want 2)"
rc=0; "$RUNNER" --workspace relative/path --profile github-pr-reviewer > /dev/null 2>&1 || rc=$?
[ "$rc" -eq 2 ] || fail "$t: relative workspace exit $rc (want 2)"
ws="$TMP/$t"; mkdir -p "$ws" || exit 1
rc=0; "$RUNNER" --workspace "$ws" --profile no-such-profile > /dev/null 2>&1 || rc=$?
[ "$rc" -eq 2 ] || fail "$t: unknown profile exit $rc (want 2)"
pass "$t argument validation"

# --- test 11: child arguments are allowlisted ------------------------------
t=t11
ws="$TMP/$t"; mkdir -p "$ws" || exit 1
for bad in --force --yolo --auto-review --approve-mcps --sandbox --sandbox=disabled \
  --workspace -w --config-dir=/elsewhere --add-dir --plugin-dir --resume=abc --continue \
  --endpoint=http://example.invalid; do
  rc=0
  FAKE_TOUCH="$ws/launched" "$RUNNER" --workspace "$ws" --profile github-pr-reviewer \
    -- -p "$bad" "task" > /dev/null 2>&1 || rc=$?
  [ "$rc" -eq 2 ] || fail "$t: $bad exit $rc (want 2)"
done
rc=0
FAKE_TOUCH="$ws/launched-sep" "$RUNNER" --workspace "$ws" --profile github-pr-reviewer \
  -- -p --add-dir "$ws" "task" > /dev/null 2>&1 || rc=$?
[ "$rc" -eq 2 ] || fail "$t: separated --add-dir value exit $rc (want 2)"
[ ! -e "$ws/launched" ] && [ ! -e "$ws/launched-sep" ] || fail "$t: launched despite disallowed flag"
[ ! -e "$ws/.cursor-profile-txn" ] || fail "$t: rejection should precede locking"
rc=0
FAKE_TOUCH="$ws/launched-ok" "$RUNNER" --workspace "$ws" --profile github-pr-reviewer \
  -- -p --output-format json --model default-model --trust "task" > /dev/null 2>&1 || rc=$?
[ "$rc" -eq 0 ] || fail "$t: allowlisted argument set exit $rc (want 0)"
[ -e "$ws/launched-ok" ] || fail "$t: allowlisted argument set did not launch"
pass "$t child arguments allowlisted (separated and = forms rejected)"

# --- test 12: unauthenticated journal cannot direct removals ---------------
# Owner spec: pre-seed `cursordir created` and a same-pattern temp path;
# both unrelated sentinels must survive and no agent may launch.
t=t12
ws="$TMP/$t"; mkdir -p "$ws/.cursor" || exit 1
printf 'sentinel\n' > "$ws/.cursor/user-file"
txn="$ws/.cursor-profile-txn"; mkdir -p "$txn/backup" || exit 1
lure="$(mktemp -d "${TMPDIR:-/tmp}/cursor-profile.XXXXXXXX")" || exit 1
printf 'sentinel\n' > "$lure/keep"
{
  echo "cursordir created"
  echo "tmpconfig $lure"
} > "$txn/manifest"
sleep 0.01 & dead_pid=$!; wait "$dead_pid" 2>/dev/null
echo "pid=$dead_pid" > "$txn/owner"      # no nonce, no registry entry
rc=0
FAKE_TOUCH="$ws/launched" "$RUNNER" --workspace "$ws" --profile github-pr-reviewer -- -p "x" \
  > /dev/null 2>&1 || rc=$?
[ "$rc" -eq 70 ] || fail "$t: exit $rc (want 70 = fail closed)"
[ ! -e "$ws/launched" ] || fail "$t: launched under an unauthenticated journal"
[ -f "$ws/.cursor/user-file" ] || fail "$t: unrelated .cursor directory was removed"
[ -f "$lure/keep" ] || fail "$t: same-pattern temp path was removed"
[ -e "$txn" ] || fail "$t: unauthenticated journal must be left untouched"
rm -rf "$lure"
pass "$t unauthenticated journal cannot direct removals"

# --- test 13: setup failure + failed rollback retains the journal ----------
# Injected: install of the second policy file fails after the first is
# installed, then restoration of the first fails; the runner must report the
# rollback failure and keep the journal/backup instead of deleting them.
t=t13
ws="$TMP/$t"; mkdir -p "$ws/.cursor" || exit 1
printf 'rollback original\n' > "$ws/.cursor/cli.json"
rc=0
FAKE_CP_FAIL=1 FAKE_TOUCH="$ws/launched" "$RUNNER" --workspace "$ws" --profile github-pr-reviewer \
  -- -p "x" > /dev/null 2> "$TMP/$t.err" || rc=$?
[ "$rc" -eq 70 ] || fail "$t: exit $rc (want 70 = cleanup failure)"
[ ! -e "$ws/launched" ] || fail "$t: launched despite setup failure"
[ -f "$ws/.cursor-profile-txn/backup/cli.json" ] || fail "$t: backup not retained after failed rollback"
[ -f "$ws/.cursor-profile-txn/manifest" ] || fail "$t: manifest not retained after failed rollback"
grep -q "rollback also failed" "$TMP/$t.err" || fail "$t: rollback failure not reported"
pass "$t failed rollback reported, journal and backup retained"

# ---------------------------------------------------------------------------
if [ "$failures" -gt 0 ]; then
  echo "$failures test failure(s)" >&2
  exit 1
fi
echo "all cursor-runner tests passed"
